using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Threading;
using System.Threading.Tasks;

namespace ParleyAI.Providers.Anthropic;

/// <summary>
/// A <see cref="DelegatingHandler"/> that rewrites each outgoing request's full <b>origin</b>
/// (scheme + host + port) to a configured base URL, preserving the path + query, and captures the
/// detail of any non-success response into an <see cref="AsyncLocal{T}"/> for the error mapper.
/// </summary>
/// <remarks>
/// <para>
/// <b>Why an origin rewrite (not <c>HttpClient.BaseAddress</c>):</b> <c>Anthropic.SDK</c> builds
/// absolute request URIs from its own <c>ApiUrlFormat</c> (<c>https://api.anthropic.com/{v}/{ep}</c>)
/// and so ignores <c>HttpClient.BaseAddress</c>. To honor <c>ANTHROPIC_BASE_URL</c> (a host root) we
/// must swap the origin on the wire while keeping the SDK's <c>/v1/messages</c> path — proven with
/// <c>http://localhost:&lt;port&gt;</c> ⇒ <c>http://localhost:&lt;port&gt;/v1/messages</c> (scheme
/// rewrite, no double <c>/v1</c>).
/// </para>
/// <para>
/// <b>Why capture the error here:</b> the SDK's exceptions drop the response headers/body the
/// ParleyAI mapping contract needs (e.g. <c>retry-after</c>,
/// <c>anthropic-ratelimit-requests-remaining</c>). On a non-success response the handler buffers the
/// body (so the SDK can still read it) and stashes <c>(status, headers, body)</c> into the active
/// <see cref="CaptureScope"/> for <see cref="AnthropicErrorMapper"/> to consume in the client's catch.
/// </para>
/// </remarks>
internal sealed class AnthropicOriginRewriteHandler : DelegatingHandler
{
    // A mutable holder is stashed in the AsyncLocal by the CLIENT (the shallow frame) before each
    // call; the handler (a deeper async frame) MUTATES the holder. AsyncLocal values set by a parent
    // flow DOWN to children, and a child's mutation of the shared reference IS visible to the parent
    // — whereas a child REASSIGNING the AsyncLocal would not flow back up. That is why the capture is
    // a holder mutation, not an AsyncLocal assignment.
    private static readonly AsyncLocal<ErrorContextHolder?> Holder = new();

    private readonly string? _scheme;
    private readonly string? _host;
    private readonly int _port;
    private readonly bool _rewrite;

    /// <summary>
    /// Creates the handler. When <paramref name="baseUrl"/> is null/blank the handler is a
    /// pass-through (the SDK default origin applies); otherwise the value MUST be an absolute,
    /// root-only URI (no path/query) or construction throws.
    /// </summary>
    /// <param name="baseUrl">The host-root base URL override, or null for the SDK default.</param>
    /// <exception cref="ArgumentException">
    /// The base URL is present but not an absolute root-only URI.
    /// </exception>
    public AnthropicOriginRewriteHandler(string? baseUrl)
    {
        if (string.IsNullOrWhiteSpace(baseUrl))
        {
            _rewrite = false;
            return;
        }

        Uri origin = ParseRootOnly(baseUrl);
        _scheme = origin.Scheme;
        _host = origin.Host;
        _port = origin.Port;
        _rewrite = true;
    }

    /// <summary>
    /// Establishes a fresh capture scope on the current async flow and returns it. The client calls
    /// this immediately BEFORE issuing the SDK call so the handler (a deeper frame) can write the
    /// captured error into it; the client reads <see cref="CaptureScope.Context"/> in its catch.
    /// </summary>
    internal static CaptureScope BeginCapture()
    {
        var holder = new ErrorContextHolder();
        Holder.Value = holder;
        return new CaptureScope(holder);
    }

    /// <summary>A disposable capture scope; exposes the captured error detail (if any).</summary>
    internal readonly struct CaptureScope : IDisposable
    {
        private readonly ErrorContextHolder _holder;

        internal CaptureScope(ErrorContextHolder holder) => _holder = holder;

        /// <summary>The error detail captured during the scope, or <c>null</c> when none was.</summary>
        public AnthropicErrorContext? Context => _holder.Context;

        /// <summary>Clears the AsyncLocal slot so a captured response is not retained beyond the call.</summary>
        public void Dispose() => Holder.Value = null;
    }

    internal sealed class ErrorContextHolder
    {
        public AnthropicErrorContext? Context { get; set; }
    }

    /// <summary>
    /// Validates that <paramref name="baseUrl"/> is an absolute, root-only URI (scheme+host+port,
    /// no path beyond <c>/</c>, no query, no fragment), returning the parsed origin.
    /// </summary>
    /// <exception cref="ArgumentException">The value is not an absolute root-only URI.</exception>
    internal static Uri ParseRootOnly(string baseUrl)
    {
        if (!Uri.TryCreate(baseUrl, UriKind.Absolute, out Uri? uri))
        {
            throw new ArgumentException(
                $"ANTHROPIC_BASE_URL must be an absolute URI; got '{baseUrl}'.",
                nameof(baseUrl));
        }

        if (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps)
        {
            throw new ArgumentException(
                $"ANTHROPIC_BASE_URL must use the http or https scheme; got '{uri.Scheme}' in '{baseUrl}'.",
                nameof(baseUrl));
        }

        bool hasPath = !string.IsNullOrEmpty(uri.AbsolutePath) && uri.AbsolutePath != "/";
        if (hasPath || !string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment))
        {
            throw new ArgumentException(
                $"ANTHROPIC_BASE_URL must be the host root (scheme+host+port, no path/query); got '{baseUrl}'. " +
                "Unlike OPENAI_BASE_URL, the Anthropic base URL carries no /v1 suffix.",
                nameof(baseUrl));
        }

        return uri;
    }

    /// <inheritdoc />
    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        if (_rewrite && request.RequestUri is { IsAbsoluteUri: true } original)
        {
            var rebuilt = new UriBuilder(original)
            {
                Scheme = _scheme,
                Host = _host,
                Port = _port,
            };
            // Path + query are preserved verbatim (UriBuilder keeps them from the original).
            request.RequestUri = rebuilt.Uri;
        }

        HttpResponseMessage response = await base.SendAsync(request, cancellationToken).ConfigureAwait(false);

        if (!response.IsSuccessStatusCode && Holder.Value is { } holder)
        {
            holder.Context = await CaptureErrorAsync(response, cancellationToken).ConfigureAwait(false);
        }

        return response;
    }

    private static async Task<AnthropicErrorContext> CaptureErrorAsync(
        HttpResponseMessage response,
        CancellationToken cancellationToken)
    {
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        CollectHeaders(response.Headers, headers);
        if (response.Content is not null)
        {
            CollectHeaders(response.Content.Headers, headers);
        }

        string? body = null;
        if (response.Content is not null)
        {
            // Buffer the body so the SDK can still read it after we capture it.
            byte[] bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken).ConfigureAwait(false);
            body = bytes.Length > 0 ? System.Text.Encoding.UTF8.GetString(bytes) : null;

            var buffered = new ByteArrayContent(bytes);
            foreach (KeyValuePair<string, IEnumerable<string>> header in response.Content.Headers)
            {
                buffered.Headers.TryAddWithoutValidation(header.Key, header.Value);
            }

            response.Content = buffered;
        }

        return new AnthropicErrorContext(response.StatusCode, headers, body);
    }

    private static void CollectHeaders(HttpHeaders source, IDictionary<string, string> sink)
    {
        foreach (KeyValuePair<string, IEnumerable<string>> header in source)
        {
            if (!sink.ContainsKey(header.Key))
            {
                foreach (string value in header.Value)
                {
                    sink[header.Key] = value;
                    break;
                }
            }
        }
    }
}

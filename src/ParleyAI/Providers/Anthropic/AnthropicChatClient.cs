using System;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using Anthropic.SDK;
using Anthropic.SDK.Messaging;
using ParleyAI.Abstractions;

namespace ParleyAI.Providers.Anthropic;

/// <summary>
/// The Anthropic implementation of <see cref="IAiChatClient"/>, built over <c>Anthropic.SDK</c>.
/// </summary>
/// <remarks>
/// <para>
/// <b>Base-URL override:</b> the SDK emits absolute <c>https://api.anthropic.com/...</c> URIs and
/// ignores <c>HttpClient.BaseAddress</c>, so an <see cref="AnthropicOriginRewriteHandler"/> on the
/// injected (keyed, singleton-safe) <see cref="HttpClient"/> rewrites the full origin
/// (scheme+host+port) of each request when <see cref="AnthropicChatClientSettings.BaseUrl"/> is
/// present, preserving the SDK's <c>/v1/messages</c> path. When absent the SDK default origin
/// applies — ParleyAI never hardcodes <c>api.anthropic.com</c>. The base URL is validated as a
/// root-only absolute URI at construction.
/// </para>
/// <para>
/// <b>Single retry authority:</b> <c>Anthropic.SDK</c> 5.10.0 adds NO retry layer of its own — a
/// logical call makes exactly ONE HTTP attempt (its <c>RetryInterceptor</c> is an opt-in example
/// type, never wired by default, and is NOT used here). This is verified by the single-attempt test.
/// The standard resilience handler (fn-4.4) is therefore the only retry layer; the AIMD optimizer
/// reacts to the final mapped error.
/// </para>
/// <para>
/// <b>Role mapping:</b> a single leading <see cref="Role.System"/> message is hoisted to the
/// top-level <c>system</c> field; User/Assistant turns map to the SDK message list. A non-leading or
/// repeated system message is rejected with <see cref="ParleyAIErrorCategory.InvalidRequest"/>.
/// </para>
/// </remarks>
public sealed class AnthropicChatClient : IAiChatClient
{
    private readonly AnthropicClient _client;

    /// <summary>
    /// Constructs the client from resolved settings + the keyed transport <see cref="HttpClient"/>
    /// (whose pipeline carries the origin-rewrite handler).
    /// </summary>
    /// <param name="settings">
    /// The resolved connection settings (required API key + optional root-only base URL), already
    /// having applied the ctor &gt; flat-key precedence in the DI layer.
    /// </param>
    /// <param name="httpClient">The keyed, singleton-safe transport <see cref="HttpClient"/>.</param>
    /// <exception cref="ArgumentException">
    /// The API key is missing/blank, or the base URL is present but not a root-only absolute URI.
    /// </exception>
    public AnthropicChatClient(AnthropicChatClientSettings settings, HttpClient httpClient)
    {
        ArgumentNullException.ThrowIfNull(settings);
        ArgumentNullException.ThrowIfNull(httpClient);

        if (string.IsNullOrWhiteSpace(settings.ApiKey))
        {
            throw new ArgumentException(
                "An Anthropic API key is required (ctor override or the flat ANTHROPIC_API_KEY config key); there is no SDK-default key.",
                nameof(settings));
        }

        // Validate the base URL eagerly at construction (root-only). The actual origin rewrite is
        // performed by the handler already attached to the keyed HttpClient pipeline (DI layer); we
        // re-validate here so the contract holds for the direct-ctor (test/advanced) path too.
        if (!string.IsNullOrWhiteSpace(settings.BaseUrl))
        {
            _ = AnthropicOriginRewriteHandler.ParseRootOnly(settings.BaseUrl);
        }

        _client = new AnthropicClient(new APIAuthentication(settings.ApiKey), httpClient);
    }

    /// <summary>Test/advanced seam: inject a pre-built <see cref="AnthropicClient"/> directly.</summary>
    internal AnthropicChatClient(AnthropicClient client) =>
        _client = client ?? throw new ArgumentNullException(nameof(client));

    /// <inheritdoc />
    public async Task<ChatResponse> CompleteChatAsync(
        ChatRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);

        // Validation + role mapping (throws InvalidRequest for the single-leading-System rule).
        MessageParameters parameters = AnthropicMessageMapper.MapRequest(request);

        // Establish a capture scope on THIS async frame so the rewrite handler (a deeper frame) can
        // record the failed response detail back into it (the SDK's exceptions drop it).
        using AnthropicOriginRewriteHandler.CaptureScope capture = AnthropicOriginRewriteHandler.BeginCapture();
        try
        {
            MessageResponse response =
                await _client.Messages.GetClaudeMessageAsync(parameters, cancellationToken)
                    .ConfigureAwait(false);
            return AnthropicMessageMapper.MapResponse(response);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // COOPERATIVE cancellation (the caller's token fired) propagates un-wrapped.
            throw;
        }
        catch (OperationCanceledException ex)
        {
            // A TaskCanceledException NOT driven by the caller token is a TRANSPORT TIMEOUT
            // (e.g. HttpClient.Timeout / SocketsHttpHandler) — map it to Transient, not cancellation.
            throw AnthropicErrorMapper.MapTimeout(ex);
        }
        catch (ParleyAIException)
        {
            // Mapping/validation already produced a neutral exception — surface as-is.
            throw;
        }
        catch (Exception ex)
        {
            // The rewrite handler captured the response detail (status/headers/body) the SDK's
            // exceptions drop; map with full fidelity. A null capture ⇒ a transport-level failure.
            throw AnthropicErrorMapper.Map(ex, capture.Context);
        }
    }
}

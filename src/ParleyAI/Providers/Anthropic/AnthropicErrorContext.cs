using System.Collections.Generic;
using System.Net;

namespace ParleyAI.Providers.Anthropic;

/// <summary>
/// The HTTP error detail captured by <see cref="AnthropicOriginRewriteHandler"/> for the most
/// recent non-success response on the current async flow.
/// </summary>
/// <remarks>
/// The <c>Anthropic.SDK</c> wraps failures in exceptions (<c>RateLimitsExceeded</c>,
/// <c>AuthenticationException</c>, <c>HttpRequestException</c>) that do NOT carry the response
/// headers (notably <c>retry-after</c> and <c>anthropic-ratelimit-requests-remaining</c>) needed by
/// the ParleyAI mapping contract. The handler captures them so
/// <see cref="AnthropicErrorMapper"/> has full fidelity regardless of which exception type the SDK
/// surfaces.
/// </remarks>
internal sealed class AnthropicErrorContext
{
    public AnthropicErrorContext(
        HttpStatusCode statusCode,
        IReadOnlyDictionary<string, string> headers,
        string? body)
    {
        StatusCode = statusCode;
        Headers = headers;
        Body = body;
    }

    /// <summary>The HTTP status of the failed response.</summary>
    public HttpStatusCode StatusCode { get; }

    /// <summary>The response headers (case-insensitive), flattened to the first value per name.</summary>
    public IReadOnlyDictionary<string, string> Headers { get; }

    /// <summary>The response body, when readable.</summary>
    public string? Body { get; }
}

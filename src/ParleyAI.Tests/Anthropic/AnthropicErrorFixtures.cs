using System.Collections.Generic;
using System.Net;
using System.Net.Http;

namespace ParleyAI.Tests.Anthropic;

/// <summary>
/// Named Anthropic error fixtures (status + headers + body) backing the error→category mapping
/// contract tests. Names match the spec: <c>anthropic-429-tokens</c>, <c>anthropic-429-requests</c>,
/// <c>anthropic-401</c>, <c>anthropic-400</c>, <c>anthropic-529</c>.
/// </summary>
internal static class AnthropicErrorFixtures
{
    /// <summary>
    /// 429 <c>rate_limit_error</c> with <c>anthropic-ratelimit-tokens-remaining: 0</c> ⇒ TokenLimit.
    /// </summary>
    public static HttpResponseMessage Anthropic429Tokens() => FakeHttpMessageHandler.Error(
        HttpStatusCode.TooManyRequests,
        "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"This request would exceed your tokens per minute rate limit\"}}",
        new[]
        {
            new KeyValuePair<string, string>("anthropic-ratelimit-tokens-remaining", "0"),
            new KeyValuePair<string, string>("anthropic-ratelimit-requests-remaining", "42"),
            new KeyValuePair<string, string>("retry-after", "8"),
        });

    /// <summary>
    /// 429 <c>rate_limit_error</c> with <c>anthropic-ratelimit-requests-remaining: 0</c> (tokens still
    /// available, no token signal in the body) ⇒ RateLimit.
    /// </summary>
    public static HttpResponseMessage Anthropic429Requests() => FakeHttpMessageHandler.Error(
        HttpStatusCode.TooManyRequests,
        "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"Number of requests has exceeded your per-minute rate limit\"}}",
        new[]
        {
            new KeyValuePair<string, string>("anthropic-ratelimit-requests-remaining", "0"),
            new KeyValuePair<string, string>("anthropic-ratelimit-tokens-remaining", "5000"),
            new KeyValuePair<string, string>("retry-after", "3"),
        });

    /// <summary>401 <c>authentication_error</c> ⇒ Authentication.</summary>
    public static HttpResponseMessage Anthropic401() => FakeHttpMessageHandler.Error(
        HttpStatusCode.Unauthorized,
        "{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"invalid x-api-key\"}}");

    /// <summary>400 <c>invalid_request_error</c> ⇒ InvalidRequest.</summary>
    public static HttpResponseMessage Anthropic400() => FakeHttpMessageHandler.Error(
        HttpStatusCode.BadRequest,
        "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"max_tokens is required\"}}");

    /// <summary>529 <c>overloaded_error</c> ⇒ Transient.</summary>
    public static HttpResponseMessage Anthropic529() => FakeHttpMessageHandler.Error(
        (HttpStatusCode)529,
        "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}");

    /// <summary>500 <c>api_error</c> ⇒ Transient.</summary>
    public static HttpResponseMessage Anthropic500() => FakeHttpMessageHandler.Error(
        HttpStatusCode.InternalServerError,
        "{\"type\":\"error\",\"error\":{\"type\":\"api_error\",\"message\":\"internal server error\"}}");
}

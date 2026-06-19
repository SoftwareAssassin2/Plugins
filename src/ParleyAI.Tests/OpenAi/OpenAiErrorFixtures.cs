using System.Collections.Generic;
using System.Net;
using System.Net.Http;

namespace ParleyAI.Tests.OpenAi;

/// <summary>
/// Named OpenAI error fixtures (status + headers + body) backing the error→category mapping
/// contract tests. Names match the spec: <c>openai-429-tpm</c>, <c>openai-429-rpm</c>,
/// <c>openai-401</c>, <c>openai-400</c>, <c>openai-500</c>.
/// </summary>
internal static class OpenAiErrorFixtures
{
    /// <summary>429 with <c>x-ratelimit-remaining-tokens: 0</c> + a TPM body ⇒ TokenLimit.</summary>
    public static HttpResponseMessage Openai429Tpm() => FakeHttpMessageHandler.Error(
        HttpStatusCode.TooManyRequests,
        "{\"error\":{\"message\":\"Rate limit reached: Limit 10000, used 10000 tokens per min\",\"code\":\"rate_limit_exceeded\"}}",
        new[]
        {
            new KeyValuePair<string, string>("x-ratelimit-remaining-tokens", "0"),
            new KeyValuePair<string, string>("x-ratelimit-remaining-requests", "42"),
            new KeyValuePair<string, string>("Retry-After", "8"),
        });

    /// <summary>429 with requests remaining = 0 (no token signal) ⇒ RateLimit.</summary>
    public static HttpResponseMessage Openai429Rpm() => FakeHttpMessageHandler.Error(
        HttpStatusCode.TooManyRequests,
        "{\"error\":{\"message\":\"Rate limit reached for requests\",\"code\":\"rate_limit_exceeded\"}}",
        new[]
        {
            new KeyValuePair<string, string>("x-ratelimit-remaining-requests", "0"),
            new KeyValuePair<string, string>("x-ratelimit-remaining-tokens", "5000"),
            new KeyValuePair<string, string>("retry-after-ms", "1500"),
        });

    /// <summary>
    /// 429 with NO token header but a machine <c>code</c> variant (<c>tokens_per_minute</c>) ⇒
    /// TokenLimit (proves the code/separator-insensitive detector, not just the exact phrase).
    /// </summary>
    public static HttpResponseMessage Openai429TpmCodeOnly() => FakeHttpMessageHandler.Error(
        HttpStatusCode.TooManyRequests,
        "{\"error\":{\"message\":\"Rate limit reached\",\"code\":\"tokens_per_minute\"}}",
        new[]
        {
            new KeyValuePair<string, string>("x-ratelimit-remaining-requests", "7"),
        });

    /// <summary>401 ⇒ Authentication.</summary>
    public static HttpResponseMessage Openai401() => FakeHttpMessageHandler.Error(
        HttpStatusCode.Unauthorized,
        "{\"error\":{\"message\":\"Incorrect API key provided\",\"code\":\"invalid_api_key\"}}");

    /// <summary>400 ⇒ InvalidRequest.</summary>
    public static HttpResponseMessage Openai400() => FakeHttpMessageHandler.Error(
        HttpStatusCode.BadRequest,
        "{\"error\":{\"message\":\"Invalid 'model'\",\"code\":\"invalid_request_error\"}}");

    /// <summary>500 ⇒ Transient.</summary>
    public static HttpResponseMessage Openai500() => FakeHttpMessageHandler.Error(
        HttpStatusCode.InternalServerError,
        "{\"error\":{\"message\":\"The server had an error\"}}");
}

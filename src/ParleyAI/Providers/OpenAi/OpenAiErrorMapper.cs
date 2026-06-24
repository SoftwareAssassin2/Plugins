using System;
using System.ClientModel;
using System.ClientModel.Primitives;
using System.Globalization;
using System.Net;
using System.Net.Http;
using ParleyAI.Abstractions;

namespace ParleyAI.Providers.OpenAi;

/// <summary>
/// Maps OpenAI SDK / transport failures onto ParleyAI's provider-neutral
/// <see cref="ParleyAIException"/> + <see cref="ParleyAIErrorCategory"/>.
/// </summary>
/// <remarks>
/// <para><b>Category precedence (first match wins):</b></para>
/// <list type="number">
///   <item>429 with <c>x-ratelimit-remaining-tokens: 0</c> OR a message/<c>code</c> indicating
///         tokens-per-minute (body contains <c>tokens per min</c>) ⇒ <see cref="ParleyAIErrorCategory.TokenLimit"/>.</item>
///   <item>Any other 429 (incl. <c>x-ratelimit-remaining-requests: 0</c>) ⇒ <see cref="ParleyAIErrorCategory.RateLimit"/>.</item>
///   <item>401 / 403 ⇒ <see cref="ParleyAIErrorCategory.Authentication"/>.</item>
///   <item>400 / 422 ⇒ <see cref="ParleyAIErrorCategory.InvalidRequest"/>.</item>
///   <item>408 / 5xx / timeout / <see cref="HttpRequestException"/> ⇒ <see cref="ParleyAIErrorCategory.Transient"/>.</item>
///   <item>else ⇒ <see cref="ParleyAIErrorCategory.Unknown"/>.</item>
/// </list>
/// <para>
/// <see cref="ParleyAIException.RetryAfter"/> = <c>Retry-After</c> (seconds) else
/// <c>retry-after-ms</c> (milliseconds). <see cref="OperationCanceledException"/> is never
/// mapped here — it propagates un-wrapped from the client.
/// </para>
/// </remarks>
internal static class OpenAiErrorMapper
{
    /// <summary>
    /// Maps a <see cref="ClientResultException"/> (HTTP error surfaced by the SDK) onto a
    /// <see cref="ParleyAIException"/>.
    /// </summary>
    public static ParleyAIException Map(ClientResultException ex)
    {
        int status = ex.Status;
        PipelineResponse? response = TryGetRawResponse(ex);

        string? remainingTokens = TryHeader(response, "x-ratelimit-remaining-tokens");
        string? body = TryBody(response);
        TimeSpan? retryAfter = ParseRetryAfter(response);

        ParleyAIErrorCategory category = Classify(status, remainingTokens, body);

        var statusCode = Enum.IsDefined(typeof(HttpStatusCode), status)
            ? (HttpStatusCode?)status
            : null;

        return new ParleyAIException(
            ex.Message,
            category,
            ProviderKeys.OpenAi,
            statusCode,
            retryAfter,
            ex);
    }

    /// <summary>
    /// Maps a transport-level <see cref="HttpRequestException"/> (connection failure, DNS,
    /// reset) onto a <see cref="ParleyAIErrorCategory.Transient"/> <see cref="ParleyAIException"/>.
    /// </summary>
    public static ParleyAIException Map(HttpRequestException ex) =>
        new ParleyAIException(
            ex.Message,
            ParleyAIErrorCategory.Transient,
            ProviderKeys.OpenAi,
            statusCode: null,
            retryAfter: null,
            innerException: ex);

    /// <summary>
    /// Maps a transport-level timeout (a <see cref="OperationCanceledException"/> NOT driven by the
    /// caller's <see cref="System.Threading.CancellationToken"/>) onto a
    /// <see cref="ParleyAIErrorCategory.Transient"/> <see cref="ParleyAIException"/>.
    /// </summary>
    public static ParleyAIException MapTimeout(OperationCanceledException ex) =>
        new ParleyAIException(
            ex.Message,
            ParleyAIErrorCategory.Transient,
            ProviderKeys.OpenAi,
            statusCode: null,
            retryAfter: null,
            innerException: ex);

    /// <summary>
    /// Maps any other unexpected exception onto an <see cref="ParleyAIErrorCategory.Unknown"/>
    /// <see cref="ParleyAIException"/>.
    /// </summary>
    public static ParleyAIException MapUnknown(Exception ex) =>
        new ParleyAIException(
            ex.Message,
            ParleyAIErrorCategory.Unknown,
            ProviderKeys.OpenAi,
            statusCode: null,
            retryAfter: null,
            innerException: ex);

    internal static ParleyAIErrorCategory Classify(int status, string? remainingTokens, string? body)
    {
        if (status == 429)
        {
            bool tokenLimit =
                string.Equals(remainingTokens?.Trim(), "0", StringComparison.Ordinal)
                || IndicatesTokensPerMinute(body);
            return tokenLimit ? ParleyAIErrorCategory.TokenLimit : ParleyAIErrorCategory.RateLimit;
        }

        return status switch
        {
            401 or 403 => ParleyAIErrorCategory.Authentication,
            400 or 422 => ParleyAIErrorCategory.InvalidRequest,
            408 => ParleyAIErrorCategory.Transient,
            >= 500 and <= 599 => ParleyAIErrorCategory.Transient,
            _ => ParleyAIErrorCategory.Unknown,
        };
    }

    /// <summary>
    /// Detects a tokens-per-minute signal in the error body — either the human-readable message
    /// (<c>tokens per min</c>) or a machine <c>code</c> variant (<c>tokens_per_min[ute]</c> /
    /// <c>tokens-per-min[ute]</c>). Whitespace/separator-insensitive so message and code shapes
    /// both match.
    /// </summary>
    internal static bool IndicatesTokensPerMinute(string? body)
    {
        if (string.IsNullOrEmpty(body))
        {
            return false;
        }

        // Collapse the separators OpenAI uses between the words (space / underscore / hyphen) so a
        // single substring check covers "tokens per min", "tokens_per_minute", "tokens-per-min", etc.
        string normalized = body
            .Replace('_', ' ')
            .Replace('-', ' ')
            .ToLowerInvariant();

        return normalized.Contains("tokens per min");
    }

    private static TimeSpan? ParseRetryAfter(PipelineResponse? response)
    {
        if (response is null)
        {
            return null;
        }

        string? retryAfter = TryHeader(response, "Retry-After");
        if (retryAfter is not null
            && int.TryParse(retryAfter.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out int seconds)
            && seconds >= 0)
        {
            return TimeSpan.FromSeconds(seconds);
        }

        string? retryAfterMs = TryHeader(response, "retry-after-ms");
        if (retryAfterMs is not null
            && double.TryParse(retryAfterMs.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out double ms)
            && ms >= 0)
        {
            return TimeSpan.FromMilliseconds(ms);
        }

        return null;
    }

    private static PipelineResponse? TryGetRawResponse(ClientResultException ex)
    {
        try
        {
            return ex.GetRawResponse();
        }
        catch
        {
            return null;
        }
    }

    private static string? TryHeader(PipelineResponse? response, string name)
    {
        if (response is null)
        {
            return null;
        }

        return response.Headers.TryGetValue(name, out string? value) ? value : null;
    }

    private static string? TryBody(PipelineResponse? response)
    {
        try
        {
            return response?.Content?.ToString();
        }
        catch
        {
            return null;
        }
    }
}

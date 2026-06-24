using System;
using System.Collections.Generic;
using System.Globalization;
using System.Net;
using System.Net.Http;
using ParleyAI.Abstractions;

namespace ParleyAI.Providers.Anthropic;

/// <summary>
/// Maps Anthropic SDK / transport failures onto ParleyAI's provider-neutral
/// <see cref="ParleyAIException"/> + <see cref="ParleyAIErrorCategory"/>.
/// </summary>
/// <remarks>
/// <para><b>Category precedence (first match wins):</b></para>
/// <list type="number">
///   <item>429 with <c>anthropic-ratelimit-tokens-remaining: 0</c> OR a body/message indicating a
///         token limit ⇒ <see cref="ParleyAIErrorCategory.TokenLimit"/>.</item>
///   <item>Any other 429 (incl. <c>anthropic-ratelimit-requests-remaining: 0</c>) ⇒
///         <see cref="ParleyAIErrorCategory.RateLimit"/>.</item>
///   <item>401 (<c>authentication_error</c>) ⇒ <see cref="ParleyAIErrorCategory.Authentication"/>.</item>
///   <item>400 (<c>invalid_request_error</c>) ⇒ <see cref="ParleyAIErrorCategory.InvalidRequest"/>.</item>
///   <item>529 (<c>overloaded_error</c>) / 5xx / timeout ⇒ <see cref="ParleyAIErrorCategory.Transient"/>.</item>
///   <item>else ⇒ <see cref="ParleyAIErrorCategory.Unknown"/>.</item>
/// </list>
/// <para>
/// <see cref="ParleyAIException.RetryAfter"/> = the <c>retry-after</c> header (seconds).
/// <see cref="OperationCanceledException"/> is never mapped here — it propagates from the client.
/// </para>
/// <para>
/// Status + headers + body are read from the <see cref="AnthropicOriginRewriteHandler"/> capture
/// (the SDK's exceptions drop them); the original exception is preserved as the inner exception.
/// </para>
/// </remarks>
internal static class AnthropicErrorMapper
{
    /// <summary>
    /// Maps an exception thrown by the SDK using the handler-captured response detail when present.
    /// </summary>
    /// <param name="ex">The originating SDK/transport exception.</param>
    /// <param name="context">
    /// The response detail captured by the rewrite handler, or <c>null</c> when none was captured
    /// (e.g. a transport-level failure that never produced a response).
    /// </param>
    public static ParleyAIException Map(Exception ex, AnthropicErrorContext? context)
    {
        if (context is null)
        {
            // No HTTP response was captured — a transport-level failure (connection/DNS/reset).
            ParleyAIErrorCategory transportCategory = ex is HttpRequestException
                ? ParleyAIErrorCategory.Transient
                : ParleyAIErrorCategory.Unknown;

            return new ParleyAIException(
                ex.Message,
                transportCategory,
                ProviderKeys.Anthropic,
                statusCode: null,
                retryAfter: null,
                innerException: ex);
        }

        int status = (int)context.StatusCode;
        string? tokensRemaining = TryHeader(context.Headers, "anthropic-ratelimit-tokens-remaining");
        ParleyAIErrorCategory category = Classify(status, tokensRemaining, context.Body);
        TimeSpan? retryAfter = ParseRetryAfter(context.Headers);

        // Preserve the actual status verbatim — including Anthropic's non-standard 529 (overloaded),
        // which is NOT a defined HttpStatusCode member but is carried fine by a cast. Nulling it
        // would drop useful response metadata from the surfaced exception.
        return new ParleyAIException(
            ex.Message,
            category,
            ProviderKeys.Anthropic,
            context.StatusCode,
            retryAfter,
            ex);
    }

    /// <summary>
    /// Maps a transport-level timeout (an <see cref="OperationCanceledException"/> NOT driven by the
    /// caller's <see cref="System.Threading.CancellationToken"/>) onto a
    /// <see cref="ParleyAIErrorCategory.Transient"/> <see cref="ParleyAIException"/>.
    /// </summary>
    public static ParleyAIException MapTimeout(OperationCanceledException ex) =>
        new ParleyAIException(
            ex.Message,
            ParleyAIErrorCategory.Transient,
            ProviderKeys.Anthropic,
            statusCode: null,
            retryAfter: null,
            innerException: ex);

    /// <summary>Maps any other unexpected exception onto an <see cref="ParleyAIErrorCategory.Unknown"/>.</summary>
    public static ParleyAIException MapUnknown(Exception ex) =>
        new ParleyAIException(
            ex.Message,
            ParleyAIErrorCategory.Unknown,
            ProviderKeys.Anthropic,
            statusCode: null,
            retryAfter: null,
            innerException: ex);

    internal static ParleyAIErrorCategory Classify(int status, string? tokensRemaining, string? body)
    {
        if (status == 429)
        {
            bool tokenLimit =
                string.Equals(tokensRemaining?.Trim(), "0", StringComparison.Ordinal)
                || IndicatesTokenLimit(body);
            return tokenLimit ? ParleyAIErrorCategory.TokenLimit : ParleyAIErrorCategory.RateLimit;
        }

        return status switch
        {
            401 => ParleyAIErrorCategory.Authentication,
            403 => ParleyAIErrorCategory.Authentication,
            400 => ParleyAIErrorCategory.InvalidRequest,
            422 => ParleyAIErrorCategory.InvalidRequest,
            408 => ParleyAIErrorCategory.Transient,
            >= 500 and <= 599 => ParleyAIErrorCategory.Transient,
            _ => ParleyAIErrorCategory.Unknown,
        };
    }

    /// <summary>
    /// Detects a token-limit signal in a 429 error body. Normalizes separators (<c>_</c> / <c>-</c>
    /// to spaces) so both the human message and machine <c>type</c>/<c>code</c> variants
    /// (e.g. <c>tokens per min</c>, <c>token_limit</c>, <c>tokens-per-minute</c>) match.
    /// </summary>
    internal static bool IndicatesTokenLimit(string? body)
    {
        if (string.IsNullOrEmpty(body))
        {
            return false;
        }

        string normalized = body
            .Replace('_', ' ')
            .Replace('-', ' ')
            .ToLowerInvariant();

        return normalized.Contains("tokens per min")
            || normalized.Contains("token limit")
            || normalized.Contains("tokens limit");
    }

    private static TimeSpan? ParseRetryAfter(IReadOnlyDictionary<string, string> headers)
    {
        string? retryAfter = TryHeader(headers, "retry-after");
        if (retryAfter is not null
            && int.TryParse(retryAfter.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out int seconds)
            && seconds >= 0)
        {
            return TimeSpan.FromSeconds(seconds);
        }

        return null;
    }

    private static string? TryHeader(IReadOnlyDictionary<string, string> headers, string name) =>
        headers.TryGetValue(name, out string? value) ? value : null;
}

using System;
using System.Net;

namespace ParleyAI.Abstractions;

/// <summary>
/// The single provider-agnostic exception ParleyAI surfaces for failed chat
/// operations, regardless of the underlying provider SDK.
/// </summary>
/// <remarks>
/// <para>
/// Provider/SDK errors are mapped onto this type so callers catch ONE exception
/// type across both OpenAI and Anthropic. The <see cref="Category"/> classifies the
/// failure and drives the adaptive AIMD rate optimizer.
/// </para>
/// <para>
/// <b>Cancellation is never wrapped:</b> an <see cref="OperationCanceledException"/>
/// (including <see cref="System.Threading.Tasks.TaskCanceledException"/>) raised by a
/// caller-supplied <see cref="System.Threading.CancellationToken"/> propagates
/// un-wrapped so cooperative cancellation is not misclassified as a provider fault.
/// </para>
/// </remarks>
public sealed class ParleyAIException : Exception
{
    /// <summary>
    /// Creates a provider-agnostic ParleyAI exception.
    /// </summary>
    /// <param name="message">A human-readable description of the failure.</param>
    /// <param name="category">The provider-neutral failure classification.</param>
    /// <param name="providerKey">
    /// The originating provider key (e.g. <see cref="ProviderKeys.OpenAi"/>).
    /// </param>
    /// <param name="statusCode">The originating HTTP status, when known.</param>
    /// <param name="retryAfter">
    /// The provider-advised wait before retrying, when supplied (e.g. via a
    /// <c>Retry-After</c> header).
    /// </param>
    /// <param name="innerException">The originating provider/SDK exception, when any.</param>
    public ParleyAIException(
        string message,
        ParleyAIErrorCategory category,
        string providerKey,
        HttpStatusCode? statusCode = null,
        TimeSpan? retryAfter = null,
        Exception? innerException = null)
        : base(message, innerException)
    {
        Category = category;
        ProviderKey = providerKey;
        StatusCode = statusCode;
        RetryAfter = retryAfter;
    }

    /// <summary>The provider-neutral failure classification.</summary>
    public ParleyAIErrorCategory Category { get; }

    /// <summary>The originating provider key (e.g. <c>"openai"</c> / <c>"anthropic"</c>).</summary>
    public string ProviderKey { get; }

    /// <summary>The originating HTTP status, or <c>null</c> when not HTTP-derived.</summary>
    public HttpStatusCode? StatusCode { get; }

    /// <summary>
    /// The provider-advised wait before retrying, or <c>null</c> when none was given.
    /// Honored by the AIMD optimizer on a <see cref="ParleyAIErrorCategory.RateLimit"/>
    /// / <see cref="ParleyAIErrorCategory.TokenLimit"/> back-off.
    /// </summary>
    public TimeSpan? RetryAfter { get; }
}

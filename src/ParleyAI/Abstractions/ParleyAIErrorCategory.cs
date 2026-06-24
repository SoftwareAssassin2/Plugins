namespace ParleyAI.Abstractions;

/// <summary>
/// Provider-neutral classification of a failed chat operation.
/// </summary>
/// <remarks>
/// The category is the single signal that drives the adaptive AIMD rate optimizer:
/// <see cref="RateLimit"/> and <see cref="TokenLimit"/> trigger (distinct)
/// multiplicative back-off; other categories do not.
/// </remarks>
public enum ParleyAIErrorCategory
{
    /// <summary>Request-rate limit exceeded (e.g. requests-per-minute).</summary>
    RateLimit = 0,

    /// <summary>Token budget exceeded (e.g. tokens-per-minute or context window).</summary>
    TokenLimit = 1,

    /// <summary>Authentication / authorization failure (missing or invalid key).</summary>
    Authentication = 2,

    /// <summary>The request was malformed or otherwise rejected as invalid.</summary>
    InvalidRequest = 3,

    /// <summary>A transient failure (timeout, 5xx, connection reset) worth retrying.</summary>
    Transient = 4,

    /// <summary>An error ParleyAI could not classify into the above.</summary>
    Unknown = 5,
}

namespace ParleyAI.Providers.OpenAi;

/// <summary>
/// The resolved OpenAI connection settings consumed by <see cref="OpenAiChatClient"/>.
/// </summary>
/// <remarks>
/// The DI layer materializes this AFTER applying precedence: API key ctor &gt; flat
/// <c>OPENAI_API_KEY</c> (required); base URL ctor &gt; flat <c>OPENAI_BASE_URL</c> &gt; SDK
/// default (null here). The client validates these at construction (lazy — at first resolve,
/// not at registration).
/// </remarks>
public sealed class OpenAiChatClientSettings
{
    /// <summary>The resolved API key. Required; the client throws when null/blank.</summary>
    public string? ApiKey { get; set; }

    /// <summary>
    /// The resolved base URL override, verbatim (includes <c>/v1</c> per the fn-3 contract), or
    /// <c>null</c> to use the SDK default endpoint.
    /// </summary>
    public string? BaseUrl { get; set; }
}

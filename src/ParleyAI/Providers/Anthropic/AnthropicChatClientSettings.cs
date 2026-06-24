namespace ParleyAI.Providers.Anthropic;

/// <summary>
/// The resolved Anthropic connection settings consumed by <see cref="AnthropicChatClient"/>.
/// </summary>
/// <remarks>
/// The DI layer materializes this AFTER applying precedence: API key ctor &gt; flat
/// <c>ANTHROPIC_API_KEY</c> (required); base URL ctor &gt; flat <c>ANTHROPIC_BASE_URL</c> &gt; SDK
/// default (null here). Unlike OpenAI's verbatim <c>/v1</c> endpoint, <c>ANTHROPIC_BASE_URL</c> is
/// the host <b>root</b> (scheme+host+port, no path) per the fn-3 contract — a base URL carrying a
/// path is rejected at construction/resolve (lazy). The override is applied by an origin-rewrite
/// <see cref="System.Net.Http.DelegatingHandler"/> on the keyed transport client, because the SDK
/// emits absolute <c>https://api.anthropic.com/...</c> URIs that ignore <c>HttpClient.BaseAddress</c>.
/// </remarks>
public sealed class AnthropicChatClientSettings
{
    /// <summary>The resolved API key. Required; the client throws when null/blank.</summary>
    public string? ApiKey { get; set; }

    /// <summary>
    /// The resolved base URL override — the host <b>root</b> only (scheme+host+port, no path/query)
    /// per the fn-3 contract — or <c>null</c> to use the SDK default origin
    /// (<c>https://api.anthropic.com</c>). A value carrying a path/query is rejected.
    /// </summary>
    public string? BaseUrl { get; set; }
}

namespace ParleyAI.Abstractions;

/// <summary>
/// Resolves a keyed <see cref="IAiChatClient"/> by provider key at runtime.
/// </summary>
/// <remarks>
/// A convenience over <c>[FromKeyedServices(...)]</c> injection for callers that
/// choose the provider dynamically (e.g. from configuration or a request field).
/// </remarks>
public interface IAiChatClientFactory
{
    /// <summary>
    /// Returns the chat client registered under <paramref name="providerKey"/>.
    /// </summary>
    /// <param name="providerKey">
    /// One of <see cref="ProviderKeys.OpenAi"/> / <see cref="ProviderKeys.Anthropic"/>.
    /// </param>
    /// <returns>The keyed <see cref="IAiChatClient"/>.</returns>
    IAiChatClient Create(string providerKey);
}

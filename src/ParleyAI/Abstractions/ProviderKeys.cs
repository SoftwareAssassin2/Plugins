namespace ParleyAI.Abstractions;

/// <summary>
/// The canonical keyed-service identifiers for the providers ParleyAI registers.
/// </summary>
/// <remarks>
/// ParleyAI registers each provider as a <em>keyed</em> <see cref="IAiChatClient"/>;
/// there is no unkeyed default. Consumers select a provider explicitly by one of
/// these keys (e.g. <c>[FromKeyedServices(ProviderKeys.OpenAi)]</c>) or via
/// <see cref="IAiChatClientFactory.Create(string)"/>.
/// </remarks>
public static class ProviderKeys
{
    /// <summary>The OpenAI provider key.</summary>
    public const string OpenAi = "openai";

    /// <summary>The Anthropic provider key.</summary>
    public const string Anthropic = "anthropic";
}

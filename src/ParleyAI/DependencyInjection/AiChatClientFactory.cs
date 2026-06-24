using System;
using Microsoft.Extensions.DependencyInjection;
using ParleyAI.Abstractions;

namespace ParleyAI.DependencyInjection;

/// <summary>
/// The default <see cref="IAiChatClientFactory"/>: resolves the PUBLIC keyed
/// <see cref="IAiChatClient"/> (the composed client — provider + optional decorator) by provider key.
/// </summary>
/// <remarks>
/// Runtime selection over <c>[FromKeyedServices(...)]</c> injection. There is NO unkeyed default:
/// an unknown key throws (the keyed service is simply not registered).
/// </remarks>
internal sealed class AiChatClientFactory : IAiChatClientFactory
{
    private readonly IServiceProvider _services;

    public AiChatClientFactory(IServiceProvider services) =>
        _services = services ?? throw new ArgumentNullException(nameof(services));

    /// <inheritdoc />
    public IAiChatClient Create(string providerKey)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(providerKey);

        // Resolves the composed (public) keyed IAiChatClient; throws if the key is not registered.
        return _services.GetRequiredKeyedService<IAiChatClient>(providerKey);
    }
}

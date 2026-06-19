using System;
using ParleyAI.Abstractions;

namespace ParleyAI.DependencyInjection;

/// <summary>
/// The OPTIONAL per-provider decoration hook the composition factory (fn-4.4) applies when present.
/// </summary>
/// <remarks>
/// <para>
/// This is the single, concrete, optional decorator delegate ParleyAI's composition recognizes
/// (v1 — one decorator, no chaining). When a singleton <see cref="AiChatClientDecorator"/> is
/// registered (fn-4.5 registers it for the AIMD optimizer; fn-4.4 registers NONE), the composition
/// factory invokes it with the resolving <see cref="IServiceProvider"/>, the provider key, and the
/// bare provider client, and uses the returned client as the public keyed <see cref="IAiChatClient"/>.
/// When absent, the bare provider is returned.
/// </para>
/// <para>
/// Defining the hook as a concrete delegate type means fn-4.5 needs NO descriptor surgery: it
/// simply <c>AddSingleton&lt;AiChatClientDecorator&gt;(...)</c>; the gate (enabled/off) lives inside
/// its own options.
/// </para>
/// </remarks>
/// <param name="services">The resolving service provider (for the decorator's own dependencies).</param>
/// <param name="providerKey">
/// The provider key being composed (<see cref="ProviderKeys.OpenAi"/> / <see cref="ProviderKeys.Anthropic"/>).
/// </param>
/// <param name="inner">The bare provider <see cref="IAiChatClient"/> to wrap.</param>
/// <returns>The decorated client (or <paramref name="inner"/> itself to opt out for this provider).</returns>
public delegate IAiChatClient AiChatClientDecorator(
    IServiceProvider services,
    string providerKey,
    IAiChatClient inner);

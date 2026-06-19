using System;
using System.Collections.Concurrent;
using System.Net.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using ParleyAI.Abstractions;
using ParleyAI.Abstractions.Options;
using ParleyAI.Providers.Anthropic;
using ParleyAI.Providers.OpenAi;
using ParleyAI.RateLimiting;

namespace ParleyAI.DependencyInjection;

/// <summary>
/// The PUBLIC, no-glue consumer API for ParleyAI: <see cref="AddParleyAi(IServiceCollection, IConfiguration, Action{ParleyAiOptions}?)"/>.
/// </summary>
/// <remarks>
/// <para>
/// <see cref="AddParleyAi(IServiceCollection, IConfiguration, Action{ParleyAiOptions}?)"/> assembles
/// the cross-provider composition: it calls the per-provider building blocks (fn-4.2/.3), registers
/// the PUBLIC keyed <see cref="IAiChatClient"/> per provider via a composition factory (applying the
/// optional decoration hook when present), attaches the standard resilience pipeline to each
/// provider's keyed <see cref="IHttpClientBuilder"/> EXACTLY ONCE, and registers the
/// <see cref="IAiChatClientFactory"/>. There is NO unkeyed default — unkeyed resolution throws.
/// </para>
/// <para>
/// <b>Decoration (no .4/.5 cycle):</b> the public keyed <see cref="IAiChatClient"/> is composed as
/// <c>Compose(sp, key, bareProvider)</c>: if a singleton
/// <c>Func&lt;IServiceProvider, string /*providerKey*/, IAiChatClient /*inner*/, IAiChatClient&gt;</c>
/// is registered (fn-4.5 registers it for AIMD; this task registers NONE), it is invoked and its
/// result is the public client; otherwise the bare provider is returned. One decorator, v1 — no
/// chaining, no descriptor surgery.
/// </para>
/// <para>
/// <b>Resilience (no stacking):</b> the SDK-native retry is disabled in .2/.3, so this is the single
/// place an HTTP retry layer is added — a custom timeout+retry pipeline (NO rate-limiter strategy)
/// attached once per provider via the .2/.3-exposed <see cref="IHttpClientBuilder"/>.
/// </para>
/// </remarks>
public static class ParleyAiServiceCollectionExtensions
{
    /// <summary>
    /// Registers ParleyAI: both providers keyed (public composed <see cref="IAiChatClient"/> +
    /// resilience) and the <see cref="IAiChatClientFactory"/>. The no-glue consumer entry point.
    /// </summary>
    /// <param name="services">The service collection.</param>
    /// <param name="configuration">
    /// Configuration carrying the flat <c>OPENAI_*</c> / <c>ANTHROPIC_*</c> keys (passed explicitly
    /// so the flat <c>IConfiguration[KEY]</c> reads are unambiguous — not resolved from DI).
    /// </param>
    /// <param name="configure">Optional per-provider ctor-override + resilience tuning.</param>
    /// <returns>The same service collection for chaining.</returns>
    public static IServiceCollection AddParleyAi(
        this IServiceCollection services,
        IConfiguration configuration,
        Action<ParleyAiOptions>? configure = null)
    {
        ArgumentNullException.ThrowIfNull(services);
        ArgumentNullException.ThrowIfNull(configuration);

        var options = new ParleyAiOptions();
        configure?.Invoke(options);

        // OpenAI: building block (keyed concrete + named HttpClient + exposed builder) → resilience
        // → public composed keyed IAiChatClient.
        IHttpClientBuilder openAiBuilder = services.AddOpenAiChatClient(configuration, options.ConfigureOpenAi);
        AttachResilience(openAiBuilder, ProviderKeys.OpenAi, options.ConfigureOpenAiResilience);
        services.AddKeyedSingleton<IAiChatClient>(
            ProviderKeys.OpenAi,
            (sp, key) => Compose(sp, (string)key!, sp.GetRequiredKeyedService<OpenAiChatClient>(key)));

        // Anthropic: same shape.
        IHttpClientBuilder anthropicBuilder = services.AddAnthropicChatClient(configuration, options.ConfigureAnthropic);
        AttachResilience(anthropicBuilder, ProviderKeys.Anthropic, options.ConfigureAnthropicResilience);
        services.AddKeyedSingleton<IAiChatClient>(
            ProviderKeys.Anthropic,
            (sp, key) => Compose(sp, (string)key!, sp.GetRequiredKeyedService<AnthropicChatClient>(key)));

        // Runtime selection over the PUBLIC composed keyed clients. NO unkeyed default registered.
        services.AddSingleton<IAiChatClientFactory, AiChatClientFactory>();

        // Wire the adaptive AIMD rate optimizer as the composition decoration hook — ON by default
        // (no extra opt-in call; AddParleyAi ALONE yields AIMD-decorated clients). The per-provider
        // off switch (AimdOptions.Enabled == false) makes the hook return the bare inner for that
        // provider while keeping the other decorated.
        RegisterAimdHook(services, options);

        return services;
    }

    /// <summary>
    /// Registers the single composition decoration hook (the EXACT spec-defined delegate
    /// <c>Func&lt;IServiceProvider, string, IAiChatClient, IAiChatClient&gt;</c>) that wraps each keyed
    /// provider client with the <see cref="AimdChatClientDecorator"/> — on by default, per-provider off
    /// switch honored. One <see cref="AimdRateController"/> per provider key (cached for the provider's
    /// lifetime) gives per-provider isolation; the controller takes an injected <see cref="TimeProvider"/>
    /// (DI-registered or <see cref="TimeProvider.System"/>) and <see cref="IJitterSource"/> (DI-registered
    /// or <see cref="DefaultJitterSource.Instance"/>) so it is deterministically testable.
    /// </summary>
    private static void RegisterAimdHook(IServiceCollection services, ParleyAiOptions options)
    {
        // Per-provider AIMD tuning, resolved ONCE here (immutable thereafter — the controller never
        // mutates these). A disabled provider gets no decorator.
        AimdOptions openAiAimd = BuildAimd(options.ConfigureOpenAiAimd);
        AimdOptions anthropicAimd = BuildAimd(options.ConfigureAnthropicAimd);

        services.AddSingleton<Func<IServiceProvider, string, IAiChatClient, IAiChatClient>>(_ =>
        {
            // One controller per provider key, lazily created on first decoration and cached for the
            // ServiceProvider's lifetime. The cache is created INSIDE this singleton factory so each
            // ServiceProvider built from the same IServiceCollection gets its OWN cache — otherwise
            // controller state (and the resolved clock/jitter) would leak across containers.
            // ConcurrentDictionary keeps the get-or-add atomic under concurrent first-resolution.
            var controllers = new ConcurrentDictionary<string, AimdRateController>(StringComparer.Ordinal);

            return (sp, providerKey, inner) =>
            {
                AimdOptions aimd = providerKey == ProviderKeys.Anthropic ? anthropicAimd : openAiAimd;

                // Per-provider hard off switch → bare client (no decorator) for THIS provider only.
                if (!aimd.Enabled)
                {
                    return inner;
                }

                AimdRateController controller = controllers.GetOrAdd(
                    providerKey,
                    _ => new AimdRateController(
                        aimd,
                        sp.GetService<TimeProvider>() ?? TimeProvider.System,
                        sp.GetService<IJitterSource>() ?? DefaultJitterSource.Instance));

                return new AimdChatClientDecorator(inner, controller);
            };
        });
    }

    /// <summary>Builds an <see cref="AimdOptions"/> from the optional per-provider tuning delegate.</summary>
    private static AimdOptions BuildAimd(Action<AimdOptions>? configure)
    {
        var aimd = new AimdOptions();
        configure?.Invoke(aimd);
        return aimd;
    }

    /// <summary>
    /// Ctor-override overload: supply base-URL/key for BOTH providers directly (no flat config).
    /// </summary>
    /// <param name="services">The service collection.</param>
    /// <param name="configureOpenAi">OpenAI ctor-override (base URL / key).</param>
    /// <param name="configureAnthropic">Anthropic ctor-override (base URL / key).</param>
    /// <param name="configure">Optional further options (resilience tuning).</param>
    /// <returns>The same service collection for chaining.</returns>
    public static IServiceCollection AddParleyAi(
        this IServiceCollection services,
        Action<OpenAiChatClientSettings> configureOpenAi,
        Action<AnthropicChatClientSettings> configureAnthropic,
        Action<ParleyAiOptions>? configure = null)
    {
        ArgumentNullException.ThrowIfNull(services);
        ArgumentNullException.ThrowIfNull(configureOpenAi);
        ArgumentNullException.ThrowIfNull(configureAnthropic);

        // An empty configuration: the ctor-override delegates fully supply base URL + key, so the
        // flat IConfiguration[KEY] reads return null and the override wins (ctor > flat). Use a tiny
        // local IConfiguration (NOT ConfigurationBuilder, which lives in the concrete
        // Microsoft.Extensions.Configuration package — only its Abstractions are a direct ref here).
        IConfiguration empty = EmptyConfiguration.Instance;

        return services.AddParleyAi(empty, opts =>
        {
            opts.ConfigureOpenAi = configureOpenAi;
            opts.ConfigureAnthropic = configureAnthropic;
            configure?.Invoke(opts);
        });
    }

    /// <summary>
    /// Composes the public keyed <see cref="IAiChatClient"/>: applies the optional decoration hook
    /// (the concrete singleton <c>Func&lt;IServiceProvider, string, IAiChatClient, IAiChatClient&gt;</c>)
    /// when registered, else returns the bare provider.
    /// </summary>
    private static IAiChatClient Compose(IServiceProvider sp, string providerKey, IAiChatClient bareInner)
    {
        // ONE optional decorator (v1, no chaining). The hook is the EXACT spec-defined delegate type
        // Func<IServiceProvider, string, IAiChatClient, IAiChatClient> — fn-4.4 registers none → bare;
        // fn-4.5 registers it (AIMD) → wrapped. No descriptor surgery either way.
        var decorator = sp.GetService<Func<IServiceProvider, string, IAiChatClient, IAiChatClient>>();
        return decorator is null ? bareInner : decorator(sp, providerKey, bareInner);
    }

    /// <summary>
    /// Attaches the resilience pipeline EXACTLY ONCE to a provider's keyed transport builder, unless
    /// disabled via <see cref="ParleyAiResilienceOptions.Enabled"/>.
    /// </summary>
    private static void AttachResilience(
        IHttpClientBuilder builder,
        string providerKey,
        Action<ParleyAiResilienceOptions>? configure)
    {
        var resilience = new ParleyAiResilienceOptions();
        configure?.Invoke(resilience);

        if (!resilience.Enabled)
        {
            // No handler added → exactly ONE HTTP attempt (proves no silent stacking with .2/.3).
            return;
        }

        // A custom resilience pipeline (timeout + retry ONLY, NO rate-limiter) — the SINGLE place
        // resilience is added (.2/.3 add none). A stable, provider-scoped pipeline name.
        builder.AddResilienceHandler($"parleyai-{providerKey}", pipelineBuilder =>
        {
            if (resilience.ConfigurePipeline is { } replace)
            {
                // Full replacement: the caller owns the whole pipeline (knobs ignored).
                replace(pipelineBuilder, providerKey);
            }
            else
            {
                resilience.ApplyDefaultPipeline(pipelineBuilder);
            }
        });
    }

    /// <summary>
    /// A minimal empty <see cref="IConfiguration"/> for the ctor-override overload — every key reads
    /// as <see langword="null"/> so the override delegates fully supply base URL + key.
    /// </summary>
    /// <remarks>
    /// Hand-rolled (not <c>ConfigurationBuilder</c>) so production code depends ONLY on
    /// <c>Microsoft.Extensions.Configuration.Abstractions</c> — the concrete
    /// <c>Microsoft.Extensions.Configuration</c> package is not a direct reference and must not be
    /// relied on transitively.
    /// </remarks>
    private sealed class EmptyConfiguration : IConfiguration, IConfigurationSection
    {
        public static readonly EmptyConfiguration Instance = new();

        public string? this[string key]
        {
            get => null;
            set { /* no-op: empty configuration is read-only and always empty */ }
        }

        // IConfigurationSection members (a section of the empty config is itself empty).
        public string Key => string.Empty;

        public string Path => string.Empty;

        public string? Value
        {
            get => null;
            set { /* no-op */ }
        }

        public IConfigurationSection GetSection(string key) => Instance;

        public System.Collections.Generic.IEnumerable<IConfigurationSection> GetChildren() =>
            System.Array.Empty<IConfigurationSection>();

        public Microsoft.Extensions.Primitives.IChangeToken GetReloadToken() =>
            new Microsoft.Extensions.Primitives.CancellationChangeToken(System.Threading.CancellationToken.None);
    }
}

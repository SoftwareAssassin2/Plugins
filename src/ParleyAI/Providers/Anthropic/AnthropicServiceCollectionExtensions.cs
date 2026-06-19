using System;
using System.Net.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using ParleyAI.Abstractions;
using ParleyAI.Telemetry;

namespace ParleyAI.Providers.Anthropic;

/// <summary>
/// DI building blocks for the Anthropic provider.
/// </summary>
/// <remarks>
/// <para>
/// <see cref="AddAnthropicChatClient(IServiceCollection, IConfiguration, Action{AnthropicChatClientSettings}?, ParleyAI.Telemetry.ParleyAiTelemetryOptions?)"/>
/// is a documented building block; the public no-glue consumer API is <c>AddParleyAi</c> (fn-4.4).
/// It registers a named, singleton-safe <see cref="HttpClient"/> (<c>"anthropic"</c>) whose pipeline
/// carries the origin-rewrite <see cref="AnthropicOriginRewriteHandler"/>, plus a keyed CONCRETE
/// <see cref="AnthropicChatClient"/> under <see cref="ProviderKeys.Anthropic"/>. It does NOT register
/// a public keyed <see cref="IAiChatClient"/> — that composition (with the AIMD decorator) is
/// fn-4.4's job. It returns the keyed <see cref="IHttpClientBuilder"/> so fn-4.4 can attach the
/// resilience handler exactly once.
/// </para>
/// <para>
/// <b>Config mapping is explicit, flat, and section-free:</b> <c>ANTHROPIC_API_KEY</c> /
/// <c>ANTHROPIC_BASE_URL</c> are read directly via <see cref="IConfiguration"/> indexing — no section
/// binding. <b>Precedence:</b> the ctor-override delegate's values win over the flat keys (key
/// required; base URL ctor &gt; flat &gt; SDK default). Settings + the rewrite handler are both
/// resolved lazily at first resolve, so an unused provider never fails a fresh-scaffold boot.
/// </para>
/// </remarks>
public static class AnthropicServiceCollectionExtensions
{
    /// <summary>The named-<see cref="HttpClient"/> name for the Anthropic transport.</summary>
    public const string HttpClientName = "anthropic";

    private const string ApiKeyConfigKey = "ANTHROPIC_API_KEY";
    private const string BaseUrlConfigKey = "ANTHROPIC_BASE_URL";

    /// <summary>
    /// Registers the Anthropic provider building blocks and returns the keyed
    /// <see cref="IHttpClientBuilder"/> (for fn-4.4 to attach resilience once).
    /// </summary>
    /// <param name="services">The service collection.</param>
    /// <param name="configuration">
    /// Configuration carrying the flat <c>ANTHROPIC_API_KEY</c> / <c>ANTHROPIC_BASE_URL</c> keys.
    /// </param>
    /// <param name="configureOverride">
    /// Optional ctor-override: values set here win over the flat config keys.
    /// </param>
    /// <returns>The keyed <see cref="IHttpClientBuilder"/> for the <c>"anthropic"</c> transport client.</returns>
    public static IHttpClientBuilder AddAnthropicChatClient(
        this IServiceCollection services,
        IConfiguration configuration,
        Action<AnthropicChatClientSettings>? configureOverride = null) =>
        services.AddAnthropicChatClient(configuration, configureOverride, telemetryOptions: null);

    /// <summary>
    /// Registers the Anthropic provider building blocks (with GenAI telemetry tuning) and returns the
    /// keyed <see cref="IHttpClientBuilder"/>.
    /// </summary>
    /// <param name="services">The service collection.</param>
    /// <param name="configuration">
    /// Configuration carrying the flat <c>ANTHROPIC_API_KEY</c> / <c>ANTHROPIC_BASE_URL</c> keys.
    /// </param>
    /// <param name="configureOverride">
    /// Optional ctor-override: values set here win over the flat config keys.
    /// </param>
    /// <param name="telemetryOptions">
    /// GenAI telemetry tuning (content-capture gate; default off) passed to the client. Spans + metrics
    /// are emitted regardless; <c>null</c> ⇒ defaults.
    /// </param>
    /// <returns>The keyed <see cref="IHttpClientBuilder"/> for the <c>"anthropic"</c> transport client.</returns>
    public static IHttpClientBuilder AddAnthropicChatClient(
        this IServiceCollection services,
        IConfiguration configuration,
        Action<AnthropicChatClientSettings>? configureOverride,
        ParleyAiTelemetryOptions? telemetryOptions)
    {
        ArgumentNullException.ThrowIfNull(services);
        ArgumentNullException.ThrowIfNull(configuration);

        // Named, singleton-safe HttpClient: a SocketsHttpHandler with a bounded
        // PooledConnectionLifetime keeps DNS fresh while letting the handler be reused for the
        // app lifetime (no captive-dependency / stale-handler problems). The origin-rewrite +
        // error-capture handler is attached HERE, in the transport pipeline, because the SDK emits
        // absolute URIs that ignore HttpClient.BaseAddress and a handler cannot be grafted onto an
        // HttpClient post-construction — so DI is the single place that wires it (the public
        // construction path). Its base URL is resolved lazily (at handler construction, not at
        // registration) so an unused/misconfigured provider does not fail a fresh-scaffold boot.
        IHttpClientBuilder httpClientBuilder = services
            .AddHttpClient(HttpClientName)
            .ConfigurePrimaryHttpMessageHandler(static () => new SocketsHttpHandler
            {
                PooledConnectionLifetime = TimeSpan.FromMinutes(2),
            })
            .AddHttpMessageHandler(() =>
            {
                AnthropicChatClientSettings settings = ResolveSettings(configuration, configureOverride);
                return new AnthropicOriginRewriteHandler(settings.BaseUrl);
            });

        // Keyed CONCRETE client. Settings are resolved lazily at first resolve (not at
        // registration). NOTE: the public keyed IAiChatClient is deliberately NOT registered here
        // (fn-4.4).
        services.AddKeyedSingleton(ProviderKeys.Anthropic, (sp, _) =>
        {
            AnthropicChatClientSettings settings = ResolveSettings(configuration, configureOverride);
            IHttpClientFactory httpClientFactory = sp.GetRequiredService<IHttpClientFactory>();
            HttpClient httpClient = httpClientFactory.CreateClient(HttpClientName);
            return new AnthropicChatClient(settings, httpClient, telemetryOptions);
        });

        return httpClientBuilder;
    }

    /// <summary>
    /// Opt-in: validates the Anthropic client can be constructed (key present, base URL root-only)
    /// at host start, surfacing config errors eagerly instead of on first call.
    /// </summary>
    /// <param name="services">The service collection.</param>
    /// <returns>The same service collection for chaining.</returns>
    public static IServiceCollection ValidateAnthropicChatClientOnStart(this IServiceCollection services)
    {
        ArgumentNullException.ThrowIfNull(services);

        services.AddHostedService<AnthropicStartupValidator>();
        return services;
    }

    internal static AnthropicChatClientSettings ResolveSettings(
        IConfiguration configuration,
        Action<AnthropicChatClientSettings>? configureOverride)
    {
        // Start from the flat config keys (read explicitly — no section binding).
        var settings = new AnthropicChatClientSettings
        {
            ApiKey = configuration[ApiKeyConfigKey],
            BaseUrl = configuration[BaseUrlConfigKey],
        };

        // Ctor override wins: the delegate mutates settings last, so any value it sets beats the
        // flat key (key precedence ctor > flat; base URL ctor > flat > SDK default).
        configureOverride?.Invoke(settings);
        return settings;
    }

    /// <summary>
    /// Resolves the keyed concrete client once at startup to force lazy validation eagerly.
    /// </summary>
    private sealed class AnthropicStartupValidator : IHostedService
    {
        private readonly IServiceProvider _services;

        public AnthropicStartupValidator(IServiceProvider services) => _services = services;

        public System.Threading.Tasks.Task StartAsync(System.Threading.CancellationToken cancellationToken)
        {
            // Force construction (and thus validation) of the keyed client.
            _ = _services.GetRequiredKeyedService<AnthropicChatClient>(ProviderKeys.Anthropic);
            return System.Threading.Tasks.Task.CompletedTask;
        }

        public System.Threading.Tasks.Task StopAsync(System.Threading.CancellationToken cancellationToken) =>
            System.Threading.Tasks.Task.CompletedTask;
    }
}

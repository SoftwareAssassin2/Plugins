using System;
using System.Net.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using ParleyAI.Abstractions;

namespace ParleyAI.Providers.OpenAi;

/// <summary>
/// DI building blocks for the OpenAI provider.
/// </summary>
/// <remarks>
/// <para>
/// <see cref="AddOpenAiChatClient(IServiceCollection, IConfiguration, Action{OpenAiChatClientSettings}?)"/>
/// is a documented building block; the public no-glue consumer API is <c>AddParleyAi</c> (fn-4.4).
/// It registers a named, singleton-safe <see cref="HttpClient"/> (<c>"openai"</c>) and a keyed
/// CONCRETE <see cref="OpenAiChatClient"/> under <see cref="ProviderKeys.OpenAi"/>; it does NOT
/// register a public keyed <see cref="IAiChatClient"/> — that composition (with the AIMD
/// decorator) is fn-4.4's job. It returns the keyed <see cref="IHttpClientBuilder"/> so fn-4.4
/// can attach the resilience handler exactly once.
/// </para>
/// <para>
/// <b>Config mapping is explicit, flat, and section-free:</b> <c>OPENAI_API_KEY</c> /
/// <c>OPENAI_BASE_URL</c> are read directly via <see cref="IConfiguration"/> indexing — no
/// section binding. <b>Precedence:</b> the ctor-override delegate's values win over the flat keys
/// (key required; base URL ctor &gt; flat &gt; SDK default).
/// </para>
/// </remarks>
public static class OpenAiServiceCollectionExtensions
{
    /// <summary>The named-<see cref="HttpClient"/> name for the OpenAI transport.</summary>
    public const string HttpClientName = "openai";

    private const string ApiKeyConfigKey = "OPENAI_API_KEY";
    private const string BaseUrlConfigKey = "OPENAI_BASE_URL";

    /// <summary>
    /// Registers the OpenAI provider building blocks and returns the keyed
    /// <see cref="IHttpClientBuilder"/> (for fn-4.4 to attach resilience once).
    /// </summary>
    /// <param name="services">The service collection.</param>
    /// <param name="configuration">
    /// Configuration carrying the flat <c>OPENAI_API_KEY</c> / <c>OPENAI_BASE_URL</c> keys.
    /// </param>
    /// <param name="configureOverride">
    /// Optional ctor-override: values set here win over the flat config keys.
    /// </param>
    /// <returns>The keyed <see cref="IHttpClientBuilder"/> for the <c>"openai"</c> transport client.</returns>
    public static IHttpClientBuilder AddOpenAiChatClient(
        this IServiceCollection services,
        IConfiguration configuration,
        Action<OpenAiChatClientSettings>? configureOverride = null)
    {
        ArgumentNullException.ThrowIfNull(services);
        ArgumentNullException.ThrowIfNull(configuration);

        // Named, singleton-safe HttpClient: a SocketsHttpHandler with a bounded
        // PooledConnectionLifetime keeps DNS fresh while letting the handler be reused for the
        // app lifetime (no captive-dependency / stale-handler problems).
        IHttpClientBuilder httpClientBuilder = services
            .AddHttpClient(HttpClientName)
            .ConfigurePrimaryHttpMessageHandler(static () => new SocketsHttpHandler
            {
                PooledConnectionLifetime = TimeSpan.FromMinutes(2),
            });

        // Keyed CONCRETE client. Settings are resolved lazily at first resolve (not at
        // registration) so an unused provider never fails a fresh-scaffold boot. NOTE: the
        // public keyed IAiChatClient is deliberately NOT registered here (fn-4.4).
        services.AddKeyedSingleton(ProviderKeys.OpenAi, (sp, _) =>
        {
            OpenAiChatClientSettings settings = ResolveSettings(configuration, configureOverride);
            IHttpClientFactory httpClientFactory = sp.GetRequiredService<IHttpClientFactory>();
            HttpClient httpClient = httpClientFactory.CreateClient(HttpClientName);
            return new OpenAiChatClient(settings, httpClient);
        });

        return httpClientBuilder;
    }

    /// <summary>
    /// Opt-in: validates the OpenAI client can be constructed (key present, base URL absolute) at
    /// host start, surfacing config errors eagerly instead of on first call.
    /// </summary>
    /// <param name="services">The service collection.</param>
    /// <returns>The same service collection for chaining.</returns>
    public static IServiceCollection ValidateOpenAiChatClientOnStart(this IServiceCollection services)
    {
        ArgumentNullException.ThrowIfNull(services);

        services.AddHostedService<OpenAiStartupValidator>();
        return services;
    }

    internal static OpenAiChatClientSettings ResolveSettings(
        IConfiguration configuration,
        Action<OpenAiChatClientSettings>? configureOverride)
    {
        // Start from the flat config keys (read explicitly — no section binding).
        var settings = new OpenAiChatClientSettings
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
    private sealed class OpenAiStartupValidator : IHostedService
    {
        private readonly IServiceProvider _services;

        public OpenAiStartupValidator(IServiceProvider services) => _services = services;

        public System.Threading.Tasks.Task StartAsync(System.Threading.CancellationToken cancellationToken)
        {
            // Force construction (and thus validation) of the keyed client.
            _ = _services.GetRequiredKeyedService<OpenAiChatClient>(ProviderKeys.OpenAi);
            return System.Threading.Tasks.Task.CompletedTask;
        }

        public System.Threading.Tasks.Task StopAsync(System.Threading.CancellationToken cancellationToken) =>
            System.Threading.Tasks.Task.CompletedTask;
    }
}

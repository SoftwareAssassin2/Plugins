using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Polly;
using Polly.Timeout; // AddTimeout's strategy types live here; the extension itself is in the Polly namespace.
using ParleyAI.Abstractions;
using ParleyAI.DependencyInjection;
using ParleyAI.Providers.Anthropic;
using ParleyAI.Providers.OpenAi;
using Xunit;

namespace ParleyAI.Tests.DependencyInjection;

/// <summary>
/// Tests for the public no-glue <c>AddParleyAi</c> composition (fn-4.4) WITHOUT any AIMD decorator:
/// keyed resolution returns a working bare client; unkeyed throws; the <see cref="IAiChatClientFactory"/>
/// resolves by key; the optional <see cref="AiChatClientDecorator"/> hook is applied when present;
/// the ctor-override precedence holds through the public path; and the resilience pipeline is
/// attached EXACTLY ONCE (the single HTTP retry authority — no stacking with the SDK-native retry
/// disabled in .2/.3), retrying true transient failures but NEVER a <c>429</c>.
/// </summary>
public sealed class ParleyAiServiceCollectionExtensionsTests
{
    private static IConfiguration Config(params (string Key, string Value)[] pairs)
    {
        var dict = new Dictionary<string, string?>();
        foreach ((string key, string value) in pairs)
        {
            dict[key] = value;
        }

        return new ConfigurationBuilder().AddInMemoryCollection(dict).Build();
    }

    private static IConfiguration BothProvidersConfigured() => Config(
        ("OPENAI_API_KEY", "sk-openai"),
        ("OPENAI_BASE_URL", "http://localhost:4010/v1"),
        ("ANTHROPIC_API_KEY", "sk-ant"),
        ("ANTHROPIC_BASE_URL", "http://localhost:4011"));

    /// <summary>
    /// A counting fake handler: records every attempt and replays a per-attempt response built FRESH
    /// each send (an HttpResponseMessage cannot be re-sent once consumed). Used to assert the
    /// resilience handler's attempt count.
    /// </summary>
    private sealed class CountingHandler : HttpMessageHandler
    {
        private readonly Func<int, HttpResponseMessage> _perAttempt;

        public CountingHandler(Func<int, HttpResponseMessage> perAttempt) => _perAttempt = perAttempt;

        public int Attempts { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Attempts++;
            return Task.FromResult(_perAttempt(Attempts));
        }

        public static HttpResponseMessage Error(HttpStatusCode status) =>
            new(status) { Content = new StringContent("{\"error\":{\"message\":\"boom\"}}") };

        public static HttpResponseMessage Ok() =>
            ParleyAI.Tests.OpenAi.FakeHttpMessageHandler.Completion();
    }

    private static ChatRequest SampleRequest() =>
        new("gpt-4o", new[] { new ChatMessage(Role.User, "hi") });

    [Fact]
    public void Keyed_public_client_resolves_for_both_providers_and_unkeyed_throws()
    {
        var services = new ServiceCollection();
        services.AddParleyAi(BothProvidersConfigured());

        using ServiceProvider provider = services.BuildServiceProvider();

        // The PUBLIC keyed IAiChatClient resolves for both providers...
        Assert.NotNull(provider.GetRequiredKeyedService<IAiChatClient>(ProviderKeys.OpenAi));
        Assert.NotNull(provider.GetRequiredKeyedService<IAiChatClient>(ProviderKeys.Anthropic));

        // ...but there is NO unkeyed default — unkeyed resolution throws.
        Assert.Throws<InvalidOperationException>(() => provider.GetRequiredService<IAiChatClient>());
        Assert.Null(provider.GetService<IAiChatClient>());
    }

    [Fact]
    public void Both_providers_are_injectable_in_one_scope()
    {
        var services = new ServiceCollection();
        services.AddParleyAi(BothProvidersConfigured());
        using ServiceProvider provider = services.BuildServiceProvider();

        IAiChatClient openai = provider.GetRequiredKeyedService<IAiChatClient>(ProviderKeys.OpenAi);
        IAiChatClient anthropic = provider.GetRequiredKeyedService<IAiChatClient>(ProviderKeys.Anthropic);

        // Two distinct, concurrently-usable clients in the same scope.
        Assert.NotSame(openai, anthropic);
    }

    [Fact]
    public void Factory_resolves_the_public_keyed_client_by_key()
    {
        var services = new ServiceCollection();
        services.AddParleyAi(BothProvidersConfigured());
        using ServiceProvider provider = services.BuildServiceProvider();

        var factory = provider.GetRequiredService<IAiChatClientFactory>();

        IAiChatClient viaFactory = factory.Create(ProviderKeys.OpenAi);
        IAiChatClient viaKeyed = provider.GetRequiredKeyedService<IAiChatClient>(ProviderKeys.OpenAi);

        // The factory returns the SAME (singleton) composed client the keyed resolution returns.
        Assert.Same(viaKeyed, viaFactory);
        Assert.NotNull(factory.Create(ProviderKeys.Anthropic));
    }

    [Fact]
    public void With_aimd_disabled_per_provider_the_public_client_is_the_bare_provider()
    {
        var services = new ServiceCollection();
        // fn-4.5 wires the AIMD decorator ON by default; the per-provider off switch
        // (AimdOptions.Enabled == false) makes the public keyed client the bare concrete provider.
        services.AddParleyAi(BothProvidersConfigured(), opts =>
            opts.ConfigureOpenAiAimd = a => a.Enabled = false);
        using ServiceProvider provider = services.BuildServiceProvider();

        var bare = provider.GetRequiredKeyedService<OpenAiChatClient>(ProviderKeys.OpenAi);
        var publicClient = provider.GetRequiredKeyedService<IAiChatClient>(ProviderKeys.OpenAi);
        Assert.Same(bare, publicClient);
    }

    private sealed class WrappingClient : IAiChatClient
    {
        public WrappingClient(IAiChatClient inner, string providerKey)
        {
            Inner = inner;
            ProviderKey = providerKey;
        }

        public IAiChatClient Inner { get; }

        public string ProviderKey { get; }

        public Task<ChatResponse> CompleteChatAsync(ChatRequest request, CancellationToken cancellationToken = default) =>
            Inner.CompleteChatAsync(request, cancellationToken);
    }

    [Fact]
    public void When_a_decorator_is_registered_compose_applies_it_to_the_bare_provider()
    {
        var services = new ServiceCollection();
        services.AddParleyAi(BothProvidersConfigured());

        // Simulate fn-4.5: register the single optional decorator hook as the EXACT spec-defined
        // Func<IServiceProvider, string, IAiChatClient, IAiChatClient> delegate (no descriptor surgery).
        services.AddSingleton<Func<IServiceProvider, string, IAiChatClient, IAiChatClient>>(
            (_, key, inner) => new WrappingClient(inner, key));

        using ServiceProvider provider = services.BuildServiceProvider();

        var bare = provider.GetRequiredKeyedService<OpenAiChatClient>(ProviderKeys.OpenAi);
        var publicClient = provider.GetRequiredKeyedService<IAiChatClient>(ProviderKeys.OpenAi);

        var wrapped = Assert.IsType<WrappingClient>(publicClient);
        Assert.Same(bare, wrapped.Inner);
        Assert.Equal(ProviderKeys.OpenAi, wrapped.ProviderKey);
    }

    [Fact]
    public void Ctor_override_beats_populated_flat_config_through_AddParleyAi_for_both_providers()
    {
        // Flat config populated for BOTH providers; the ctor-override delegates must win.
        IConfiguration config = Config(
            ("OPENAI_API_KEY", "sk-openai-flat"),
            ("OPENAI_BASE_URL", "http://flat-openai:1/v1"),
            ("ANTHROPIC_API_KEY", "sk-ant-flat"),
            ("ANTHROPIC_BASE_URL", "http://flat-anthropic:1"));

        OpenAiChatClientSettings? openAiResolved = null;
        AnthropicChatClientSettings? anthropicResolved = null;

        var services = new ServiceCollection();
        services.AddParleyAi(config, opts =>
        {
            opts.ConfigureOpenAi = s =>
            {
                s.ApiKey = "sk-openai-ctor";
                s.BaseUrl = "http://ctor-openai:2/v1";
                openAiResolved = s;
            };
            opts.ConfigureAnthropic = s =>
            {
                s.ApiKey = "sk-ant-ctor";
                s.BaseUrl = "http://ctor-anthropic:2";
                anthropicResolved = s;
            };
        });

        using ServiceProvider provider = services.BuildServiceProvider();

        // Force construction so the override delegates run.
        _ = provider.GetRequiredKeyedService<IAiChatClient>(ProviderKeys.OpenAi);
        _ = provider.GetRequiredKeyedService<IAiChatClient>(ProviderKeys.Anthropic);

        Assert.NotNull(openAiResolved);
        Assert.Equal("sk-openai-ctor", openAiResolved!.ApiKey);
        Assert.Equal("http://ctor-openai:2/v1", openAiResolved.BaseUrl);

        Assert.NotNull(anthropicResolved);
        Assert.Equal("sk-ant-ctor", anthropicResolved!.ApiKey);
        Assert.Equal("http://ctor-anthropic:2", anthropicResolved.BaseUrl);
    }

    [Fact]
    public void Ctor_override_overload_supplies_both_providers_with_no_flat_config()
    {
        // The (configureOpenAi, configureAnthropic) overload uses an internal empty IConfiguration —
        // the ctor delegates fully supply base URL + key, so both providers resolve with NO flat config.
        var services = new ServiceCollection();
        services.AddParleyAi(
            configureOpenAi: s => { s.ApiKey = "sk-openai-ctor"; s.BaseUrl = "http://ctor-openai:2/v1"; },
            configureAnthropic: s => { s.ApiKey = "sk-ant-ctor"; s.BaseUrl = "http://ctor-anthropic:2"; });

        using ServiceProvider provider = services.BuildServiceProvider();

        Assert.NotNull(provider.GetRequiredKeyedService<IAiChatClient>(ProviderKeys.OpenAi));
        Assert.NotNull(provider.GetRequiredKeyedService<IAiChatClient>(ProviderKeys.Anthropic));
        Assert.NotNull(provider.GetRequiredService<IAiChatClientFactory>().Create(ProviderKeys.OpenAi));
    }

    [Fact]
    public async Task Resilience_is_attached_once_and_retries_a_transient_5xx()
    {
        // One logical call hitting a retryable TRANSIENT 5xx must produce 1 + MaxRetryAttempts HTTP
        // attempts — proving the resilience retry is present exactly once and the SDK-native retry
        // (disabled in .2/.3) does NOT stack on top of it.
        var counting = new CountingHandler(_ => CountingHandler.Error(HttpStatusCode.ServiceUnavailable));

        var services = new ServiceCollection();
        services.AddParleyAi(Config(("OPENAI_API_KEY", "sk-openai")), opts =>
            opts.ConfigureOpenAiResilience = r =>
            {
                r.MaxRetryAttempts = 2;
                r.BaseRetryDelay = TimeSpan.Zero; // keep the test fast
            });

        // Swap the "openai" transport's PRIMARY handler for the counting fake (resilience stays in
        // the pipeline above it).
        services.AddHttpClient(OpenAiServiceCollectionExtensions.HttpClientName)
            .ConfigurePrimaryHttpMessageHandler(() => counting);

        using ServiceProvider provider = services.BuildServiceProvider();
        var client = provider.GetRequiredKeyedService<IAiChatClient>(ProviderKeys.OpenAi);

        await Assert.ThrowsAsync<ParleyAIException>(() => client.CompleteChatAsync(SampleRequest()));

        // 1 initial + 2 retries = 3 attempts (single retry authority, no doubling).
        Assert.Equal(3, counting.Attempts);
    }

    [Fact]
    public async Task A_non_transient_5xx_is_not_retried()
    {
        // Only SELECTED 5xx are transient (500/502/503/504). A 501 Not Implemented is NOT transient
        // and must surface immediately (one attempt) despite a generous MaxRetryAttempts.
        var counting = new CountingHandler(_ => CountingHandler.Error(HttpStatusCode.NotImplemented));

        var services = new ServiceCollection();
        services.AddParleyAi(Config(("OPENAI_API_KEY", "sk-openai")), opts =>
            opts.ConfigureOpenAiResilience = r =>
            {
                r.MaxRetryAttempts = 3;
                r.BaseRetryDelay = TimeSpan.Zero;
            });

        services.AddHttpClient(OpenAiServiceCollectionExtensions.HttpClientName)
            .ConfigurePrimaryHttpMessageHandler(() => counting);

        using ServiceProvider provider = services.BuildServiceProvider();
        var client = provider.GetRequiredKeyedService<IAiChatClient>(ProviderKeys.OpenAi);

        await Assert.ThrowsAsync<ParleyAIException>(() => client.CompleteChatAsync(SampleRequest()));

        Assert.Equal(1, counting.Attempts);
    }

    [Fact]
    public async Task With_resilience_disabled_a_transient_5xx_makes_exactly_one_attempt()
    {
        // Resilience OFF → no retry handler → exactly ONE HTTP attempt (no SDK-native retry either).
        var counting = new CountingHandler(_ => CountingHandler.Error(HttpStatusCode.ServiceUnavailable));

        var services = new ServiceCollection();
        services.AddParleyAi(Config(("OPENAI_API_KEY", "sk-openai")), opts =>
            opts.ConfigureOpenAiResilience = r => r.Enabled = false);

        services.AddHttpClient(OpenAiServiceCollectionExtensions.HttpClientName)
            .ConfigurePrimaryHttpMessageHandler(() => counting);

        using ServiceProvider provider = services.BuildServiceProvider();
        var client = provider.GetRequiredKeyedService<IAiChatClient>(ProviderKeys.OpenAi);

        await Assert.ThrowsAsync<ParleyAIException>(() => client.CompleteChatAsync(SampleRequest()));

        Assert.Equal(1, counting.Attempts);
    }

    [Fact]
    public async Task A_429_is_not_retried_by_resilience_and_surfaces_immediately()
    {
        // A 429 must NOT be retried by the resilience handler — it surfaces immediately (one attempt)
        // as a mapped ParleyAIException so the AIMD decorator (fn-4.5) sees the rate-limit signal.
        var counting = new CountingHandler(_ => CountingHandler.Error(HttpStatusCode.TooManyRequests));

        var services = new ServiceCollection();
        services.AddParleyAi(Config(("OPENAI_API_KEY", "sk-openai")), opts =>
            opts.ConfigureOpenAiResilience = r =>
            {
                r.MaxRetryAttempts = 3;
                r.BaseRetryDelay = TimeSpan.Zero;
            });

        services.AddHttpClient(OpenAiServiceCollectionExtensions.HttpClientName)
            .ConfigurePrimaryHttpMessageHandler(() => counting);

        using ServiceProvider provider = services.BuildServiceProvider();
        var client = provider.GetRequiredKeyedService<IAiChatClient>(ProviderKeys.OpenAi);

        await Assert.ThrowsAsync<ParleyAIException>(() => client.CompleteChatAsync(SampleRequest()));

        // Exactly ONE attempt despite MaxRetryAttempts=3 — the retry predicate excludes 429.
        Assert.Equal(1, counting.Attempts);
    }

    [Fact]
    public async Task Resilience_is_attached_through_the_anthropic_builder_and_retries_a_transient_5xx()
    {
        // Per-provider attachment: the same retry behavior must hold through the ANTHROPIC builder,
        // proving resilience is wired to its keyed transport (not just OpenAI's).
        var counting = new CountingHandler(_ => CountingHandler.Error(HttpStatusCode.ServiceUnavailable));

        var services = new ServiceCollection();
        services.AddParleyAi(
            Config(("ANTHROPIC_API_KEY", "sk-ant"), ("ANTHROPIC_BASE_URL", "http://localhost:4011")),
            opts => opts.ConfigureAnthropicResilience = r =>
            {
                r.MaxRetryAttempts = 2;
                r.BaseRetryDelay = TimeSpan.Zero;
            });

        services.AddHttpClient(AnthropicServiceCollectionExtensions.HttpClientName)
            .ConfigurePrimaryHttpMessageHandler(() => counting);

        using ServiceProvider provider = services.BuildServiceProvider();
        var client = provider.GetRequiredKeyedService<IAiChatClient>(ProviderKeys.Anthropic);

        await Assert.ThrowsAsync<ParleyAIException>(() => client.CompleteChatAsync(
            new ChatRequest("claude-3-5-sonnet", new[] { new ChatMessage(Role.User, "hi") })));

        // 1 initial + 2 retries = 3 attempts through the Anthropic pipeline.
        Assert.Equal(3, counting.Attempts);
    }

    [Fact]
    public async Task A_429_through_the_anthropic_builder_is_not_retried()
    {
        // A 429 must surface immediately through the Anthropic pipeline too (no retry → AIMD signal).
        var counting = new CountingHandler(_ => CountingHandler.Error(HttpStatusCode.TooManyRequests));

        var services = new ServiceCollection();
        services.AddParleyAi(
            Config(("ANTHROPIC_API_KEY", "sk-ant"), ("ANTHROPIC_BASE_URL", "http://localhost:4011")),
            opts => opts.ConfigureAnthropicResilience = r =>
            {
                r.MaxRetryAttempts = 3;
                r.BaseRetryDelay = TimeSpan.Zero;
            });

        services.AddHttpClient(AnthropicServiceCollectionExtensions.HttpClientName)
            .ConfigurePrimaryHttpMessageHandler(() => counting);

        using ServiceProvider provider = services.BuildServiceProvider();
        var client = provider.GetRequiredKeyedService<IAiChatClient>(ProviderKeys.Anthropic);

        await Assert.ThrowsAsync<ParleyAIException>(() => client.CompleteChatAsync(
            new ChatRequest("claude-3-5-sonnet", new[] { new ChatMessage(Role.User, "hi") })));

        Assert.Equal(1, counting.Attempts);
    }

    [Fact]
    public async Task A_full_pipeline_replacement_takes_precedence_over_the_default_knobs()
    {
        // ConfigurePipeline replaces the whole pipeline: here, NO retry strategy at all → one attempt
        // even on a 5xx, proving the replacement wins over MaxRetryAttempts.
        var counting = new CountingHandler(_ => CountingHandler.Error(HttpStatusCode.ServiceUnavailable));

        var services = new ServiceCollection();
        services.AddParleyAi(Config(("OPENAI_API_KEY", "sk-openai")), opts =>
            opts.ConfigureOpenAiResilience = r =>
            {
                r.MaxRetryAttempts = 5; // ignored because ConfigurePipeline is set
                r.ConfigurePipeline = (builder, _) => builder.AddTimeout(TimeSpan.FromSeconds(30));
            });

        services.AddHttpClient(OpenAiServiceCollectionExtensions.HttpClientName)
            .ConfigurePrimaryHttpMessageHandler(() => counting);

        using ServiceProvider provider = services.BuildServiceProvider();
        var client = provider.GetRequiredKeyedService<IAiChatClient>(ProviderKeys.OpenAi);

        await Assert.ThrowsAsync<ParleyAIException>(() => client.CompleteChatAsync(SampleRequest()));

        Assert.Equal(1, counting.Attempts);
    }
}

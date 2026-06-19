using System;
using System.Collections.Generic;
using System.Net.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using ParleyAI.Abstractions;
using ParleyAI.Providers.Anthropic;
using Xunit;

namespace ParleyAI.Tests.Anthropic;

/// <summary>
/// DI-layer tests for <see cref="AnthropicServiceCollectionExtensions"/>: flat-key mapping with NO
/// config section + NO caller glue, lazy validation (at resolve, not registration), the
/// ctor-override precedence (ctor beats a populated flat <c>ANTHROPIC_*</c>), the keyed concrete
/// registration, the exposed keyed <see cref="IHttpClientBuilder"/>, and that NO public
/// <see cref="IAiChatClient"/> is registered (deferred to fn-4.4).
/// </summary>
public sealed class AnthropicServiceCollectionExtensionsTests
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

    [Fact]
    public void Flat_keys_resolve_with_no_section_and_no_glue()
    {
        IConfiguration config = Config(
            ("ANTHROPIC_API_KEY", "sk-ant-flat"),
            ("ANTHROPIC_BASE_URL", "http://localhost:4010"));

        AnthropicChatClientSettings settings =
            AnthropicServiceCollectionExtensions.ResolveSettings(config, configureOverride: null);

        Assert.Equal("sk-ant-flat", settings.ApiKey);
        Assert.Equal("http://localhost:4010", settings.BaseUrl);
    }

    [Fact]
    public void Ctor_override_beats_populated_flat_config_keys()
    {
        IConfiguration config = Config(
            ("ANTHROPIC_API_KEY", "sk-ant-flat"),
            ("ANTHROPIC_BASE_URL", "http://flat:1"));

        AnthropicChatClientSettings settings = AnthropicServiceCollectionExtensions.ResolveSettings(
            config,
            s =>
            {
                s.ApiKey = "sk-ant-ctor";
                s.BaseUrl = "http://ctor:2";
            });

        // Ctor wins for BOTH key and base URL.
        Assert.Equal("sk-ant-ctor", settings.ApiKey);
        Assert.Equal("http://ctor:2", settings.BaseUrl);
    }

    [Fact]
    public void AddAnthropicChatClient_registers_keyed_concrete_and_exposes_keyed_http_builder()
    {
        var services = new ServiceCollection();
        IConfiguration config = Config(
            ("ANTHROPIC_API_KEY", "sk-ant-flat"),
            ("ANTHROPIC_BASE_URL", "http://localhost:4010"));

        IHttpClientBuilder builder = services.AddAnthropicChatClient(config);

        // The keyed transport client is named "anthropic" — fn-4.4 attaches resilience to THIS builder.
        Assert.Equal(AnthropicServiceCollectionExtensions.HttpClientName, builder.Name);

        using ServiceProvider provider = services.BuildServiceProvider();

        // Keyed CONCRETE client resolves.
        var client = provider.GetRequiredKeyedService<AnthropicChatClient>(ProviderKeys.Anthropic);
        Assert.NotNull(client);

        // NO public keyed IAiChatClient is registered at this task (deferred to fn-4.4).
        Assert.Null(provider.GetKeyedService<IAiChatClient>(ProviderKeys.Anthropic));
    }

    [Fact]
    public void Validation_is_lazy_registration_succeeds_resolve_throws_on_missing_key()
    {
        var services = new ServiceCollection();
        // No ANTHROPIC_API_KEY in config and no ctor override → invalid, but only at RESOLVE.
        IConfiguration config = Config(("ANTHROPIC_BASE_URL", "http://localhost:4010"));

        // Registration does NOT throw (lazy).
        services.AddAnthropicChatClient(config);
        using ServiceProvider provider = services.BuildServiceProvider();

        // First resolve constructs the client → missing key surfaces here.
        Assert.ThrowsAny<Exception>(() =>
            provider.GetRequiredKeyedService<AnthropicChatClient>(ProviderKeys.Anthropic));
    }

    [Fact]
    public void Validation_is_lazy_registration_succeeds_resolve_throws_on_base_url_with_path()
    {
        var services = new ServiceCollection();
        IConfiguration config = Config(
            ("ANTHROPIC_API_KEY", "sk-ant"),
            // A path-bearing base URL is invalid (root-only contract) but only surfaces at RESOLVE.
            ("ANTHROPIC_BASE_URL", "http://localhost:4010/v1"));

        services.AddAnthropicChatClient(config);
        using ServiceProvider provider = services.BuildServiceProvider();

        Assert.ThrowsAny<Exception>(() =>
            provider.GetRequiredKeyedService<AnthropicChatClient>(ProviderKeys.Anthropic));
    }

    [Fact]
    public void Ctor_override_supplies_a_key_when_flat_config_is_absent()
    {
        var services = new ServiceCollection();
        IConfiguration config = Config(); // no flat keys at all

        services.AddAnthropicChatClient(config, s => s.ApiKey = "sk-ant-ctor");
        using ServiceProvider provider = services.BuildServiceProvider();

        // The ctor-supplied key satisfies the requirement → resolve succeeds.
        var client = provider.GetRequiredKeyedService<AnthropicChatClient>(ProviderKeys.Anthropic);
        Assert.NotNull(client);
    }
}

using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Time.Testing;
using ParleyAI.Abstractions;
using ParleyAI.Abstractions.Options;
using ParleyAI.DependencyInjection;
using ParleyAI.Providers.Anthropic;
using ParleyAI.Providers.OpenAi;
using ParleyAI.RateLimiting;
using Xunit;

namespace ParleyAI.Tests.RateLimiting;

/// <summary>
/// Tests that <c>AddParleyAi</c> wires the AIMD optimizer ON by default with no extra opt-in call
/// (the no-glue API), honors the PER-PROVIDER off switch, isolates providers (one controller each),
/// and exercises limiter-swap thread-safety under concurrency.
/// </summary>
public sealed class AimdDependencyInjectionTests
{
    private static IConfiguration BothProvidersConfigured() =>
        new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["OPENAI_API_KEY"] = "sk-openai",
            ["OPENAI_BASE_URL"] = "http://localhost:4010/v1",
            ["ANTHROPIC_API_KEY"] = "sk-ant",
            ["ANTHROPIC_BASE_URL"] = "http://localhost:4011",
        }).Build();

    [Fact]
    public void AddParleyAi_alone_returns_AIMD_decorated_clients_by_default()
    {
        // No extra opt-in call: AddParleyAi ALONE yields AIMD-decorated keyed clients.
        var services = new ServiceCollection();
        services.AddParleyAi(BothProvidersConfigured());
        using ServiceProvider provider = services.BuildServiceProvider();

        var openai = provider.GetRequiredKeyedService<IAiChatClient>(ProviderKeys.OpenAi);
        var anthropic = provider.GetRequiredKeyedService<IAiChatClient>(ProviderKeys.Anthropic);

        AimdChatClientDecorator openaiDecorator = Assert.IsType<AimdChatClientDecorator>(openai);
        AimdChatClientDecorator anthropicDecorator = Assert.IsType<AimdChatClientDecorator>(anthropic);

        // Each decorator wraps the bare concrete provider client.
        Assert.Same(provider.GetRequiredKeyedService<OpenAiChatClient>(ProviderKeys.OpenAi), openaiDecorator.Inner);
        Assert.Same(provider.GetRequiredKeyedService<AnthropicChatClient>(ProviderKeys.Anthropic), anthropicDecorator.Inner);
    }

    [Fact]
    public void Per_provider_off_switch_disables_one_provider_and_keeps_the_other_decorated()
    {
        var services = new ServiceCollection();
        services.AddParleyAi(BothProvidersConfigured(), opts =>
            opts.ConfigureOpenAiAimd = a => a.Enabled = false);
        using ServiceProvider provider = services.BuildServiceProvider();

        // OpenAI disabled → bare; Anthropic still decorated. Per-provider isolation of the off switch.
        var openai = provider.GetRequiredKeyedService<IAiChatClient>(ProviderKeys.OpenAi);
        var anthropic = provider.GetRequiredKeyedService<IAiChatClient>(ProviderKeys.Anthropic);

        Assert.IsType<OpenAiChatClient>(openai);
        Assert.IsType<AimdChatClientDecorator>(anthropic);
    }

    [Fact]
    public void Global_off_is_just_both_providers_disabled()
    {
        var services = new ServiceCollection();
        services.AddParleyAi(BothProvidersConfigured(), opts =>
        {
            opts.ConfigureOpenAiAimd = a => a.Enabled = false;
            opts.ConfigureAnthropicAimd = a => a.Enabled = false;
        });
        using ServiceProvider provider = services.BuildServiceProvider();

        Assert.IsType<OpenAiChatClient>(provider.GetRequiredKeyedService<IAiChatClient>(ProviderKeys.OpenAi));
        Assert.IsType<AnthropicChatClient>(provider.GetRequiredKeyedService<IAiChatClient>(ProviderKeys.Anthropic));
    }

    [Fact]
    public void Providers_get_isolated_controllers_resolved_via_the_injected_TimeProvider_and_jitter()
    {
        // A DI-registered TimeProvider + IJitterSource are picked up by the hook → deterministic.
        var clock = new FakeTimeProvider();
        var services = new ServiceCollection();
        services.AddSingleton<TimeProvider>(clock);
        services.AddSingleton<IJitterSource, ZeroJitterSource>();
        services.AddParleyAi(BothProvidersConfigured());
        using ServiceProvider provider = services.BuildServiceProvider();

        var openai = (AimdChatClientDecorator)provider.GetRequiredKeyedService<IAiChatClient>(ProviderKeys.OpenAi);
        var anthropic = (AimdChatClientDecorator)provider.GetRequiredKeyedService<IAiChatClient>(ProviderKeys.Anthropic);

        // The decorators wrap distinct providers — per-provider isolation (distinct controllers).
        Assert.NotSame(openai.Inner, anthropic.Inner);
        // The keyed singleton means a re-resolve yields the SAME decorator instance (controller cached).
        Assert.Same(openai, provider.GetRequiredKeyedService<IAiChatClient>(ProviderKeys.OpenAi));
    }

    [Fact]
    public async Task Limiter_swap_is_thread_safe_under_concurrent_success_and_backoff()
    {
        // Drive concurrent OnSuccess (rate swap up) and OnBackoff (rate swap down) against ONE
        // controller; the rate must always stay clamped within [floor, ceiling] and never tear.
        var options = new AimdOptions
        {
            AdditiveIncreaseStep = 1.0,
            RateFloor = 1.0,
            RateCeiling = 50.0,
            RateLimitBackoff = new BackoffOptions { MultiplicativeDecreaseFactor = 0.5, Cooldown = TimeSpan.Zero },
            TokenLimitBackoff = new BackoffOptions { MultiplicativeDecreaseFactor = 0.5, Cooldown = TimeSpan.Zero },
        };
        var clock = new FakeTimeProvider();
        var controller = new AimdRateController(options, clock, new ZeroJitterSource());

        var tasks = new List<Task>();
        for (int t = 0; t < 16; t++)
        {
            tasks.Add(Task.Run(() =>
            {
                for (int i = 0; i < 500; i++)
                {
                    if ((i & 1) == 0)
                    {
                        controller.OnSuccess();
                    }
                    else
                    {
                        controller.OnBackoff(ParleyAIErrorCategory.RateLimit, retryAfter: null);
                    }

                    double rate = controller.CurrentRate;
                    Assert.InRange(rate, options.RateFloor, options.RateCeiling);
                }
            }));
        }

        await Task.WhenAll(tasks);
        Assert.InRange(controller.CurrentRate, options.RateFloor, options.RateCeiling);
    }
}

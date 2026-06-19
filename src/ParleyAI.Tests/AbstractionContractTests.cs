using System;
using System.Net;
using ParleyAI.Abstractions;
using ParleyAI.Abstractions.Options;
using Xunit;

namespace ParleyAI.Tests;

/// <summary>
/// fn-4.1 contract tests: the provider-neutral abstraction surface compiles, the
/// DTO/enum shapes are as specified, and <see cref="ParleyAIException"/> carries its
/// category / status / retry-after / provider-key payload. (Provider implementations,
/// DI wiring, and the override paths are fn-4.2+.)
/// </summary>
public sealed class AbstractionContractTests
{
    [Fact]
    public void Role_enum_pins_system_user_assistant()
    {
        Assert.Equal(0, (int)Role.System);
        Assert.Equal(1, (int)Role.User);
        Assert.Equal(2, (int)Role.Assistant);
        Assert.Equal(3, Enum.GetValues<Role>().Length);
    }

    [Fact]
    public void ChatRequest_preserves_model_message_order_and_optional_tuning()
    {
        var request = new ChatRequest(
            "gpt-4o",
            new[]
            {
                new ChatMessage(Role.System, "be terse"),
                new ChatMessage(Role.User, "hi"),
            })
        {
            MaxTokens = 256,
            Temperature = 0.2,
        };

        Assert.Equal("gpt-4o", request.Model);
        Assert.Equal(2, request.Messages.Count);
        Assert.Equal(Role.System, request.Messages[0].Role);
        Assert.Equal(Role.User, request.Messages[1].Role);
        Assert.Equal(256, request.MaxTokens);
        Assert.Equal(0.2, request.Temperature);
    }

    [Fact]
    public void ChatResponse_carries_content_usage_and_finish_reason()
    {
        var response = new ChatResponse("hello", new TokenUsage(10, 5), FinishReason.Stop);

        Assert.Equal("hello", response.Content);
        Assert.Equal(10, response.Usage.InputTokens);
        Assert.Equal(5, response.Usage.OutputTokens);
        Assert.Equal(15, response.Usage.TotalTokens);
        Assert.Equal(FinishReason.Stop, response.FinishReason);
    }

    [Fact]
    public void ParleyAIException_carries_category_status_retryafter_and_provider_key()
    {
        var inner = new InvalidOperationException("boom");
        var ex = new ParleyAIException(
            "rate limited",
            ParleyAIErrorCategory.RateLimit,
            ProviderKeys.OpenAi,
            HttpStatusCode.TooManyRequests,
            TimeSpan.FromSeconds(3),
            inner);

        Assert.Equal(ParleyAIErrorCategory.RateLimit, ex.Category);
        Assert.Equal(ProviderKeys.OpenAi, ex.ProviderKey);
        Assert.Equal(HttpStatusCode.TooManyRequests, ex.StatusCode);
        Assert.Equal(TimeSpan.FromSeconds(3), ex.RetryAfter);
        Assert.Same(inner, ex.InnerException);
    }

    [Fact]
    public void ParleyAIException_status_and_retryafter_are_nullable()
    {
        var ex = new ParleyAIException(
            "bad request",
            ParleyAIErrorCategory.InvalidRequest,
            ProviderKeys.Anthropic);

        Assert.Null(ex.StatusCode);
        Assert.Null(ex.RetryAfter);
        Assert.Null(ex.InnerException);
    }

    [Fact]
    public void ParleyAIErrorCategory_covers_the_six_specified_categories()
    {
        Assert.Equal(6, Enum.GetValues<ParleyAIErrorCategory>().Length);
        Assert.True(Enum.IsDefined(ParleyAIErrorCategory.RateLimit));
        Assert.True(Enum.IsDefined(ParleyAIErrorCategory.TokenLimit));
        Assert.True(Enum.IsDefined(ParleyAIErrorCategory.Authentication));
        Assert.True(Enum.IsDefined(ParleyAIErrorCategory.InvalidRequest));
        Assert.True(Enum.IsDefined(ParleyAIErrorCategory.Transient));
        Assert.True(Enum.IsDefined(ParleyAIErrorCategory.Unknown));
    }

    [Fact]
    public void ProviderKeys_match_the_keyed_registration_contract()
    {
        Assert.Equal("openai", ProviderKeys.OpenAi);
        Assert.Equal("anthropic", ProviderKeys.Anthropic);
    }

    [Fact]
    public void Options_default_to_capture_off_resilience_on_and_aimd_on_with_per_category_backoff()
    {
        var options = new ProviderOptions();

        Assert.False(options.CaptureContent);
        Assert.True(options.ResilienceEnabled);
        Assert.True(options.Aimd.Enabled);
        // Per-category back-off fields are present and independently tunable.
        Assert.NotNull(options.Aimd.RateLimitBackoff);
        Assert.NotNull(options.Aimd.TokenLimitBackoff);
        Assert.NotSame(options.Aimd.RateLimitBackoff, options.Aimd.TokenLimitBackoff);
        Assert.InRange(options.Aimd.RateLimitBackoff.MultiplicativeDecreaseFactor, 0.0, 1.0);
        Assert.True(options.Aimd.RateLimitBackoff.Cooldown > TimeSpan.Zero);
    }
}

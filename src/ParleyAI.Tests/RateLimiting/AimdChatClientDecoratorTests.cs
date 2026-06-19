using System;
using System.Net;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Time.Testing;
using ParleyAI.Abstractions;
using ParleyAI.Abstractions.Options;
using ParleyAI.RateLimiting;
using Xunit;

namespace ParleyAI.Tests.RateLimiting;

/// <summary>
/// Tests the AIMD decorator's reaction to the FINAL mapped outcome: success ramps; a RateLimit /
/// TokenLimit <see cref="ParleyAIException"/> backs off (distinctly); a non-limit exception and
/// cancellation pass through WITHOUT a rate change. The decorator wraps a tiny in-process fake
/// <see cref="IAiChatClient"/> (no HTTP), proving it reacts above the transport.
/// </summary>
public sealed class AimdChatClientDecoratorTests
{
    /// <summary>A scripted in-process client: each call returns OK or throws the queued exception.</summary>
    private sealed class ScriptedClient : IAiChatClient
    {
        private readonly Func<int, Exception?> _outcome;

        public ScriptedClient(Func<int, Exception?> outcome) => _outcome = outcome;

        public int Calls { get; private set; }

        public Task<ChatResponse> CompleteChatAsync(ChatRequest request, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Calls++;
            Exception? ex = _outcome(Calls);
            if (ex is not null)
            {
                return Task.FromException<ChatResponse>(ex);
            }

            return Task.FromResult(new ChatResponse("ok", new TokenUsage(1, 1), FinishReason.Stop));
        }
    }

    private static AimdRateController Controller(out FakeTimeProvider clock, Action<AimdOptions>? configure = null)
    {
        var options = new AimdOptions
        {
            AdditiveIncreaseStep = 2.0,
            RateFloor = 1.0,
            RateCeiling = 100.0,
            RateLimitBackoff = new BackoffOptions { MultiplicativeDecreaseFactor = 0.5, Cooldown = TimeSpan.FromSeconds(5) },
            TokenLimitBackoff = new BackoffOptions { MultiplicativeDecreaseFactor = 0.25, Cooldown = TimeSpan.FromSeconds(10) },
        };
        configure?.Invoke(options);
        clock = new FakeTimeProvider();
        return new AimdRateController(options, clock, new ZeroJitterSource());
    }

    private static ChatRequest Request() => new("m", new[] { new ChatMessage(Role.User, "hi") });

    [Fact]
    public async Task Success_ramps_the_rate()
    {
        AimdRateController controller = Controller(out _);
        var inner = new ScriptedClient(_ => null);
        var decorator = new AimdChatClientDecorator(inner, controller);

        double before = controller.CurrentRate;
        ChatResponse response = await decorator.CompleteChatAsync(Request());

        Assert.Equal("ok", response.Content);
        Assert.True(controller.CurrentRate > before);
    }

    [Fact]
    public async Task A_RateLimit_exception_backs_off_and_re_throws()
    {
        AimdRateController controller = Controller(out FakeTimeProvider clock);
        // Ramp once so there's headroom to back off from.
        var inner = new ScriptedClient(call => call == 1 ? null : new ParleyAIException(
            "rate", ParleyAIErrorCategory.RateLimit, ProviderKeys.OpenAi, HttpStatusCode.TooManyRequests));
        var decorator = new AimdChatClientDecorator(inner, controller);

        await decorator.CompleteChatAsync(Request()); // success → ramp
        clock.Advance(TimeSpan.FromSeconds(1));
        double ramped = controller.CurrentRate;

        await Assert.ThrowsAsync<ParleyAIException>(() => decorator.CompleteChatAsync(Request()));

        Assert.Equal(ramped * 0.5, controller.CurrentRate, precision: 6);
    }

    [Fact]
    public async Task RateLimit_vs_TokenLimit_produce_different_back_offs_through_the_decorator()
    {
        AimdRateController rateCtl = Controller(out FakeTimeProvider rateClock);
        AimdRateController tokenCtl = Controller(out FakeTimeProvider tokenClock);

        // Succeed for the first 5 calls (ramp well above the floor so the 0.25 factor does not clamp),
        // then a limit failure.
        const int rampCalls = 5;
        var rateInner = new ScriptedClient(call => call <= rampCalls ? null
            : new ParleyAIException("r", ParleyAIErrorCategory.RateLimit, ProviderKeys.OpenAi));
        var tokenInner = new ScriptedClient(call => call <= rampCalls ? null
            : new ParleyAIException("t", ParleyAIErrorCategory.TokenLimit, ProviderKeys.OpenAi));

        var rateDec = new AimdChatClientDecorator(rateInner, rateCtl);
        var tokenDec = new AimdChatClientDecorator(tokenInner, tokenCtl);

        for (int i = 0; i < rampCalls; i++)
        {
            await rateDec.CompleteChatAsync(Request());
            await tokenDec.CompleteChatAsync(Request());
            rateClock.Advance(TimeSpan.FromSeconds(1));
            tokenClock.Advance(TimeSpan.FromSeconds(1));
        }

        double ramped = rateCtl.CurrentRate; // floor 1 + 5*step 2 = 11
        Assert.Equal(ramped, tokenCtl.CurrentRate); // identical ramp before back-off

        await Assert.ThrowsAsync<ParleyAIException>(() => rateDec.CompleteChatAsync(Request()));
        await Assert.ThrowsAsync<ParleyAIException>(() => tokenDec.CompleteChatAsync(Request()));

        Assert.Equal(ramped * 0.5, rateCtl.CurrentRate, precision: 6);
        Assert.Equal(ramped * 0.25, tokenCtl.CurrentRate, precision: 6);
        Assert.NotEqual(rateCtl.CurrentRate, tokenCtl.CurrentRate);
    }

    [Fact]
    public async Task RetryAfter_on_the_exception_is_honored_into_the_cooldown()
    {
        AimdRateController controller = Controller(out FakeTimeProvider clock);
        var inner = new ScriptedClient(_ => new ParleyAIException(
            "rate", ParleyAIErrorCategory.RateLimit, ProviderKeys.OpenAi,
            HttpStatusCode.TooManyRequests, retryAfter: TimeSpan.FromSeconds(30)));
        var decorator = new AimdChatClientDecorator(inner, controller);

        await Assert.ThrowsAsync<ParleyAIException>(() => decorator.CompleteChatAsync(Request()));
        double afterBackoff = controller.CurrentRate;

        // Inside the 30s RetryAfter window a (would-be) success cannot ramp.
        clock.Advance(TimeSpan.FromSeconds(10));
        controller.OnSuccess();
        Assert.Equal(afterBackoff, controller.CurrentRate);

        // Past the RetryAfter window, ramp resumes.
        clock.Advance(TimeSpan.FromSeconds(21));
        controller.OnSuccess();
        Assert.True(controller.CurrentRate > afterBackoff);
    }

    [Fact]
    public async Task A_non_limit_exception_passes_through_without_a_rate_change()
    {
        AimdRateController controller = Controller(out _);
        var inner = new ScriptedClient(_ => new ParleyAIException(
            "bad", ParleyAIErrorCategory.InvalidRequest, ProviderKeys.OpenAi, HttpStatusCode.BadRequest));
        var decorator = new AimdChatClientDecorator(inner, controller);

        double before = controller.CurrentRate;
        await Assert.ThrowsAsync<ParleyAIException>(() => decorator.CompleteChatAsync(Request()));
        Assert.Equal(before, controller.CurrentRate);
    }

    [Fact]
    public async Task Cancellation_passes_through_without_a_rate_change()
    {
        AimdRateController controller = Controller(out _);
        var inner = new ScriptedClient(_ => new OperationCanceledException());
        var decorator = new AimdChatClientDecorator(inner, controller);

        double before = controller.CurrentRate;
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => decorator.CompleteChatAsync(Request()));
        Assert.Equal(before, controller.CurrentRate);
    }

    [Fact]
    public async Task Concurrent_limit_hits_collapse_to_a_single_decrease()
    {
        // High rate (50 req/s) so the token bucket holds enough permits for all concurrent acquires
        // WITHOUT pacing waits, and a low floor (1) so the 0.5 back-off is visible (50 -> 25, not
        // clamped). A big additive step lets one OnSuccess reach the ceiling deterministically.
        const int hitCount = 8;
        AimdRateController controller = Controller(out FakeTimeProvider clock, o =>
        {
            o.RateFloor = 1.0;
            o.RateCeiling = 50.0;
            o.AdditiveIncreaseStep = 100.0; // one success clamps straight to the ceiling
        });
        controller.OnSuccess();                 // rate -> 50 (ceiling)
        clock.Advance(TimeSpan.FromSeconds(1)); // fill the bucket to the burst cap (50 ≥ 8)

        double ramped = controller.CurrentRate; // 50.0

        var inner = new ScriptedClient(_ => new ParleyAIException("r", ParleyAIErrorCategory.RateLimit, ProviderKeys.OpenAi));
        var decorator = new AimdChatClientDecorator(inner, controller);

        // Many concurrent limit hits in the same cooldown window → ONE decrease (50 -> 25).
        Task[] hits = new Task[hitCount];
        for (int i = 0; i < hits.Length; i++)
        {
            hits[i] = Task.Run(async () =>
                await Assert.ThrowsAsync<ParleyAIException>(() => decorator.CompleteChatAsync(Request())));
        }

        await Task.WhenAll(hits);
        Assert.Equal(ramped * 0.5, controller.CurrentRate, precision: 6);
    }

    [Fact]
    public void Decorator_exposes_the_wrapped_inner()
    {
        AimdRateController controller = Controller(out _);
        var inner = new ScriptedClient(_ => null);
        var decorator = new AimdChatClientDecorator(inner, controller);
        Assert.Same(inner, decorator.Inner);
    }
}

using System;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Time.Testing;
using ParleyAI.Abstractions;
using ParleyAI.Abstractions.Options;
using ParleyAI.RateLimiting;
using Xunit;

namespace ParleyAI.Tests.RateLimiting;

/// <summary>
/// Deterministic unit tests for the AIMD controller's control logic: additive ramp on success,
/// distinct multiplicative back-off per limit category, RetryAfter honored, one-decrease-per-cooldown
/// window, floor/ceiling clamping. All time flows through a <see cref="FakeTimeProvider"/> and all
/// jitter through a <see cref="ZeroJitterSource"/> — NO real sleeps, exact assertions.
/// </summary>
public sealed class AimdRateControllerTests
{
    private static (AimdRateController Controller, FakeTimeProvider Clock) Build(Action<AimdOptions>? configure = null)
    {
        var options = new AimdOptions
        {
            AdditiveIncreaseStep = 2.0,
            RateFloor = 1.0,
            RateCeiling = 20.0,
            RateLimitBackoff = new BackoffOptions { MultiplicativeDecreaseFactor = 0.5, Cooldown = TimeSpan.FromSeconds(5) },
            TokenLimitBackoff = new BackoffOptions { MultiplicativeDecreaseFactor = 0.25, Cooldown = TimeSpan.FromSeconds(10) },
        };
        configure?.Invoke(options);

        var clock = new FakeTimeProvider();
        var controller = new AimdRateController(options, clock, new ZeroJitterSource());
        return (controller, clock);
    }

    [Fact]
    public void Starts_at_the_configured_floor()
    {
        (AimdRateController controller, _) = Build();
        Assert.Equal(1.0, controller.CurrentRate);
    }

    [Fact]
    public void Sustained_success_additively_ramps_the_rate()
    {
        (AimdRateController controller, FakeTimeProvider clock) = Build();

        controller.OnSuccess();
        Assert.Equal(3.0, controller.CurrentRate); // floor 1 + step 2

        // Advance past any (zero, at start) cooldown and ramp again.
        clock.Advance(TimeSpan.FromSeconds(1));
        controller.OnSuccess();
        Assert.Equal(5.0, controller.CurrentRate);
    }

    [Fact]
    public void Ramp_is_capped_at_the_ceiling()
    {
        (AimdRateController controller, FakeTimeProvider clock) = Build(o => o.RateCeiling = 4.0);

        controller.OnSuccess(); // 1 -> 3
        clock.Advance(TimeSpan.FromSeconds(1));
        controller.OnSuccess(); // 3 + 2 = 5, capped at 4
        Assert.Equal(4.0, controller.CurrentRate);
    }

    [Fact]
    public void RateLimit_and_TokenLimit_drive_DIFFERENT_decreases_on_the_same_pacer()
    {
        // RateLimit factor 0.5 vs TokenLimit factor 0.25 — same starting rate, different result.
        (AimdRateController rateCtl, FakeTimeProvider rateClock) = Build();
        (AimdRateController tokenCtl, FakeTimeProvider tokenClock) = Build();

        // Ramp both to 10 first.
        for (int i = 0; i < 5; i++)
        {
            rateCtl.OnSuccess();
            rateClock.Advance(TimeSpan.FromSeconds(1));
            tokenCtl.OnSuccess();
            tokenClock.Advance(TimeSpan.FromSeconds(1));
        }

        double rampedRate = rateCtl.CurrentRate;
        double rampedToken = tokenCtl.CurrentRate;
        Assert.Equal(rampedRate, rampedToken); // identical ramp

        rateCtl.OnBackoff(ParleyAIErrorCategory.RateLimit, retryAfter: null);
        tokenCtl.OnBackoff(ParleyAIErrorCategory.TokenLimit, retryAfter: null);

        // RateLimit halves; TokenLimit quarters — distinctly different from the SAME ramped rate.
        Assert.Equal(rampedRate * 0.5, rateCtl.CurrentRate, precision: 6);
        Assert.Equal(rampedToken * 0.25, tokenCtl.CurrentRate, precision: 6);
        Assert.NotEqual(rateCtl.CurrentRate, tokenCtl.CurrentRate);
    }

    [Fact]
    public void Decrease_is_floored()
    {
        (AimdRateController controller, _) = Build(o =>
        {
            o.RateFloor = 4.0;
            o.RateLimitBackoff = new BackoffOptions { MultiplicativeDecreaseFactor = 0.1, Cooldown = TimeSpan.FromSeconds(5) };
        });
        // Starts at floor 4; 4 * 0.1 = 0.4 but floored back to 4.
        controller.OnBackoff(ParleyAIErrorCategory.RateLimit, retryAfter: null);
        Assert.Equal(4.0, controller.CurrentRate);
    }

    [Fact]
    public void Only_one_decrease_per_cooldown_window()
    {
        (AimdRateController controller, FakeTimeProvider clock) = Build();

        // Ramp to 9.
        for (int i = 0; i < 4; i++)
        {
            controller.OnSuccess();
            clock.Advance(TimeSpan.FromSeconds(1));
        }
        Assert.Equal(9.0, controller.CurrentRate);

        // A burst of three RateLimit hits within the cooldown window → exactly ONE decrease (9 -> 4.5).
        controller.OnBackoff(ParleyAIErrorCategory.RateLimit, retryAfter: null);
        controller.OnBackoff(ParleyAIErrorCategory.RateLimit, retryAfter: null);
        controller.OnBackoff(ParleyAIErrorCategory.RateLimit, retryAfter: null);
        Assert.Equal(4.5, controller.CurrentRate, precision: 6);

        // After the 5s cooldown elapses, a further back-off applies again (4.5 -> 2.25).
        clock.Advance(TimeSpan.FromSeconds(5));
        controller.OnBackoff(ParleyAIErrorCategory.RateLimit, retryAfter: null);
        Assert.Equal(2.25, controller.CurrentRate, precision: 6);
    }

    [Fact]
    public void Success_during_cooldown_does_not_ramp()
    {
        (AimdRateController controller, FakeTimeProvider clock) = Build();

        controller.OnSuccess(); // 1 -> 3
        clock.Advance(TimeSpan.FromSeconds(1));
        controller.OnBackoff(ParleyAIErrorCategory.RateLimit, retryAfter: null); // 3 -> 1.5, 5s cooldown opens

        double afterBackoff = controller.CurrentRate;
        controller.OnSuccess(); // inside cooldown → suppressed
        Assert.Equal(afterBackoff, controller.CurrentRate);

        // Once the cooldown elapses, success ramps again.
        clock.Advance(TimeSpan.FromSeconds(5));
        controller.OnSuccess();
        Assert.Equal(afterBackoff + 2.0, controller.CurrentRate, precision: 6);
    }

    [Fact]
    public void RetryAfter_longer_than_cooldown_extends_the_suppression_window()
    {
        // RateLimit cooldown is 5s; a RetryAfter of 20s must win → ramp suppressed until 20s passes.
        (AimdRateController controller, FakeTimeProvider clock) = Build();

        controller.OnBackoff(ParleyAIErrorCategory.RateLimit, retryAfter: TimeSpan.FromSeconds(20));
        double afterBackoff = controller.CurrentRate;

        // At 6s (past the 5s cooldown, but inside the 20s RetryAfter) success is STILL suppressed.
        clock.Advance(TimeSpan.FromSeconds(6));
        controller.OnSuccess();
        Assert.Equal(afterBackoff, controller.CurrentRate);

        // Past 20s total, ramp resumes.
        clock.Advance(TimeSpan.FromSeconds(15));
        controller.OnSuccess();
        Assert.Equal(afterBackoff + 2.0, controller.CurrentRate, precision: 6);
    }

    [Fact]
    public void Non_limit_categories_do_not_change_the_rate()
    {
        (AimdRateController controller, _) = Build();
        double before = controller.CurrentRate;

        controller.OnBackoff(ParleyAIErrorCategory.Authentication, retryAfter: null);
        controller.OnBackoff(ParleyAIErrorCategory.InvalidRequest, retryAfter: null);
        controller.OnBackoff(ParleyAIErrorCategory.Transient, retryAfter: null);
        controller.OnBackoff(ParleyAIErrorCategory.Unknown, retryAfter: null);

        Assert.Equal(before, controller.CurrentRate);
    }

    [Fact]
    public async Task First_acquire_proceeds_immediately_then_pacing_waits_at_the_current_rate()
    {
        // Floor rate 1 req/s, ceiling 1 so it stays at 1: the seeded permit lets the first acquire
        // through instantly; the second must wait ~1s (asserted by completing only after the fake
        // clock advances 1s).
        (AimdRateController controller, FakeTimeProvider clock) = Build(o =>
        {
            o.RateFloor = 1.0;
            o.RateCeiling = 1.0;
            o.AdditiveIncreaseStep = 0.0;
        });

        await controller.AcquireAsync(CancellationToken.None); // immediate (seeded token)

        Task second = controller.AcquireAsync(CancellationToken.None);
        Assert.False(second.IsCompleted); // pacing: must wait for replenish

        clock.Advance(TimeSpan.FromSeconds(1)); // one token replenishes at 1 req/s
        await second; // now completes
    }

    [Fact]
    public async Task Acquire_honors_cancellation()
    {
        (AimdRateController controller, _) = Build(o =>
        {
            o.RateFloor = 1.0;
            o.RateCeiling = 1.0;
        });

        await controller.AcquireAsync(CancellationToken.None); // consume the seeded token

        using var cts = new CancellationTokenSource();
        Task pending = controller.AcquireAsync(cts.Token);
        cts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => pending);
    }
}

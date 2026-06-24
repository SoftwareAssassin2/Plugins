using System;
using System.Threading;
using System.Threading.Tasks;
using ParleyAI.Abstractions;
using ParleyAI.Abstractions.Options;

namespace ParleyAI.RateLimiting;

/// <summary>
/// A per-provider adaptive AIMD (additive-increase / multiplicative-decrease) request-rate
/// pacer. It is a custom <em>manual-replenish</em> token-bucket controller — the allowed rate
/// is adjusted by replacing the controller's internal rate field under a lock (no in-place
/// mutation of the immutable <see cref="AimdOptions"/>, and no fighting an immutable
/// <c>System.Threading.RateLimiting</c> limiter's options), so a rate change applies atomically
/// to all in-flight and future permit acquisitions.
/// </summary>
/// <remarks>
/// <para>
/// <b>Control model (v1, fixed):</b> ONE per-provider <em>request-rate</em> token bucket.
/// A success additively raises the rate (with jitter), capped at <see cref="AimdOptions.RateCeiling"/>.
/// A mapped <see cref="ParleyAIException"/> whose <see cref="ParleyAIException.Category"/> is
/// <see cref="ParleyAIErrorCategory.RateLimit"/> or <see cref="ParleyAIErrorCategory.TokenLimit"/>
/// multiplicatively lowers it (per-category factor), floored at <see cref="AimdOptions.RateFloor"/>.
/// Per-token (TPM) budgeting is a documented v1 non-goal — both categories pace the SAME request-rate
/// bucket, only with distinct factor + cooldown.
/// </para>
/// <para>
/// <b>Determinism:</b> all time flows through an injected <see cref="TimeProvider"/> and all jitter
/// through an injected <see cref="IJitterSource"/>, so cooldown / <c>RetryAfter</c> / ramp behavior is
/// asserted with a fake clock + zero-jitter source and NO real sleeps.
/// </para>
/// <para>
/// <b>Cooldown semantics:</b> at most ONE multiplicative decrease per <see cref="BackoffOptions.Cooldown"/>
/// window — a burst of concurrent limit-hits collapses to a single back-off. Additive increase is also
/// suppressed until the active cooldown (the max of the back-off cooldown and any honored
/// <c>RetryAfter</c>) has elapsed, so a ramp cannot immediately undo a back-off.
/// </para>
/// <para>Thread-safe: every rate read/write and timestamp check is performed under <see cref="_gate"/>.</para>
/// </remarks>
public sealed class AimdRateController
{
    private readonly AimdOptions _options;
    private readonly TimeProvider _timeProvider;
    private readonly IJitterSource _jitter;
    private readonly object _gate = new();

    // The available permit budget (fractional tokens). One whole token is consumed per acquire.
    private double _availableTokens;

    // The current allowed rate (requests/second). Adjusted by AIMD; never < floor or > ceiling.
    private double _currentRate;

    // The clock instant tokens were last replenished from (monotonic, from TimeProvider).
    private long _lastReplenishTimestamp;

    // The clock instant the current cooldown ends — additive increase and a further decrease are
    // both suppressed until then. Honors the max of the category cooldown and any RetryAfter.
    private long _cooldownUntilTimestamp;

    // The clock instant until which request ACQUISITION itself is paused — set from a provider-advised
    // RetryAfter so AcquireAsync actually stops sending during the advised wait (not just suppressing
    // the AIMD ramp). A bare category cooldown (no RetryAfter) does NOT pause traffic, only the ramp.
    private long _blockUntilTimestamp;

    /// <summary>
    /// Creates the controller for one provider.
    /// </summary>
    /// <param name="options">The AIMD tuning (step / factor / floor / ceiling / per-category back-off).</param>
    /// <param name="timeProvider">The clock (inject a fake in tests).</param>
    /// <param name="jitter">The jitter source for additive increase (inject a zero-jitter fake in tests).</param>
    public AimdRateController(AimdOptions options, TimeProvider timeProvider, IJitterSource jitter)
    {
        ArgumentNullException.ThrowIfNull(options);
        ArgumentNullException.ThrowIfNull(timeProvider);
        ArgumentNullException.ThrowIfNull(jitter);

        _options = options;
        _timeProvider = timeProvider;
        _jitter = jitter;

        // Start at the floor and ramp up — conservative; never above the ceiling.
        _currentRate = Math.Clamp(options.RateFloor, options.RateFloor, options.RateCeiling);

        long now = timeProvider.GetTimestamp();
        _lastReplenishTimestamp = now;
        _cooldownUntilTimestamp = now;
        _blockUntilTimestamp = now;

        // Seed one whole permit so the very first call proceeds immediately (no cold-start stall).
        _availableTokens = 1.0;
    }

    /// <summary>The current allowed rate (requests/second). Exposed for assertions/diagnostics.</summary>
    public double CurrentRate
    {
        get { lock (_gate) { return _currentRate; } }
    }

    /// <summary>
    /// Acquires one request permit, asynchronously waiting (via the injected clock, using
    /// <see cref="Task.Delay(TimeSpan, TimeProvider, CancellationToken)"/>) until BOTH any active
    /// provider-advised <c>RetryAfter</c> pause has elapsed AND the token bucket has replenished
    /// enough at the current rate. Honors cancellation.
    /// </summary>
    public async Task AcquireAsync(CancellationToken cancellationToken)
    {
        while (true)
        {
            // Honor cancellation BEFORE granting a permit so a pre-canceled (or mid-wait canceled)
            // token never charges the bucket for a request that must not acquire.
            cancellationToken.ThrowIfCancellationRequested();

            TimeSpan wait;
            lock (_gate)
            {
                long now = _timeProvider.GetTimestamp();

                // A provider-advised RetryAfter pauses acquisition outright: do not grant a permit
                // (even if tokens remain) until the advised wait elapses. This actually honors
                // RetryAfter as a request pause, not merely an AIMD-ramp suppression.
                if (now < _blockUntilTimestamp)
                {
                    wait = FromTicks(_blockUntilTimestamp - now);
                }
                else
                {
                    Replenish();
                    if (_availableTokens >= 1.0)
                    {
                        _availableTokens -= 1.0;
                        return;
                    }

                    // Time until the next whole token replenishes at the current rate.
                    double deficit = 1.0 - _availableTokens;
                    wait = TimeSpan.FromSeconds(deficit / _currentRate);
                }
            }

            // Wait OUTSIDE the lock so concurrent callers and AIMD adjustments are not blocked.
            // Task.Delay's TimeProvider overload drives the wait off the injected clock, so a fake
            // clock advances it deterministically in tests (no real sleep).
            await Task.Delay(wait, _timeProvider, cancellationToken).ConfigureAwait(false);
        }
    }

    /// <summary>
    /// Records a successful call: additively increases the allowed rate (with jitter), capped at the
    /// ceiling — UNLESS a cooldown window is still active, in which case the ramp is suppressed so a
    /// success immediately after a back-off cannot undo it.
    /// </summary>
    public void OnSuccess()
    {
        lock (_gate)
        {
            Replenish();

            long now = _timeProvider.GetTimestamp();
            if (now < _cooldownUntilTimestamp)
            {
                // Still cooling down from a recent back-off — do not ramp yet.
                return;
            }

            // Additive increase, scaled by a small jitter fraction in [0, 0.1] so concurrent clients
            // do not ramp in lock-step. Zero-jitter source ⇒ exact +step (deterministic tests).
            double jittered = _options.AdditiveIncreaseStep * (1.0 + _jitter.NextJitterFraction(0.1));
            _currentRate = Math.Min(_options.RateCeiling, _currentRate + jittered);
        }
    }

    /// <summary>
    /// Records a mapped limit failure: multiplicatively decreases the allowed rate using the
    /// per-category factor (distinct for <see cref="ParleyAIErrorCategory.RateLimit"/> vs
    /// <see cref="ParleyAIErrorCategory.TokenLimit"/>), floored at <see cref="AimdOptions.RateFloor"/>,
    /// and opens a cooldown window of <c>max(category cooldown, RetryAfter)</c>. At most ONE decrease
    /// per active window — concurrent limit-hits collapse to a single back-off.
    /// </summary>
    /// <param name="category">The mapped error category driving the back-off.</param>
    /// <param name="retryAfter">
    /// The provider-advised wait, when present. It is honored two ways: it extends the AIMD-ramp
    /// suppression window AND pauses request acquisition (<see cref="AcquireAsync"/>) until it elapses.
    /// </param>
    public void OnBackoff(ParleyAIErrorCategory category, TimeSpan? retryAfter)
    {
        BackoffOptions backoff = category switch
        {
            ParleyAIErrorCategory.RateLimit => _options.RateLimitBackoff,
            ParleyAIErrorCategory.TokenLimit => _options.TokenLimitBackoff,
            // Only the two limit categories drive AIMD back-off; ignore anything else.
            _ => null!,
        };

        if (backoff is null)
        {
            return;
        }

        lock (_gate)
        {
            Replenish();

            long now = _timeProvider.GetTimestamp();

            // The suppression window for THIS hit: the longer of the category cooldown and any
            // provider-advised RetryAfter (a RetryAfter exceeding the cooldown is honored).
            TimeSpan window = backoff.Cooldown;
            if (retryAfter is { } ra && ra > window)
            {
                window = ra;
            }

            long windowEnd = now + ToTicks(window);

            // A provider-advised RetryAfter ALSO pauses request acquisition (not just the ramp) until
            // it elapses. A bare category cooldown does not block traffic — only the AIMD ramp.
            if (retryAfter is { } pause && pause > TimeSpan.Zero)
            {
                long blockEnd = now + ToTicks(pause);
                if (blockEnd > _blockUntilTimestamp)
                {
                    _blockUntilTimestamp = blockEnd; // extend, never shorten
                }
            }

            if (now < _cooldownUntilTimestamp)
            {
                // A decrease already happened this window — one decrease per cooldown, so SKIP the
                // further multiplicative decrease. BUT still honor a longer RetryAfter/cooldown from
                // this hit by extending the suppression window (never shorten it): a second 429 with a
                // longer RetryAfter during cooldown must not let the controller resume ramping early.
                if (windowEnd > _cooldownUntilTimestamp)
                {
                    _cooldownUntilTimestamp = windowEnd;
                }

                return;
            }

            // Multiplicative decrease, floored.
            _currentRate = Math.Max(_options.RateFloor, _currentRate * backoff.MultiplicativeDecreaseFactor);

            // Open the cooldown.
            _cooldownUntilTimestamp = windowEnd;

            // Clamp any pre-back-off token surplus down to the new (reduced) rate's burst cap so a
            // stale surplus cannot let a large burst through at the old rate before the lower rate
            // bites — but do NOT drain to zero: leaving up to one burst-cap of permits keeps already
            // in-flight / immediately-following callers from stalling on a pacing wait. The burst cap
            // is floored at one whole permit (matching Replenish) so sub-1 rates never deadlock.
            double burstCap = Math.Max(1.0, _currentRate);
            if (_availableTokens > burstCap)
            {
                _availableTokens = burstCap;
            }
        }
    }

    // Replenish the bucket from elapsed wall time at the current rate, capped at a one-second burst
    // (rate * 1s) so an idle period cannot accumulate an unbounded backlog of permits. Must hold _gate.
    private void Replenish()
    {
        long now = _timeProvider.GetTimestamp();
        double elapsedSeconds = (now - _lastReplenishTimestamp) / (double)_timeProvider.TimestampFrequency;
        _lastReplenishTimestamp = now;

        if (elapsedSeconds <= 0)
        {
            return;
        }

        // At most one second of tokens buffered, but NEVER below a single whole permit: a configured
        // rate < 1 req/s would otherwise cap the bucket below the 1.0 a single AcquireAsync needs and
        // stall every caller after the seeded permit. The floor of 1 lets one request through per
        // (1 / rate) seconds at sub-1 rates without deadlocking.
        double burstCap = Math.Max(1.0, _currentRate);
        _availableTokens = Math.Min(burstCap, _availableTokens + (elapsedSeconds * _currentRate));
    }

    // Convert a TimeSpan to the TimeProvider's timestamp ticks (its frequency, not DateTime ticks).
    private long ToTicks(TimeSpan span) =>
        (long)(span.TotalSeconds * _timeProvider.TimestampFrequency);

    // Convert a span of TimeProvider timestamp ticks back to a TimeSpan.
    private TimeSpan FromTicks(long ticks) =>
        TimeSpan.FromSeconds(ticks / (double)_timeProvider.TimestampFrequency);
}

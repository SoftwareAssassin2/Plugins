using System;
using Polly;
using Polly.Retry;
using Polly.Timeout;

namespace ParleyAI.DependencyInjection;

/// <summary>
/// The override surface for the per-provider HTTP resilience pipeline that fn-4.4 attaches
/// EXACTLY ONCE to each provider's keyed <see cref="Microsoft.Extensions.DependencyInjection.IHttpClientBuilder"/>.
/// </summary>
/// <remarks>
/// <para>
/// The default pipeline is a CUSTOM handler containing ONLY a total timeout, a retry strategy, and
/// a per-attempt timeout — <b>NO rate-limiter strategy</b> (the AIMD decorator, fn-4.5, is the sole
/// pacer). This is deliberately not <c>AddStandardResilienceHandler</c>, whose built-in rate limiter
/// would have to be disabled afterwards.
/// </para>
/// <para>
/// <b>Retry scope:</b> the retry handles ONLY true transient transport/server failures — connection
/// faults (<see cref="System.Net.Http.HttpRequestException"/>), per-attempt timeouts
/// (<see cref="TimeoutRejectedException"/>), <c>408</c>, and selected <c>5xx</c>. It explicitly does
/// NOT retry <c>429</c>: a rate-limit signal must surface (as a mapped <c>ParleyAIException</c>) to
/// the AIMD decorator, because a retry-success here would hide it and make AIMD ramp UP instead of
/// backing off.
/// </para>
/// <para>
/// <b>Precedence:</b> explicit options set here win over the defaults. Set
/// <see cref="ConfigurePipeline"/> to replace the whole pipeline; otherwise the knobs
/// (<see cref="Enabled"/>, <see cref="MaxRetryAttempts"/>, <see cref="TotalRequestTimeout"/>,
/// <see cref="AttemptTimeout"/>, <see cref="BaseRetryDelay"/>) tune the default pipeline. Lifetime is
/// singleton-with-options (resolved once when the pipeline is built).
/// </para>
/// </remarks>
public sealed class ParleyAiResilienceOptions
{
    /// <summary>
    /// Whether the resilience pipeline is attached for this provider. When <see langword="false"/>
    /// no resilience handler is added — a logical call makes exactly ONE HTTP attempt (proving the
    /// SDK-native retry, disabled in .2/.3, does not silently stack). Default <see langword="true"/>.
    /// </summary>
    public bool Enabled { get; set; } = true;

    /// <summary>
    /// The maximum number of RETRIES (additional attempts beyond the first) for transient failures.
    /// Total HTTP attempts = <c>1 + MaxRetryAttempts</c>. Default <c>3</c>.
    /// </summary>
    public int MaxRetryAttempts { get; set; } = 3;

    /// <summary>
    /// The total time budget for one logical call across all attempts (the outer timeout).
    /// Default 30 seconds.
    /// </summary>
    public TimeSpan TotalRequestTimeout { get; set; } = TimeSpan.FromSeconds(30);

    /// <summary>
    /// The per-attempt timeout (the inner timeout). A breach surfaces as a
    /// <see cref="TimeoutRejectedException"/>, which the retry treats as transient.
    /// Default 10 seconds.
    /// </summary>
    public TimeSpan AttemptTimeout { get; set; } = TimeSpan.FromSeconds(10);

    /// <summary>
    /// The base delay for the exponential-with-jitter retry back-off. Default 1 second.
    /// </summary>
    public TimeSpan BaseRetryDelay { get; set; } = TimeSpan.FromSeconds(1);

    /// <summary>
    /// Optional total replacement of the resilience pipeline. When set, it is invoked with the
    /// resilience pipeline builder INSTEAD of building the default timeout+retry pipeline, giving
    /// full control (the knobs above are then ignored). The provider key is supplied so a caller
    /// can vary the pipeline per provider.
    /// </summary>
    public Action<ResiliencePipelineBuilder<System.Net.Http.HttpResponseMessage>, string>? ConfigurePipeline { get; set; }

    /// <summary>
    /// Builds the default timeout + retry pipeline (NO rate-limiter) onto <paramref name="builder"/>
    /// using the configured knobs. Order: total timeout (outermost) → retry → per-attempt timeout.
    /// </summary>
    internal void ApplyDefaultPipeline(ResiliencePipelineBuilder<System.Net.Http.HttpResponseMessage> builder)
    {
        // Outermost: a single budget across all attempts.
        builder.AddTimeout(TotalRequestTimeout);

        // Retry ONLY true transient failures. NOTE: 429 is deliberately NOT in the predicate —
        // it must surface to the AIMD decorator (fn-4.5) instead of being retried away here.
        builder.AddRetry(new RetryStrategyOptions<System.Net.Http.HttpResponseMessage>
        {
            MaxRetryAttempts = MaxRetryAttempts,
            BackoffType = DelayBackoffType.Exponential,
            UseJitter = true,
            Delay = BaseRetryDelay,
            ShouldHandle = static args => new ValueTask<bool>(IsTransient(args.Outcome)),

            // Dispose the discarded failed response before the next attempt. A generic Polly retry
            // over HttpResponseMessage does NOT dispose handled outcomes, so a retried 5xx (with a
            // body) would otherwise hold its content buffer / socket until GC — a resource-exhaustion
            // risk during a downstream outage. (The final, non-retried outcome is returned to the
            // caller pipeline and disposed there.)
            OnRetry = static args =>
            {
                args.Outcome.Result?.Dispose();
                return default;
            },
        });

        // Innermost: bound a single attempt; a breach → TimeoutRejectedException (retried as transient).
        builder.AddTimeout(AttemptTimeout);
    }

    /// <summary>
    /// Classifies an outcome as a transient failure the retry should handle: connection faults,
    /// per-attempt timeouts, <c>408</c>, and selected <c>5xx</c> — but explicitly NOT <c>429</c>.
    /// </summary>
    private static bool IsTransient(Outcome<System.Net.Http.HttpResponseMessage> outcome)
    {
        // Transport/connection faults + per-attempt timeout rejections are transient.
        if (outcome.Exception is System.Net.Http.HttpRequestException or TimeoutRejectedException)
        {
            return true;
        }

        if (outcome.Result is { } response)
        {
            int status = (int)response.StatusCode;

            // 429 is NEVER retried here — surfaces to AIMD (fn-4.5).
            if (status == 429)
            {
                return false;
            }

            // 408 Request Timeout + 5xx server errors are transient.
            return status == 408 || status >= 500;
        }

        return false;
    }
}

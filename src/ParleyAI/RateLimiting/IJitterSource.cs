using System;

namespace ParleyAI.RateLimiting;

/// <summary>
/// Supplies the multiplicative jitter applied to the AIMD additive-increase step so that
/// many decorated clients backing off concurrently do not all ramp back up in lock-step.
/// </summary>
/// <remarks>
/// Injected into <see cref="AimdRateController"/> so tests can substitute a deterministic
/// (zero-jitter) fake and assert exact rate transitions WITHOUT real randomness. Production
/// uses <see cref="DefaultJitterSource"/>.
/// </remarks>
public interface IJitterSource
{
    /// <summary>
    /// Returns a non-negative jitter fraction in <c>[0, maxFraction]</c> applied to a single
    /// additive-increase step (the step is scaled by <c>1 + NextJitterFraction(...)</c>).
    /// </summary>
    /// <param name="maxFraction">The inclusive upper bound on the returned fraction (≥ 0).</param>
    double NextJitterFraction(double maxFraction);
}

/// <summary>
/// The default <see cref="IJitterSource"/>: a thread-safe uniform sample in
/// <c>[0, maxFraction]</c> backed by <see cref="Random.Shared"/>.
/// </summary>
public sealed class DefaultJitterSource : IJitterSource
{
    /// <summary>A process-wide singleton; <see cref="Random.Shared"/> is itself thread-safe.</summary>
    public static readonly DefaultJitterSource Instance = new();

    /// <inheritdoc />
    public double NextJitterFraction(double maxFraction)
    {
        if (maxFraction <= 0)
        {
            return 0;
        }

        return Random.Shared.NextDouble() * maxFraction;
    }
}

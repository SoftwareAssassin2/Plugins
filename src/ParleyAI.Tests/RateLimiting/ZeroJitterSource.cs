using ParleyAI.RateLimiting;

namespace ParleyAI.Tests.RateLimiting;

/// <summary>
/// A deterministic <see cref="IJitterSource"/> that always returns zero jitter, so additive-increase
/// steps are exact (<c>+step</c>) and rate transitions are precisely assertable in tests.
/// </summary>
internal sealed class ZeroJitterSource : IJitterSource
{
    public double NextJitterFraction(double maxFraction) => 0.0;
}

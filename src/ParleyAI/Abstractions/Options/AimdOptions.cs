using System;

namespace ParleyAI.Abstractions.Options;

/// <summary>
/// Tuning for the adaptive AIMD (additive-increase / multiplicative-decrease) rate
/// optimizer that decorates each keyed provider client.
/// </summary>
/// <remarks>
/// <para>
/// The optimizer paces logical calls through a per-provider request-rate token
/// bucket: it additively increases the allowed rate on sustained success and
/// multiplicatively decreases it on a mapped <see cref="ParleyAIException"/> whose
/// <see cref="ParleyAIException.Category"/> is
/// <see cref="ParleyAIErrorCategory.RateLimit"/> or
/// <see cref="ParleyAIErrorCategory.TokenLimit"/> — honoring
/// <see cref="ParleyAIException.RetryAfter"/> when present.
/// </para>
/// <para>
/// The two limit categories carry <em>distinct</em> back-off factors + cooldowns so
/// a token-budget breach and a request-rate breach can react differently. Concrete
/// numeric defaults are finalized by the optimizer implementation (fn-4.5); the
/// values here are the contract surface.
/// </para>
/// <para>Enabled by default; set <see cref="Enabled"/> to <c>false</c> for a bare client.</para>
/// </remarks>
public sealed class AimdOptions
{
    /// <summary>
    /// When <c>true</c> (default), the AIMD decorator wraps the provider client.
    /// When <c>false</c>, the bare client is used (hard off switch).
    /// </summary>
    public bool Enabled { get; set; } = true;

    /// <summary>
    /// The additive increase applied to the allowed rate (requests/second) per
    /// sustained-success interval.
    /// </summary>
    public double AdditiveIncreaseStep { get; set; } = 1.0;

    /// <summary>The floor the allowed rate is never decreased below (requests/second).</summary>
    public double RateFloor { get; set; } = 1.0;

    /// <summary>The ceiling the allowed rate is never increased above (requests/second).</summary>
    public double RateCeiling { get; set; } = 100.0;

    /// <summary>Per-category back-off applied on a <see cref="ParleyAIErrorCategory.RateLimit"/>.</summary>
    public BackoffOptions RateLimitBackoff { get; set; } = new();

    /// <summary>Per-category back-off applied on a <see cref="ParleyAIErrorCategory.TokenLimit"/>.</summary>
    public BackoffOptions TokenLimitBackoff { get; set; } = new();
}

/// <summary>
/// The multiplicative-decrease factor + cooldown for one limit category.
/// </summary>
public sealed class BackoffOptions
{
    /// <summary>
    /// The multiplicative factor applied to the allowed rate on a breach
    /// (0 &lt; factor &lt; 1; smaller ⇒ more aggressive back-off).
    /// </summary>
    public double MultiplicativeDecreaseFactor { get; set; } = 0.5;

    /// <summary>
    /// The minimum quiet period after a back-off before additive increase resumes.
    /// </summary>
    public TimeSpan Cooldown { get; set; } = TimeSpan.FromSeconds(5);
}

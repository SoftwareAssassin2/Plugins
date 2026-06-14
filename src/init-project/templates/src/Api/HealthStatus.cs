namespace Api;

/// <summary>
/// A trivial, transport-free unit the <c>Api</c> can map onto an endpoint. It
/// exists so the <c>Api</c> layer has a directly-testable seam (docs/tdd.md)
/// while <c>Program</c> stays thin bootstrap glue. Replace/extend it as real
/// endpoints arrive; keep the decisions here (or one layer in), not in the
/// minimal-API lambdas.
/// </summary>
public static class HealthStatus
{
    /// <summary>The shape returned by the liveness endpoint.</summary>
    public sealed record Report(string Status);

    /// <summary>Builds the liveness report.</summary>
    public static Report Live() => new("ok");
}

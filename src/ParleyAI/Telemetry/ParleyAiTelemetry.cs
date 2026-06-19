using System.Diagnostics;
using System.Diagnostics.Metrics;

namespace ParleyAI.Telemetry;

/// <summary>
/// The named <see cref="System.Diagnostics.ActivitySource"/> and <see cref="System.Diagnostics.Metrics.Meter"/>
/// ParleyAI emits OpenTelemetry GenAI telemetry on, plus the pinned metric instruments.
/// </summary>
/// <remarks>
/// <para>
/// <b>Stable, documented public names — a consumer MUST register these by exact name.</b> The
/// scaffolded <c>Api</c> (fn-4.9) calls <c>AddSource(ParleyAiTelemetry.ActivitySourceName)</c> on the
/// tracer-provider builder and <c>AddMeter(ParleyAiTelemetry.MeterName)</c> on the meter-provider
/// builder; a name mismatch silently drops all ParleyAI telemetry, so these constants are the contract.
/// Both names are <c>"ParleyAI"</c> today (one source, one meter) and are surfaced as public constants
/// so the registration code references them rather than hardcoding the literal.
/// </para>
/// <para>
/// The instruments are the two pinned GenAI client metrics:
/// <see cref="OperationDuration"/> (<c>gen_ai.client.operation.duration</c>, unit <c>s</c>) and
/// <see cref="TokenUsage"/> (<c>gen_ai.client.token.usage</c>, unit <c>{token}</c>, dimensioned by
/// <c>gen_ai.token.type</c>). ParleyAI takes no OTLP-exporter dependency itself — wiring an exporter is
/// the consuming application's job.
/// </para>
/// </remarks>
public static class ParleyAiTelemetry
{
    /// <summary>
    /// The public, stable name of the <see cref="System.Diagnostics.ActivitySource"/> ParleyAI emits
    /// chat spans on. Register it via <c>AddSource(ParleyAiTelemetry.ActivitySourceName)</c>.
    /// </summary>
    public const string ActivitySourceName = "ParleyAI";

    /// <summary>
    /// The public, stable name of the <see cref="System.Diagnostics.Metrics.Meter"/> ParleyAI emits the
    /// GenAI client metrics on. Register it via <c>AddMeter(ParleyAiTelemetry.MeterName)</c>.
    /// </summary>
    public const string MeterName = "ParleyAI";

    /// <summary>
    /// The version stamped on the <see cref="System.Diagnostics.ActivitySource"/> /
    /// <see cref="System.Diagnostics.Metrics.Meter"/>. Anchored to the assembly version so it tracks the
    /// shipped package; the emitted <c>gen_ai.*</c> shape is pinned separately in
    /// <see cref="GenAiAttributes.SemanticConventionsVersion"/>.
    /// </summary>
    internal static readonly string TelemetryVersion =
        typeof(ParleyAiTelemetry).Assembly.GetName().Version?.ToString() ?? "1.0.0";

    /// <summary>The shared <see cref="System.Diagnostics.ActivitySource"/> for ParleyAI chat spans.</summary>
    internal static readonly ActivitySource ActivitySource = new(ActivitySourceName, TelemetryVersion);

    /// <summary>The shared <see cref="System.Diagnostics.Metrics.Meter"/> for the GenAI client metrics.</summary>
    internal static readonly Meter Meter = new(MeterName, TelemetryVersion);

    /// <summary>
    /// <c>gen_ai.client.operation.duration</c> — a histogram of chat-call wall-clock duration in
    /// seconds (unit <c>s</c>).
    /// </summary>
    internal static readonly Histogram<double> OperationDuration = Meter.CreateHistogram<double>(
        GenAiAttributes.OperationDurationMetric,
        unit: GenAiAttributes.OperationDurationUnit,
        description: "Duration of a ParleyAI chat client operation.");

    /// <summary>
    /// <c>gen_ai.client.token.usage</c> — a histogram of tokens used per call (unit <c>{token}</c>),
    /// dimensioned by <c>gen_ai.token.type</c> = <c>input</c> / <c>output</c>.
    /// </summary>
    internal static readonly Histogram<long> TokenUsage = Meter.CreateHistogram<long>(
        GenAiAttributes.TokenUsageMetric,
        unit: GenAiAttributes.TokenUsageUnit,
        description: "Number of tokens used in a ParleyAI chat client operation, by token type.");
}

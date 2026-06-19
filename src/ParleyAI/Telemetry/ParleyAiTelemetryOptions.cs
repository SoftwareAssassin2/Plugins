namespace ParleyAI.Telemetry;

/// <summary>
/// Tuning for ParleyAI's OpenTelemetry GenAI instrumentation.
/// </summary>
/// <remarks>
/// <para>
/// ParleyAI always emits <c>gen_ai.*</c> spans on <see cref="ParleyAiTelemetry.ActivitySourceName"/>
/// and the pinned metric instruments on <see cref="ParleyAiTelemetry.MeterName"/> — whether or not a
/// listener/exporter is attached, the instrumentation is cheap when nobody is listening. These options
/// only gate the <b>optional, privacy-sensitive</b> behavior.
/// </para>
/// <para>
/// ParleyAI itself takes no OTLP-exporter dependency; registering the source/meter with an exporter is
/// the consuming application's job (the scaffolded <c>Api</c>, fn-4.9).
/// </para>
/// </remarks>
public sealed class ParleyAiTelemetryOptions
{
    /// <summary>
    /// Whether to capture chat message content (prompts + completions) as span attributes
    /// (<c>gen_ai.input.messages</c> / <c>gen_ai.output.messages</c>). <b>Default <see langword="false"/></b>
    /// — message content is sensitive and is never recorded unless a consumer opts in.
    /// </summary>
    public bool CaptureMessageContent { get; set; }
}

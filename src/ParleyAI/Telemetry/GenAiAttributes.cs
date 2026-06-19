namespace ParleyAI.Telemetry;

/// <summary>
/// The SINGLE source of truth for the OpenTelemetry GenAI semantic-convention names ParleyAI emits:
/// the pinned semconv version, every <c>gen_ai.*</c> attribute key, the well-known attribute values,
/// the span/metric names, and the metric units.
/// </summary>
/// <remarks>
/// <para>
/// The GenAI semantic conventions are <b>experimental</b> and still moving. Every string ParleyAI
/// puts on a span or metric lives here so a semconv bump is a one-file change and a reviewer can audit
/// the emitted contract in one place. The values below track the version pinned in
/// <see cref="SemanticConventionsVersion"/>.
/// </para>
/// <para>
/// <b>Stability opt-in:</b> the OpenTelemetry ecosystem gates experimental-vs-stable GenAI emission on
/// the <c>OTEL_SEMCONV_STABILITY_OPT_IN</c> environment variable. ParleyAI emits the experimental
/// <c>gen_ai.*</c> shape directly (it does not branch on that variable); the constant
/// <see cref="StabilityOptInEnvVar"/> is documented here so consumers and the scaffold (fn-4.9) know
/// the knob exists.
/// </para>
/// <para>
/// <b>Provider attribute rename:</b> recent semconv renamed <c>gen_ai.system</c> to
/// <c>gen_ai.provider.name</c>. ParleyAI emits the current <see cref="ProviderName"/> key; the older
/// key name is recorded in <see cref="LegacyProviderSystemKey"/> for reviewers cross-referencing older
/// dashboards.
/// </para>
/// </remarks>
internal static class GenAiAttributes
{
    /// <summary>
    /// The OpenTelemetry GenAI semantic-conventions version this constants source tracks. Bumping the
    /// emitted contract is a one-file change anchored to this version.
    /// </summary>
    internal const string SemanticConventionsVersion = "1.30.0";

    /// <summary>
    /// The environment variable the OpenTelemetry ecosystem uses to opt into stable-vs-experimental
    /// GenAI semconv emission. Documented for consumers; ParleyAI emits the experimental shape directly.
    /// </summary>
    internal const string StabilityOptInEnvVar = "OTEL_SEMCONV_STABILITY_OPT_IN";

    // --- Span / operation -------------------------------------------------------------------------

    /// <summary>The <c>gen_ai.operation.name</c> attribute key.</summary>
    internal const string OperationName = "gen_ai.operation.name";

    /// <summary>The well-known <c>gen_ai.operation.name</c> value for a chat completion.</summary>
    internal const string OperationChat = "chat";

    // --- Provider ---------------------------------------------------------------------------------

    /// <summary>The current <c>gen_ai.provider.name</c> attribute key (renamed from <c>gen_ai.system</c>).</summary>
    internal const string ProviderName = "gen_ai.provider.name";

    /// <summary>The pre-rename attribute key for the provider, retained for reviewer cross-reference.</summary>
    internal const string LegacyProviderSystemKey = "gen_ai.system";

    /// <summary>The <c>gen_ai.provider.name</c> value for the OpenAI provider.</summary>
    internal const string ProviderOpenAi = "openai";

    /// <summary>The <c>gen_ai.provider.name</c> value for the Anthropic provider.</summary>
    internal const string ProviderAnthropic = "anthropic";

    // --- Request / response -----------------------------------------------------------------------

    /// <summary>The <c>gen_ai.request.model</c> attribute key.</summary>
    internal const string RequestModel = "gen_ai.request.model";

    /// <summary>The <c>gen_ai.request.max_tokens</c> attribute key.</summary>
    internal const string RequestMaxTokens = "gen_ai.request.max_tokens";

    /// <summary>The <c>gen_ai.request.temperature</c> attribute key.</summary>
    internal const string RequestTemperature = "gen_ai.request.temperature";

    /// <summary>The <c>gen_ai.response.finish_reasons</c> attribute key (an array of strings).</summary>
    internal const string ResponseFinishReasons = "gen_ai.response.finish_reasons";

    /// <summary>The <c>gen_ai.usage.input_tokens</c> attribute key.</summary>
    internal const string UsageInputTokens = "gen_ai.usage.input_tokens";

    /// <summary>The <c>gen_ai.usage.output_tokens</c> attribute key.</summary>
    internal const string UsageOutputTokens = "gen_ai.usage.output_tokens";

    // --- Token-usage metric dimension -------------------------------------------------------------

    /// <summary>The <c>gen_ai.token.type</c> attribute key dimensioning the token-usage metric.</summary>
    internal const string TokenType = "gen_ai.token.type";

    /// <summary>The <c>gen_ai.token.type</c> value for prompt/input tokens.</summary>
    internal const string TokenTypeInput = "input";

    /// <summary>The <c>gen_ai.token.type</c> value for generated/output tokens.</summary>
    internal const string TokenTypeOutput = "output";

    // --- Error ------------------------------------------------------------------------------------

    /// <summary>The <c>error.type</c> attribute key set on a failed span / the metric error dimension.</summary>
    internal const string ErrorType = "error.type";

    // --- Captured content (gated, default OFF) ----------------------------------------------------

    /// <summary>The <c>gen_ai.input.messages</c> attribute key — emitted only when content capture is on.</summary>
    internal const string InputMessages = "gen_ai.input.messages";

    /// <summary>The <c>gen_ai.output.messages</c> attribute key — emitted only when content capture is on.</summary>
    internal const string OutputMessages = "gen_ai.output.messages";

    // --- Metric names + units ---------------------------------------------------------------------

    /// <summary>The pinned client operation-duration histogram name.</summary>
    internal const string OperationDurationMetric = "gen_ai.client.operation.duration";

    /// <summary>The unit of <see cref="OperationDurationMetric"/> — seconds.</summary>
    internal const string OperationDurationUnit = "s";

    /// <summary>The pinned client token-usage histogram name.</summary>
    internal const string TokenUsageMetric = "gen_ai.client.token.usage";

    /// <summary>The unit of <see cref="TokenUsageMetric"/> — UCUM annotation for "token".</summary>
    internal const string TokenUsageUnit = "{token}";
}

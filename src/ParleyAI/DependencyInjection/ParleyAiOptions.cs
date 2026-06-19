using System;
using ParleyAI.Abstractions.Options;
using ParleyAI.Providers.Anthropic;
using ParleyAI.Providers.OpenAi;

namespace ParleyAI.DependencyInjection;

/// <summary>
/// Caller-facing configuration for <see cref="ParleyAiServiceCollectionExtensions.AddParleyAi(Microsoft.Extensions.DependencyInjection.IServiceCollection, Microsoft.Extensions.Configuration.IConfiguration, System.Action{ParleyAiOptions})"/>.
/// </summary>
/// <remarks>
/// All knobs are optional. The flat <c>OPENAI_*</c> / <c>ANTHROPIC_*</c> config keys remain the
/// no-glue default; these overrides exist for callers that supply a base URL / key directly or want
/// to tune per-provider resilience. The ctor-override delegates carry the SAME ctor &gt; flat-key
/// precedence the per-provider helpers (fn-4.2/.3) enforce.
/// </remarks>
public sealed class ParleyAiOptions
{
    /// <summary>
    /// Optional ctor-override for the OpenAI provider settings (base URL / key). Values set here win
    /// over the flat <c>OPENAI_*</c> config keys.
    /// </summary>
    public Action<OpenAiChatClientSettings>? ConfigureOpenAi { get; set; }

    /// <summary>
    /// Optional ctor-override for the Anthropic provider settings (base URL / key). Values set here
    /// win over the flat <c>ANTHROPIC_*</c> config keys.
    /// </summary>
    public Action<AnthropicChatClientSettings>? ConfigureAnthropic { get; set; }

    /// <summary>
    /// Optional tuning of the OpenAI resilience pipeline (timeout/retry knobs, enable/disable, or a
    /// full pipeline replacement). Applied to the default before the pipeline is built.
    /// </summary>
    public Action<ParleyAiResilienceOptions>? ConfigureOpenAiResilience { get; set; }

    /// <summary>
    /// Optional tuning of the Anthropic resilience pipeline (timeout/retry knobs, enable/disable, or
    /// a full pipeline replacement). Applied to the default before the pipeline is built.
    /// </summary>
    public Action<ParleyAiResilienceOptions>? ConfigureAnthropicResilience { get; set; }

    /// <summary>
    /// Optional tuning of the OpenAI adaptive AIMD rate optimizer (step / factor / floor / ceiling /
    /// per-category back-off, plus the hard <see cref="AimdOptions.Enabled"/> off switch). The
    /// optimizer is ON by default; set <see cref="AimdOptions.Enabled"/> to <c>false</c> here to get a
    /// bare OpenAI client (per-provider off switch). Applied to a fresh <see cref="AimdOptions"/> before
    /// the controller is built.
    /// </summary>
    public Action<AimdOptions>? ConfigureOpenAiAimd { get; set; }

    /// <summary>
    /// Optional tuning of the Anthropic adaptive AIMD rate optimizer. Same semantics as
    /// <see cref="ConfigureOpenAiAimd"/>, scoped to the Anthropic provider (independent per-provider
    /// isolation — disabling one leaves the other decorated; a global-off is just both disabled).
    /// </summary>
    public Action<AimdOptions>? ConfigureAnthropicAimd { get; set; }
}

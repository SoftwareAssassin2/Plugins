namespace ParleyAI.Abstractions.Options;

/// <summary>
/// Per-provider connection + behavior options.
/// </summary>
/// <remarks>
/// <para>
/// Precedence (resolved by the DI layer, fn-4.2/.3/.4): an explicit
/// <see cref="ApiKey"/> / <see cref="BaseUrl"/> set here (ctor override) wins over
/// the flat environment key; an absent <see cref="BaseUrl"/> falls through to the
/// provider SDK default (ParleyAI never hardcodes a provider host).
/// </para>
/// <para>The API key is REQUIRED — there is no SDK-default key fallback.</para>
/// </remarks>
public sealed class ProviderOptions
{
    /// <summary>
    /// The API key. Required (ctor override or the flat env key); never defaulted.
    /// </summary>
    public string? ApiKey { get; set; }

    /// <summary>
    /// The base URL override. <c>null</c> ⇒ the provider SDK default applies.
    /// Path semantics follow fn-3 verbatim (OpenAI includes <c>/v1</c>; Anthropic is
    /// the host root).
    /// </summary>
    public string? BaseUrl { get; set; }

    /// <summary>
    /// When <c>true</c>, prompt/response content is captured on telemetry spans.
    /// Default <c>false</c> (privacy-preserving).
    /// </summary>
    public bool CaptureContent { get; set; }

    /// <summary>
    /// When <c>true</c> (default), the standard transient-retry + timeout resilience
    /// pipeline is applied to the provider <c>HttpClient</c>.
    /// </summary>
    public bool ResilienceEnabled { get; set; } = true;

    /// <summary>The adaptive AIMD rate-optimizer options for this provider.</summary>
    public AimdOptions Aimd { get; set; } = new();
}

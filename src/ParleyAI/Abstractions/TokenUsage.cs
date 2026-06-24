namespace ParleyAI.Abstractions;

/// <summary>
/// Token accounting for a single chat exchange.
/// </summary>
/// <param name="InputTokens">Tokens consumed by the prompt / request.</param>
/// <param name="OutputTokens">Tokens generated in the response.</param>
public sealed record TokenUsage(int InputTokens, int OutputTokens)
{
    /// <summary>Total tokens billed for the exchange.</summary>
    public int TotalTokens => InputTokens + OutputTokens;
}

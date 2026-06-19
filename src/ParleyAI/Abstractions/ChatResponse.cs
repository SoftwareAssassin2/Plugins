namespace ParleyAI.Abstractions;

/// <summary>
/// A provider-neutral non-streaming chat response.
/// </summary>
/// <param name="Content">The generated assistant text.</param>
/// <param name="Usage">Token accounting for the exchange.</param>
/// <param name="FinishReason">Why generation stopped.</param>
public sealed record ChatResponse(string Content, TokenUsage Usage, FinishReason FinishReason);

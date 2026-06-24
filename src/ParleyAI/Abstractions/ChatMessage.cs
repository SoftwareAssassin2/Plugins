namespace ParleyAI.Abstractions;

/// <summary>
/// A single message in a chat exchange.
/// </summary>
/// <param name="Role">The participant role for this message.</param>
/// <param name="Content">The textual content of the message.</param>
public sealed record ChatMessage(Role Role, string Content);

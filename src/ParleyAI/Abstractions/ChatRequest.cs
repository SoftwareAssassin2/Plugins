using System.Collections.Generic;

namespace ParleyAI.Abstractions;

/// <summary>
/// A provider-neutral non-streaming chat request.
/// </summary>
/// <remarks>
/// <para>
/// The public surface deliberately exposes no provider-SDK types; each provider
/// implementation maps this shape onto its own wire model.
/// </para>
/// <para>
/// <b>Single-leading-System rule:</b> at most one <see cref="Role.System"/> message
/// is permitted and, when present, it MUST be the first element of
/// <see cref="Messages"/>. A request with multiple system messages, or a system
/// message in any non-leading position, is invalid and is rejected by provider
/// implementations with a <see cref="ParleyAIException"/> of category
/// <see cref="ParleyAIErrorCategory.InvalidRequest"/>.
/// </para>
/// </remarks>
public sealed class ChatRequest
{
    /// <summary>
    /// Creates a chat request.
    /// </summary>
    /// <param name="model">The provider model identifier (e.g. <c>gpt-4o</c>).</param>
    /// <param name="messages">
    /// The ordered conversation messages. Order is significant and preserved.
    /// </param>
    public ChatRequest(string model, IReadOnlyList<ChatMessage> messages)
    {
        Model = model;
        Messages = messages;
    }

    /// <summary>The provider model identifier.</summary>
    public string Model { get; }

    /// <summary>
    /// The ordered conversation messages. Order is significant. Subject to the
    /// single-leading-<see cref="Role.System"/> rule.
    /// </summary>
    public IReadOnlyList<ChatMessage> Messages { get; }

    /// <summary>Optional cap on generated tokens. <c>null</c> ⇒ provider default.</summary>
    public int? MaxTokens { get; init; }

    /// <summary>Optional sampling temperature. <c>null</c> ⇒ provider default.</summary>
    public double? Temperature { get; init; }
}

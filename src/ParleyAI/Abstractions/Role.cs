namespace ParleyAI.Abstractions;

/// <summary>
/// The role of a message participant in a chat exchange.
/// </summary>
/// <remarks>
/// ParleyAI enforces a single, leading <see cref="System"/> message per request
/// (see <see cref="ChatRequest"/>). The enum is intentionally pinned to the v1
/// non-streaming chat shape — additional roles (e.g. tool) are out of scope.
/// </remarks>
public enum Role
{
    /// <summary>
    /// System / developer instruction. At most one, and it must be the first
    /// message in the request.
    /// </summary>
    System = 0,

    /// <summary>An end-user turn.</summary>
    User = 1,

    /// <summary>A prior assistant turn.</summary>
    Assistant = 2,
}

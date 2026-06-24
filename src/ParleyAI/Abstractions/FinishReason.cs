namespace ParleyAI.Abstractions;

/// <summary>
/// The provider-neutral reason a chat completion stopped generating.
/// </summary>
public enum FinishReason
{
    /// <summary>The model emitted a natural stop / end-of-turn.</summary>
    Stop = 0,

    /// <summary>Generation hit the requested or model maximum token limit.</summary>
    Length = 1,

    /// <summary>Generation was halted by a provider content filter.</summary>
    ContentFilter = 2,

    /// <summary>The provider reported a reason ParleyAI does not map to the above.</summary>
    Unknown = 3,
}

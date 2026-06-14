using Framework;

namespace BusinessLogic;

/// <summary>
/// A minimal sample use-case demonstrating where domain behavior lives: in
/// <c>BusinessLogic</c>, exercised directly by a unit test (the Humble-Object
/// pattern from docs/architecture.md and docs/tdd.md). Replace it with the real
/// domain rules as the system grows.
/// </summary>
public sealed class Greeter
{
    /// <summary>
    /// Builds a greeting scoped to the authenticated session. Throws when the
    /// session is not authenticated — a decision that belongs here, not in the
    /// transport layer.
    /// </summary>
    public string Greet(SessionContext session)
    {
        ArgumentNullException.ThrowIfNull(session);
        if (!session.IsAuthenticated)
        {
            throw new InvalidOperationException("Cannot greet an unauthenticated session.");
        }

        return $"Hello, {session.UserId}.";
    }
}

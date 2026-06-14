using Framework;

namespace DataAccess.Rls;

/// <summary>
/// The thin database seam the <see cref="SessionUnitOfWork"/> orchestrates. It
/// isolates the only three raw-database operations the unit of work needs —
/// open a transaction, apply the session context, commit — behind an interface
/// so the UoW's ORDERING decision (transaction first, then session context) is a
/// pure, directly-testable unit, while the real EF Core / Npgsql calls live in a
/// thin adapter (<see cref="EfDbSession"/>) excluded from the coverage gate.
/// See docs/architecture.md (testability is a design property) and docs/tdd.md §5.
/// </summary>
public interface IDbSession : IAsyncDisposable
{
    /// <summary>Opens a database transaction (the <c>BEGIN</c>).</summary>
    Task BeginTransactionAsync(CancellationToken cancellationToken = default);

    /// <summary>
    /// Applies the session context for <paramref name="session"/> inside the open
    /// transaction (the parameterised <c>set_config(..., true)</c> for
    /// <c>app.user_id</c>/<c>app.roles</c>). MUST be called after
    /// <see cref="BeginTransactionAsync"/>.
    /// </summary>
    Task ApplySessionContextAsync(SessionContext session, CancellationToken cancellationToken = default);

    /// <summary>Commits the open transaction.</summary>
    Task CommitTransactionAsync(CancellationToken cancellationToken = default);

    /// <summary>Rolls back the open transaction (the failure-path counterpart of commit).</summary>
    Task RollbackTransactionAsync(CancellationToken cancellationToken = default);
}

using Framework;

namespace DataAccess.Rls;

/// <summary>
/// The per-request <see cref="ISessionUnitOfWork"/>. It owns the load-bearing
/// ordering decision and the transaction lifecycle and nothing else: open the
/// transaction FIRST, THEN apply the session context; reject a double-begin
/// (single-use per request); only commit an OPEN transaction; never act on an
/// already-completed one. The raw database calls are delegated to an
/// <see cref="IDbSession"/> seam (the real one is <see cref="EfDbSession"/>), so
/// this orchestration is a pure unit testable without a database. See
/// docs/keycloak.md §4.
/// </summary>
public sealed class SessionUnitOfWork : ISessionUnitOfWork
{
    private readonly IDbSession _session;
    private bool _everBegun;  // a unit is single-use: never re-begin, even after completion.
    private bool _open;       // a transaction is currently open and owned (begun, not yet committed/rolled back).
    private bool _disposed;

    public SessionUnitOfWork(IDbSession session)
    {
        _session = session ?? throw new ArgumentNullException(nameof(session));
    }

    /// <inheritdoc />
    public async Task BeginAsync(SessionContext session, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(session);
        if (_everBegun)
        {
            throw new InvalidOperationException(
                "The unit of work has already begun; create one per request.");
        }

        _everBegun = true;

        // ORDER IS THE CONTRACT: BEGIN, then SET LOCAL. A local setting only holds
        // inside an open transaction (and is pooling-safe only that way).
        await _session.BeginTransactionAsync(cancellationToken).ConfigureAwait(false);

        // Mark open the instant the transaction is live — BEFORE applying the
        // session context — so a failure while issuing SET LOCAL still rolls the
        // transaction back rather than leaking it.
        _open = true;
        try
        {
            await _session.ApplySessionContextAsync(session, cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            // Roll back with CancellationToken.None, NOT the caller's token — if the
            // apply failed due to cancellation, the token is already canceled and
            // cleanup must still run. Clear _open BEFORE rethrowing so a subsequent
            // RollbackAsync/CommitAsync from the caller's catch is a safe no-op (no
            // double-rollback on the same txn) while still surfacing the failure.
            await _session.RollbackTransactionAsync(CancellationToken.None).ConfigureAwait(false);
            _open = false;
            throw;
        }
    }

    /// <inheritdoc />
    public async Task CommitAsync(CancellationToken cancellationToken = default)
    {
        if (!_open)
        {
            throw new InvalidOperationException(
                "Cannot commit: no open transaction (it never began or was already committed/rolled back).");
        }

        // Clear _open before the call so a failed commit doesn't leave the unit
        // claiming an open transaction (the failure path rolls back via the caller).
        _open = false;
        await _session.CommitTransactionAsync(cancellationToken).ConfigureAwait(false);
    }

    /// <inheritdoc />
    public async Task RollbackAsync(CancellationToken cancellationToken = default)
    {
        // No-op when there is no open transaction (never began, or already
        // committed/rolled back) so a catch-all rollback is always safe to call.
        if (!_open)
        {
            return;
        }

        _open = false;
        await _session.RollbackTransactionAsync(cancellationToken).ConfigureAwait(false);
    }

    /// <inheritdoc />
    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        await _session.DisposeAsync().ConfigureAwait(false);
    }
}

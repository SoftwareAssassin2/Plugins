using Framework;

namespace DataAccess.Rls;

/// <summary>
/// The per-request <see cref="ISessionUnitOfWork"/>. It owns the load-bearing
/// ordering decision and nothing else: open the transaction FIRST, THEN apply the
/// session context, reject a double-begin, and only commit a begun unit. The raw
/// database calls are delegated to an <see cref="IDbSession"/> seam (the real one
/// is <see cref="EfDbSession"/>), so this orchestration is a pure unit testable
/// without a database. See docs/keycloak.md §4.
/// </summary>
public sealed class SessionUnitOfWork : ISessionUnitOfWork
{
    private readonly IDbSession _session;
    private bool _begun;
    private bool _disposed;

    public SessionUnitOfWork(IDbSession session)
    {
        _session = session ?? throw new ArgumentNullException(nameof(session));
    }

    /// <inheritdoc />
    public async Task BeginAsync(SessionContext session, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(session);
        if (_begun)
        {
            throw new InvalidOperationException(
                "The unit of work has already begun; create one per request.");
        }

        // ORDER IS THE CONTRACT: BEGIN, then SET LOCAL. A local setting only holds
        // inside an open transaction (and is pooling-safe only that way).
        await _session.BeginTransactionAsync(cancellationToken).ConfigureAwait(false);
        await _session.ApplySessionContextAsync(session, cancellationToken).ConfigureAwait(false);
        _begun = true;
    }

    /// <inheritdoc />
    public async Task CommitAsync(CancellationToken cancellationToken = default)
    {
        if (!_begun)
        {
            throw new InvalidOperationException(
                "Cannot commit a unit of work that has not begun.");
        }

        await _session.CommitTransactionAsync(cancellationToken).ConfigureAwait(false);
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

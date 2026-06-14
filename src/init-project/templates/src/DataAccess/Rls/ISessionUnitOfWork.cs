using Framework;

namespace DataAccess.Rls;

/// <summary>
/// The per-request unit of work that gates database access on the authenticated
/// session. Its contract is the load-bearing ORDER guarantee:
/// <c>BEGIN</c> the transaction FIRST, THEN issue the <c>SET LOCAL</c>-equivalent
/// <c>set_config(..., true)</c> for <c>app.user_id</c>/<c>app.roles</c> — because
/// a local session setting only persists inside an open transaction and is
/// pooling-safe only that way (a plain <c>SET</c> would leak across pooled
/// connections). All request work then runs inside that transaction, where
/// row-level security reads the settings. See docs/keycloak.md §4.
///
/// A deep, narrow interface: callers say "begin for this session" and "commit",
/// and the transaction + session-context wiring is hidden behind it.
/// </summary>
public interface ISessionUnitOfWork : IAsyncDisposable
{
    /// <summary>
    /// Opens the request transaction and applies the session context, in that
    /// order. Throws if a transaction is already open (a unit of work is
    /// single-use per request).
    /// </summary>
    Task BeginAsync(SessionContext session, CancellationToken cancellationToken = default);

    /// <summary>Commits the request transaction. No-op if none is open.</summary>
    Task CommitAsync(CancellationToken cancellationToken = default);
}

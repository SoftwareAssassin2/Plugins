using DataAccess.Rls;
using Microsoft.AspNetCore.Http;

namespace Api.Auth;

/// <summary>
/// The per-request middleware that ties Keycloak identity to the database session
/// context. For an authenticated request it opens the <see cref="ISessionUnitOfWork"/>
/// (transaction first, then <c>SET LOCAL app.user_id</c>), runs the rest of the
/// pipeline inside that transaction, then commits — so every query the request
/// issues is scoped by row-level security. Anonymous requests (no validated JWT)
/// run with no session context, so RLS-enabled tables return no rows
/// (deny-by-default). See docs/keycloak.md §4.
///
/// The decision-bearing core is <see cref="InvokeCoreAsync"/> (a pure unit over the
/// seams), kept separate from the ASP.NET <see cref="InvokeAsync"/> adapter so it
/// is testable to 100% without a host (docs/tdd.md, docs/architecture.md).
/// </summary>
public sealed class SessionUnitOfWorkMiddleware
{
    private readonly RequestDelegate _next;

    public SessionUnitOfWorkMiddleware(RequestDelegate next)
    {
        _next = next ?? throw new ArgumentNullException(nameof(next));
    }

    /// <summary>ASP.NET entry point: resolve the per-request UoW from DI and delegate.</summary>
    public Task InvokeAsync(HttpContext context, ISessionUnitOfWork unitOfWork)
    {
        ArgumentNullException.ThrowIfNull(context);
        var session = SessionContextFactory.FromPrincipal(context.User);
        return InvokeCoreAsync(session, unitOfWork, () => _next(context), context.RequestAborted);
    }

    /// <summary>
    /// The transport-free core. When the session is authenticated: begin the unit
    /// of work, run <paramref name="next"/> inside it, then commit. When it is not:
    /// just run <paramref name="next"/> (no transaction, no session context — RLS
    /// denies by default). Exposed for direct testing.
    /// </summary>
    public static async Task InvokeCoreAsync(
        Framework.SessionContext session,
        ISessionUnitOfWork unitOfWork,
        Func<Task> next,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(session);
        ArgumentNullException.ThrowIfNull(unitOfWork);
        ArgumentNullException.ThrowIfNull(next);

        if (!session.IsAuthenticated)
        {
            await next().ConfigureAwait(false);
            return;
        }

        try
        {
            await unitOfWork.BeginAsync(session, cancellationToken).ConfigureAwait(false);
            await next().ConfigureAwait(false);
            await unitOfWork.CommitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            // Deterministically close the transaction on ANY failure (begin,
            // request work, or commit) so the pooled `api` connection is never
            // returned with an open transaction / lingering RLS session settings.
            // Roll back with CancellationToken.None, NOT the request token — on a
            // client disconnect / cancellation the request token is already
            // canceled, and cleanup must still run. RollbackAsync is a no-op if
            // nothing began (BeginAsync self-heals a mid-begin failure), so this is
            // always safe. Rethrow to surface the original failure.
            await unitOfWork.RollbackAsync(CancellationToken.None).ConfigureAwait(false);
            throw;
        }
    }
}

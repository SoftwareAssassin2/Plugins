using System.Diagnostics.CodeAnalysis;
using Framework;
using Microsoft.EntityFrameworkCore;
using Npgsql;

namespace DataAccess.Rls;

/// <summary>
/// The EF Core / Npgsql adapter behind <see cref="IDbSession"/>. It is the THIN
/// glue that maps the seam's three operations onto the real database: begin an EF
/// transaction, run the parameterised <c>set_config</c> from
/// <see cref="SessionContextSql"/>, commit. It holds no decisions of its own — the
/// ordering decision lives in <see cref="SessionUnitOfWork"/> — so it is excluded
/// from the coverage gate per docs/tdd.md §5 (the parameterised SQL it issues is
/// asserted as a string by SessionContextSql's tests, and the live behaviour is
/// proven by the RLS integration smoke).
/// </summary>
[ExcludeFromCodeCoverage]
public sealed class EfDbSession : IDbSession
{
    private readonly PlatformDbContext _context;

    public EfDbSession(PlatformDbContext context)
    {
        _context = context ?? throw new ArgumentNullException(nameof(context));
    }

    public async Task BeginTransactionAsync(CancellationToken cancellationToken = default)
    {
        await _context.Database.BeginTransactionAsync(cancellationToken).ConfigureAwait(false);
    }

    public async Task ApplySessionContextAsync(SessionContext session, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(session);

        // Parameterised: the user id / roles are bound, never interpolated into SQL.
        var userId = new NpgsqlParameter("user_id", session.UserId);
        var roles = new NpgsqlParameter("roles", SessionContextSql.JoinRoles(session.Roles));

        await _context.Database
            .ExecuteSqlRawAsync(SessionContextSql.ApplySessionSql, new object[] { userId, roles }, cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task CommitTransactionAsync(CancellationToken cancellationToken = default)
    {
        var transaction = _context.Database.CurrentTransaction
            ?? throw new InvalidOperationException("No transaction is open to commit.");
        await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
    }

    public async ValueTask DisposeAsync()
    {
        var transaction = _context.Database.CurrentTransaction;
        if (transaction is not null)
        {
            await transaction.DisposeAsync().ConfigureAwait(false);
        }
    }
}

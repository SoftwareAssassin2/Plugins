using Microsoft.EntityFrameworkCore;

namespace DataAccess;

/// <summary>
/// The EF Core context for the <c>platform</c> database. This is the single
/// persistence seam for the system (see docs/architecture.md): business rules
/// live one layer up in <c>BusinessLogic</c>, never here.
///
/// Entities and code-first migrations are added in later work; this stub exists
/// so the design-time tooling (<c>dotnet ef</c>, via
/// <see cref="DesignTimeDbContextFactory"/>) and the runtime DI registration
/// have a context to bind to. Row-level security is enforced in Postgres off the
/// per-request session context (<c>app.user_id</c>) — see docs/keycloak.md.
/// </summary>
public class PlatformDbContext : DbContext
{
    public PlatformDbContext(DbContextOptions<PlatformDbContext> options)
        : base(options)
    {
    }
}

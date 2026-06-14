using System.Diagnostics.CodeAnalysis;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;

namespace DataAccess;

/// <summary>
/// Design-time factory the <c>dotnet ef</c> tooling uses to build a
/// <see cref="PlatformDbContext"/> WITHOUT starting the application or
/// authenticating through Keycloak.
///
/// It reads the connection string from the <c>MIGRATOR_CONNECTION_STRING</c>
/// environment variable — the <c>migrator</c>-role connection that
/// <c>system.sh migrate</c> (via <c>src/system-cli/migrate.sh</c>) sources from
/// the generated <c>src/DataAccess/.env</c> and exports before invoking
/// <c>dotnet ef</c> (.NET does not read <c>.env</c> files on its own). The
/// runtime <c>api</c>-role connection is never used here — migrations run as
/// <c>migrator</c> (a member of <c>owner</c>), issuing <c>SET ROLE owner</c> for
/// owner-privileged DDL. See docs/config-management.md and docs/keycloak.md.
///
/// This is design-time-only bootstrap glue (never executed at runtime), so it is
/// excluded from the coverage gate per docs/tdd.md §5.
/// </summary>
[ExcludeFromCodeCoverage]
public sealed class DesignTimeDbContextFactory : IDesignTimeDbContextFactory<PlatformDbContext>
{
    /// <summary>The env var carrying the design-time <c>migrator</c> connection string.</summary>
    public const string ConnectionStringVariable = "MIGRATOR_CONNECTION_STRING";

    public PlatformDbContext CreateDbContext(string[] args)
    {
        var connectionString = Environment.GetEnvironmentVariable(ConnectionStringVariable);
        if (string.IsNullOrWhiteSpace(connectionString))
        {
            throw new InvalidOperationException(
                $"{ConnectionStringVariable} is not set. Run migrations via " +
                "`./system.sh migrate`, which sources the generated src/DataAccess/.env " +
                "and exports the migrator connection string before invoking `dotnet ef`.");
        }

        var options = new DbContextOptionsBuilder<PlatformDbContext>()
            .UseNpgsql(connectionString)
            .Options;

        return new PlatformDbContext(options);
    }
}

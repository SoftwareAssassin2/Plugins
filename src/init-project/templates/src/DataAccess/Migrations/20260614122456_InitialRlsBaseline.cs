using System.Diagnostics.CodeAnalysis;
using DataAccess.Rls;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace DataAccess.Migrations
{
    /// <summary>
    /// The initial migration: installs the shared, NON-table-specific row-level-
    /// security baseline (default privileges for the <c>api</c> role + schema
    /// USAGE), all owner-privileged DDL wrapped in <c>SET ROLE owner</c> via
    /// <see cref="RlsBaseline"/>. It deliberately enables RLS on NO table — RLS is
    /// table-specific and there are no entity tables yet; each future entity
    /// migration calls <see cref="RlsPolicy.EnableForTable"/> for its own table.
    ///
    /// Runs as the <c>migrator</c> LOGIN role (a member of <c>owner</c>) via the
    /// design-time factory; <c>system.sh migrate</c> applies it. The SQL string is
    /// asserted by <c>RlsBaselineTests</c>; this migration is bootstrap glue with
    /// no decisions of its own, so it is excluded from the coverage gate per
    /// docs/tdd.md §5. See docs/keycloak.md §4.
    /// </summary>
    [ExcludeFromCodeCoverage]
    public partial class InitialRlsBaseline : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.Sql(RlsBaseline.Up());
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.Sql(RlsBaseline.Down());
        }
    }
}

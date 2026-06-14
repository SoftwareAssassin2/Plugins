using Microsoft.EntityFrameworkCore.Migrations;

namespace DataAccess.Rls;

/// <summary>
/// The MAKE-THE-SAFE-PATH-THE-DEFAULT migration helpers. Future entity migrations
/// call these instead of hand-emitting RLS / owner DDL, so they CANNOT forget the
/// <c>SET ROLE owner</c> wrapper that keeps every object owner-owned and applied
/// with owner privileges (EF connects as <c>migrator</c>; un-wrapped DDL would run
/// as <c>migrator</c> and create objects under the wrong role). This is the durable,
/// testable convention the spec asks for. See docs/keycloak.md §4.
/// </summary>
public static class MigrationBuilderRlsExtensions
{
    /// <summary>
    /// Enables row-level security on <paramref name="table"/> (scoped by
    /// <paramref name="userIdColumn"/> against <c>app.user_id</c>) as the
    /// <c>owner</c> role — the per-table RLS template (<see cref="RlsPolicy.EnableForTable"/>)
    /// already wrapped in <see cref="OwnerDdl.Wrap"/>. This is the call future
    /// entity migrations should make in <c>Up</c>.
    /// </summary>
    public static void EnableRlsForTableAsOwner(
        this MigrationBuilder migrationBuilder,
        string table,
        string userIdColumn,
        string? policyName = null)
    {
        ArgumentNullException.ThrowIfNull(migrationBuilder);
        var ddl = RlsPolicy.EnableForTable(table, userIdColumn, policyName);
        migrationBuilder.Sql(OwnerDdl.Wrap(ddl));
    }

    /// <summary>
    /// Runs arbitrary owner-privileged DDL (e.g. <c>CREATE TABLE</c>) wrapped in
    /// <c>SET ROLE owner</c> / <c>RESET ROLE</c>, so the created objects are
    /// owner-owned. The obvious way to emit any owner DDL from a migration.
    /// </summary>
    public static void SqlAsOwner(this MigrationBuilder migrationBuilder, string ownerDdl)
    {
        ArgumentNullException.ThrowIfNull(migrationBuilder);
        migrationBuilder.Sql(OwnerDdl.Wrap(ownerDdl));
    }
}

using System;
using System.Linq;
using DataAccess.Rls;
using Microsoft.EntityFrameworkCore.Migrations;
using Microsoft.EntityFrameworkCore.Migrations.Operations;
using Xunit;

namespace DataAccess.Tests.Rls;

public class MigrationBuilderRlsExtensionsTests
{
    private static string SingleSql(MigrationBuilder builder)
    {
        var op = Assert.Single(builder.Operations);
        return Assert.IsType<SqlOperation>(op).Sql;
    }

    [Fact]
    public void EnableRlsForTableAsOwner_EmitsOwnerWrappedPerTableRls()
    {
        var builder = new MigrationBuilder("Npgsql.EntityFrameworkCore.PostgreSQL");

        builder.EnableRlsForTableAsOwner("widgets", "user_id");

        var sql = SingleSql(builder);
        Assert.StartsWith("SET ROLE owner;", sql);
        Assert.EndsWith("RESET ROLE;", sql);
        Assert.Contains("ALTER TABLE \"widgets\" FORCE ROW LEVEL SECURITY;", sql);
        Assert.Contains("current_setting('app.user_id', true)", sql);
        // Equivalent to wrapping the raw template by hand.
        Assert.Equal(OwnerDdl.Wrap(RlsPolicy.EnableForTable("widgets", "user_id")), sql);
    }

    [Fact]
    public void EnableRlsForTableAsOwner_HonoursExplicitPolicyName()
    {
        var builder = new MigrationBuilder("Npgsql.EntityFrameworkCore.PostgreSQL");

        builder.EnableRlsForTableAsOwner("widgets", "user_id", "only_owner");

        Assert.Contains("CREATE POLICY \"only_owner\" ON \"widgets\"", SingleSql(builder));
    }

    [Fact]
    public void SqlAsOwner_WrapsArbitraryDdlInSetRoleOwner()
    {
        var builder = new MigrationBuilder("Npgsql.EntityFrameworkCore.PostgreSQL");

        builder.SqlAsOwner("CREATE TABLE widgets (id text);");

        var sql = SingleSql(builder);
        Assert.Equal(OwnerDdl.Wrap("CREATE TABLE widgets (id text);"), sql);
    }

    [Fact]
    public void EnableRlsForTableAsOwner_NullBuilder_Throws()
    {
        Assert.Throws<ArgumentNullException>(() =>
            ((MigrationBuilder)null!).EnableRlsForTableAsOwner("t", "user_id"));
    }

    [Fact]
    public void SqlAsOwner_NullBuilder_Throws()
    {
        Assert.Throws<ArgumentNullException>(() =>
            ((MigrationBuilder)null!).SqlAsOwner("SELECT 1;"));
    }
}

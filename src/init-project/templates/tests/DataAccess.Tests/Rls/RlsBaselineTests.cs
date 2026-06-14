using DataAccess.Rls;
using Xunit;

namespace DataAccess.Tests.Rls;

public class RlsBaselineTests
{
    [Fact]
    public void OwnerSql_GrantsApiSchemaUsage_AndDefaultPrivileges()
    {
        var sql = RlsBaseline.OwnerSql();

        Assert.Contains("GRANT USAGE ON SCHEMA public TO api;", sql);
        Assert.Contains("ALTER DEFAULT PRIVILEGES FOR ROLE owner IN SCHEMA public", sql);
        Assert.Contains("GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO api;", sql);
        Assert.Contains("GRANT USAGE, SELECT ON SEQUENCES TO api;", sql);
    }

    [Fact]
    public void OwnerSql_DoesNotEnableRlsOnAnyTable()
    {
        var sql = RlsBaseline.OwnerSql();

        // The baseline is NOT table-specific — no ENABLE/FORCE here.
        Assert.DoesNotContain("ENABLE ROW LEVEL SECURITY", sql);
        Assert.DoesNotContain("FORCE ROW LEVEL SECURITY", sql);
        Assert.DoesNotContain("CREATE POLICY", sql);
    }

    [Fact]
    public void Up_WrapsBaselineInSetRoleOwner()
    {
        var up = RlsBaseline.Up();

        Assert.StartsWith("SET ROLE owner;", up);
        Assert.EndsWith("RESET ROLE;", up);
        Assert.Contains(RlsBaseline.OwnerSql(), up);
    }

    [Fact]
    public void DownOwnerSql_RevokesWhatUpGranted()
    {
        var sql = RlsBaseline.DownOwnerSql();

        Assert.Contains("REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM api;", sql);
        Assert.Contains("REVOKE USAGE, SELECT ON SEQUENCES FROM api;", sql);
        Assert.Contains("REVOKE USAGE ON SCHEMA public FROM api;", sql);
    }

    [Fact]
    public void Down_WrapsReversalInSetRoleOwner()
    {
        var down = RlsBaseline.Down();

        Assert.StartsWith("SET ROLE owner;", down);
        Assert.EndsWith("RESET ROLE;", down);
        Assert.Contains(RlsBaseline.DownOwnerSql(), down);
    }
}

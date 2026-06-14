using DataAccess.Rls;
using Xunit;

namespace DataAccess.Tests.Rls;

public class OwnerDdlTests
{
    [Fact]
    public void RoleConstants_AreTheFixedScaffoldNames()
    {
        Assert.Equal("owner", OwnerDdl.OwnerRole);
        Assert.Equal("api", OwnerDdl.ApiRole);
    }

    [Fact]
    public void Wrap_BracketsDdlWithSetRoleOwnerAndResetRole()
    {
        var wrapped = OwnerDdl.Wrap("CREATE TABLE widgets (id text);");

        Assert.StartsWith("SET ROLE owner;", wrapped);
        Assert.EndsWith("RESET ROLE;", wrapped);
        Assert.Contains("CREATE TABLE widgets (id text);", wrapped);
    }

    [Fact]
    public void Wrap_TrimsSurroundingWhitespaceOfInnerDdl()
    {
        var wrapped = OwnerDdl.Wrap("   SELECT 1;   ");

        Assert.Equal("SET ROLE owner;\nSELECT 1;\nRESET ROLE;", wrapped);
    }

    [Fact]
    public void Wrap_Null_Throws()
    {
        Assert.Throws<System.ArgumentNullException>(() => OwnerDdl.Wrap(null!));
    }
}

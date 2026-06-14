using DataAccess.Rls;
using Xunit;

namespace DataAccess.Tests.Rls;

public class SessionContextSqlTests
{
    [Fact]
    public void Keys_AreTheDocumentedSessionKeys()
    {
        Assert.Equal("app.user_id", SessionContextSql.UserIdKey);
        Assert.Equal("app.roles", SessionContextSql.RolesKey);
    }

    [Fact]
    public void ApplySessionSql_UsesParameterisedSetConfig_ForBothKeys()
    {
        var sql = SessionContextSql.ApplySessionSql;

        // Parameterised (values bound, never interpolated) and is_local = true.
        Assert.Contains("set_config('app.user_id', @user_id, true)", sql);
        Assert.Contains("set_config('app.roles', @roles, true)", sql);
        Assert.DoesNotContain("SET LOCAL", sql);
    }

    [Fact]
    public void JoinRoles_JoinsWithComma()
    {
        var joined = SessionContextSql.JoinRoles(new[] { "admin", "user" });

        Assert.Equal("admin,user", joined);
    }

    [Fact]
    public void JoinRoles_Null_ReturnsEmpty()
    {
        Assert.Equal(string.Empty, SessionContextSql.JoinRoles(null));
    }

    [Fact]
    public void JoinRoles_Empty_ReturnsEmpty()
    {
        Assert.Equal(string.Empty, SessionContextSql.JoinRoles(System.Array.Empty<string>()));
    }
}

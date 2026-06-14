using System;
using DataAccess.Rls;
using Xunit;

namespace DataAccess.Tests.Rls;

public class RlsPolicyTests
{
    [Fact]
    public void EnableForTable_GrantsApiCrud_AndForcesRls()
    {
        var sql = RlsPolicy.EnableForTable("widgets", "user_id");

        Assert.Contains("GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE \"widgets\" TO api;", sql);
        Assert.Contains("ALTER TABLE \"widgets\" ENABLE ROW LEVEL SECURITY;", sql);
        Assert.Contains("ALTER TABLE \"widgets\" FORCE ROW LEVEL SECURITY;", sql);
    }

    [Fact]
    public void EnableForTable_PolicyKeysOffAppUserIdSetting_UsingAndWithCheck()
    {
        var sql = RlsPolicy.EnableForTable("widgets", "user_id");

        Assert.Contains("USING (\"user_id\" = current_setting('app.user_id', true))", sql);
        Assert.Contains("WITH CHECK (\"user_id\" = current_setting('app.user_id', true))", sql);
        Assert.Equal("app.user_id", RlsPolicy.UserIdSetting);
    }

    [Fact]
    public void EnableForTable_DefaultsPolicyName_FromTable()
    {
        var sql = RlsPolicy.EnableForTable("widgets", "user_id");

        Assert.Contains("CREATE POLICY \"widgets_user_isolation\" ON \"widgets\"", sql);
        Assert.Contains("DROP POLICY IF EXISTS \"widgets_user_isolation\" ON \"widgets\";", sql);
    }

    [Fact]
    public void EnableForTable_HonoursExplicitPolicyName()
    {
        var sql = RlsPolicy.EnableForTable("widgets", "user_id", "owner_only");

        Assert.Contains("CREATE POLICY \"owner_only\" ON \"widgets\"", sql);
    }

    [Theory]
    [InlineData("good_name")]
    [InlineData("_leading_underscore")]
    [InlineData("Mixed123")]
    public void ValidateIdentifier_AcceptsAllowedNames(string name)
    {
        Assert.Equal(name, RlsPolicy.ValidateIdentifier(name, "name"));
    }

    [Theory]
    [InlineData("")]            // empty
    [InlineData("1leading")]    // digit at position 0
    [InlineData("has space")]   // illegal char mid-string
    [InlineData("drop;table")]  // injection attempt
    public void ValidateIdentifier_RejectsIllegalNames(string name)
    {
        Assert.Throws<ArgumentException>(() => RlsPolicy.ValidateIdentifier(name, "name"));
    }

    [Fact]
    public void ValidateIdentifier_Null_Throws()
    {
        Assert.Throws<ArgumentException>(() => RlsPolicy.ValidateIdentifier(null!, "name"));
    }

    [Fact]
    public void EnableForTable_RejectsIllegalTableName()
    {
        Assert.Throws<ArgumentException>(() => RlsPolicy.EnableForTable("bad name", "user_id"));
    }
}

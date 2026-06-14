using Framework;
using Xunit;

namespace Framework.Tests;

public class SessionContextTests
{
    [Fact]
    public void IsAuthenticated_True_ForNonEmptyUserId()
    {
        var session = new SessionContext("user-1", new[] { "user" });

        Assert.True(session.IsAuthenticated);
        Assert.Equal("user-1", session.UserId);
        Assert.Contains("user", session.Roles);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    public void IsAuthenticated_False_ForBlankUserId(string userId)
    {
        var session = new SessionContext(userId, System.Array.Empty<string>());

        Assert.False(session.IsAuthenticated);
    }
}

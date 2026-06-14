using System.Security.Claims;
using Api.Auth;
using Xunit;

namespace Api.Tests.Auth;

public class SessionContextFactoryTests
{
    private static ClaimsPrincipal Authenticated(params Claim[] claims)
        => new(new ClaimsIdentity(claims, authenticationType: "Bearer"));

    [Fact]
    public void FromPrincipal_Null_ReturnsUnauthenticated()
    {
        var session = SessionContextFactory.FromPrincipal(null);

        Assert.False(session.IsAuthenticated);
        Assert.Empty(session.Roles);
    }

    [Fact]
    public void FromPrincipal_UnauthenticatedIdentity_ReturnsUnauthenticated()
    {
        // No authenticationType => Identity.IsAuthenticated is false.
        var principal = new ClaimsPrincipal(new ClaimsIdentity());

        var session = SessionContextFactory.FromPrincipal(principal);

        Assert.False(session.IsAuthenticated);
    }

    [Fact]
    public void FromPrincipal_UsesSubClaim_ForUserId()
    {
        var principal = Authenticated(new Claim("sub", "kc-user-123"));

        var session = SessionContextFactory.FromPrincipal(principal);

        Assert.True(session.IsAuthenticated);
        Assert.Equal("kc-user-123", session.UserId);
    }

    [Fact]
    public void FromPrincipal_FallsBackToNameIdentifier_WhenSubAbsent()
    {
        var principal = Authenticated(new Claim(ClaimTypes.NameIdentifier, "ni-456"));

        var session = SessionContextFactory.FromPrincipal(principal);

        Assert.Equal("ni-456", session.UserId);
    }

    [Fact]
    public void FromPrincipal_AuthenticatedButNoSubject_ReturnsEmptyUserId()
    {
        var principal = Authenticated(new Claim("unrelated", "x"));

        var session = SessionContextFactory.FromPrincipal(principal);

        Assert.Equal(string.Empty, session.UserId);
        Assert.False(session.IsAuthenticated);
    }

    [Fact]
    public void FromPrincipal_CollectsRoleClaims_DroppingEmpties()
    {
        var principal = Authenticated(
            new Claim("sub", "u"),
            new Claim(ClaimTypes.Role, "admin"),
            new Claim(ClaimTypes.Role, ""),
            new Claim(ClaimTypes.Role, "user"));

        var session = SessionContextFactory.FromPrincipal(principal);

        Assert.Equal(new[] { "admin", "user" }, session.Roles);
    }
}

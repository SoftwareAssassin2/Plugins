using System.Linq;
using System.Security.Claims;
using Api.Auth;
using Xunit;

namespace Api.Tests.Auth;

public class KeycloakRoleClaimsTests
{
    private static ClaimsIdentity IdentityWithRealmAccess(string json)
        => new(new[] { new Claim(KeycloakRoleClaims.RealmAccessClaimType, json) }, "Bearer");

    [Fact]
    public void ExtractRealmRoles_NullIdentity_Empty()
    {
        Assert.Empty(KeycloakRoleClaims.ExtractRealmRoles(null));
    }

    [Fact]
    public void ExtractRealmRoles_NoRealmAccessClaim_Empty()
    {
        var identity = new ClaimsIdentity(new[] { new Claim("sub", "u") }, "Bearer");

        Assert.Empty(KeycloakRoleClaims.ExtractRealmRoles(identity));
    }

    [Fact]
    public void ExtractRealmRoles_BlankClaim_Empty()
    {
        Assert.Empty(KeycloakRoleClaims.ExtractRealmRoles(IdentityWithRealmAccess("   ")));
    }

    [Fact]
    public void ExtractRealmRoles_InvalidJson_Empty()
    {
        Assert.Empty(KeycloakRoleClaims.ExtractRealmRoles(IdentityWithRealmAccess("{not json")));
    }

    [Fact]
    public void ExtractRealmRoles_NonObjectRoot_Empty()
    {
        Assert.Empty(KeycloakRoleClaims.ExtractRealmRoles(IdentityWithRealmAccess("[1,2,3]")));
    }

    [Fact]
    public void ExtractRealmRoles_NoRolesProperty_Empty()
    {
        Assert.Empty(KeycloakRoleClaims.ExtractRealmRoles(IdentityWithRealmAccess("{\"other\":1}")));
    }

    [Fact]
    public void ExtractRealmRoles_RolesNotArray_Empty()
    {
        Assert.Empty(KeycloakRoleClaims.ExtractRealmRoles(IdentityWithRealmAccess("{\"roles\":\"admin\"}")));
    }

    [Fact]
    public void ExtractRealmRoles_FlattensStringRoles_DroppingNonStringsAndBlanks()
    {
        var identity = IdentityWithRealmAccess("{\"roles\":[\"admin\",\"\",\"user\",42,null]}");

        var roles = KeycloakRoleClaims.ExtractRealmRoles(identity);

        Assert.Equal(new[] { "admin", "user" }, roles.ToArray());
    }

    [Fact]
    public void PopulateRoleClaims_Null_NoThrow()
    {
        KeycloakRoleClaims.PopulateRoleClaims(null);
    }

    [Fact]
    public void PopulateRoleClaims_AddsRoleClaims_FromRealmAccess()
    {
        var identity = IdentityWithRealmAccess("{\"roles\":[\"admin\",\"user\"]}");

        KeycloakRoleClaims.PopulateRoleClaims(identity);

        var roles = identity.FindAll(ClaimTypes.Role).Select(c => c.Value).ToArray();
        Assert.Equal(new[] { "admin", "user" }, roles);
    }

    [Fact]
    public void PopulateRoleClaims_Idempotent_NoDuplicates()
    {
        var identity = IdentityWithRealmAccess("{\"roles\":[\"admin\",\"admin\"]}");
        identity.AddClaim(new Claim(ClaimTypes.Role, "admin")); // pre-existing

        KeycloakRoleClaims.PopulateRoleClaims(identity);
        KeycloakRoleClaims.PopulateRoleClaims(identity);

        var adminCount = identity.FindAll(ClaimTypes.Role).Count(c => c.Value == "admin");
        Assert.Equal(1, adminCount);
    }

    [Fact]
    public void PopulateRoleClaims_ThenFactory_SurfacesRolesInSessionContext()
    {
        var identity = IdentityWithRealmAccess("{\"roles\":[\"admin\"]}");
        identity.AddClaim(new Claim("sub", "kc-1"));
        KeycloakRoleClaims.PopulateRoleClaims(identity);

        var session = SessionContextFactory.FromPrincipal(new ClaimsPrincipal(identity));

        Assert.Equal("kc-1", session.UserId);
        Assert.Contains("admin", session.Roles);
    }
}

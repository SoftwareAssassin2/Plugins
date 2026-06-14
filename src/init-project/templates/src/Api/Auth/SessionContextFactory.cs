using System.Security.Claims;
using Framework;

namespace Api.Auth;

/// <summary>
/// Maps the validated Keycloak JWT (a <see cref="ClaimsPrincipal"/>) onto the
/// repo's <see cref="SessionContext"/> primitive: the subject (<c>sub</c>) claim
/// becomes the user id that flows into <c>app.user_id</c>, and the realm roles
/// become <c>app.roles</c>. This is the one decision-bearing seam in the auth
/// path, kept out of the middleware glue so it can be exercised directly to 100%
/// (docs/tdd.md, docs/architecture.md). See docs/keycloak.md §4.
/// </summary>
public static class SessionContextFactory
{
    /// <summary>The claim type carrying the Keycloak subject id (OIDC <c>sub</c>).</summary>
    public const string SubjectClaimType = "sub";

    /// <summary>The claim type Keycloak realm roles are surfaced under after mapping.</summary>
    public const string RoleClaimType = ClaimTypes.Role;

    /// <summary>
    /// Builds a <see cref="SessionContext"/> from the principal. Returns an
    /// unauthenticated context (empty user id) when the principal is null, has no
    /// authenticated identity, or carries no usable subject claim — so callers can
    /// branch on <see cref="SessionContext.IsAuthenticated"/> rather than handling
    /// nulls. Falls back to <see cref="ClaimTypes.NameIdentifier"/> when the raw
    /// <c>sub</c> claim is absent (some JWT handlers remap it).
    /// </summary>
    public static SessionContext FromPrincipal(ClaimsPrincipal? principal)
    {
        if (principal?.Identity is null || !principal.Identity.IsAuthenticated)
        {
            return new SessionContext(string.Empty, Array.Empty<string>());
        }

        var subject = principal.FindFirst(SubjectClaimType)?.Value
            ?? principal.FindFirst(ClaimTypes.NameIdentifier)?.Value
            ?? string.Empty;

        var roles = principal.FindAll(RoleClaimType)
            .Select(c => c.Value)
            .Where(v => !string.IsNullOrEmpty(v))
            .ToArray();

        return new SessionContext(subject, roles);
    }
}

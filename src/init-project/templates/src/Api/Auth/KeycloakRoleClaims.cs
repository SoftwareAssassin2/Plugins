using System.Security.Claims;
using System.Text.Json;

namespace Api.Auth;

/// <summary>
/// Flattens Keycloak's <c>realm_access.roles</c> JSON array into individual
/// <see cref="ClaimTypes.Role"/> claims. Keycloak does NOT emit one role claim per
/// role — it emits a single <c>realm_access</c> claim whose value is a JSON object
/// like <c>{"roles":["admin","user"]}</c>. Setting
/// <c>TokenValidationParameters.RoleClaimType</c> alone does not expand that array,
/// so <see cref="SessionContextFactory"/> would see no roles. This unit performs
/// the expansion so realm roles flow into <c>app.roles</c>. See docs/keycloak.md §4.
///
/// Kept as a pure, directly-testable function (the JWT bearer event in Program.cs
/// is thin glue that calls it) per docs/architecture.md / docs/tdd.md.
/// </summary>
public static class KeycloakRoleClaims
{
    /// <summary>The Keycloak token claim holding the realm-roles JSON object.</summary>
    public const string RealmAccessClaimType = "realm_access";

    /// <summary>
    /// Extracts realm role names from the <c>realm_access</c> claim of
    /// <paramref name="identity"/>. Returns an empty sequence when the claim is
    /// absent, blank, not valid JSON, or has no <c>roles</c> array — so the caller
    /// never has to special-case a malformed/absent claim. Blank role entries are
    /// dropped.
    /// </summary>
    public static IReadOnlyList<string> ExtractRealmRoles(ClaimsIdentity? identity)
    {
        var raw = identity?.FindFirst(RealmAccessClaimType)?.Value;
        if (string.IsNullOrWhiteSpace(raw))
        {
            return Array.Empty<string>();
        }

        try
        {
            using var doc = JsonDocument.Parse(raw);
            if (doc.RootElement.ValueKind != JsonValueKind.Object
                || !doc.RootElement.TryGetProperty("roles", out var rolesElement)
                || rolesElement.ValueKind != JsonValueKind.Array)
            {
                return Array.Empty<string>();
            }

            var roles = new List<string>();
            foreach (var element in rolesElement.EnumerateArray())
            {
                if (element.ValueKind == JsonValueKind.String)
                {
                    var value = element.GetString();
                    if (!string.IsNullOrWhiteSpace(value))
                    {
                        roles.Add(value!);
                    }
                }
            }

            return roles;
        }
        catch (JsonException)
        {
            return Array.Empty<string>();
        }
    }

    /// <summary>
    /// Adds a <see cref="ClaimTypes.Role"/> claim to <paramref name="identity"/>
    /// for each realm role not already present, so role-based checks and
    /// <see cref="SessionContextFactory"/> see them. Idempotent: re-running adds no
    /// duplicates. No-op when <paramref name="identity"/> is null.
    /// </summary>
    public static void PopulateRoleClaims(ClaimsIdentity? identity)
    {
        if (identity is null)
        {
            return;
        }

        var existing = identity.FindAll(ClaimTypes.Role)
            .Select(c => c.Value)
            .ToHashSet(StringComparer.Ordinal);

        foreach (var role in ExtractRealmRoles(identity))
        {
            if (existing.Add(role))
            {
                identity.AddClaim(new Claim(ClaimTypes.Role, role));
            }
        }
    }
}

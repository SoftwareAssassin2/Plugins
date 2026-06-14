namespace Framework;

/// <summary>
/// The per-request identity context resolved from the validated Keycloak JWT.
/// This is the cross-cutting primitive the layers above use to scope work to a
/// user; <c>DataAccess</c> projects it onto the Postgres session
/// (<c>app.user_id</c> / <c>app.roles</c>) so row-level security can read it via
/// <c>current_setting('app.user_id', true)</c>. See docs/keycloak.md.
/// </summary>
/// <param name="UserId">The authenticated subject id (Keycloak <c>sub</c> claim).</param>
/// <param name="Roles">The realm/role names granted to the subject.</param>
public sealed record SessionContext(string UserId, IReadOnlyCollection<string> Roles)
{
    /// <summary>True when this context carries a non-empty user id.</summary>
    public bool IsAuthenticated => !string.IsNullOrWhiteSpace(UserId);
}

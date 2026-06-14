namespace DataAccess.Rls;

/// <summary>
/// The single source of truth for the Postgres session-context keys and the SQL
/// that projects a <see cref="Framework.SessionContext"/> onto them. Row-level
/// security policies read these keys via <c>current_setting(&lt;key&gt;, true)</c>
/// (the <c>true</c> = "missing_ok", so an unset key yields NULL rather than an
/// error — deny-by-default for RLS). See docs/keycloak.md §4.
///
/// The values are applied with <c>set_config(key, value, /*is_local*/ true)</c>
/// rather than a literal <c>SET LOCAL key = 'value'</c> statement: <c>set_config</c>
/// takes the value as a real query parameter, so the user id / roles never enter
/// the SQL text and there is no injection surface. <c>is_local = true</c> scopes
/// the setting to the surrounding transaction (so it is pooling-safe and cleared
/// at commit/rollback) — which is exactly why the unit-of-work must
/// <em>open the transaction first, then</em> call this. This is a deep unit: a
/// narrow surface (two keys, one parameterised statement) hiding the pooling /
/// quoting / deny-by-default reasoning.
/// </summary>
public static class SessionContextSql
{
    /// <summary>The Postgres session key carrying the authenticated user id.</summary>
    public const string UserIdKey = "app.user_id";

    /// <summary>The Postgres session key carrying the comma-joined role names.</summary>
    public const string RolesKey = "app.roles";

    /// <summary>The separator role names are joined with for the <c>app.roles</c> setting.</summary>
    public const char RolesSeparator = ',';

    /// <summary>
    /// The parameterised statement that sets BOTH session keys for the current
    /// transaction. Bind <c>@user_id</c> to <see cref="Framework.SessionContext.UserId"/>
    /// and <c>@roles</c> to <see cref="JoinRoles"/>. <c>set_config</c> returns the
    /// applied value (discarded). Uses positional/named parameters so the values
    /// are never interpolated into SQL.
    /// </summary>
    public const string ApplySessionSql =
        "SELECT set_config('" + UserIdKey + "', @user_id, true), " +
        "set_config('" + RolesKey + "', @roles, true);";

    /// <summary>
    /// Joins role names into the single string stored in <c>app.roles</c>. Returns
    /// the empty string for a null/empty collection (a present-but-empty setting,
    /// distinct from an unset one). Null entries are treated as empty segments.
    /// </summary>
    public static string JoinRoles(IReadOnlyCollection<string>? roles)
    {
        if (roles is null || roles.Count == 0)
        {
            return string.Empty;
        }

        return string.Join(RolesSeparator, roles);
    }
}

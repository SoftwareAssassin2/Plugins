namespace DataAccess.Rls;

/// <summary>
/// Generates the per-table row-level-security baseline SQL — the documented
/// template every entity migration uses to make a table user-scoped. RLS is
/// table-specific, so it cannot be enabled before a table exists; the INITIAL
/// migration ships no <c>ENABLE</c> (there are no tables yet) and instead installs
/// the shared grants/helpers, while each future entity migration calls
/// <see cref="EnableForTable"/> for its own table. See docs/keycloak.md §4.
///
/// The generated SQL, for a table with a user-id column:
/// <list type="bullet">
/// <item>grants the table CRUD to the runtime <c>api</c> role,</item>
/// <item><c>ENABLE</c> + <c>FORCE ROW LEVEL SECURITY</c> (FORCE so even the table
/// owner is subject to the policy — defence in depth),</item>
/// <item>a policy whose <c>USING</c> and <c>WITH CHECK</c> both compare the row's
/// user-id column to <c>current_setting('app.user_id', true)</c>. The
/// <c>true</c> (missing_ok) means an unset session key yields NULL, and
/// <c>column = NULL</c> is never true — so with no session context NO rows are
/// visible or writable (deny-by-default).</item>
/// </list>
/// Emitted as owner-privileged DDL, so callers wrap the result in
/// <see cref="OwnerDdl.Wrap"/>.
/// </summary>
public static class RlsPolicy
{
    /// <summary>The session key the generated policy keys off (mirrors <see cref="SessionContextSql.UserIdKey"/>).</summary>
    public const string UserIdSetting = SessionContextSql.UserIdKey;

    /// <summary>
    /// Builds the full RLS-enable SQL for <paramref name="table"/>, scoping rows
    /// by <paramref name="userIdColumn"/> against the per-request
    /// <c>app.user_id</c> session setting. Identifiers are validated (see
    /// <see cref="ValidateIdentifier"/>) and quoted so they are safe to embed.
    /// </summary>
    /// <param name="table">The table name (unqualified; lives in <c>public</c>).</param>
    /// <param name="userIdColumn">The column holding the owning user's id.</param>
    /// <param name="policyName">The policy name; defaults to <c>&lt;table&gt;_user_isolation</c>.</param>
    public static string EnableForTable(string table, string userIdColumn, string? policyName = null)
    {
        var t = ValidateIdentifier(table, nameof(table));
        var col = ValidateIdentifier(userIdColumn, nameof(userIdColumn));
        var policy = policyName is null
            ? $"{t}_user_isolation"
            : ValidateIdentifier(policyName, nameof(policyName));

        // current_setting(...) returns text; compare against the text user-id column.
        // Quote identifiers; the setting key is a fixed constant (no injection surface).
        return
            $"GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE \"{t}\" TO {OwnerDdl.ApiRole};\n" +
            $"ALTER TABLE \"{t}\" ENABLE ROW LEVEL SECURITY;\n" +
            $"ALTER TABLE \"{t}\" FORCE ROW LEVEL SECURITY;\n" +
            $"DROP POLICY IF EXISTS \"{policy}\" ON \"{t}\";\n" +
            $"CREATE POLICY \"{policy}\" ON \"{t}\"\n" +
            $"  USING (\"{col}\" = current_setting('{UserIdSetting}', true))\n" +
            $"  WITH CHECK (\"{col}\" = current_setting('{UserIdSetting}', true));";
    }

    /// <summary>
    /// Validates a SQL identifier against a conservative allow-list
    /// (<c>^[A-Za-z_][A-Za-z0-9_]*$</c>) so a caller-supplied table/column/policy
    /// name can be embedded without a quoting hazard. Throws
    /// <see cref="ArgumentException"/> on a null/empty or out-of-alphabet name.
    /// </summary>
    public static string ValidateIdentifier(string identifier, string paramName)
    {
        if (string.IsNullOrEmpty(identifier))
        {
            throw new ArgumentException("Identifier must be non-empty.", paramName);
        }

        foreach (var (ch, index) in identifier.Select((c, i) => (c, i)))
        {
            var ok = ch == '_'
                || (ch >= 'A' && ch <= 'Z')
                || (ch >= 'a' && ch <= 'z')
                || (index > 0 && ch >= '0' && ch <= '9');
            if (!ok)
            {
                throw new ArgumentException(
                    $"Identifier '{identifier}' contains an illegal character at position {index}; " +
                    "only [A-Za-z_][A-Za-z0-9_]* is allowed.",
                    paramName);
            }
        }

        return identifier;
    }
}

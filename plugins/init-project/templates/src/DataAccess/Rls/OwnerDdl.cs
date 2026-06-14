namespace DataAccess.Rls;

/// <summary>
/// The durable convention for owner-privileged DDL in EF migrations. Migrations
/// connect as the LOGIN <c>migrator</c> role (EF cannot log in as the NOLOGIN
/// <c>owner</c>), which is a <em>member</em> of <c>owner</c>; owner-privileged DDL
/// must therefore run under <c>SET ROLE owner</c> so every created object is
/// owned by <c>owner</c> (not by <c>migrator</c>). This wrapper makes that the one
/// obvious way to emit such DDL — every future schema/RLS migration calls
/// <see cref="Wrap"/> rather than open-coding the role switch. See
/// docs/keycloak.md §4 and docs/config-management.md §3.
///
/// The role names <c>owner</c>/<c>migrator</c>/<c>api</c> are FIXED scaffold
/// constants (not configurable), so they appear here as literals.
/// </summary>
public static class OwnerDdl
{
    /// <summary>The NOLOGIN role that owns all schema objects; DDL runs as this role.</summary>
    public const string OwnerRole = "owner";

    /// <summary>The least-privilege LOGIN role the runtime Api connects as.</summary>
    public const string ApiRole = "api";

    /// <summary>
    /// Wraps owner-privileged DDL so it executes under <c>SET ROLE owner</c> and
    /// resets afterwards, leaving the connection's role unchanged for the caller.
    /// The inner SQL is emitted verbatim between the role switch and the reset.
    /// </summary>
    /// <param name="ownerDdl">The DDL to run as <c>owner</c> (one or more statements).</param>
    /// <returns>The wrapped SQL: <c>SET ROLE owner;</c> … <c>RESET ROLE;</c></returns>
    public static string Wrap(string ownerDdl)
    {
        ArgumentNullException.ThrowIfNull(ownerDdl);

        var trimmed = ownerDdl.Trim();
        return $"SET ROLE {OwnerRole};\n{trimmed}\nRESET ROLE;";
    }
}

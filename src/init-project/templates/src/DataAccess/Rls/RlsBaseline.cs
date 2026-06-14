namespace DataAccess.Rls;

/// <summary>
/// The owner-privileged DDL the INITIAL migration installs once: the shared
/// row-level-security baseline that is NOT table-specific. It deliberately does
/// NOT enable RLS on any table (there are none yet — per-table ENABLE/FORCE ships
/// in the entity migrations via <see cref="RlsPolicy.EnableForTable"/>). It sets:
/// <list type="bullet">
/// <item><c>ALTER DEFAULT PRIVILEGES FOR ROLE owner</c> so tables/sequences
/// <em>subsequently</em> created by <c>owner</c> automatically grant the runtime
/// <c>api</c> role CRUD (RLS still constrains the rows) — so future entity
/// migrations don't have to remember per-object grants,</item>
/// <item>USAGE on the <c>public</c> schema to <c>api</c> (idempotent re-assert),</item>
/// <item>the named session-context helper function <see cref="HelperFunctionName"/>
/// (a <c>STABLE</c> wrapper over <c>current_setting('app.user_id', true)</c>) so
/// RLS policies and queries read the per-request user id through one canonical
/// name instead of repeating the raw <c>current_setting</c> call.</item>
/// </list>
/// The result is emitted as <c>owner</c>-privileged DDL (callers wrap in
/// <see cref="OwnerDdl.Wrap"/>). See docs/keycloak.md §4.
/// </summary>
public static class RlsBaseline
{
    /// <summary>The installed session-context helper that returns the request user id.</summary>
    public const string HelperFunctionName = "app_current_user_id";

    /// <summary>
    /// The <c>CREATE OR REPLACE FUNCTION</c> for the session-context helper.
    /// <c>STABLE</c> (its result is fixed within a statement) and
    /// <c>SECURITY INVOKER</c> (runs with the caller's privileges — it reads only
    /// a session setting, grants no escalation). Returns the <c>app.user_id</c>
    /// session setting, or NULL when unset (deny-by-default for RLS).
    /// </summary>
    public static string HelperFunctionSql() =>
        $"CREATE OR REPLACE FUNCTION public.{HelperFunctionName}()\n" +
        $"  RETURNS text LANGUAGE sql STABLE AS\n" +
        $"  $$ SELECT current_setting('{SessionContextSql.UserIdKey}', true) $$;";

    /// <summary>
    /// The owner-privileged baseline DDL (idempotent). Not yet role-wrapped; the
    /// migration passes this through <see cref="OwnerDdl.Wrap"/>.
    /// </summary>
    public static string OwnerSql()
    {
        var api = OwnerDdl.ApiRole;
        var owner = OwnerDdl.OwnerRole;
        return
            $"GRANT USAGE ON SCHEMA public TO {api};\n" +
            $"ALTER DEFAULT PRIVILEGES FOR ROLE {owner} IN SCHEMA public\n" +
            $"  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO {api};\n" +
            $"ALTER DEFAULT PRIVILEGES FOR ROLE {owner} IN SCHEMA public\n" +
            $"  GRANT USAGE, SELECT ON SEQUENCES TO {api};\n" +
            $"{HelperFunctionSql()}\n" +
            $"GRANT EXECUTE ON FUNCTION public.{HelperFunctionName}() TO {api};";
    }

    /// <summary>The full role-wrapped baseline DDL the initial migration runs in <c>Up</c>.</summary>
    public static string Up() => OwnerDdl.Wrap(OwnerSql());

    /// <summary>
    /// The owner-privileged reversal: drop the default-privilege grants again.
    /// Mirrors <see cref="OwnerSql"/> so the initial migration is reversible.
    /// </summary>
    public static string DownOwnerSql()
    {
        var api = OwnerDdl.ApiRole;
        var owner = OwnerDdl.OwnerRole;
        return
            $"DROP FUNCTION IF EXISTS public.{HelperFunctionName}();\n" +
            $"ALTER DEFAULT PRIVILEGES FOR ROLE {owner} IN SCHEMA public\n" +
            $"  REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM {api};\n" +
            $"ALTER DEFAULT PRIVILEGES FOR ROLE {owner} IN SCHEMA public\n" +
            $"  REVOKE USAGE, SELECT ON SEQUENCES FROM {api};\n" +
            $"REVOKE USAGE ON SCHEMA public FROM {api};";
    }

    /// <summary>The full role-wrapped reversal the initial migration runs in <c>Down</c>.</summary>
    public static string Down() => OwnerDdl.Wrap(DownOwnerSql());
}

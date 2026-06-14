---
satisfies: [R28, R29]
---

## Description
Wire **EF Core code-first migrations** (DataAccess) and the **Keycloak-gated, session-context RLS** baseline. `system.sh migrate` applies them; per-request session context from the Keycloak JWT drives RLS.

**Size:** M
**Files:** `templates/src/DataAccess/Migrations/` (initial migration w/ RLS baseline), **transaction/unit-of-work middleware** + JWT/auth wiring in `templates/src/Api/` (NOT a ConnectionOpened interceptor), `tests/` coverage for the new behavior, `system.sh migrate` body (fn-2….6)

## Approach (from docs-scout + practice-scout)
- **EF migrations (R29):** code-first in DataAccess; `system.sh migrate` runs **`dotnet tool restore` then `dotnet ef database update`** (`--project src/DataAccess --startup-project src/Api`; `dotnet-ef` pinned in `.config/dotnet-tools.json`, fn-2….9) against the Npgsql connection string from the generated config. **Role names (`owner`/`migrator`/`api`) + db name (`platform`) are FIXED scaffold constants** — the static migration SQL references them literally (no config injection); config supplies only host/port/password. Migration history in `__EFMigrationsHistory`. Ship a **migration helper / documented convention in DataAccess** (e.g. a `MigrationBuilder` extension or base wrapper) so **every future schema/RLS migration wraps owner-privileged DDL in `SET ROLE owner` … `RESET ROLE`** — a durable, testable convention, not a one-off in the initial migration.
- **RLS baseline via raw SQL in the initial migration (R28)** — roles **already exist** (postgres init, fn-2….10). The initial migration (run as `migrator`/owner-member, idempotent via `DROP ... IF EXISTS`) sets `ALTER DEFAULT PRIVILEGES FOR ROLE owner ... GRANT ... TO api`, installs a **session-context helper**, and ships a **documented per-table RLS policy template** (`ENABLE`+`FORCE ROW LEVEL SECURITY`, `USING`+`WITH CHECK`, keyed off `current_setting('app.user_id', true)`). **It does NOT enable RLS on any table** (RLS is table-specific; no tables yet) — per-table `ENABLE/FORCE` + policies are applied in **future entity migrations** (an optional sample table may demonstrate the pattern).
- **Keycloak-gated DB auth (R28):** `Api` validates the Keycloak JWT (OIDC bearer); **each authenticated request runs inside a transaction / unit-of-work** (middleware) — REQUIRED so `SET LOCAL` holds (it persists only within a transaction; plain `SET` leaks across pooled clients). Runtime connects as the least-privilege **api** role; a **unit-of-work opens the transaction FIRST, then issues `SET LOCAL app.user_id/app.roles`** (an EF transaction step / UoW middleware — NOT a `ConnectionOpened` interceptor, which fires before `BEGIN`), then runs request work in that transaction. RLS policies key off `current_setting('app.user_id', true)`.
- Pitfalls to encode (practice-scout): never run the app as owner/superuser/BYPASSRLS; **EF connects as the LOGIN `migrator`** (a member of the NOLOGIN `owner`), issuing `SET ROLE owner` for owner-privileged DDL; **runtime connects only as `api`**; deny-by-default (RLS-on, no policy = no rows); index policy-filter columns.

## Investigation targets
**Required:**
- `templates/src/DataAccess/` (fn-2….9) — DbContext to attach migrations to
- `templates/src/postgres/` (fn-2….10) — the DB the roles/RLS target
- `.flow/specs/fn-2-...md` — R28/R29 + `docs/keycloak.md` (fn-2….8)

## Acceptance
- [ ] DataAccess ships an initial EF migration + an `IDesignTimeDbContextFactory` (reads the exported migrator conn-string; uses the `migrator` role, NOT `api`/Api startup); `system.sh migrate` (tool restore → `dotnet ef database update`) succeeds against the `platform` DB
- [ ] Roles pre-created by postgres init (fn-2….10); initial migration (as `migrator`) sets ALTER DEFAULT PRIVILEGES + session-context helper + a documented per-table RLS policy template; baseline does NOT enable RLS on any table (per-table ENABLE/FORCE in future entity migrations)
- [ ] Authenticated requests run inside a per-request UoW that **opens the transaction first, then `SET LOCAL`** (not a ConnectionOpened interceptor); Api connects as least-privilege `api` role
- [ ] EF connects as `migrator` (member of `owner`), `SET ROLE owner` for owner DDL; runtime connects only as `api` (never owner/superuser/BYPASSRLS)
- [ ] **Coverage-preserving tests added** (so fn-2….13's 100% gate stays green): UoW opens-txn-then-`SET LOCAL` ordering, JWT claim extraction, migrator-vs-runtime role separation

## Done summary
Authored the build-time-complete EF Core code-first migration (InitialRlsBaseline) with the owner-wrapped, session-context RLS baseline in DataAccess, plus the per-request Keycloak-gated unit of work (transaction-first then set_config app.user_id) and JWT-bearer auth + middleware in Api — tying the .NET solution to the postgres roles. RLS isolation was proven live against the .10 postgres container.
## Evidence
- Commits: 7589782, bc16892, eb58195, 4836e91, 960b794
- Tests: dotnet build src/system.sln (succeeds, roll-forward), dotnet test src/system.sln -p:CollectCoverage=true -p:Threshold=100 (Framework 3, BusinessLogic 3, DataAccess 51, Api 29 — all 100% line+branch), dotnet ef migrations list/script via design-time factory (InitialRlsBaseline real), LIVE: dotnet ef database update as migrator vs .10 postgres container; RLS isolation proven (per-user rows isolated, WITH CHECK forge rejected, deny-by-default with no app.user_id, set_config no-leak across txns, installed helper app_current_user_id() drives policy), scaffold_test.sh 235 ok / 0 fail, dispatcher_test.sh 61 passed
- PRs:
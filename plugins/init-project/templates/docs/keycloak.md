# Keycloak identity standard

This is the authoritative standard for **identity in this repo**: how Keycloak is
run, how its realm is defined and imported, and how database access is gated
through Keycloak using per-request session context and row-level security (RLS).
Read it whenever you touch authentication, the realm, client configuration, or
the database session-context / RLS path.

Keycloak is a system component: it has a `src/keycloak/` folder and a matching
`config.json` `systems[]` entry. Its non-secret fields (realm name, public base
URL, public client ids) and generated secrets (admin credentials, the `Api`
confidential-client secret) are defined in `config.json` — see
[config-management.md](config-management.md) for the schema and how they flow to
downstream artifacts.

## 1. Self-hosted, compose-managed

Keycloak runs as a self-hosted container defined by `src/keycloak/`'s own
`docker-compose.yml`, brought up via the dispatcher:

```bash
./system.sh up      # starts postgres, keycloak, and the observability stack
./system.sh down
```

It is not a hosted/external dependency — the realm and clients are version-
controlled in this repo, so a fresh clone stands up the same identity setup.

## 2. Realm: committed template → generated import file

The realm is defined **once**, in a committed template, and imported
deterministically. There are two distinct files — do not confuse them:

| File | Tracked? | Role |
|---|---|---|
| `src/keycloak/realm.template.json` | committed | the source of truth: realm, clients, roles, with **dev-only dummy secrets** pinned. NOT mounted into Keycloak. |
| `src/keycloak/import/<realm>-realm.json` | gitignored | the generated runtime import file — the ONLY file Keycloak's `--import-realm` loads. |

`./system.sh build-config` stamps the import file from the template via
**deterministic JSON-field replacement** (not Keycloak env-substitution, which is
unreliable): it injects the real realm name, client ids, and the generated
`Api` client secret from `config.json` into a fresh
`src/keycloak/import/<realm>-realm.json`. Because it owns that directory, it
**removes any prior generated `*-realm.json` before writing the current one**, so
a realm rename never leaves a stale import file behind.

Keycloak starts with `--import-realm`, loading only the generated file. Real
secrets never reach the committed template — they enter at deploy via
`config.deploy.json`'s `{{VAR-NAME}}` placeholders. See
[config-management.md](config-management.md).

## 3. Clients in the starter realm

| Client | Type | Purpose |
|---|---|---|
| `WebApp` | public SPA | the authenticated application front-end |
| `MarketingSite` | public SPA | the marketing front-end |
| `Api` | confidential | the backend HTTP API; `serviceAccountsEnabled: true` |

The two SPAs are **public** clients (no secret — secrets can't be hidden in a
static bundle). Each receives only **non-secret** runtime config (realm URL +
public client id) via its gitignored `src/<SPA>/public/config.json`, fetched at
runtime — **no secrets ship in `dist/`** (see [front-end.md](front-end.md)).

The `Api` is a **confidential** client with a generated secret and a
**service account** (client-credentials, for machine-to-machine calls). It is the
only backend *service* in the starter — `BusinessLogic`, `DataAccess`, and
`Framework` are libraries, not services, so they get no clients of their own.

## 4. Database access is gated through Keycloak with session-context RLS

The database is never reached with an ambient super-user. Access is gated through
Keycloak identity and enforced in Postgres with row-level security keyed off
per-request session context.

**Roles (FIXED scaffold constants — `owner` / `migrator` / `api`).** These role
names and the database name (`platform`) are fixed, not configurable, so static
EF migration SQL can reference them literally:

- `owner` — NOLOGIN, owns the schema; DDL runs as `owner`.
- `migrator` — LOGIN, a member of `owner`; **EF connects as `migrator`** (EF can't
  connect as a NOLOGIN role) and issues `SET ROLE owner` for owner-privileged DDL.
- `api` — LOGIN, least-privilege; the **runtime `Api` connects as `api`**.

The `owner`/`migrator`/`api` roles are bootstrapped by the `postgres` container
init script **before any EF migration** (a migration can't create the role it
connects as). See [config-management.md](config-management.md) for how the
generated role passwords flow in.

**Per-request flow (the `Api`):**

1. Validate the incoming Keycloak JWT.
2. Connect to Postgres as the least-privilege `api` login role.
3. Open a **unit-of-work transaction first**, then issue
   `SET LOCAL app.user_id = …` / `SET LOCAL app.roles = …` from the validated
   claims. `SET LOCAL` only holds inside a transaction and is pooling-safe — so
   the transaction must open *before* the `SET LOCAL`. This is a UoW / EF
   transaction step, **NOT** a `ConnectionOpened` interceptor (which fires before
   any `BEGIN`).
4. Run the request work inside that transaction; RLS policies read
   `current_setting('app.user_id', true)` to scope every row.

**RLS baseline (EF migrations, in `DataAccess`).** An initial migration sets
`ALTER DEFAULT PRIVILEGES`, installs a session-context helper, and ships a
documented per-table RLS policy template (`ENABLE` + `FORCE ROW LEVEL SECURITY`,
`USING` + `WITH CHECK`, keyed off `current_setting('app.user_id', true)`). Because
RLS is table-specific, per-table `ENABLE`/`FORCE` + policies are applied in the
**entity migrations that create those tables** — they can't be enabled before the
tables exist. Run migrations with:

```bash
./system.sh migrate     # dotnet tool restore && dotnet ef database update (as migrator)
```

See [architecture.md](architecture.md) for where this logic sits in the layered
solution, and [tdd.md](tdd.md) for how it's tested.

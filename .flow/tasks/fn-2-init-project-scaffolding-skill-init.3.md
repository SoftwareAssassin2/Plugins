---
satisfies: [R8, R13, R25]
---

## Description
Author the config system: `templates/docs/config-management.md` (generalized standard) + `templates/config.json` (local dev, prepopulated) + `templates/config.deploy.json` (deployment template). Encodes the `systems[]`/`services{}` model, generated secrets, and the URL-safe alphabet.

**Size:** M
**Files:** `src/init-project/templates/docs/config-management.md`, `src/init-project/templates/config.json`, `src/init-project/templates/config.deploy.json`

## Approach
- **config-management.md** (from source §1/§5/§6, generalized — **drop §2 and §4** per P3/P5; **generalize §3 into the `postgres` component** per P4): document `config.json` single-source-of-truth → `system.sh build-config` → per-component `.env` (12-factor); the `systems[]` (1:1 with `src/<component>/`) + `services{}` model with a generic worked example; **keep a generalized `postgres` config example — the `owner`/`migrator`/`api` role split + db/host/port (generalized from source §3 per P4); the role identifiers are **exactly `owner`/`migrator`/`api`** + db name **`platform`** — FIXED scaffold constants (only host/port/passwords configurable), pinned in the schema with their concrete **env-var names** (passwords + connection strings) so .6/.10/.11 use identical identifiers; static EF migration SQL references them literally** + a `claude-api` `services{}` example; **ban only `platform-db`/Flyway/play.sh/games/PGS framing, not the role/config concept**; the **URL-safe password alphabet `[A-Za-z0-9_-]+`** + `openssl rand -base64 32 | tr -d '=' | tr '/+' '_-'` generation recipe (source §5); `config.deploy.json` + CI/CD `{{VAR-NAME}}` flow.
- **config.json** (local dev, R13): prepopulated `systems[]` for every starter component — `postgres` (host, port, docker, password fields as `__SCAFFOLD_GEN_URLSAFE__` sentinels — scaffold.sh generates per project; the db name `platform` + role names `owner`/`migrator`/`api` are FIXED constants, NOT in config.json), `keycloak` (realm name, host, port, docker, admin-cred field as `__SCAFFOLD_GEN_URLSAFE__`), and the .NET/Angular components (minimal/empty config); `services{}` with `claude-api` → `REPLACE_ME`.
- **config.deploy.json** (R25): mirrors the `systems[]`/`services{}` shape with every secret as a `{{VAR-NAME}}` placeholder for CI/CD substitution. Keep the two files' key-sets identical (a CI diff-check guards drift — see fn-2….13).

## Investigation targets
**Required:** (raw `config-management.md` source moves `src/project-init/`→`src/init-project/` via fn-2….1; path below is post-rename)
- `src/init-project/config-management.md:1-16,84-115` — portable kernel (§1, §5 password alphabet, §6 12-factor)
- `src/init-project/config-management.md:40-61` — owner/migrator/api role pattern to generalize into the `postgres` systems entry

## Config schema (authoritative — dependents reference this)
Define, in `config-management.md`, a table that downstream tasks (.6/.10/.11/.12) MUST follow so field/env-var names don't drift: per `systems[]` entry — `name` (== `src/<component>/`), its config keys, the generated `.env` path + **env-var names**, which fields are secret/URL-safe vs structural (SQL-identifier/port/host), and which consumer reads each value (postgres compose, keycloak realm stamp, EF migrator + runtime conn-strings, Api auth, each SPA's public `config.json`). It also pins **exact validators** for configurable structural fields: realm/client-id regex (e.g. `^[A-Za-z0-9._-]+$`), host/container-name regex, port range `1..65535` — `build-config` (fn-2….6) enforces these. The schema **explicitly enumerates the Keycloak fields**: realm name + URL, **public SPA client IDs** (WebApp, MarketingSite — non-secret, reach the browser), the **Api confidential client ID + (generated) secret**, — and the Api client has `serviceAccountsEnabled: true` (its own service account; **NO separate per-service service-account client objects**) — marking which are generated URL-safe secrets vs structural public values.

## Acceptance
- [ ] config-management.md documents systems[]/services{} + build-config + URL-safe alphabet + config.deploy.json, **incl. a generalized `postgres` owner/migrator/api role/config example (P4)**; no `platform-db`/Flyway/OAuth-PGS/play.sh/games H&G framing
- [ ] config.json prepopulated with a `systems[]` entry for EVERY starter component — `Framework`, `DataAccess`, `BusinessLogic`, `Api`, `MarketingSite`, `WebApp`, `postgres`, `keycloak`, **and `SampleApp`** — incl. `postgres` (host/port/docker + per-occurrence `__SCAFFOLD_GEN_URLSAFE__` password sentinels; NO db/role names — fixed constants), `keycloak` (realm/host/port + `__SCAFFOLD_GEN_URLSAFE__` admin cred + Api client secret sentinel), `services{}` claude-api `REPLACE_ME`
- [ ] config-management.md's schema table enumerates the **exact Keycloak fields** (realm + public URL, WebApp/MarketingSite public client IDs, Api confidential client ID/secret with `serviceAccountsEnabled:true` — no separate SA client objects, admin creds, env-var names, per-SPA public config fields) + Postgres host/port/passwords (role/db names are constants)
- [ ] config-management.md includes the authoritative **config schema table** (field/env-var names, .env paths, secret/url-safe vs structural, consumers) that .6/.10/.11/.12 reference; documents Postgres role/db names as FIXED constants and the `build-config --config <path>` (default config.json) deploy handoff
- [ ] config.deploy.json mirrors the shape with `{{VAR-NAME}}` placeholders for every secret; identical key-set to config.json
- [ ] generated secrets match `[A-Za-z0-9_-]+`

## Done summary
Authored the config-management standard: templates/docs/config-management.md (generalized systems[]/services{} model, generalized postgres owner/migrator/api role example, URL-safe secret alphabet + openssl recipe, an authoritative config schema table pinning exact field/env-var names, validators, .env paths and consumers for postgres/keycloak/SPA/Api/services, and the build-config --config deploy handoff). Built templates/config.json to build-time-complete form (systems[] entry for every starter component incl. keycloak public SPA client ids + Api confidential client secret sentinel) and added templates/config.deploy.json mirroring the shape with {{VAR-NAME}} placeholders (identical key-set). Extended scaffold_test.sh with 13 new assertions (44 pass).
## Evidence
- Commits: 01ef86323ebd06cfd1ff4b61c11eaa8a95b7c87f, acd9f4d2d19a13c4d99adf24c3eea4befe9f84c9, b964d12cac37df3ca72b4f6a037ab201c9dc430b, 31ae6e797b5b112c5decdb919cbad8e3f7e683be, 55772d271591910a20da513cc6e9ec35e1cb7f36
- Tests: bash src/init-project/tests/scaffold_test.sh (44 passed, 0 failed)
- PRs:
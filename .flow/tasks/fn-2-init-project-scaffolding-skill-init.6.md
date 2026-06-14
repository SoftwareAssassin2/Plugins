---
satisfies: [R6, R24]
---

## Description
Author the **`system.sh` dispatcher** + `src/system-cli/` subcommands, including `build-config`, and the **100% line+branch coverage** test harness (kcov) for the dispatcher AND the `scaffold.sh` engine (fn-2….1).

**Size:** M
**Files:** `plugins/init-project/templates/system.sh`, `plugins/init-project/templates/src/system-cli/{help,build-config,up,down,migrate,status}.sh`, `plugins/init-project/templates/tests/system-cli/` (generated-project shell test harness), `plugins/init-project/tests/` (skill-package kcov tests for scaffold.sh)

## Approach (carry forward source conventions)
- **Dispatcher path (note from fn-2….1 review):** the generated `system.sh` lives at the **repo root**, so `script_dir`=repo root and `$script_dir/src/system-cli/<sub>.sh` resolves correctly. (The raw source copy at `plugins/init-project/system-cli/system.sh` mis-resolves from its own location — author the template for the root location; don't copy the source's `$script_dir` assumption blindly.)
- Dispatcher `system.sh` → `src/system-cli/<subcommand>.sh` (`system.sh:30-38` pattern): `set -euo pipefail`; usage error exit **64**; `_`-prefixed subcommands non-dispatchable (exit 64, pinned `ERROR: '<sub>' ...`); unknown subcommand exit **127**; `exec target "$@"`.
- `help.sh`: `shopt -s nullglob`; scrape each file's top `# Description:` comment via `sed -nE 's/^#[[:space:]]*Description:[[:space:]]*(.*)$/\1/p' | head -n1`; column-align (source `help.sh:39`).
- `build-config.sh`: `build-config [--config <path>]` (default `config.json`; the deploy pipeline passes the rendered `config.deploy.json`) → write per-component `.env`; **validate every schema-declared URL-safe field** (postgres/keycloak credential fields, from ANY concrete `--config` input — local or rendered deploy) against `[A-Za-z0-9_-]+` (exit 64 on out-of-alphabet); **external service credentials are exempt** (opaque); raw `{{VAR-NAME}}` deploy placeholders never validated in build/test CI (source §5); **also stamp `src/keycloak/import/<realm>-realm.json`** (gitignored — the only file `--import-realm` loads) from the committed template `src/keycloak/realm.template.json` via deterministic JSON-field replacement (client `secret` + realm/client ids from config) (fn-2….10). Postgres role/db names are FIXED constants (not validated/injected). Use the **exact role identifiers `owner`/`migrator`/`api`, db `platform`, and env-var names pinned in the .3 schema** consistently across init SQL/EF/conn-strings. Validate configurable structural fields (filename-safe realm name, integer ports, host shapes) and use `jq --arg` structured edits (no string replacement).
- `build-config` also stamps each Angular SPA's gitignored public `config.json` (`src/<SPA>/public/config.json`, non-secret values only) per the .3 schema.
- `up`/`down`: orchestrate the per-component compose stacks (postgres, keycloak, observability). `migrate`: `system-cli/migrate.sh` sources the generated config + **exports the migrator connection string** (.NET doesn't read `.env`), `dotnet tool restore`, then `dotnet ef database update` via the DataAccess design-time factory using the **`migrator`** role (fn-2….9/.11). `status`: health of the stack.
- Each subcommand file carries a `# Description:` line. **Tests, two surfaces:** (a) **skill-package** kcov tests for the skill's own `scaffold.sh` (100% line + an explicit test per branch — this is internal to the init-project package, NOT shipped to generated projects); (b) a **shell test-harness template** shipped into generated projects covering their `system.sh` + `src/system-cli/*.sh` (consumed by the generated project's CI, fn-2….13). kcov bash branch metrics aren't portable, so branch completeness is enforced by an explicit test per branch. Cover usage/unknown/underscore-rejection, refuse-non-empty/`--force`/`--dry-run` (scaffold.sh), build-config alphabet-reject, realm-stamp.

## Investigation targets
**Required:** (dispatcher source moves `plugins/project-init/system-cli/`→`plugins/init-project/system-cli/` via fn-2….1; paths below post-rename)
- `plugins/init-project/system-cli/system.sh:1-38`, `help.sh:1-43` — dispatcher + Description-scraping source
- `plugins/init-project/templates/docs/tdd.md` (fn-2….8) — coverage standard + kcov tooling
- `plugins/init-project/scaffold.sh` (fn-2….1) — the other script under test

## Acceptance
- [ ] `system.sh <sub>` routes to `src/system-cli/<sub>.sh`; exit 64 (usage/underscore), 127 (unknown); pinned error format; `_`-helpers hidden
- [ ] `help` lists subcommands + `# Description:`-scraped one-liners
- [ ] `build-config` distributes config.json → per-component `.env` (per the .3 schema) + stamps each SPA's public `config.json`; validates **every schema-declared URL-safe field** from ANY concrete `--config` input (local `config.json` OR rendered deploy config; external service creds exempt; raw `{{VAR-NAME}}` deploy placeholders never validated in build/test CI) AND configurable structural fields per the .3 schema's exact validators (realm/client-id regex, host/container regex, port `1..65535` — NOT role/db names, fixed constants); uses `jq --arg` structured edits; exit 64 on violation; **tests cover each reject path**
- [ ] `build-config` accepts `--config <path>` (default config.json) for the deploy handoff
- [ ] `up`/`down`/`migrate`/`status` subcommands present with `# Description:` lines
- [ ] Skill-package kcov tests hit 100% line + a test per branch for `scaffold.sh` (init-project-internal, not shipped); a **shell test-harness template** for the generated project's `system.sh` + `src/system-cli/*.sh` ships for fn-2….13 CI — both with an explicit test per branch (no kcov bash branch metric)
- [ ] `build-config` cleans the realm import dir (removes prior generated `*-realm.json`) before stamping the current one (no stale-on-rename)
- [ ] `build-config` provides the generic stamping **mechanism** (config→`.env`, realm-file stamp, SPA public-config stamp); the **Keycloak realm-stamp** integration+test is owned by fn-2….10 and the **SPA public-config stamp** by fn-2….12 (this task ships the capability, those tasks wire+verify their specific stamps)

## Done summary
Authored the build-time-complete `system.sh` dispatcher template (lands at the scaffolded repo root so `$script_dir/src/system-cli/<sub>.sh` resolves), its `help/build-config/up/down/migrate/status` subcommands, a kcov line-coverage wrapper that degrades cleanly when kcov is absent, the skill-package dispatcher test suite, and the generated-project shell test-harness shipped for fn-2....13 CI. `build-config` distributes `config.json` into per-component `.env` (with the migrator/api connection strings + keycloak values per the docs/config-management.md §4 schema), stamps each SPA's non-secret public config, and stamps the gitignored Keycloak realm import (clean-prior-on-rename), validating every URL-safe secret + structural field with exit 64 on violation.
## Evidence
- Commits: cfb31bfe4a6d726a5d9b2e8daaac2a815faa2f60
- Tests: bash plugins/init-project/tests/scaffold_test.sh (132 passed), bash plugins/init-project/tests/dispatcher_test.sh (60 passed), bash plugins/init-project/tests/coverage.sh (kcov-absent degrade, exit 0; both suites run), bash <scaffolded>/tests/system-cli/system_cli_test.sh (30 passed, from clean git export), shellcheck -S error all new/changed scripts (clean), scaffold from `git checkout-index` clean export: dispatch help->0, no-arg->64, underscore->64, unknown->127; build-config distributes .env+SPA config, realm-stamp skips gracefully
- PRs:
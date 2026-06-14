# init-project scaffolding skill (/init-project)

## Overview

`/init-project` is a **Claude Code skill** (lives at `src/init-project/`, registered in `.claude-plugin/marketplace.json`) that stands up a brand-new software project with the user's preferred defaults. It asks only for a **project name** + **short description** (plus a few git/GitHub prompts), then lays down a fixed, opinionated **starter solution** (root layout, root `CLAUDE.md` + `README.md`, dev container, standards docs, a `system.sh` dispatcher CLI, a starter .NET solution, two Angular SPAs, a `postgres` service, and a `keycloak` IdP). It finishes with an optional `/dick` (fn-1) hand-off and a **git/GitHub phase** (repo creation, status line, initial commit).

The scaffolded project is a **mono-repo containing every component of the software system**, governed by a 1:1 correspondence: **every component is a subfolder `src/<component>/` AND has a matching entry in `config.json`'s top-level `systems[]` array**. External dependencies the system connects to are entries under a peer `services{}` object.

Deterministic file-stamping (skeleton + `{{PLACEHOLDER}}` substitution) is a **bundled, tested shell script** invoked by the skill; per-project adaptation stays in skill prose. The existing `src/project-init/*.md` files are raw material — generalized per the **H&G Removal Decisions** section below.

## Starter solution (what gets scaffolded)

Every new project ships these components — each its own `src/<component>/` folder + a `config.json` `systems[]` entry:

**Permanent defaults (always laid down):**
- `Framework` — .NET class library
- `DataAccess` — .NET class library (owns the EF Core `DbContext` + code-first migrations)
- `BusinessLogic` — .NET class library
- `Api` — .NET HTTP API
- `MarketingSite` — Angular SPA (prerendered, client-side only, S3-static, no server runtime)
- `WebApp` — Angular SPA (same build profile)
- `postgres` — Postgres database in a docker container (the database is named `platform`); compose service, OUTSIDE `.devcontainer/` per the dev-container philosophy
- `keycloak` — Keycloak identity provider, self-hosted in a docker container (compose service, OUTSIDE `.devcontainer/`)

The .NET projects compose into a single solution **`src/system.sln`** (layered `Api → BusinessLogic → DataAccess → Framework`). Repo tooling (the `system.sh` dispatcher subcommands) lives under `src/system-cli/`.

**Removable starter sample (clearly marked):**
- `SampleApp` — .NET console app demonstrating the conventions (documented as prunable)

## Quick commands
```bash
jq -e '.plugins[] | select(.name=="init-project")' .claude-plugin/marketplace.json
tmp=$(mktemp -d); ( cd "$tmp" && /path/to/scaffold.sh demo-app "A demo" ) && ls "$tmp/demo-app/src" && ! grep -rq '{{' "$tmp/demo-app"
# config.json prepopulated with the starter components + services
jq -e '.systems and .services and ([.systems[].name] | index("postgres"))' "$tmp/demo-app/config.json"
# dispatcher distributes config → per-component .env
( cd "$tmp/demo-app" && ./system.sh build-config && ./system.sh help )
```

## Boundaries / non-goals
- NOT opinionated *configuration* of the project's behavior — that is `/dick` (fn-1), the optional last step. (It IS opinionated about default *architecture* — the starter solution above.)
- Grafana + OTel Collector, the `postgres` service, and `keycloak` are **services** → per-component compose stacks OUTSIDE `.devcontainer/`, orchestrated by `system.sh up`.
- Does not publish/share anything externally; purely local file creation.

## Decision context
- **Skill-first, script-behind:** front door is a skill; deterministic stamping delegated to a bundled, tested script (satisfies the 100%-coverage tdd standard, no run-to-run drift).
- **Build-time-complete templates (the core authoring principle):** every template file — `_CLAUDE.md`, `README.md`, `docs/*.md`, `.gitignore`, `.devcontainer/*`, the `system.sh` dispatcher + `src/system-cli/*` subcommands, `config.json`, `config.deploy.json`, compose/realm files — is authored to its **final, complete form during fn-2's `/flow-next:work`**, including the **full verbatim text** of every `_CLAUDE.md` directive specified in this spec. At `/init-project` **runtime the scaffold engine only COPIES these templates and applies minimal `{{PLACEHOLDER}}` substitution** (project name/description) — it does **NOT** author, generate, or LLM-fill content. A freshly scaffolded project is fully-formed from copy-ready templates.
- **Config model:** `config.json` is the single source of truth for local dev — `systems[]` (one entry per `src/<component>/`) + peer `services{}` (one entry per external service, e.g. `claude-api`). `system.sh build-config` distributes per-component `.env`; runtime reads env only (12-factor). A parallel **`config.deploy.json`** is the deployment template — every secret is a `{{VAR-NAME}}` placeholder the CI/CD pipeline substitutes before `build-config` runs.
- **Secret handling:** scaffold-time, `config.json` carries **generated URL-safe passwords** for the self-hosted local-dev components (`postgres`, `keycloak`), and **`REPLACE_ME`** for external-service credentials the operator must supply (e.g. `claude-api`). Generated/accepted secrets must match the **URL-safe alphabet `[A-Za-z0-9_-]+`** (safe in `.env`, URLs, SQL with no escaping); `build-config` validates and errors on out-of-alphabet chars.
- **Dispatcher CLI:** a root **`system.sh`** routes `system.sh <subcommand>` → `src/system-cli/<subcommand>.sh`. Subcommands: **`build-config`** (config.json → per-component `.env`), **`help`** (lists subcommands + descriptions, each scraped from a `# Description:` comment at the top of its file), **`up`**/**`down`** (bring the per-component compose service stack up/down), **`migrate`** (EF Core migrations), **`status`**. `_`-prefixed files are private helpers (non-dispatchable). (Supersedes the earlier `<project>.sh` / `<name>-cli` idea — the dispatcher is fixed `system.sh` + `src/system-cli/`, not project-named.)
- **Component ↔ folder ↔ config invariant:** each project (incl. .NET class libraries) is its OWN `src/<component>/` + `systems[]` entry; libraries carry minimal/empty config.
- **`main.md` → `_CLAUDE.md`:** the root-CLAUDE template is renamed `_CLAUDE.md` (underscore = template, scaffolds to the project's `CLAUDE.md`).
- **Front-end standard:** Angular SPAs are prerendered (SSG), client-side only, deployed static to an S3 bucket, **no server-side runtime**; **path-based routing** with the S3 error-document→`index.html` fallback (+ CloudFront note) documented in `front-end.md`. Styling **SCSS**; lint/format **angular-eslint + Prettier**; package manager **npm**; unit tests **Jest** (100% coverage applies). Captured in `docs/front-end.md`, linked from `_CLAUDE.md`'s Standards index.
- **Identity provider + DB auth:** Keycloak is the system's IdP, self-hosted (compose). A committed **realm-import JSON** (`--import-realm`) makes local-dev auth reproducible — it pre-defines the realm, SPA public clients (`WebApp`, `MarketingSite`), the `Api` confidential client, a **service-account client per backend service**, and baseline roles; `build-config` injects realm/client ids/secrets from config. **DB access is gated through Keycloak**: the `Api` validates the Keycloak JWT, connects to Postgres as a least-privilege `api` role, and sets per-request **session context** (`app.user_id`/`app.roles` from token claims); **row-level security** policies key off `current_setting('app.*')`. Standards in `docs/keycloak.md`.
- **Database / migrations:** EF Core **code-first** migrations live in the **DataAccess** project; `system.sh migrate` runs **`dotnet ef database update`** (Npgsql) against the connection string built from config. The RLS baseline that can be scaffolded without the schema — `owner`/`migrator`/`api` roles, RLS-on-by-default convention, a session-context helper, and a documented policy template — is authored as **raw SQL inside EF Core migrations**; concrete per-table policies land with the schema.
- **Devcontainer:** base image **`mcr.microsoft.com/devcontainers/dotnet`** + Node feature (for Angular CLI). Toolset: .NET SDK, **Node + Angular CLI (npm)**, GCP CLI, AWS CLI, Azure CLI, GitHub CLI, **Atlassian CLI `acli`** (Jira + Confluence), DuckDB CLI, Claude Code (`install.sh`), **Codex CLI**; registers THIS marketplace + enables **nine plugins**: `dick`, `grill-me`, `handoff`, `tdd`, `ubiquitous-language`, Playwright (`preferred-browser-automation-plugin`), `context7`, flow-next (`preferred-ralph-loops-plugin`), and the **GitHub MCP server** (`github-mcp-server` — distinct from the `gh` CLI).
- **CI:** the scaffold ships `.github/workflows/` (GitHub Actions) running .NET + Angular build/test with the **100% line+branch coverage gate** (+ kcov for shell), matching the tdd standard and the git/GitHub repo-creation phase.
- **Git/GitHub final phase:** after scaffolding the skill (a) prompts — create a GitHub repo? (name?) / auto-commit after setup? / run `/init` after setup?, (b) `git init`s the project, (c) optionally creates the GitHub repo via `gh`, (d) sets up a **status line** (branch + model + % context used), (e) optionally runs `/init`, (f) optionally makes the initial commit **last** so it captures the `/dick` + `/init` output.
- **Docs set (all H&G-free):** the scaffold lays down `docs/` with (a) **empty TODO-stub homes for Dick's business docs** — `business.md`, `strategy.md`, `customers.md`, `priorities.md`, `decisions.md` (owned/filled by `/dick`, fn-1; **no `roadmap.md`** — `priorities.md` replaces it), and (b) the technical standards docs `ubiquitous-language.md`, `architecture.md`, `config-management.md`, `tdd.md`, `dev-container.md`, `front-end.md`, `keycloak.md`. `etc/` ships a `.gitkeep`; `src/` is populated by the starter solution. (Dick's `docs/strategy.md`/`docs/decisions.md` are distinct from flow-next's repo-root `STRATEGY.md` / `.flow` decisions.)
- **CLAUDE.md philosophy (hybrid):** inline directives in `_CLAUDE.md` (concision — "sacrifice grammar for concision"; simplicity-over-complexity — Ousterhout/software-entropy; plus the R9 brevity/honesty/verify); deep material in linked docs — **DDD** (Evans) → `ubiquitous-language.md`, **TDD/feedback-loops/deep-modules** (Hunt & Thomas, Ousterhout, "design the interface, delegate the implementation") → `tdd.md`, **design philosophy** → `architecture.md` — surfaced via the Standards index.
- **Auto-update hook:** the scaffolded `.claude/` ships a **non-blocking Stop hook** that surfaces a "refresh `CLAUDE.md`/sub-docs?" reminder **only when** the session surfaced updates worth persisting — **no silent edits**.
- **Doc strategies:** `CLAUDE.md` = thin always-on index (root layout + Standards index + inline directives, depth in `docs/` on demand, hook-maintained); `README.md` = human-facing onboarding (overview, dev-container quickstart, how to run `system.sh` + bring up `postgres`/`keycloak`/observability), distinct from agent-facing CLAUDE.md; **sub-agent convention** = delegate read-heavy exploration/research + parallelizable work to subagents, documented in CLAUDE.md.
- **Business-consult sub-agent (inline `_CLAUDE.md` directive, R20):** before non-trivial work, Claude consults the business direction via a sub-agent that reads Dick's business docs (in the SOUL.md voice) and reports back — consult-only (interactive `/dick` stays main-thread), with a "flag the gap + suggest `/dick`, never fabricate" fallback.
- **Git-commit policy (inline `_CLAUDE.md` directive, R21):** no commits to `main` without explicit user instruction (ask first if a changeset seems commit-worthy on `main`); commit freely on non-default branches; always `push` after any commit; new branches named `change/<description>` (description only, no epic/spec-id prefix); worktrees created under `.worktrees/`. Mirrors this repo's own operating guidance.
- **Scaffolded `.gitignore` (R22):** ships a stack-aware starting point (.NET + Angular/Node build output, generated `.env` files, OS noise, `.worktrees/`, `.flow/bin/`, local Claude settings); `config.json` stays tracked.
- **Refuse-by-default on non-empty target** with `--force`; scaffold into `./<project-name>/`; bash parameter-expansion for substitution (no sed-injection).
- **Directory rename:** `src/project-init/` → `src/init-project/`.

## H&G Removal Decisions

Per-passage rulings from the interview (drive tasks `.2` and `.3`). "H&G" content = the H&G game-catalog domain (game telemetry, Postgres `platform-db`/`platform-api`, Unity, etc.).

| # | Location | Content | Decision |
|---|----------|---------|----------|
| P1 | `main.md:5` | "Shared infrastructure and tooling for H&G's game catalog…" + `play.sh`/`platform/<name>-cli` | **Remove the sentence** entirely |
| P2 | `dev-container.md:24,26` | "services live outside `.devcontainer/`" rule + Postgres/`platform-db`/`platform-api` example | **Keep the principle + dep-placement table; swap the example** to the Grafana+OTel observability stack; strip all H&G |
| P3 | `config-management.md §2 (18-38)` | `play.sh` telemetry keys (`games[]`, ad-campaign, store-listing, package_name, GCS) | **Remove entirely** (no analog in `systems[]`/`services{}`) |
| P4 | `config-management.md §3 (40-61)` | `platform-db` Postgres roles / Flyway / RLS | **Keep generalized**: becomes the real `postgres` component (a `systems[]` entry; database named `platform`); the owner/migrator/api role + RLS pattern is reused (now via EF Core migrations) — remove all H&G/game framing |
| P5 | `config-management.md §4 (63-82)` | `platform-api` Google OAuth / PGS keys | **Replace with a generic `services{}` example** (e.g. `claude-api` → api key/credentials) |
| P6 | `config-management.md §5/§6 (88,103,109,115)` | Incidental Postgres / Cloud SQL / Secret Manager / `platform/` mentions in the password-alphabet + 12-factor sections | **Keep the sections; neutralize the incidental examples** (the URL-safe password alphabet is retained as a real standard — see R24) |
| P7 | `tdd.md (5,14-23,38,46,52,54)` | Unity / `games/` / `coverlet` / `platform-api` / `play.sh` framing | **Keep concept, reword/generalize**: retain 100% line+branch coverage rule, "restructure to test" ethos, Humble-Object idea, tooling-table shape; drop Unity/games/coverlet/play.sh carve-outs; reconcile with the `/tdd` plugin |

> **Override (post-interview):** the earlier instruction in task `.2` to *remove* the `docs/business.md` / `docs/roadmap.md` references is **reversed**: the scaffold creates **empty, H&G-free TODO-stub homes for Dick's business-doc set** (`business.md`, `strategy.md`, `customers.md`, `priorities.md`, `decisions.md`) and indexes them in `_CLAUDE.md`. **`roadmap.md` is dropped** (`priorities.md` replaces it). Owned/filled by `/dick` (fn-1); fn-2 only provides empty homes.
> **Rename (post-interview):** the Postgres component is `src/postgres/` (systems[] entry `postgres`); the *database* it hosts is named `platform`. Earlier "`platform` component" references are superseded.

## Acceptance Criteria
- **R1:** `/init-project` is a registered, invocable skill (`src/init-project/SKILL.md` frontmatter `name: init-project` + `argument-hint`; `init-project` entry in marketplace.json with `source: "./src/init-project"`).
- **R2:** Invoking the skill asks only for project name + short description, then scaffolds `./<project-name>/` with the root layout (`.claude/ .devcontainer/ docs/ src/ etc/`), root `CLAUDE.md`, standards docs, config-management standard, dispatcher CLI, and dev container — name/description substituted, **no leftover `{{PLACEHOLDER}}` tokens**.
- **R3:** All scaffolded template content is **generalized per the H&G Removal Decisions** — no "H&G", `play.sh`, game/Unity/`coverlet`/`games[]`, Google OAuth/PGS, or `platform-api` references remain (the Postgres survives only as the generalized `postgres` component per P4).
- **R4:** The scaffolded **dev container** uses base image `mcr.microsoft.com/devcontainers/dotnet` + Node feature, and installs .NET SDK, **Node + Angular CLI (npm)**, GCP CLI, AWS CLI, Azure CLI, GitHub CLI, Atlassian CLI `acli`, DuckDB CLI, Claude Code, **Codex CLI**; registers this marketplace + enables the **nine plugins** (`dick`, `grill-me`, `handoff`, `tdd`, `ubiquitous-language`, Playwright `preferred-browser-automation-plugin`, `context7`, flow-next `preferred-ralph-loops-plugin`, **GitHub MCP server** `github-mcp-server`); fresh build/`setup.sh` succeeds; optional installs best-effort.
- **R5:** Grafana + OTel Collector scaffolded as a separate observability compose stack outside `.devcontainer/`, launched via `system.sh up` (alongside `postgres` + `keycloak`).
- **R6:** Bundled scaffold/dispatcher scripts meet the tdd standard — 100% line+branch coverage, `set -euo pipefail`, source-guarded `main`, refuse non-empty target unless `--force`.
- **R7:** Final opt-in `/dick` hand-off against the scaffolded project, graceful non-fatal degradation when `/dick` absent.
- **R8:** Config-management standard doc + scaffolded `config.json` encode the model: `systems[]` (one entry per `src/<component>/`) + peer `services{}` (one entry per external service), build-step `.env` distribution, 12-factor runtime contract.
- **R9:** Scaffolded root `CLAUDE.md` states mono-repo-of-all-components, documents the `src/<component>` ↔ `systems[]` invariant, and includes behavior directives: brevity/DRY, brutal honesty, always verify before making claims.
- **R10:** The scaffold lays down the **starter solution** — permanent components `Framework`, `DataAccess`, `BusinessLogic`, `Api` (.NET), `MarketingSite`, `WebApp` (Angular), `postgres` (Postgres docker, DB named `platform`), `keycloak` (Keycloak IdP docker), plus a clearly-marked **removable** `SampleApp` (.NET console) — each as `src/<component>/` + a `systems[]` entry.
- **R11:** A `docs/front-end.md` Angular standard ships, specifying: prerendered/SSG, client-side only, S3-static, no server runtime; **path-based routing + the S3 error-document→`index.html` fallback (+ CloudFront note)**; SCSS; angular-eslint + Prettier; npm; Jest unit tests (100% coverage). The two Angular SPAs follow it.
- **R12:** The root-CLAUDE template is named `_CLAUDE.md` (scaffolds to `CLAUDE.md`), and its Standards index links `docs/front-end.md`, `docs/keycloak.md`, and the other standards per the documented standards convention.
- **R13:** Scaffolded `config.json` is **prepopulated** with `systems[]` entries for every starter component — incl. the `postgres` settings (database `platform`, generated URL-safe credentials, host, port, docker) and the `keycloak` settings (realm, generated admin credentials, host, port, docker) — and a `services{}` example (`claude-api`, `REPLACE_ME`). A parallel `config.deploy.json` mirrors the shape with `{{VAR-NAME}}` placeholders for every secret (R25).
- **R14:** A `docs/keycloak.md` standard ships documenting the Keycloak identity-provider conventions (self-hosted compose, realm-import, DB-auth-via-Keycloak + session-context RLS), linked from `_CLAUDE.md`'s Standards index.
- **R15:** The skill runs a **git/GitHub final phase**: prompts (create GitHub repo? name? auto-commit after setup? run `/init` after setup?), `git init`, optional `gh` repo creation, **status-line setup (branch + model + % context used)**, optional `/init` run, and an optional initial commit made **last**. All prompts default to safe/no-op; a declined GitHub repo or absent `gh` degrades gracefully.
- **R16:** The scaffold lays down `docs/` stubs — **empty TODO-stub homes for Dick's business docs** (`business.md`, `strategy.md`, `customers.md`, `priorities.md`, `decisions.md`; owned/filled by `/dick`, fn-1; **no `roadmap.md`**) plus the technical standards docs (`ubiquitous-language.md`, `architecture.md`, `config-management.md`, `tdd.md`, `dev-container.md`, `front-end.md`, `keycloak.md`) — **all H&G-free** — and indexes them in `_CLAUDE.md`. `etc/` ships a `.gitkeep`.
- **R17:** `_CLAUDE.md` carries the philosophy content per the hybrid model: **inline** concision directive + simplicity-over-complexity (Ousterhout); **linked** DDD (Evans) → `ubiquitous-language.md`, TDD/feedback-loops/deep-modules → `tdd.md`, design philosophy → `architecture.md`, all surfaced via the Standards index.
- **R18:** The scaffolded `.claude/` ships a **non-blocking Stop hook** that surfaces a "refresh `CLAUDE.md`/sub-docs?" reminder **only when** the session surfaced updates worth persisting — **no silent edits**.
- **R19:** Doc strategies are realized: `CLAUDE.md` = thin always-on index; `README.md` = human-facing onboarding (overview, dev-container quickstart, run `system.sh` + bring up `postgres`/`keycloak`/observability), distinct from CLAUDE.md; the **sub-agent convention** is documented in `CLAUDE.md`.
- **R20:** `_CLAUDE.md` carries an **inline directive**: **before any non-trivial work**, Claude spawns a sub-agent to **consult the business direction** — read Dick's business docs reasoning in the `src/dick/SOUL.md` voice — and report back. **Consult-only**; if the docs can't answer, surface the gap and suggest an interactive `/dick` session — **never fabricating** business direction.
- **R21:** `_CLAUDE.md` carries an inline **git-commit policy**: never commit to `main` without explicit user instruction (ask first if commit-worthy on `main`); commit freely on non-default branches; always `push` after any commit; new branches `change/<description-of-change>` (description only, no epic/spec-id prefix); worktrees under `.worktrees/`. Lives next to the commit instructions.
- **R22:** The scaffold ships a stack-aware **`.gitignore`**: OS noise; `.worktrees/`; .NET (`bin/`,`obj/`,`.vs/`,`*.user`,`[Tt]est[Rr]esults/`); Node/Angular (`node_modules/`,`dist/`,`.angular/`,`coverage/`,`npm-debug.log*`); generated per-component `.env` (NOT `config.json`); `.claude/settings.local.json`; `.flow/bin/`.
- **R23 (cross-cutting):** Every scaffolded template file is authored to its **final, complete form during fn-2 implementation** — full verbatim directive text lives **in the template files** (not as a pointer to this spec). At `/init-project` runtime the engine performs **only copy + minimal `{{PLACEHOLDER}}` substitution** — no content generation. A freshly scaffolded project is fully-formed.
- **R24:** A root **`system.sh`** dispatcher routes `system.sh <subcommand>` → `src/system-cli/<subcommand>.sh`, with `_`-prefixed files non-dispatchable. Ships subcommands: **`build-config`** (distributes `config.json` → per-component `.env`; validates secrets against the URL-safe alphabet `[A-Za-z0-9_-]+`), **`help`** (lists subcommands + a one-line description scraped from each file's top `# Description:` comment), **`up`**/**`down`** (per-component compose stacks), **`migrate`** (EF Core), **`status`**. Carries forward the source repo's dispatcher conventions (exit codes, error format).
- **R25:** Two config files ship: **`config.json`** (local dev — generated URL-safe secrets for `postgres`+`keycloak`, `REPLACE_ME` for external service creds) and **`config.deploy.json`** (deployment template — every secret is a `{{VAR-NAME}}` placeholder the CI/CD pipeline substitutes before `build-config`). Both share the `systems[]`/`services{}` shape.
- **R26:** The .NET projects compose into a single solution **`src/system.sln`** referencing each `src/<component>/` `.csproj`, layered `Api → BusinessLogic → DataAccess → Framework`; `DataAccess` owns the EF Core `DbContext` + migrations.
- **R27:** A committed Keycloak **realm-import JSON** (loaded via `--import-realm` on `up`) pre-defines the realm, SPA public clients (`WebApp`, `MarketingSite`), the `Api` confidential client, **one service-account client per backend service**, and a baseline role set; `build-config` injects realm/client ids/secrets from config (never hardcoded).
- **R28:** DB access is **gated through Keycloak with session-context row-level security**: the `Api` validates the Keycloak JWT, connects to Postgres as a least-privilege `api` login role, and sets per-request session context (`app.user_id`/`app.roles` from claims); RLS policies key off `current_setting('app.*')`. The scaffold ships the schema-independent baseline — `owner`/`migrator`/`api` roles, RLS-on-by-default convention, a session-context helper, and a documented policy template — as **raw SQL inside EF Core migrations** (DataAccess). Concrete per-table policies land with the schema.
- **R29:** EF Core **code-first** migrations live in `DataAccess`; **`system.sh migrate`** runs **`dotnet ef database update`** (Npgsql) against the connection string built from the generated config, targeting the `postgres` component's `platform` database.
- **R30:** The scaffold ships **CI** under `.github/workflows/` (GitHub Actions) running .NET + Angular build/test with the **100% line+branch coverage gate** (+ kcov for shell), aligned with the tdd standard.

## Early proof point
Task fn-2….1 (skill skeleton + bundled scaffold engine) proves the skill→script→skeleton loop with safe substitution and refuse-non-empty. If it fails, reconsider the skill-first/script-behind split before investing in the starter-solution templates.

## Resolved via Codebase
- Full H&G reference enumeration (grep over `src/project-init/`): `main.md:5`; `dev-container.md:24,26`; `config-management.md:18-38,40-61,63-82,88,103,109,115`; `tdd.md:5,14-16,20-23,38,46,52,54`. Governed by the H&G Removal Decisions table.
- No pre-existing front-end.md / Angular preferences anywhere in the repo (grep) — the Angular standard (R11) is authored fresh.
- The `system.sh` dispatcher + `help` `# Description:`-scraping pattern, the `config.json`→`.env` `build-config` step, the URL-safe password alphabet, and the `owner`/`migrator`/`api` + RLS role pattern are all **carried forward from the source repo** (`src/project-init/system-cli/system.sh`, `help.sh`, `config-management.md §3/§5`) — generalized off H&G. The interview re-confirmed them as standards.
- `/playwright` is registered as `preferred-browser-automation-plugin` (git-subdir re-export); an existing external plugin, no epic/dependency — joins the devcontainer enabled-plugins list (R4).

## Open Questions
_All four prior open questions were resolved in the fn-2 interview: .NET solution wiring → R26 (`src/system.sln`); Angular routing → R11 (path routing + S3 fallback); auto-update hook trigger → R18 (non-blocking Stop reminder); GitHub plugin identity → R4 (GitHub MCP server)._

Forward notes (not blocking — resolved when the schema/auth model is fleshed out, not at scaffold time):
- **Concrete RLS per-table policies** and the **exact realm role/client model** are scaffolded as baselines + templates now; finalized when real entities exist.

## Strategy drift flagged for review
_None — no STRATEGY.md present._

## Requirement coverage

| Req | Description | Task(s) | Gap justification |
|-----|-------------|---------|-------------------|
| R1  | Registered, invocable skill | fn-2….1 | — |
| R2  | Name+description → scaffolded skeleton | fn-2….1, fn-2….2 | — |
| R3  | Content generalized per H&G Removal Decisions | fn-2….2, fn-2….3 | — |
| R4  | Dev container: base image + CLIs + Node/Angular + 9 plugins (incl. GitHub MCP) | fn-2….4 | — |
| R5  | Grafana + OTel compose stack via `system.sh up` | fn-2….5 | — |
| R6  | Scripts 100% coverage, refuse-non-empty | fn-2….1, fn-2….6 | — |
| R7  | Final opt-in `/dick` hand-off | fn-2….7 | Depends on fn-1 |
| R8  | config.json systems[]/services{} standard | fn-2….3 | — |
| R9  | CLAUDE.md mono-repo + behavior directives | fn-2….2 | — |
| R10 | Starter solution components (.NET + Angular + postgres + keycloak + SampleApp) | _new task(s) — run /flow-next:plan_ | Not yet tasked |
| R11 | front-end.md Angular standard (+ path routing/S3 fallback) + 2 SPAs | _new task(s) — run /flow-next:plan_ | Not yet tasked |
| R12 | `_CLAUDE.md` rename + front-end.md/keycloak.md Standards-index links | fn-2….2 | — |
| R13 | config.json + config.deploy.json prepopulated (postgres + keycloak, generated secrets) | fn-2….3 | — |
| R14 | keycloak.md standard (+ DB-auth/RLS) + _CLAUDE.md link | _new task(s) — run /flow-next:plan_ | Not yet tasked |
| R15 | Git/GitHub final phase (repo, status line, /init, commit) | _new task(s) — run /flow-next:plan_ | Not yet tasked |
| R16 | docs/ stubs (Dick biz-docs + tech standards) H&G-free + indexed; etc/.gitkeep | fn-2….2 + _new task_ | Partially tasked |
| R17 | CLAUDE.md philosophy (inline + linked DDD/TDD/design) | fn-2….2 | — |
| R18 | Auto-update Stop hook (reminder, non-blocking) | _new task(s) — run /flow-next:plan_ | Not yet tasked |
| R19 | Doc strategies (thin CLAUDE.md, human README, subagent convention) | fn-2….2 + _new task_ | Partially tasked |
| R20 | Inline _CLAUDE.md business-consult sub-agent directive | fn-2….2 | — |
| R21 | Inline _CLAUDE.md git-commit policy (+ branch convention + worktrees) | fn-2….2 | — |
| R22 | Stack-aware `.gitignore` (incl. `.worktrees/`) | fn-2….2 | — |
| R23 | Build-time-complete templates (copy + substitute only at runtime) | fn-2….1, fn-2….2 | Cross-cutting |
| R24 | `system.sh` dispatcher + `src/system-cli/` subcommands (build-config/help/up/down/migrate/status) | _new task(s) — run /flow-next:plan_ | Supersedes earlier dispatcher framing in fn-2….6 |
| R25 | config.json + config.deploy.json ({{VAR-NAME}} for CI/CD) + secret-gen + URL-safe alphabet | fn-2….3 | — |
| R26 | Single `src/system.sln` referencing layered .NET projects | _new task(s) — run /flow-next:plan_ | Part of R10 starter solution |
| R27 | Keycloak realm-import JSON (realm + clients + service accounts) | _new task(s) — run /flow-next:plan_ | Not yet tasked |
| R28 | DB-auth via Keycloak + session-context RLS baseline (raw SQL in EF migrations) | _new task(s) — run /flow-next:plan_ | Not yet tasked |
| R29 | EF Core code-first migrations in DataAccess via `system.sh migrate` | _new task(s) — run /flow-next:plan_ | Not yet tasked |
| R30 | CI: GitHub Actions + 100% coverage gate | _new task(s) — run /flow-next:plan_ | Not yet tasked |

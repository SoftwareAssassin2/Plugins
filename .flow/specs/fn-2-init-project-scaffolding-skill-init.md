# init-project scaffolding skill (/init-project)

## Overview

`/init-project` is a **Claude Code skill** (lives at `src/init-project/`, registered in `.claude-plugin/marketplace.json`) that stands up a brand-new software project with the user's preferred defaults. It asks only for a **project name** + **short description** (plus a few git/GitHub prompts), then lays down a fixed, opinionated **starter solution** (root layout, root `CLAUDE.md` + `README.md`, dev container, standards docs, dispatcher CLI, a starter .NET solution, two Angular SPAs, a `platform` Postgres service, and a `keycloak` IdP). It finishes with an optional `/dick` (fn-1) hand-off and a **git/GitHub phase** (repo creation, status line, initial commit).

The scaffolded project is a **mono-repo containing every component of the software system**, governed by a 1:1 correspondence: **every component is a subfolder `src/<component>/` AND has a matching entry in `config.json`'s top-level `systems[]` array**. External dependencies the system connects to are entries under a peer `services{}` object.

Deterministic file-stamping (skeleton + `{{PLACEHOLDER}}` substitution) is a **bundled, tested shell script** invoked by the skill; per-project adaptation stays in skill prose. The existing `src/project-init/*.md` files are raw material — generalized per the **H&G Removal Decisions** section below.

## Starter solution (what gets scaffolded)

Every new project ships these components — each its own `src/<component>/` folder + a `config.json` `systems[]` entry:

**Permanent defaults (always laid down):**
- `Framework` — .NET class library
- `DataAccess` — .NET class library
- `BusinessLogic` — .NET class library
- `Api` — .NET HTTP API
- `MarketingSite` — Angular SPA (prerendered, client-side only, S3-static, no server runtime)
- `WebApp` — Angular SPA (same build profile)
- `platform` — Postgres database running in a docker container (compose service, OUTSIDE `.devcontainer/` per the dev-container philosophy)
- `keycloak` — Keycloak identity provider, self-hosted in a docker container (compose service, OUTSIDE `.devcontainer/`, same treatment as `platform` Postgres)

**Removable starter sample (clearly marked):**
- `SampleApp` — .NET console app demonstrating the conventions (documented as prunable)

## Quick commands
```bash
jq -e '.plugins[] | select(.name=="init-project")' .claude-plugin/marketplace.json
tmp=$(mktemp -d); ( cd "$tmp" && /path/to/scaffold.sh demo-app "A demo" ) && ls "$tmp/demo-app/src" && ! grep -rq '{{' "$tmp/demo-app"
# config.json prepopulated with the starter components + services
jq -e '.systems and .services and ([.systems[].name] | index("platform"))' "$tmp/demo-app/config.json"
```

## Boundaries / non-goals
- NOT opinionated *configuration* of the project's behavior — that is `/dick` (fn-1), the optional last step. (It IS opinionated about default *architecture* — the starter solution above.)
- Grafana + OTel Collector, the `platform` Postgres, and `keycloak` are **services** → separate compose stack(s) OUTSIDE `.devcontainer/`, brought up via the project dispatcher.
- Does not publish/share anything externally; purely local file creation.

## Decision context
- **Skill-first, script-behind:** front door is a skill; deterministic stamping delegated to a bundled, tested script (satisfies the 100%-coverage tdd standard, no run-to-run drift).
- **Config model:** `config.json` single source of truth — `systems[]` (one entry per `src/<component>/`) + peer `services{}` (one entry per external service, e.g. `claude-api` → api key/credentials). Build step distributes per-component `.env`; runtime reads env only (12-factor).
- **Component ↔ folder ↔ config invariant:** each project (incl. .NET class libraries) is its OWN `src/<component>/` + `systems[]` entry; libraries carry minimal/empty config.
- **`main.md` → `_CLAUDE.md`:** the root-CLAUDE template is renamed `_CLAUDE.md` (underscore = template, scaffolds to the project's `CLAUDE.md`).
- **Front-end standard:** Angular SPAs are prerendered (SSG), client-side only, deployed static to an S3 bucket, **no server-side runtime**. Styling **SCSS**; lint/format **angular-eslint + Prettier**; package manager **npm**; unit tests **Jest** (100% coverage applies). Captured in a new `docs/front-end.md`, linked from `_CLAUDE.md`'s Standards index.
- **Identity provider:** Keycloak is the system's IdP — self-hosted as a docker/compose service (`systems[]` entry `keycloak`), with standards in a new `docs/keycloak.md` linked from `_CLAUDE.md`'s Standards index.
- **Devcontainer toolset:** .NET SDK, **Node + Angular CLI** (npm), GCP CLI, AWS CLI, Azure CLI, GitHub CLI, **Atlassian CLI `acli`** (covers Jira + Confluence), DuckDB CLI, Claude Code (`install.sh`), **Codex CLI**; registers THIS marketplace + enables **nine plugins**: `dick`, `grill-me`, `handoff`, `tdd`, `ubiquitous-language`, the Playwright plugin (`preferred-browser-automation-plugin`), **`context7`**, **flow-next** (`preferred-ralph-loops-plugin`), and a **GitHub plugin**.
- **Git/GitHub final phase:** after scaffolding the skill (a) prompts — create a GitHub repo? (name?) / auto-commit after setup? / run `/init` after setup?, (b) `git init`s the project, (c) optionally creates the GitHub repo via `gh`, (d) sets up a status line, (e) optionally runs `/init`, (f) optionally makes the initial commit **last** so it captures the `/dick` + `/init` output.
- **Docs set (all H&G-free):** the scaffold lays down `docs/` with (a) **empty TODO-stub homes for Dick's business docs** — `business.md`, `strategy.md`, `customers.md`, `priorities.md`, `decisions.md` (owned/filled by `/dick`, fn-1; **no `roadmap.md`** — `priorities.md` replaces it), and (b) the technical standards docs `ubiquitous-language.md`, `architecture.md`, `config-management.md`, `tdd.md`, `dev-container.md`, `front-end.md`, `keycloak.md`. `etc/` ships a `.gitkeep`; `src/` is populated by the starter solution. (Dick's `docs/strategy.md`/`docs/decisions.md` are distinct from flow-next's repo-root `STRATEGY.md` / `.flow` decisions.)
- **CLAUDE.md philosophy (hybrid):** inline directives in `_CLAUDE.md` (concision — "sacrifice grammar for concision"; simplicity-over-complexity — Ousterhout/software-entropy; plus the R9 brevity/honesty/verify); deep material in linked docs — **DDD** (Evans) → `ubiquitous-language.md`, **TDD/feedback-loops/deep-modules** (Hunt & Thomas, Ousterhout, "design the interface, delegate the implementation") → `tdd.md`, **design philosophy** → `architecture.md` — surfaced via the Standards index.
- **Auto-update hook:** the scaffolded `.claude/` ships a hook that keeps `CLAUDE.md` + sub-docs current within a thread (exact trigger/behavior — e.g. Stop/SessionEnd — designed as its own task).
- **Doc strategies:** `CLAUDE.md` = thin always-on index (root layout + Standards index + inline directives, depth in `docs/` on demand, hook-maintained); `README.md` = human-facing onboarding (overview, dev-container quickstart, how to run the dispatcher + bring up `platform`/`keycloak`/observability), distinct from agent-facing CLAUDE.md; **sub-agent convention** = delegate read-heavy exploration/research + parallelizable work to subagents to preserve main-thread context, documented in CLAUDE.md.
- **Business-consult sub-agent (inline `_CLAUDE.md` directive, R20):** before non-trivial work, Claude consults the business direction via a sub-agent that reads Dick's business docs (in the SOUL.md voice) and reports back — consult-only (interactive `/dick` stays main-thread), with a "flag the gap + suggest `/dick`, never fabricate" fallback.
- **Refuse-by-default on non-empty target** with `--force`; scaffold into `./<project-name>/`; bash parameter-expansion for substitution (no sed-injection).
- **Directory rename:** `src/project-init/` → `src/init-project/`.

## H&G Removal Decisions

Per-passage rulings from the interview (drive tasks `.2` and `.3`). "H&G" content = the H&G game-catalog domain (game telemetry, Postgres `platform-db`/`platform-api`, Unity, etc.).

| # | Location | Content | Decision |
|---|----------|---------|----------|
| P1 | `main.md:5` | "Shared infrastructure and tooling for H&G's game catalog…" + `play.sh`/`platform/<name>-cli` | **Remove the sentence** entirely |
| P2 | `dev-container.md:24,26` | "services live outside `.devcontainer/`" rule + Postgres/`platform-db`/`platform-api` example | **Keep the principle + dep-placement table; swap the example** to the Grafana+OTel observability stack; strip all H&G |
| P3 | `config-management.md §2 (18-38)` | `play.sh` telemetry keys (`games[]`, ad-campaign, store-listing, package_name, GCS) | **Remove entirely** (no analog in `systems[]`/`services{}`) |
| P4 | `config-management.md §3 (40-61)` | `platform-db` Postgres roles / Flyway / RLS | **Keep the example, generalized**: becomes the real `platform` Postgres database component (a `systems[]` entry: name `platform`, credentials, host, port, docker) — remove all H&G/game framing |
| P5 | `config-management.md §4 (63-82)` | `platform-api` Google OAuth / PGS keys | **Replace with a generic `services{}` example** (e.g. `claude-api` → api key/credentials) |
| P6 | `config-management.md §5/§6 (88,103,109,115)` | Incidental Postgres / Cloud SQL / Secret Manager / `platform/` mentions in the password-alphabet + 12-factor sections | **Keep the sections; neutralize the incidental examples** to generic component references |
| P7 | `tdd.md (5,14-23,38,46,52,54)` | Unity / `games/` / `coverlet` / `platform-api` / `play.sh` framing | **Keep concept, reword/generalize**: retain 100% line+branch coverage rule, "restructure to test" ethos, Humble-Object idea, tooling-table shape; drop Unity/games/coverlet/play.sh carve-outs; reconcile with the `/tdd` plugin |

> **Override (post-interview):** the earlier instruction in task `.2` to *remove* the `docs/business.md` / `docs/roadmap.md` references from `main.md` is **reversed**, then refined by the fn-1 interview: the scaffold creates **empty, H&G-free TODO-stub homes for Dick's business-doc set** — `business.md`, `strategy.md`, `customers.md`, `priorities.md`, `decisions.md` — and indexes them in `_CLAUDE.md`. **`roadmap.md` is dropped** (`priorities.md` replaces it). The docs are owned/filled by `/dick` (fn-1); fn-2 only provides the empty homes (no fabricated content).

## Acceptance Criteria
- **R1:** `/init-project` is a registered, invocable skill (`src/init-project/SKILL.md` frontmatter `name: init-project` + `argument-hint`; `init-project` entry in marketplace.json with `source: "./src/init-project"`).
- **R2:** Invoking the skill asks only for project name + short description, then scaffolds `./<project-name>/` with the root layout (`.claude/ .devcontainer/ docs/ src/ etc/`), root `CLAUDE.md`, standards docs, config-management standard, dispatcher CLI, and dev container — name/description substituted, **no leftover `{{PLACEHOLDER}}` tokens**.
- **R3:** All scaffolded template content is **generalized per the H&G Removal Decisions** — no "H&G", `play.sh`, game/Unity/`coverlet`/`games[]`, Google OAuth/PGS, or `platform-api` references remain (the `platform` Postgres survives only as the generalized database component per P4).
- **R4:** The scaffolded **dev container** installs .NET SDK, **Node + Angular CLI (npm)**, GCP CLI, AWS CLI, Azure CLI, GitHub CLI, Atlassian CLI `acli`, DuckDB CLI, Claude Code, **Codex CLI**; registers this marketplace + enables the **nine plugins** (`dick`, `grill-me`, `handoff`, `tdd`, `ubiquitous-language`, Playwright `preferred-browser-automation-plugin`, `context7`, flow-next `preferred-ralph-loops-plugin`, GitHub plugin); fresh build/`setup.sh` succeeds; optional installs best-effort.
- **R5:** Grafana + OTel Collector scaffolded as a separate observability compose stack outside `.devcontainer/`, launched via the project dispatcher.
- **R6:** Bundled scaffold/dispatcher scripts meet the tdd standard — 100% line+branch coverage, `set -euo pipefail`, source-guarded `main`, refuse non-empty target unless `--force`.
- **R7:** Final opt-in `/dick` hand-off against the scaffolded project, graceful non-fatal degradation when `/dick` absent.
- **R8:** Config-management standard doc + scaffolded `config.json` encode the model: `systems[]` (one entry per `src/<component>/`) + peer `services{}` (one entry per external service), build-step `.env` distribution, 12-factor runtime contract.
- **R9:** Scaffolded root `CLAUDE.md` states mono-repo-of-all-components, documents the `src/<component>` ↔ `systems[]` invariant, and includes behavior directives: brevity/DRY, brutal honesty, always verify before making claims.
- **R10:** The scaffold lays down the **starter solution** — permanent components `Framework`, `DataAccess`, `BusinessLogic`, `Api` (.NET), `MarketingSite`, `WebApp` (Angular), `platform` (Postgres docker), `keycloak` (Keycloak IdP docker), plus a clearly-marked **removable** `SampleApp` (.NET console) — each as `src/<component>/` + a `systems[]` entry.
- **R11:** A `docs/front-end.md` Angular standard ships, specifying: prerendered/SSG, client-side only, S3-static, no server runtime; SCSS; angular-eslint + Prettier; npm; Jest unit tests (100% coverage). The two Angular SPAs follow it.
- **R12:** The root-CLAUDE template is named `_CLAUDE.md` (scaffolds to `CLAUDE.md`), and its Standards index links `docs/front-end.md`, `docs/keycloak.md`, and the other standards per the documented standards convention.
- **R13:** Scaffolded `config.json` is **prepopulated** with `systems[]` entries for every starter component (incl. the `platform` Postgres settings: db name `platform`, credentials, host, port, docker; and the `keycloak` IdP settings: realm, admin credentials, host, port, docker) and a `services{}` example (e.g. `claude-api`).
- **R14:** A `docs/keycloak.md` standard ships documenting the Keycloak identity-provider conventions (self-hosted compose service, realm/client setup), linked from `_CLAUDE.md`'s Standards index.
- **R15:** The skill runs a **git/GitHub final phase**: prompts (create GitHub repo? name? auto-commit after setup? run `/init` after setup?), `git init`, optional `gh` repo creation, **status-line setup**, optional `/init` run, and an optional initial commit made **last** (capturing `/dick` + `/init` output). All prompts default to safe/no-op; a declined GitHub repo or absent `gh` degrades gracefully.
- **R16:** The scaffold lays down `docs/` stubs — **empty TODO-stub homes for Dick's business docs** (`business.md`, `strategy.md`, `customers.md`, `priorities.md`, `decisions.md`; owned/filled by `/dick`, fn-1; **no `roadmap.md`**) plus the technical standards docs (`ubiquitous-language.md`, `architecture.md`, `config-management.md`, `tdd.md`, `dev-container.md`, `front-end.md`, `keycloak.md`) — **all H&G-free** — and indexes them in `_CLAUDE.md`. `etc/` ships a `.gitkeep`.
- **R17:** `_CLAUDE.md` carries the philosophy content per the hybrid model: **inline** concision directive ("sacrifice grammar for concision") + simplicity-over-complexity (Ousterhout / software-entropy / "bad code = complex code"); **linked** DDD (Evans) → `ubiquitous-language.md`, TDD/feedback-loops/deep-modules (Hunt & Thomas; "design the interface, delegate the implementation") → `tdd.md`, design philosophy → `architecture.md`, all surfaced via the Standards index.
- **R18:** The scaffolded `.claude/` ships an **auto-update hook** that keeps `CLAUDE.md` + sub-docs current within a thread (exact trigger/behavior designed as its own task; must be non-blocking).
- **R19:** Doc strategies are realized: `CLAUDE.md` = thin always-on index; `README.md` = human-facing onboarding (overview, dev-container quickstart, run dispatcher + bring up `platform`/`keycloak`/observability), distinct from CLAUDE.md; the **sub-agent convention** (delegate read-heavy/parallel work to subagents) is documented in `CLAUDE.md`.
- **R20:** `_CLAUDE.md` carries an **inline directive** (not a linked doc): **before any non-trivial work**, Claude spawns a sub-agent to **consult the business direction** — read Dick's business docs (`business.md`, `strategy.md`, `customers.md`, `priorities.md`, `decisions.md`), reasoning in the `src/dick/SOUL.md` voice — and report the relevant guidance. **Consult-only** (the interactive `/dick` interview is a main-thread + user activity a sub-agent cannot run); if the docs can't answer, the sub-agent **surfaces the gap and suggests an interactive `/dick` session — never fabricating business direction.**

## Early proof point
Task fn-2….1 (skill skeleton + bundled scaffold engine) proves the skill→script→skeleton loop with safe substitution and refuse-non-empty. If it fails, reconsider the skill-first/script-behind split before investing in the starter-solution templates.

## Resolved via Codebase
- Full H&G reference enumeration (grep over `src/project-init/`): `main.md:5`; `dev-container.md:24,26`; `config-management.md:18-38,40-61,63-82,88,103,109,115`; `tdd.md:5,14-16,20-23,38,46,52,54`. These are the exact passages governed by the H&G Removal Decisions table.
- No pre-existing front-end.md / Angular preferences anywhere in the repo (grep) — the Angular standard in R11 is authored fresh from the interview.
- `dev-container.md:9` already lists Node as an example runtime — Node + Angular CLI formalized into R4.
- Repo-wide H&G sweep (whole tree, excl `.git`): actual H&G content exists ONLY in `src/project-init/{main,tdd,dev-container,config-management}.md` (all covered by the H&G Removal Decisions table); the only other matches are intentional references inside `.flow/`. Nothing leaked into README/other skills/root config.
- `/playwright` is registered in `marketplace.json` as `preferred-browser-automation-plugin` (git-subdir re-export of `anthropics/claude-plugins-official` → `external_plugins/playwright`) — an existing external plugin, so NO epic/dependency; it joins the devcontainer enabled-plugins list (R4).

## Open Questions
- **Angular S3 routing** (minor, defer to implementation): path-based routing on S3 static hosting needs a redirect/error-document fallback; confirm during the front-end.md / WebApp task.
- **.NET solution wiring** (minor): whether a single `.sln` references the per-`src/<component>/` projects, or projects are referenced loosely — decide at scaffold-authoring time.
- **Auto-update hook trigger** (R18): which Claude Code hook event drives the CLAUDE.md/sub-doc refresh (Stop / SessionEnd / PostToolUse) and whether it auto-edits vs. prompts — design during R18's task; must be non-blocking.
- **GitHub plugin identity** (R4): confirm the exact GitHub plugin/MCP to enable (distinct from the `gh` CLI already installed).

## Strategy drift flagged for review
_None — no STRATEGY.md present._

## Requirement coverage

| Req | Description | Task(s) | Gap justification |
|-----|-------------|---------|-------------------|
| R1  | Registered, invocable skill | fn-2….1 | — |
| R2  | Name+description → scaffolded skeleton | fn-2….1, fn-2….2 | — |
| R3  | Content generalized per H&G Removal Decisions | fn-2….2, fn-2….3 | — |
| R4  | Dev container: CLIs + Node/Angular CLI + 6 plugins (incl. Playwright) | fn-2….4 | — |
| R5  | Grafana + OTel compose stack | fn-2….5 | — |
| R6  | Scripts 100% coverage, refuse-non-empty | fn-2….1, fn-2….6 | — |
| R7  | Final opt-in `/dick` hand-off | fn-2….7 | Depends on fn-1 |
| R8  | config.json systems[]/services{} standard | fn-2….3 | — |
| R9  | CLAUDE.md mono-repo + behavior directives | fn-2….2 | — |
| R10 | Starter solution components (.NET + Angular + platform DB + keycloak + SampleApp) | _new task(s) — run /flow-next:plan_ | Not yet tasked |
| R11 | front-end.md Angular standard + 2 SPAs | _new task(s) — run /flow-next:plan_ | Not yet tasked |
| R12 | `_CLAUDE.md` rename + front-end.md/keycloak.md Standards-index links | fn-2….2 | — |
| R13 | config.json prepopulated with starter components (platform Postgres + keycloak) | fn-2….3 | — |
| R14 | keycloak.md identity-provider standard + _CLAUDE.md link | _new task(s) — run /flow-next:plan_ | Not yet tasked |
| R15 | Git/GitHub final phase (repo, status line, /init, commit) | _new task(s) — run /flow-next:plan_ | Not yet tasked |
| R16 | docs/ stubs: Dick's biz-doc homes (business/strategy/customers/priorities/decisions, no roadmap) + tech standards (ubiquitous-language/architecture/...) H&G-free + indexed; etc/.gitkeep | fn-2….2 + _new task_ | Partially tasked |
| R17 | CLAUDE.md philosophy (inline concision/simplicity + linked DDD/TDD/deep-modules/design) | fn-2….2 | — |
| R18 | Auto-update hook in scaffolded .claude/ | _new task(s) — run /flow-next:plan_ | Not yet tasked |
| R19 | Doc strategies (thin CLAUDE.md index, human README, subagent convention) | fn-2….2 + _new task_ | Partially tasked |
| R20 | Inline _CLAUDE.md directive: consult-business-direction sub-agent (consult-only + gap fallback) before non-trivial work | fn-2….2 | — |

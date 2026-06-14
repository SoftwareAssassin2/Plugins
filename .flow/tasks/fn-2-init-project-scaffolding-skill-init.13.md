---
satisfies: [R30]
---

## Description
Author the **CI** templates: GitHub Actions running .NET + Angular + shell build/test with the **100% line+branch coverage gate**, plus a config.json/config.deploy.json key-set drift check.

**Size:** M
**Files:** `templates/.github/workflows/ci.yml` (build/test) + `templates/.github/workflows/deploy.yml` (deploy-config rendering) (+ any helper scripts)

## Approach (from docs-scout/practice-scout)
- **Angular version:** CI uses the single declared Angular version (shared with .4/.12).
- **Two workflows:** (1) **build/test CI** (push/PR) runs `build-config` against the local `config.json` (or deterministic **dummy URL-safe test values**) — it must NOT require a secret store; (2) a **separate deploy workflow** renders `config.deploy.json` from the secret store then runs `build-config --config <rendered>`. Raw `{{VAR-NAME}}` placeholders must never reach password validation in build/test CI.
- **Build steps (R30):** CI first runs `dotnet build src/system.sln` and a static `ng build` for each SPA (asserting `dist/<app>/browser/index.html` is produced), before/alongside the coverage tests.
- **.NET:** use the **`coverlet.msbuild`** path — `dotnet test /p:CollectCoverage=true /p:Threshold=100 /p:ThresholdType=line,branch /p:ThresholdStat=total` (MSBuild integration enforces the gate). Do NOT mix the `--collect:"XPlat Code Coverage"` collector path with MSBuild threshold props; if using the collector instead, gate via a report parser.
- **Angular/Jest:** `jest --coverage` with `coverageThreshold` global 100 (non-zero exit if unmet). Monorepo caveat: thresholds don't roll up — run per-app.
- **Coverage exclusions:** apply the tdd.md exclusion policy (fn-2….8) — coverlet `/p:Exclude`/`[ExcludeFromCodeCoverage]` for EF migrations + ASP.NET bootstrap; Jest `collectCoverageFrom` excludes for Angular `main.ts`/bootstrap/`*.config.ts` — so a fresh scaffold passes its own gate.
- **Shell:** kcov over the **generated project's** `system.sh` + `src/system-cli/*.sh` (via the shell test-harness templated by fn-2….6 at `templates/tests/system-cli/`, run under kcov in CI) for **100% line coverage** — `scaffold.sh` belongs to the skill package (covered by fn-2….6's skill tests, NOT generated-project CI); branch completeness via explicit per-branch tests; **CI installs kcov explicitly** (documented install method / containerized step — runner availability varies), and the generated shell harness **stubs external commands** (`docker`, `dotnet`, etc.) so it tests command construction + branch behavior without real services. kcov has no built-in gate → parse the summary JSON and fail below 100% line.
- **Config drift guard:** normalize both files to sorted JSON **path sets** — match `systems[]` entries by `.name`, `services{}` by key, **ignore scalar values** — and fail only on missing/extra paths.
- Workflow triggers on push/PR; matches the git/GitHub repo-creation phase (fn-2….7).

## Investigation targets
**Required:**
- `src/init-project/templates/docs/tdd.md` (fn-2….8) — the 100% coverage standard + tooling table
- `.flow/specs/fn-2-...md` — R25 (config.deploy.json) + R30

## Acceptance
- [ ] `.github/workflows/ci.yml` runs .NET (`coverlet.msbuild` threshold 100 line+branch over the `*.Tests` projects), Angular (Jest coverageThreshold 100 per-app), and the generated project's shell (kcov 100% line over `system.sh`/`src/system-cli/*.sh` + parse-summary gate; NOT scaffold.sh)
- [ ] CI runs `dotnet build src/system.sln` + a static `ng build` per SPA (verifies `dist/<app>/browser/index.html`) before coverage; CI fails when any coverage metric < 100%
- [ ] A step verifies config.json ↔ config.deploy.json **JSON path-set** parity (systems[] matched by `.name`, scalars ignored); fails on missing/extra paths
- [ ] `ci.yml` (build/test) needs NO secret store and never feeds raw `{{VAR-NAME}}` to validation; a separate `deploy.yml` renders `config.deploy.json` from the secret store then runs `build-config --config <rendered>`
- [ ] `act`/dry validation or documented run confirms the workflow is well-formed
- [ ] **Fresh-scaffold proof:** scaffold a temp project, run its generated `tests/system-cli/` harness (with external commands stubbed) under kcov, parse the summary, and confirm 100% line coverage + a test per branch for `system.sh`/`src/system-cli/*.sh` (proves R6 holds on real generated output)

## Done summary
Authored the generated project's CI as build-time-complete templates under templates/.github/: ci.yml (push/PR — .NET coverlet 100% line+branch with SDK 9 pinned, Angular static SSG build + lint + prettier + jest 100% per-app, shell kcov 100%-line via tests/coverage.sh, config.json validation + config↔config.deploy path-set drift; no secret store) and deploy.yml (renders config.deploy.json {{VAR-NAME}} from GitHub secrets, then build-config --config <rendered>). Added .github/scripts/{kcov-gate,config-drift}.sh + generated tests/coverage.sh, and made the generated shell suite cover every system-cli subcommand under kcov via direct-child instrumentation. Codex impl-review: SHIP (R30 met) after two NEEDS_WORK rounds.
## Evidence
- Commits: 1dbbbcd, 9cba577, 8c622bc, 911b4eb
- Tests: bash src/init-project/tests/scaffold_test.sh (265 passed), bash src/init-project/tests/dispatcher_test.sh (61 passed), bash templates/tests/system-cli/system_cli_test.sh (40 passed, plain + kcov coverage mode), actionlint .github/workflows/*.yml (clean), shellcheck .github/scripts/*.sh tests/coverage.sh (clean), config-drift gate + deploy render proven end-to-end on fresh scaffold; kcov per-call collect+merge mechanism runs (24 dirs)
- PRs:
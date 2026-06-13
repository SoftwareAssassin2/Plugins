---
satisfies: [R6]
---

## Description
Generalize the dispatcher CLI (`system.sh` + `help.sh`) into a stamped per-project CLI template and give it **100% line + branch coverage** tests per the repo TDD standard (the existing scripts currently have none).

**Size:** M
**Files:** `src/init-project/templates/<name>-cli/` dispatcher + help scripts, `src/init-project/tests/` (bats/kcov harness for the dispatcher AND the scaffold.sh engine from fn-2….1)

## Approach
- Carry forward `system.sh`/`help.sh` patterns: dispatcher routes `<name>.sh <sub>` → `<name>-cli/<sub>.sh`; `_`-prefixed helpers non-dispatchable; exit 64 (usage) / 127 (unknown); pinned `ERROR: '<sub>' <msg>` stderr; `# Description:` scraping; `shopt -s nullglob`.
- Make the project name substitutable (`{{PROJECT_NAME}}` → dispatcher filename + internal path), reconciling the `src/<name>-cli/` vs `platform/` path with fn-2….2's CLAUDE.md.
- Tests: kcov with `set -euo pipefail` + source-guarded `main`; cover every branch incl. refuse-non-empty / `--force` / best-effort-failure / underscore-rejection / unknown-subcommand paths.

## Investigation targets
**Required:**
- `src/project-init/system-cli/system.sh:1-38` — dispatcher
- `src/project-init/system-cli/help.sh:1-42` — help lister
- `src/init-project/templates/docs/tdd.md` (from fn-2….2) — coverage standard + tooling

## Acceptance
- [ ] Dispatcher + help templates generalized with substitutable project name; conventions preserved (exit codes, error format, `_` helpers, Description scraping)
- [ ] Test harness achieves 100% line AND branch coverage for the dispatcher and `scaffold.sh`
- [ ] All branches exercised: usage error, unknown subcommand, underscore rejection, refuse-non-empty, --force, --dry-run

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

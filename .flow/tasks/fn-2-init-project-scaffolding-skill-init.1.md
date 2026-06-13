---
satisfies: [R1, R2, R6]
---

## Description
Establish `/init-project` as a registered, invocable skill AND build the bundled deterministic **scaffold engine** it delegates to. This is the spec's early proof point: a skill → bundled script → skeleton-into-`./<name>/` loop with safe substitution and refuse-non-empty.

**Size:** M
**Files:** rename `src/project-init/` → `src/init-project/`; `src/init-project/SKILL.md`; `src/init-project/.claude-plugin/plugin.json`; `.claude-plugin/marketplace.json`; `src/init-project/scaffold.sh` (the engine); a `templates/` dir for stamped assets.

## Approach
- Rename the existing directory so dir + plugin name + skill `name:` all read `init-project`.
- SKILL.md frontmatter per `src/handoff/SKILL.md:1-4` (name, description, argument-hint). Body = orchestration prose: ask name + description, run scaffold.sh, report tree, then (fn-2….7) offer `/dick`.
- Register in `.claude-plugin/marketplace.json` following `:15-20` (`source: "./src/init-project"`).
- `scaffold.sh`: scaffold into `./<project-name>/`; **refuse non-empty target unless `--force`**; `{{PROJECT_NAME}}`/`{{PROJECT_DESCRIPTION}}` substitution via **bash parameter expansion** (NOT sed); validate name `^[a-z0-9][a-z0-9-]*$`; `--dry-run` prints the tree it will create; `set -euo pipefail`; source-guarded `main "$@"` so tests can source it.
- Best-practice references: refuse-by-default norm; deterministic stamping belongs in a script, not agent prose.

## Investigation targets
**Required:**
- `src/handoff/SKILL.md:1-4` — frontmatter/argument-hint exemplar
- `.claude-plugin/marketplace.json:15-20` — local plugin entry shape
- `src/project-init/system-cli/system.sh:1-38` — bash conventions (set -euo pipefail, exit codes, BASH_SOURCE)
- `src/ubiquitous-language/.claude-plugin/plugin.json` — plugin.json shape

## Acceptance
- [ ] `src/init-project/SKILL.md` valid frontmatter (`name: init-project`, `argument-hint`); `init-project` registered in marketplace.json with `source: "./src/init-project"`; `/init-project` resolves after reload
- [ ] `scaffold.sh <name> <description>` creates `./<name>/` with the root layout and substitutes both placeholders (no `{{` tokens remain)
- [ ] Non-empty target is refused unless `--force`; invalid name exits non-zero with a clear message
- [ ] `--dry-run` prints the planned tree and writes nothing
- [ ] Script uses `set -euo pipefail` and a source-guarded `main` (testable by fn-2….6)

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

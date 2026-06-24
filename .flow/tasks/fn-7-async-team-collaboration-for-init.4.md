---
satisfies: [R14, R15]
---

## Description
Add `scaffold_test.sh` assertions proving the whole feature lands in a fresh scaffold and that the existing Stop hook + statusLine survive, and verify every new template file is git-tracked in the plugin repo.

**Size:** M
**Files:** `plugins/init-project/tests/scaffold_test.sh`

## Approach
- Mirror the existing assertion style (`check "<label>" '<predicate>'`, `$WORK/demo-app` rooting, `jq` directly on `settings.json` — it's plain JSON, no comment-strip):
  - **Docs land:** `docs/collaboration.md`, `docs/team.md`, `docs/collaboration/.gitkeep` present; `_CLAUDE.md` (the scaffolded `CLAUDE.md`) `grep`s `docs/collaboration.md` (Standards-index link) and `docs/team.md`.
  - **Hook script:** present + executable (`[[ -x ]]`), has `# Description:`, uses `set -uo pipefail`, `bash -n` clean. **No-network regression:** assert the hook never EXECUTES `git fetch`/`git pull` — `git fetch` absent entirely; any `git pull` appears ONLY inside the emitted advisory string, never as a run command (forbid the executed command, not the advisory text).
  - **settings.json:** `jq -e '.hooks.SessionStart[0].hooks[0].command'` present AND regression asserts `.hooks.Stop[0].hooks[0].command` + `.statusLine` still present (coexistence).
  - **README:** the private-repo/PII caveat string present.
  - **Three-surface:** `docs/todo.md` + `docs/priorities.md` each reference `docs/collaboration/`.
- **git-tracked verification (R15):** assert the new template files — `docs/collaboration.md`, `docs/team.md`, `docs/collaboration/.gitkeep`, AND `.claude/hooks/collaboration-inbox.sh` — are tracked in the PLUGIN repo (`git ls-files --error-unmatch …`) — guards the scaffolded-`.gitignore`-silently-drops gotcha.
- **Behavioral hook block (proves R8/R10):** isolate git config first (`HOME=<tmp>`, `GIT_CONFIG_GLOBAL=/dev/null`, neutralize system config) so identity reads ONLY what the test sets (else the CI machine's global identity leaks in and the "no identity" case is flaky). **`git init "$WORK/demo-app"`** and set/omit identity repo-locally via `git -C "$WORK/demo-app" config user.email …` per case (the hook reads at the project root). Write fixture `docs/team.md` (the fixed table) and `docs/collaboration/*.md`, then run the hook. Include a fixture thread whose **subject/body contains quotes + a newline** to prove `additionalContext` is JSON-escaped (output still `jq`-parses). **Split assertions by output kind:** JSON cases (pending thread present) pipe stdout to `jq` and assert `hookSpecificOutput.hookEventName=="SessionStart"` + the expected `additionalContext` (latest-turn routing — `awaiting-assignee→awaiting-asker→resolved` does NOT alert; asker routing — own `awaiting-asker` surfaces; freshness text present); **silent cases** (no `user.email` even with `user.name` set; in-team but no pending; no `docs/collaboration/`) assert **empty stdout + exit 0** (do NOT pipe to jq); the **identity-not-in-team** case asserts the register advisory via `jq` (same SessionStart `additionalContext` envelope); and a no-upstream fixture asserts no `@{u}` error.
- Run the full suite; confirm it stays green and `shellcheck` is clean on the new block.

## Investigation targets
**Required:**
- `plugins/init-project/tests/scaffold_test.sh:16-19,75-84` — check() helper + doc-presence + index-link patterns
- `plugins/init-project/tests/scaffold_test.sh:419,454-456` — jq-on-settings.json assertion style (+ when comment-strip applies)
**Optional:**
- the hook-script assertion precedent (executability / `# Description:` / `set` / `bash -n`) elsewhere in the file

## Key context
- `scaffold_test.sh` is also touched by fn-2.14 (todo) and fn-6.5 (todo, rewrites the harness) — append in a self-contained block; coordinate ordering to avoid churn. Note this in the done summary.
- settings.json is plain JSON → assert with `jq` directly (no `sed` comment-strip, unlike devcontainer.json).

## Acceptance
- [ ] Assertions: collaboration.md / team.md / collaboration/.gitkeep / hook script all land in a fresh scaffold
- [ ] Hook assertions (structural): executable, `# Description:`, `set -uo pipefail`, `bash -n` clean; hook EXECUTES no `git fetch`/`git pull` (advisory `git pull` text allowed)
- [ ] git config isolated (temp HOME / GIT_CONFIG_GLOBAL=/dev/null) + `git init` the temp scaffold with repo-local `user.email` per case (hook reads at project root) so the no-identity case isn't flaky
- [ ] A fixture with quotes + a newline in subject/body proves `additionalContext` is JSON-escaped (output still `jq`-parses)
- [ ] Behavioral block, split by output kind: JSON cases → `jq` confirms `hookEventName=="SessionStart"`; **pending-thread** JSON must include freshness ("as of your last pull"/`git pull`) + correct routing (latest-turn: resolved/superseded does NOT alert; asker routing); the **identity-not-in-team register advisory** uses the same JSON envelope but must NOT require freshness text; SILENT cases (no `user.email` / in-team-no-pending / no collaboration dir) → empty stdout + exit 0 (not piped to jq); no-upstream fixture → no `@{u}` error
- [ ] `settings.json`: `hooks.SessionStart` present AND `hooks.Stop` + `statusLine` preserved (coexistence regression)
- [ ] `_CLAUDE.md` links `docs/collaboration.md`; README PII caveat present; todo.md + priorities.md cross-reference `collaboration/`
- [ ] New template files (incl. `.claude/hooks/collaboration-inbox.sh`) verified git-tracked (`git ls-files --error-unmatch`)
- [ ] Full `scaffold_test.sh` green; `shellcheck` clean

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

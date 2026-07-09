---
satisfies: [R1, R2, R3, R4]
---
## Description
Build the `merge-request:create` skill: detect the forge, ensure the branch/HEAD is on the remote, open a ready PR/MR with the templated title, stash a pre-MR intent summary, capture the canonical id, then continue into the fix loop.

**Size:** M
**Files:** `plugins/merge-request/skills/create/SKILL.md` (+ optional `plugins/merge-request/skills/create/scripts/create.sh`)

## Depends on
- **fn-8.2** — the `merge-request` plugin shell (`plugins/merge-request/.claude-plugin/plugin.json`) and its `.claude-plugin/marketplace.json` registration must exist, else `/merge-request:create` is not discoverable.

## Approach
- Add `skills/create/SKILL.md` under the `merge-request` plugin (flow-next multi-skill layout) -> `/merge-request:create`. This is an assistant-executed skill; deterministic git/CLI steps may live in an optional `scripts/create.sh`.
- Invoke `/detect-source-control`; parse the stdout block; hard-stop on `supported=false`.
- Ensure HEAD is on the remote: if no upstream, `git push -u`; if upstream exists but is behind local, push the unpushed commits first.
- Create via `gh pr create` / `glab mr create`, ready-for-review, targeting the auto-detected default branch. Title exactly `Merge <source-branch> into <target-branch>`; minimal auto body.
- **Capture id robustly:** after creation resolve the canonical id via `gh pr view --json number` / `glab mr view --output json`; only if that fails, fall back to parsing the trailing PR/MR number from the create-command URL stdout.
- **Already-exists resume:** if creation reports an existing open PR/MR for the current branch, resolve that existing id (same `view --json` path), refresh the `## Intent` stash, and continue the handoff instead of erroring.
- **Intent stash:** write a `## Intent` block to `.data/merge/<ID>.md` from (a) the session's stated pre-MR intent + (b) scope from `git log <default>..HEAD --oneline` and `git diff --stat <default>...HEAD`; if no explicit intent, write `[TODO] Intent not provided` (fn-10 R11 reads this).
- **Handoff:** `SKILL.md` instructs the assistant to continue into `/merge-request:fix <ID>` with the captured id (assistant-level continuation, not a shell call).

## Investigation targets
**Required:**
- `plugins/detect-source-control/SKILL.md` -- detection stdout contract (from fn-8.1)
- `~/.claude/plugins/cache/flow-next/flow-next/1.10.2/skills/flow-next-work/SKILL.md` -- `skills/<name>/SKILL.md` layout
- `~/.claude/skills/gitlab-mr-review/scripts/setup-worktree.sh` -- `glab`/git invocation patterns

## Acceptance
- [ ] `skills/create/SKILL.md` invokes `/detect-source-control` and hard-stops when `supported=false`.
- [ ] Ensures HEAD is on the remote: pushes with `-u` when no upstream; pushes unpushed commits when the upstream is behind. Then creates a ready PR (`gh`) / MR (`glab`) targeting the default branch.
- [ ] Title is exactly `Merge <source-branch> into <target-branch>` with a minimal auto body.
- [ ] Captures the canonical id via `gh pr view --json number` / `glab mr view --output json` (URL-parse fallback documented, used only when the JSON path fails).
- [ ] Existing-open-PR/MR-for-branch case resolves the existing id and continues the handoff rather than erroring.
- [ ] Writes a `## Intent` summary into `.data/merge/<ID>.md` at creation from session intent + `git log`/`git diff --stat` scope, with `[TODO] Intent not provided` fallback.
- [ ] `SKILL.md` documents the assistant-level continuation into `/merge-request:fix <ID>` with the captured id.

## Verification
- Dry-run review of `SKILL.md` instructions for the full flow.
- If a `scripts/create.sh` is added: `shellcheck` clean, and exercise the git/`gh`/`glab` flow with mocked/stubbed `git`, `gh`, `glab` on PATH (no real PR/MR opened) covering: unsupported hard-stop, no-upstream push, behind-upstream push, id capture via JSON, id capture via URL fallback, and intent-stash fallback.

## Done summary
Built the assistant-executed `/merge-request:create` skill: SKILL.md drives detect-source-control -> hard-stop on unsupported -> ensure HEAD pushed -> open a ready PR/MR titled "Merge <source> into <target>" -> capture canonical id (view --json, URL fallback) -> stash `## Intent` to .data/merge/<ID>.md -> continue into /merge-request:fix <ID>. Backed by a shellcheck-clean scripts/create.sh (deterministic push/create/id-capture/intent-stash, already-exists resume, upstream-aware push) and a 31-case mocked git/gh/glab test suite.
## Evidence
- Commits: 26fec07, 53dad0e
- Tests: bash plugins/merge-request/skills/create/tests/create_test.sh (31 passed), shellcheck plugins/merge-request/skills/create/scripts/create.sh (clean)
- PRs:
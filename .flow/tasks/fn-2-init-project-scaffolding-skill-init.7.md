---
satisfies: [R7, R15]
---

## Description
Author the SKILL.md orchestration **tail**: the **git/GitHub final phase** and the opt-in **`/dick` hand-off**, run after the scaffold completes.

**Size:** M
**Files:** `plugins/init-project/SKILL.md` (orchestration tail; depends on fn-2….1 skeleton)

## Approach
- **Git/GitHub phase (R15):** prompt — create a GitHub repo? (name?) / auto-commit after setup? / run `/init` after setup?; `git init` the project; optionally `gh repo create`; **activate the status line (branch + model + % context used)** — the statusline script + settings are authored in fn-2….2's `templates/.claude/`; this phase points at it without clobbering the Stop-hook settings; optionally run `/init` (opt-in; it must **not clobber** the scaffolded `CLAUDE.md`/`.claude/` without explicit confirmation — if the host can't guarantee that, print the command instead of running it); then an optional initial commit (captures the scaffold + the optional `/init` output) — the **terminal `/dick` hand-off runs AFTER** this commit (committing Dick's later doc edits is a printed follow-up command, never auto-run). All prompts default safe/no-op; declined repo or absent `gh` degrades gracefully.
- **These are assistant-workflow steps** — the skill instructs the agent (prompt → hand off to `/init`/`/dick` where the host supports it, else print the exact command); it does NOT directly execute slash commands.
- **/dick hand-off (R7):** the **terminal** step (after the git phase + optional commit), offer to boot `/dick` (fn-1). If accepted and `/dick` resolves → hand off to it (terminal — do NOT assume control returns); print the exact follow-up command to commit Dick's doc edits. If `/dick` is unavailable → clear non-fatal message, still report overall success. Honors fn-1's hand-off contract (optional business-context arg; graceful no-context start).
- **Ordering (single, unambiguous):** scaffold → `git init` + status line → optional `/init` → optional **initial commit** (captures scaffold + `/init`) → **terminal `/dick` hand-off LAST**. Because `/dick` is persona-locked until "goodbye" and may not return control, the commit runs BEFORE it; committing `/dick`'s later doc edits is a **printed follow-up command**, never relied-on auto-continuation. The git-commit policy in the scaffolded `_CLAUDE.md` (R21) governs the *generated project's* future commits; this phase's own initial commit is explicitly user-opted.

## Investigation targets
**Required:**
- `plugins/init-project/SKILL.md` (fn-2….1) — orchestration body to append to
- `plugins/dick/SKILL.md` — fn-1 hand-off contract (invocation form, optional context arg)

## Acceptance
- [ ] Git phase prompts (repo/name/auto-commit/run-`/init`), `git init`s, optional `gh repo create`, **activates** the status line (authored in fn-2….2; no clobbering the Stop hook), optional `/init`, optional initial commit — **commit runs before** the terminal `/dick` hand-off; post-`/dick` commit is a printed follow-up
- [ ] Absent `gh` or declined repo degrades gracefully (non-fatal)
- [ ] Final opt-in `/dick` hand-off invokes `/dick` when present; clear non-fatal message + overall success when absent
- [ ] `/init` is run only when the host can preserve/confirm existing scaffolded files; otherwise the skill prints the exact command (never clobbers `CLAUDE.md`/`.claude/`)

## Done summary
Authored the SKILL.md orchestration tail for /init-project: a scaffold-exit gate (64 validation / 65 collision surfaced, non-zero stops), a git/GitHub final phase (git init -b main, status-line confirm without clobbering the Stop hook, optional gh repo create with graceful degradation, clobber-safe optional /init, optional user-opted initial commit on main as the deliberate bootstrap exception), and a terminal opt-in /dick hand-off run LAST with non-fatal graceful behavior when /dick is absent and a printed follow-up commit for Dick's doc edits.
## Evidence
- Commits: 9f90f98a66435f1f8073a582ea5c7ad01877745e, 46a7f1b3b0c40e2ad4bf00b33a371a9baabf236b, 15490e8d4d21d6bcd9f1e661c89e31288c211fc6
- Tests: plugins/init-project/tests/scaffold_test.sh (63 passed, 0 failed)
- PRs:
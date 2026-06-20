---
satisfies: [R8, R9, R13]
---

## Description
Rewrite `SKILL.md` orchestration for the in-place gap-fill model: optional name (CWD basename), the interactive conflict-resolution loop driven off `--plan` JSON (using engine `--diff`), `deleted`-file surfacing, and an in-place git/GitHub phase. The engine never prompts — all interaction lives here.

**Size:** M
**Files:** `plugins/init-project/SKILL.md`

## Approach
- **Name (`:12`)** optional → default CWD basename; ask only on regex-fail or explicit override. Frontmatter `description` (`:3`) → in-place gap-fill framing (drop "brand-new"/"starting a new project").
- **Orchestration (`:14`):** run `scaffold.sh … --plan` and **read its JSON directly (agent-read — never shell out to `jq`, preserving the jq-free plain-scaffold flow, R14)**. The engine auto-handles (no prompt): `missing`+`managed-update` written, `mode-update` chmod-ed, `identical`/`create-once-present` skipped, manifest-owned `config.json` merged, `retired` pruned, `gone` dropped. The skill **surfaces to the user** only: `conflict` (incl. unowned config.json), `deleted` (restore), and `retired-conflict` (keep/delete). For each `conflict`: present the file, offer **keep / overwrite / show diff** (default **keep-mine**); "show diff" calls engine `--diff <path>` (already redacted). For an **unowned `config.json`** conflict, also offer **merge** (→ `merge\t<path>` resolution, runs the structured-merge) — `merge` is a first-class resolution action alongside keep/overwrite/restore. Collect decisions into a `<action>\t<path>` resolutions file (R13 format); call `--apply --resolutions <file>`. Surface `deleted` files: offer restore, and when accepted emit a `restore\t<path>` line into the resolutions file (never auto-resurrect). Batch conflicts.
- **Exit handling (`:24-27`):** drop the "non-empty target / pick a fresh `./<name>/`" guidance; reserve non-zero exits for genuine failures + `--on-conflict fail`.
- **Git/GitHub phase (`:45-67`) — split new vs existing worktree (R9):** use `git rev-parse --is-inside-work-tree`. New/non-repo dir → `git init` + initial commit in CWD as today. **Capture a preflight snapshot BEFORE `--plan`/`--apply`** — `was_empty`, `was_inside_worktree` (`git rev-parse --is-inside-work-tree`), pre-existing uncommitted status — and branch ONLY on that snapshot (post-apply checks would misclassify every scaffold as non-empty). Only a **snapshot-known-empty** dir gets `git init` + `git add -A` + initial commit. **Any non-empty dir — git worktree OR plain existing project — never gets a blanket `git add -A`**: stage **only the paths in the engine's stdout `--apply` touched-path report** (`wrote|deleted|merged|restored|chmod|manifest`) or require **explicit confirmation**; skip `git init` inside an existing worktree; warn about pre-existing uncommitted changes. Drop every `git -C ./<name>`. Keep safe-default prompts + `/dick` hand-off (`:69-86`), re-pathed.
- **.gitignore warning (R9):** for **any non-empty target** (git worktree or not), when `--plan` shows a template `.gitignore` would land, warn (silent-untrack gotcha).
- Keep `--local-llm` opt-in prompts (`:29-43`).

## Investigation targets
**Required:**
- `plugins/init-project/SKILL.md:1-87` — full orchestration (every `./<name>` site)
- `.flow/memory/.../template-gitignore-silently-drops-2026-06-14` — the .gitignore-untrack hazard
**Optional:**
- `plugins/init-project/scaffold.sh` (post .1/.2) — the `--plan`/`--apply`/`--diff`/`--resolutions` contract

## Key context
- Engine is non-interactive by contract; this skill owns ALL prompting. Keep-mine is the mandatory safe default. Diffs come from engine `--diff` (redacted) — the skill must NOT re-stamp templates itself (fresh secrets + incomplete redaction).

## Acceptance
- [ ] Name optional (CWD basename default); frontmatter `description` describes in-place gap-fill
- [ ] Skill runs `--plan` and reads its JSON directly (no `jq` shell-out); auto-applies `missing`+`managed-update`; drives keep/overwrite/show-diff per conflict (keep-mine default, +merge for unowned config.json) using engine `--diff`; writes a `<action>\t<path>` resolutions file (keep|overwrite|restore|merge); calls `--apply`
- [ ] `deleted` files surfaced with restore offered via a `restore\t<path>` resolution (never auto); git/GitHub phase + report operate in place (no `git -C ./<name>`)
- [ ] A preflight snapshot (`was_empty`/`was_inside_worktree`/pre-existing status) is captured BEFORE apply and is the sole basis for git decisions
- [ ] Git phase: only a snapshot-known-empty dir gets `git init`+`git add -A`; ANY non-empty dir (git or not) stages only `--apply` touched-path-report paths (no blanket `git add -A`) or confirms, skips `git init` in an existing worktree, warns on pre-existing changes + on a landing `.gitignore`
- [ ] Skill prose enumerates which statuses are engine-auto (missing/managed-update/mode-update/owned-config-merge/retired/gone) vs user-surfaced (conflict/deleted/retired-conflict)
- [ ] Skill detects an existing worktree via `git rev-parse` and warns when a template `.gitignore` would land in it
- [ ] `--local-llm` opt-in prompts still function

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

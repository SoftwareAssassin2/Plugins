---
satisfies: [R9, R12, R17, R18, R19, R20, R21]
---

## Description
Author the root **`templates/_CLAUDE.md`** to its final, complete, H&G-free form — the full verbatim text of every CLAUDE.md directive in the spec — plus the scaffolded **auto-update Stop hook** under `templates/.claude/`. Build-time-complete (R23): everything ships as real prose, not pointers.

**Size:** M
**Files:** `plugins/init-project/templates/_CLAUDE.md`, `plugins/init-project/templates/README.md`, `plugins/init-project/templates/.claude/` (Stop hook + statusline script + settings.json)

## Approach
- **_CLAUDE.md** (from `main.md`, generalized): mono-repo-of-all-components statement + the `src/<component>` ↔ `config.json systems[]` invariant (R9); root-layout table + "default new dirs to etc/" + the **Standards index** always-on-TOC pattern linking every `docs/*.md` incl. `front-end.md` + `keycloak.md` (R12); **inline** behavior directives — brevity/DRY, brutal honesty, verify-before-claims, concision ("sacrifice grammar for concision"), simplicity-over-complexity (Ousterhout) (R9/R17); **linked** philosophy — DDD→`ubiquitous-language.md`, TDD/deep-modules→`tdd.md`, design→`architecture.md` (R17); **doc strategies** — thin CLAUDE.md index, human README, sub-agent convention (R19); **business-consult sub-agent** directive (R20): reads the **project's own** `docs/{business,strategy,customers,priorities,decisions}.md` — NOT any `plugins/dick/` path (absent in a scaffolded project); consult-only + gap fallback; **neutral role — the sub-agent MUST NOT invoke/adopt the `/dick` persona** (it can't run headless per /dick's contract); **git-commit policy** (R21) — no commit to main w/o explicit OK, free on branches, always push, branches `change/<description>` (no epic-id prefix), worktrees under `.worktrees/`.
- **Auto-update hook (R18):** `templates/.claude/` ships a **non-blocking Stop hook** that prints a "refresh CLAUDE.md/sub-docs?" reminder to stdout ONLY when a **marker file** `.claude/.claude-md-dirty` exists, then clears it (the assistant writes the marker when it surfaces a doc-worthy update). Wire via `.claude/settings.json` hooks; advisory, never a writer/silent-edit. Testable both ways (marker present → reminder + clear; absent → silent).
- **README.md (R19):** human-facing onboarding — what the project is, dev-container quickstart, how to run `system.sh` + bring up `postgres`/`keycloak`/observability; distinct from the agent-facing `_CLAUDE.md`.
- **Status line (R15 artifact):** author the **statusline script + a `.claude/settings.json` `statusLine` entry** (branch + model + % context used) here, coexisting in the same settings.json as the Stop hook; fn-2….7's git phase only activates it.

## Investigation targets
**Required:** (raw sources live at `plugins/project-init/` now; they move to `plugins/init-project/` after the fn-2….1 rename — paths below are post-rename)
- `plugins/init-project/main.md:3,11-29,37-41` — root-layout + Standards-index source
- `.flow/specs/fn-2-init-project-scaffolding-skill-init.md` — R9/R12/R17/R18/R19/R20/R21 verbatim directive text
- the scaffolded `docs/` business-doc set (fn-2….8) — what the R20 consult directive reads (no `plugins/dick/` path dependency)

## Acceptance
- [ ] `templates/_CLAUDE.md` is complete H&G-free prose: mono-repo + invariant; Standards index linking all docs; inline directives (brevity/DRY, honesty, verify, concision, simplicity); linked DDD/TDD/design; doc strategies; R20 consult directive; R21 git policy + branch convention + worktrees — all verbatim, no pointers
- [ ] `templates/.claude/` ships a non-blocking Stop hook keyed off a `.claude/.claude-md-dirty` marker (present → reminder + clear; absent → silent), wired in settings.json; no silent edits
- [ ] `templates/.claude/` ships the statusline script + settings.json `statusLine` entry (branch + model + % context), coexisting with the Stop hook in one settings.json
- [ ] `templates/README.md` ships human-facing onboarding (overview, dev-container quickstart, run `system.sh` + bring up services) — distinct from `_CLAUDE.md` (R19)
- [ ] `grep -rE 'H&G|play\.sh|platform-(db|api)' templates/_CLAUDE.md` returns nothing

## Done summary
Authored the build-time-complete `templates/_CLAUDE.md` (mono-repo + component↔config invariant & exceptions, root layout, always-on Standards index, inline brevity/honesty/verify/concision/simplicity directives, linked DDD/TDD/design, doc strategies, neutral business-consult sub-agent directive, and git-commit/branch/worktree policy — all verbatim, H&G-free), plus the `templates/.claude/` set (non-blocking marker-keyed Stop hook, statusline script, and one settings.json wiring both) and the human-facing `templates/README.md`. Verified via scaffold_test.sh (31/31), shellcheck, and a manual scaffold (no leftover tokens, H&G-free).
## Evidence
- Commits: afbd08f60201c270719dff9d0e9bf9020c6ecbdb
- Tests: bash plugins/init-project/tests/scaffold_test.sh (31 passed), shellcheck templates/.claude/hooks/claude-md-reminder.sh templates/.claude/statusline.sh (clean), manual scaffold into temp dir: no leftover __SCAFFOLD_*__ tokens, H&G-free, Stop hook tested both ways
- PRs:
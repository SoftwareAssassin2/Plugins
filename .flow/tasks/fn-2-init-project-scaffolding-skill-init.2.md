---
satisfies: [R2, R3, R9, R21, R22, R23]
---

## Description
Generalize the carried-forward **content-standard templates** the scaffold stamps: the root `CLAUDE.md` (from `main.md`), the testing standard (`tdd.md`), and the dev-container philosophy doc (`dev-container.md`). Strip ALL H&G/game-catalog/Postgres/Unity specifics; keep the portable patterns; add the new CLAUDE.md requirements.

**Build-time-complete (R23):** write the **full, final, verbatim** content into each template file now (during `/flow-next:work`). Every `_CLAUDE.md` directive below must appear as actual prose **in `templates/_CLAUDE.md`** — NOT as a pointer to this spec. At `/init-project` runtime the engine only copies + substitutes `{{PLACEHOLDER}}` tokens, so anything not written here will simply be missing from new projects.

**Size:** M
**Files:** `src/init-project/templates/CLAUDE.md`, `src/init-project/templates/docs/tdd.md`, `src/init-project/templates/docs/dev-container.md`, `src/init-project/templates/.gitignore`

## Approach
- **CLAUDE.md** — keep root-layout table, "default new dirs to etc/" rule, and the Standards-index pattern (always-on TOC → `docs/<topic>.md`). Remove `main.md:5` H&G/play.sh/`platform/<name>-cli`, and the `docs/business.md`/`docs/roadmap.md` refs (`main.md:39-41,49-50`). Then ADD:
  - A statement that the project is a **mono-repo containing every component of the software system**.
  - The **`src/<component>/` ↔ `config.json systems[]`** invariant (one folder + one entry per component; dispatcher routes under `src/<component>/`).
  - An **agent-behavior** section with three directives: **brevity / DRY (don't repeat yourself)**, **brutal honesty**, **always verify before making claims**.
  - A **git-commit policy** directive (R21): never commit to the `main`/default branch without explicit user instruction — if a changeset seems commit-worthy on `main`, **ask the user first**; commit freely on non-default branches; **always `push` after any commit, on any branch**; **name new branches `change/<description-of-change>`** — description only, never prefixed with the epic/spec id (e.g. `change/dick-ballsy-in-project-setup-skill-dick`, not `change/fn-1-dick-...`); **create worktrees under a top-level `.worktrees/` directory**. Keep the worktree instruction adjacent to the commit instructions.
- **tdd.md** — keep 100% line+branch coverage rule, "restructure to test" ethos, tooling-table pattern. Remove Unity/`coverlet`/`MonoBehaviour`/`games/` and `play.sh`/`system.sh` carve-outs (`tdd.md:5,15,20,45-46`). **Reconcile with the existing `tdd` plugin** (point at `/tdd` rather than duplicate TDD truth). Fix the stray `". "` typo at `tdd.md:41`.
- **dev-container.md** — keep "all deps live in `.devcontainer/`" principle + the where-each-dep-lands table; remove `platform/<name>-db`/`platform/<name>-api` Postgres examples (`dev-container.md:24,26`); replace the service-container example with the generic observability-stack note (ties to fn-2….5).
- **.gitignore (R22)** — ship a stack-aware starting point: OS noise (`.DS_Store`); `.worktrees/`; .NET (`bin/`, `obj/`, `.vs/`, `*.user`, `[Tt]est[Rr]esults/`); Node/Angular (`node_modules/`, `dist/`, `.angular/`, `coverage/`, `npm-debug.log*`); generated per-component `.env` files (NOT `config.json`, which stays tracked); `.claude/settings.local.json`; `.flow/bin/`. Keep it a sensible, extendable default.

## Investigation targets
**Required:**
- `src/project-init/main.md` — source CLAUDE.md
- `src/project-init/tdd.md` — source testing standard
- `src/project-init/dev-container.md` — source dev-container doc
- `src/tdd/SKILL.md` — existing TDD skill to reconcile against

## Acceptance
- [ ] CLAUDE.md generalized; no H&G/play.sh/platform/business/roadmap refs; Standards index + root layout intact
- [ ] CLAUDE.md states mono-repo-of-all-components and documents the `src/<component>` ↔ `systems[]` invariant
- [ ] CLAUDE.md includes the three behavior directives (brevity/DRY, brutal honesty, verify-before-claims)
- [ ] CLAUDE.md includes the git-commit policy (no commit to main without explicit OK / ask first; free commits on other branches; always push after a commit; branches named `change/<description>` with no epic/spec-id prefix; worktrees under `.worktrees/`, stated next to the commit instructions)
- [ ] A stack-aware `.gitignore` template ships (`.worktrees/`, .NET + Node/Angular output, generated `.env`, OS noise, `.flow/bin/`, local Claude settings; `config.json` not ignored)
- [ ] All `_CLAUDE.md` directives are written as **full verbatim prose in `templates/_CLAUDE.md`** (not pointers); templates are copy-ready so `/init-project` does only placeholder substitution (R23)
- [ ] tdd.md generalized (no Unity/coverlet/games); reconciled with the `tdd` plugin; typo fixed
- [ ] dev-container.md generalized; principle + dep-placement table kept; Postgres examples removed
- [ ] `grep -rE 'H&G|play\.sh|platform-(db|api)|MonoBehaviour|coverlet|games\[' templates/` returns nothing

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

---
satisfies: [R7, R11, R12, R13]
---

## Description
Wire the feature into the always-on docs with **thin pointers only** (the protocol stays in `docs/collaboration.md`): `_CLAUDE.md` Standards-index rows + a short `### Async collaboration` working agreement + the doc-inventory line; the README mention with the PII caveat; the `docs/dev-container.md` hook/identity note; and the three-surface non-overlap cross-references.

**Size:** M
**Files:** `plugins/init-project/templates/_CLAUDE.md`, `plugins/init-project/templates/README.md`, `plugins/init-project/templates/docs/dev-container.md`, `plugins/init-project/templates/docs/todo.md`, `plugins/init-project/templates/docs/priorities.md`

## Approach
- **`_CLAUDE.md`** (append/extend the build-time-complete file — do NOT re-author):
  - Standards index (`:55-69`): add rows for `docs/collaboration.md` (trigger: handing off async work to a teammate / reading-writing a thread inbox / the SessionStart collaboration behavior) and `docs/team.md` (who's who + org chart / identifying yourself).
  - Working agreements (`:103-122`): a new `### Async collaboration` subsection — a thin directive: recognize "get X's input" intents, capture to the teammate's inbox with liberal context, and check your inbox at session start; **pointer to `docs/collaboration.md` only, no protocol detail inline**.
  - "How documentation is organized" (`:140-144`): add `docs/collaboration.md` + `docs/team.md` to the inventory.
- **`README.md`** (`:95-99` docs/layout row): extend to mention the async collaboration protocol + team registry, with the **private-repo/PII caveat** ("thread inboxes are committed — keep this repo private; no secrets/sensitive personal data in threads").
- **`docs/dev-container.md`** (§2 placement table, `:32-41`): note the SessionStart hook location (`.claude/hooks/`, registered in `.claude/settings.json`) and the **per-user git-identity** the feature relies on (same register as the existing per-user-auth note).
- **Three-surface non-overlap (R12):** add a one-line scope boundary to `docs/todo.md` ("async teammate threads live in `docs/collaboration/` — not here") and a mirroring line to `docs/priorities.md` (engineering loose ends → `todo.md`; teammate threads → `collaboration/`).

## Investigation targets
**Required:**
- `plugins/init-project/templates/_CLAUDE.md:50-69,103-122,140-144` — standards-index rule + table, working agreements, doc inventory
- `plugins/init-project/templates/README.md:95-99` — docs/layout row
- `plugins/init-project/templates/docs/dev-container.md:32-49` — placement table + per-user-auth note
**Optional:**
- `plugins/init-project/templates/docs/todo.md:6`, `docs/priorities.md` — existing scope-note style

## Key context
- `_CLAUDE.md` is the thin always-on index (fn-2 R12) — keep the collaboration footprint to a Standards-index row + one short `###` directive; depth lives in `docs/collaboration.md`. Do not inline the protocol.
- Build-time-complete; no `__SCAFFOLD_` literal introduced.

## Acceptance
- [ ] `_CLAUDE.md`: Standards-index rows for `docs/collaboration.md` + `docs/team.md`; a thin `### Async collaboration` working-agreement (pointer-only); doc-inventory updated — existing directives untouched
- [ ] `README.md` mentions the collaboration feature with the **private-repo/PII caveat**
- [ ] `docs/dev-container.md` notes the SessionStart hook location + the per-user git-identity setup
- [ ] `docs/todo.md` and `docs/priorities.md` each carry a one-line boundary cross-referencing the other two surfaces
- [ ] No protocol detail duplicated into `_CLAUDE.md`; no `__SCAFFOLD_` literal

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

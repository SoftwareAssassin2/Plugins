---
satisfies: [R1, R2, R3, R4, R5, R6, R7, R15]
---

## Description
Author the **protocol standard** that is the contract for the whole feature: `docs/collaboration.md` (the full model + behavior), the `docs/team.md` registry stub + schema, and `docs/collaboration/.gitkeep`. This is build-time-complete prose — no runtime LLM-fill. Everything else (the hook, the wiring, the tests) implements against this.

**Size:** M
**Files:** `plugins/init-project/templates/docs/collaboration.md`, `plugins/init-project/templates/docs/team.md`, `plugins/init-project/templates/docs/collaboration/.gitkeep`

## Approach
- **`collaboration.md`** documents, in the existing standards-doc style (`# Title`, `##` sections, relative cross-links, states scope + what it does NOT restate — pattern `docs/tdd.md:1-19`):
  - **Identity:** keyed on `git config --get user.email` (the single match key + the `handle` slug source); `user.name` is a **display value only, never a match key**; hostname a secondary hint; confirm-before-attribute; first-run asks name + who-they-report-to; a **missing `user.email` (even with `user.name` set) = graceful non-attributing state** (dev containers may lack `.gitconfig`). **`handle` must be unique** — registration detects a slug collision (distinct emails → same slug) and stops with a clear disambiguation instruction.
  - **`team.md` format:** a **fixed, hook-parseable markdown table** with columns `handle | name | git-email | computer-name | reports-to` — `handle` is the STORED git-email slug (written at registration, not re-derived by readers), `git-email` is the key, `computer-name` a secondary hint, `reports-to` the org chart.
  - **Handle:** a person's key = a defined **git-email slug** (lowercase; non-`[a-z0-9]` runs → single `-`; trim). Used for inbox filenames + `asker`/`assignee` fields.
  - **Thread/turn/status model (append-only):** a thread lives in `docs/collaboration/<assignee-handle>.md`, opening with a fixed thread-header `## thread:<id> | asker:<handle> | assignee:<handle> | subject:<text>` (asker/assignee never change), then turns each led by an **ASCII** header `### turn <n> | author:<handle> | status:<enum> | <iso-ts>` + free-form body (liberal context). `<n>` = per-thread monotonic counter (ordering key; wall-clock display-only). `status` ∈ `awaiting-assignee | awaiting-asker | resolved`, carried PER TURN; **effective status = the highest-`n` turn's status** (never edited in place). Concurrent same-thread appends → re-pull + re-append (deterministic by `<n>`), never hand-merge. Note the thread-per-file upgrade path.
  - **Status routing:** ONLY the asker resolves; an assignee reply appends `awaiting-asker`; a push-back appends `awaiting-assignee` (unbounded rounds). Routing uses the thread-header `asker`/`assignee` **handles** (slugs, not display names) + the latest turn's status.
  - **Trigger + round-trip:** "we need X's input" → fuzzy-match `team.md` (offer to add) → append a richly-contextual thread; the git round-trip (push → assignee pulls/answers/pushes → asker pulls/resolves-or-pushes-back). Persist resolved answers back to the real artifact (spec/task via flowctl, code, decision doc), not only the thread.
  - **PII caveat:** committed + pushed; permanent in history; **private-repo only**; minimize fields; never write secrets into a thread.
- **`team.md`** ships as a build-time-complete stub: a GitHub-style markdown table — header row + `|---|` separator row + one example row with **obviously-fake placeholder data** (`alice` / `alice@example.com`), columns `| handle | name | git-email | computer-name | reports-to |`, cells trimmed. The hook (.2) parses exactly this table: skip the header + separator rows; the placeholder row never matches a real `user.email`.
- **`collaboration/.gitkeep`** seeds the dir with **real content** (mirror `templates/etc/.gitkeep`'s explanatory comment — not an empty file) and **verify `git ls-files --error-unmatch`** tracks it (the scaffolded `.gitignore` applies in this repo; force-add if a pattern would drop it). Per-person inboxes are operator-created at runtime (NOT shipped), so they never collide with a manifest-owned path.

## Investigation targets
**Required:**
- `plugins/init-project/templates/docs/tdd.md:1-19` — standards-doc authoring style to match
- `plugins/init-project/templates/docs/todo.md:1-13` — tight scope-header convention; the three-surface boundary
- `plugins/init-project/templates/etc/.gitkeep:1-4` — .gitkeep comment convention
**Optional:**
- git-bug data-model (Lamport counter + deterministic replay) for the turn-ordering rationale

## Key context
- Build-time-complete (fn-2 R23): final prose now, only `__SCAFFOLD_*__` token substitution at runtime — and the doc must NOT contain the literal `__SCAFFOLD_` (leftover-token gate fails the build).
- Wall-clock timestamps are display-only; ordering is the per-thread counter (remote clocks/timezones unreliable).

## Acceptance
- [ ] `docs/collaboration.md` defines: git-identity resolution (+ hostname hint, confirm-before-attribute, missing-identity graceful, first-run name + reports-to), the team.md schema, the append-only thread/turn model with per-thread monotonic counter + entry format, the `awaiting-assignee`/`awaiting-asker`/`resolved` machine with **only-asker-resolves** + multi-round push-back, the "get X's input" trigger + liberal-context rule + git round-trip, and the **private-repo/PII caveat**
- [ ] `docs/team.md` ships as a build-time-complete stub: the **fixed markdown table** `handle | name | git-email | computer-name | reports-to` + a marked example row (handle = stored git-email slug)
- [ ] `docs/collaboration/.gitkeep` seeds the dir; no per-person inbox files are shipped
- [ ] `collaboration.md` carries the three-surface boundary: cross-references `docs/todo.md` (my engineering loose ends) and `docs/priorities.md` (business roadmap) as the other two non-overlapping surfaces
- [ ] Authored in the existing standards-doc style; H&G-free; no `__SCAFFOLD_` literal; all three files git-tracked in the plugin repo

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

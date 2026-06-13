---
satisfies: [R7]
---

## Description
Wire the **final, opt-in `/dick` hand-off** into the `/init-project` skill: after the skeleton is scaffolded, offer to boot `/dick` (fn-1) against the fresh project, and degrade gracefully when `/dick` is not installed.

**Size:** S
**Files:** `src/init-project/SKILL.md` (orchestration tail)

## Dependencies
- Task-level: fn-2….1 (skill skeleton must exist). Cross-epic: this spec depends on fn-1 (the `/dick` epic) at the spec level — `/dick` must be a registered skill (fn-1….1) for the happy path.

## Approach
- As the LAST step of the skill, prompt the user: boot `/dick` now? (opt-in, default no surprise actions).
- If yes and `/dick` resolves → invoke it pointed at the scaffolded project.
- If `/dick` is not installed/registered → print a clear, non-fatal message (how to install it later) and exit success. Never hard-fail the scaffold because the optional hand-off is unavailable.

## Investigation targets
**Required:**
- `src/init-project/SKILL.md` (from fn-2….1) — orchestration body to append to
- `src/handoff/SKILL.md` — pattern for one skill referencing/handing to another

## Acceptance
- [ ] `/init-project` offers to boot `/dick` as its final step (opt-in)
- [ ] On accept with `/dick` present, `/dick` is invoked against the scaffolded project
- [ ] On `/dick` absent, the skill emits a clear non-fatal message and still reports overall success

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

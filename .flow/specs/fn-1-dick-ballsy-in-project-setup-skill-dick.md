# Dick Ballsy in-project setup skill (/dick)

## Overview

`/dick` is a **Claude Code skill** (`plugins/dick/`) that boots the **"Dick Ballsy" persona** — a sharp, contrarian **business-architect advisor** fully defined in `plugins/dick/SOUL.md`. Where `/init-project` (fn-2) lays the *technical* skeleton, Dick interrogates the **business** until it is clearly defined and materializes that clarity as durable **business documentation** in the project's `docs/`. He is brutally honest, never flatters, asks **one question at a time**, interrogates vague answers, marks assumptions as bets and unknowns as `TODO`, and **edits the business docs in place then reports exactly what changed**.

`SOUL.md` is the **canonical persona + playbook**; `SKILL.md` is a thin entry point that adopts it. He boots only on an explicit `/dick` call **or** when `/init-project` completes and the user opts to talk to him, and stays **fully in persona until the user says "goodbye."**

## Persona & playbook (source of truth: `plugins/dick/SOUL.md`)
- **Who:** contrarian business advisor (Founder & Managing Partner, Hartwell Strategic Advisors). Brash, blunt, irreverent; total candor; the user is a lifelong friend who wants hard truths, not a cheerleader. Never flatters ("great question", "brilliant" — banned); disagrees when he disagrees.
- **Mission:** interrogate the business → produce a small set of high-signal, **falsifiable** business docs that are the project's source of truth.
- **Interview discipline:** one question at a time; lead with the kill/validate questions (who exactly is the customer? what do they do today instead? why switch? what's the wedge?) before anything cosmetic; interrogate vague answers ("enterprises" is not a customer); surface assumptions explicitly as bets.
- **Refuses to:** fabricate docs (an empty `## TODO` beats a fabricated section), gold-plate, invent metrics/customers/traction, or bury the lede in formatting.
- **Candor targets the work, not the person:** Dick attacks weak assumptions and bad reasoning, **never the user**. Brash truth-teller, not hostile — anchored to objective truth and permission to disagree, not to performative insult.

## Business docs Dick owns (in the project's `docs/`)
Per SOUL.md, default set (create more only with real reason):
- `business.md` — what the business is, the problem, the customer, the wedge, why now
- `strategy.md` — how it wins: positioning, differentiation, the moat, what we deliberately do NOT do
- `customers.md` — specific segments, their current alternative, the switching trigger
- `priorities.md` — ranked list of what matters now and why (the most-used doc; kept ruthless)
- `decisions.md` — running log of key calls, reasoning, and what would reverse them

These are **Dick's** business docs and are **distinct** from flow-next's repo-root `STRATEGY.md` and `.flow/memory/knowledge/decisions/` (despite the similar names — Dick writes only under the project's `docs/`).

## Quick commands
```bash
jq -e '.plugins[] | select(.name=="dick")' .claude-plugin/marketplace.json
head -5 plugins/dick/SKILL.md          # frontmatter: name: dick
test -f plugins/dick/SOUL.md           # persona/playbook present
```

## Boundaries / non-goals
- **NOT a technical scaffolder** — `/init-project` (fn-2) creates the skeleton, dev container, CLIs, code, and the empty doc homes. Dick does none of that.
- **NOT the neutral assistant** — `/dick` is a persona-locked session, not a general helper.
- Dick edits **business** docs only (the set above), in place, and reports changes; he never fabricates content to fill a section.
- He does not touch technical standards docs (config-management, tdd, dev-container, front-end, keycloak, architecture, ubiquitous-language) — those are fn-2's domain.

## Session model
- **Boot triggers:** explicit `/dick` invocation, OR a `/init-project` completion opt-in ("want to talk to Dick?").
- **Persona lock + soft off-ramp:** on boot the agent adopts the SOUL.md persona and stays fully in character across every turn until the user says **"goodbye"** OR otherwise clearly signals an exit (e.g. "stop", "drop the act") or makes a genuine help/safety request — then exits the persona. The persona is a *style*, never a license to ignore the user; the off-ramp is mandatory, not just the literal "goodbye."

## Decision context
- **SOUL.md is authoritative** for persona + playbook; SKILL.md is a thin adopter that loads it. Keeps the personality/behavior in one editable place.
- **Edit-in-place + report** (per SOUL.md) — overrides the earlier "propose, then apply on approval" idea; Dick updates docs after a substantive session and tells the user exactly what changed.
- **Doc ownership split:** Dick owns the business-doc set; `/init-project` only scaffolds the **empty TODO-stub homes** for them (no fabricated content), and `roadmap.md` is **dropped** in favor of `priorities.md`. Clean ownership, no duplicate strategy surfaces.
- **Business consultant, not coder:** the value is sound judgment under uncertainty — picking the right problem before solving any problem well, forcing a ranking when everything feels urgent.

## Acceptance Criteria
- **R1:** `/dick` is a registered, invocable skill — `plugins/dick/SKILL.md` exists with valid frontmatter (`name: dick`) and a `dick` entry is present in `.claude-plugin/marketplace.json`.
- **R2:** Invoking `/dick` runs Dick's business-interrogation interview per `plugins/dick/SOUL.md` (kill/validate questions first, one at a time), not a generic setup wizard.
- **R3:** `/init-project` (fn-2) can invoke `/dick` as its final step and Dick operates correctly against a freshly scaffolded project; if `/dick` is unavailable the caller degrades gracefully. The **hand-off contract** is documented in `SKILL.md`: the invocation form, an optional business-context argument, and graceful behavior when no context is supplied (Dick starts fresh from the kill/validate questions). **This epic owns the contract + invocability only**; the caller-side hook (passing context, degrading gracefully when `/dick` is absent) is implemented in **fn-2….7** — an external dependency tracked by fn-2's dependency on this epic, not part of this epic's acceptance.
- **R4:** On boot the skill **adopts the Dick persona from `plugins/dick/SOUL.md`** (brash, contrarian, brutally honest, never flatters) and remains in persona across turns **until the user says "goodbye" OR otherwise clearly signals exit / a genuine help or safety request** (mandatory soft off-ramp — persona is style, not a trap).
- **R5:** Dick asks **one question at a time**, leads with the business kill/validate questions, interrogates vague answers, and **marks assumptions as bets / unknowns as `TODO`** — never fabricating content to fill a doc. (One-question rule applies to *interview* turns; **doc-change report turns and exit turns are exempt** — a report or a goodbye need not end in a question.)
- **R6:** Dick creates/maintains the business-doc set in the project's `docs/` — `business.md`, `strategy.md`, `customers.md`, `priorities.md`, `decisions.md` — **editing in place** and **reporting exactly what changed** after a substantive session.
- **R7:** Boot triggers are limited to an explicit `/dick` invocation OR a `/init-project` completion opt-in (no auto-launch). The skill `description` is **narrowly gated** ("use only when the user explicitly invokes `/dick` or accepts the `/init-project` hand-off") rather than trigger-rich, and the same gate is restated in the `SKILL.md` body — accepting this is convention-level (skill-selection has no hard trigger-only primitive).

## Early proof point
Task fn-1….1 proves the skill is registerable and invocable, and that the SOUL.md persona loads (the contract fn-2 depends on). If registration/invocation/persona-load doesn't work, the fn-2 hand-off is moot before investing in fn-1….2's interview behavior.

## Resolved via Codebase
- `plugins/dick/SOUL.md` (user-authored, full read) is the canonical persona + playbook: defines Dick's voice, mission, interview discipline, refusals, the 5-doc business set (business/strategy/customers/priorities/decisions), and doc conventions (prose-first, falsifiable, mark bets/TODOs, edit-in-place, report changes). The spec above derives from it.
- `plugins/dick/` currently contains only `SOUL.md` — `SKILL.md` + marketplace registration still to be built (fn-1….1).

## Open Questions
- **Persona docs vs flow-next surfaces:** Dick's `docs/strategy.md` + `docs/decisions.md` share names with flow-next's repo-root `STRATEGY.md` and `.flow` decisions. Confirm at build time that the naming coexists cleanly (Dick stays under `docs/`), or rename if it proves confusing.

## Requirement coverage

| Req | Description | Task(s) | Gap justification |
|-----|-------------|---------|-------------------|
| R1  | Registered, invocable `/dick` skill | fn-1….1 | — |
| R2  | Business-interrogation interview per SOUL.md | fn-1….2 | — |
| R3  | Hand-off contract + invocability (+ fixture behavior); caller-side hook external | fn-1….1, fn-1….2 | `.1` = contract + invocability; `.2` = "operates correctly" via fixture run. Caller-side hook is **external** (fn-2….7) |
| R4  | Persona adopted from SOUL.md, locked until "goodbye" | fn-1….1, fn-1….2 | — |
| R5  | One-question interview discipline, no fabrication | fn-1….2 | — |
| R6  | Owns/maintains the 5 business docs, edit-in-place + report | fn-1….2 | — |
| R7  | Boot triggers limited to /dick or /init-project opt-in | fn-1….1 | — |

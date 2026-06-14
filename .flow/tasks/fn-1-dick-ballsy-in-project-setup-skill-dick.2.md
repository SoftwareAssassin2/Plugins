---
satisfies: [R2, R4, R5, R6]
---

## Description
Author the `/dick` SKILL.md behavior body — the prose that turns the loaded SOUL.md persona into a working, persona-locked, one-question-at-a-time business-discovery interview that maintains Dick's business docs. SOUL.md carries the substance; this task writes the operating instructions that orchestrate it.

**Size:** M
**Files:** `plugins/dick/SKILL.md` (behavior body; depends on fn-1….1 skeleton)

## Approach
- **Persona adoption + lock (R4):** read `SOUL.md` and fully adopt the Dick persona on boot; stay in character across turns until the user says **"goodbye"** OR otherwise clearly signals exit / a genuine help or safety request (mandatory **soft off-ramp** — honor "stop", "drop the act", etc.; the persona is a style, never a license to ignore the user). Persona-lock is convention-only and drifts (worse over long sessions) — so front-load the persona, re-inject a short in-voice line at the top of each interview / doc-update **response** (**in the assistant's reply only — NEVER written into the business docs**, which stay prose-first and falsifiable per SOUL.md), and treat drift as contradicting SOUL.md's fixed persona facts.
- **Interview discipline (R5):** hard rule — *interview* turns end with exactly ONE question; self-check "if it reads as two, split it." **Exceptions:** doc-change report turns and exit/goodbye turns need NOT end in a question. Lead with SOUL.md's kill/validate questions before anything cosmetic; interrogate vague answers; surface assumptions as bets. Interview runs **main-thread only** — `AskUserQuestion` is unavailable in subagents, so the interview can't run headless (a consult-only read is fn-2's R20, a different thing).
- **Anti-sycophancy + candor line (R4/R5):** anchor candor to objective truth and explicit permission to disagree, NOT a "be mean" instruction. State explicitly: **Dick attacks weak assumptions and bad reasoning, not the user.** Brash truth-teller, not hostile.
- **Business-doc maintenance (R6):** maintain `docs/{business,strategy,customers,priorities,decisions}.md` — read-before-write, edit-in-place (never regenerate/duplicate), mark `[BET]`/`[TODO]` for anything not asserted by the user, never fabricate to fill a section, and after a substantive session report a diff of exactly what changed in which file.

## Investigation targets
**Required:**
- `plugins/dick/SOUL.md` — persona + playbook to orchestrate (reference + operationalize; do not duplicate)
- `plugins/grill-me/SKILL.md:6-10` — closest in-repo one-question interview analog
- `.flow/specs/fn-1-dick-ballsy-in-project-setup-skill-dick.md` — R2/R4/R5/R6, Persona & playbook, Session model

## Key context
- Prose, not code — no unit tests/coverage. Verify **behaviorally against a throwaway fixture project** (a temp scaffolded dir), NOT this repo: the `docs/*.md` edits land in that fixture (not committed here), which resolves the "live run edits docs outside task scope" concern — fn-1….2 only modifies `plugins/dick/SKILL.md`; the doc writes happen in the fixture at verification time.

## Acceptance
- [ ] SKILL.md instructs full SOUL.md persona adoption, persona-locked across turns until "goodbye" **or other clear exit/help/safety intent** (mandatory soft off-ramp); the in-voice re-injection appears only in assistant replies, never inside `docs/*.md`
- [ ] Encodes the one-question-per-interview-turn rule (+ self-check) and kill/validate-first ordering, with explicit exemptions for report turns and exit turns; interview is main-thread-only
- [ ] Candor anchored to truth/permission-to-disagree, with the explicit line "attacks weak assumptions, not the user" — no sycophancy fallback, no performative insult
- [ ] Defines business-doc maintenance: read-before-write, edit-in-place, mark bets/TODOs, no fabrication, per-session diff report
- [ ] Behavior verified by a live run **against a throwaway fixture project**: boots in persona, asks one question, updates a `docs/*.md` in the fixture + reports what changed, exits cleanly on "goodbye" or other clear exit intent

## Done summary
Authored SKILL.md behavior body: SOUL.md persona-lock + mandatory soft off-ramp; one-question interview discipline (kill/validate first, report/exit exempt, main-thread-only); candor-not-cruelty (attacks assumptions not the user); business-doc maintenance for docs/{business,strategy,customers,priorities,decisions}.md (read-before-write, edit-in-place, mark [BET]/[TODO], no fabrication, per-session diff; in-voice line only in replies).
## Evidence
- Commits:
- Tests:
- PRs:
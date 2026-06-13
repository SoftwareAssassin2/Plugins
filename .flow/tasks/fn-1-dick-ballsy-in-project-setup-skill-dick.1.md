---
satisfies: [R1, R3, R7]
---

## Description
Scaffold and register the `/dick` skill skeleton so it's a real, invocable Claude Code skill that loads the existing `src/dick/SOUL.md` persona. This is the contract `/init-project` (fn-2) depends on, and the spec's early proof point. No behavior prose yet beyond the SOUL.md load hook + hand-off contract (full behavior is fn-1….2).

**Size:** S
**Files:** `src/dick/SKILL.md` (new), `src/dick/.claude-plugin/plugin.json` (optional), `.claude-plugin/marketplace.json`

## Approach
- SKILL.md frontmatter per repo convention (`src/handoff/SKILL.md:1-5`): `name: dick`, an `argument-hint`, and a **narrowly-gated** `description` — "use only when the user explicitly invokes `/dick` or accepts the `/init-project` hand-off" (NOT a trigger-rich description; a broad one risks opportunistic auto-invocation, which R7 forbids). Restate the same gate in the SKILL.md body. This is convention-level — skill selection has no hard trigger-only primitive.
- Reference the persona one level deep using the repo idiom (`src/tdd/SKILL.md:16`): relative bare-filename link `[SOUL.md](SOUL.md)` + explicit "read SOUL.md and adopt the persona" (read-as-reference, not execute). Keep SKILL.md < 500 lines.
- **Hand-off contract (R3):** document in SKILL.md how `/init-project` invokes `/dick` — the invocation form, an OPTIONAL business-context argument, and graceful behavior when no context is supplied (Dick starts fresh from the kill/validate questions). Define enough that fn-2….7 can rely on more than "skill exists."
- **Do NOT set `disable-model-invocation`** — fn-2….7 must boot `/dick` via the Skill tool.
- Register in `.claude-plugin/marketplace.json` using the local-source string form (`src/ubiquitous-language` entry `:25-30`): `{ name: "dick", displayName: "Dick", description: "...", source: "./src/dick" }`.
- `plugin.json` optional (only `ubiquitous-language` has one). Include mirroring `src/ubiquitous-language/.claude-plugin/plugin.json` for consistency, or skip.

## Investigation targets
**Required:**
- `src/handoff/SKILL.md:1-5` — frontmatter + argument-hint exemplar
- `src/tdd/SKILL.md:16` — sibling-file reference idiom
- `.claude-plugin/marketplace.json:25-36` — local-source entry shape
- `src/dick/SOUL.md` — the persona/playbook this skill loads

## Key context
- `marketplace.json` is also edited by fn-2 (registers `init-project`) — coordinate to avoid a merge conflict.
- Persona-lock is convention, not a Claude Code primitive; this task only wires invocation + the SOUL.md load + the hand-off contract. The lock/behavior lives in fn-1….2.

## Acceptance
- [ ] `src/dick/SKILL.md` exists with valid frontmatter (`name: dick`, `argument-hint`, a **narrowly-gated** description) and instructs the agent to read+adopt `[SOUL.md](SOUL.md)`
- [ ] SKILL.md documents the `/init-project` hand-off contract (invocation form, optional business-context arg, graceful no-context behavior)
- [ ] `dick` entry added to `.claude-plugin/marketplace.json` (`source: "./src/dick"`); `disable-model-invocation` NOT set
- [ ] **Verification evidence:** `jq -e '.plugins[]|select(.name=="dick")' .claude-plugin/marketplace.json` passes; `head -5 src/dick/SKILL.md` shows `name: dick`; a manual reload + `/dick` invocation transcript confirms runtime availability
- [ ] (If included) `src/dick/.claude-plugin/plugin.json` mirrors the ubiquitous-language manifest shape

## Done summary
Scaffolded + registered /dick: SKILL.md (name: dick, narrowly-gated description, reads+adopts SOUL.md, hand-off contract), dick entry in marketplace.json (source ./src/dick), plugin.json manifest. No disable-model-invocation so /init-project can boot it.
## Evidence
- Commits:
- Tests:
- PRs:
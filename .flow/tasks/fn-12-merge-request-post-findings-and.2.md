---
satisfies: [R3, R4, R5, R6, R7, R9]
---
## Description
Add the learned-preferences loop: a propose-then-confirm mechanism writing to a global base + optional project override with a keyed merge model, capturing four preference classes, with the inference heuristics for skip / edit / approve.

**Size:** M
**Files:** `plugins/merge-request/skills/post-findings/SKILL.md` (extends fn-12.1), `plugins/merge-request/skills/post-findings/scripts/merge-prefs.sh`

## Approach
- At session end, propose preference updates inferred from approve/edit/skip; write only after per-item confirmation.
- Inference heuristics: a skip -> propose a `## Don't raise` candidate on the first skip (repeated same-key skips increment `count` confidence); an edit -> propose a generalized `## Wording` preference (the phrasing rule, not a verbatim example); an approve of a borderline / previously-flagged finding -> propose `## Confirmed valued`.
- **Storage + merge model:** global base `~/.claude/merge-request-preferences.md` + optional project override `.data/merge/preferences.md`. Every entry has a normalized `key` (Don't-raise: rubric-category + normalized pattern; Wording: phrasing-rule id; Confirmed-valued: rubric-category + pattern; Rubric-weighting: flag name). Same-key project entry REPLACES the global entry; different keys UNION. Don't-raise entries carry a `count` (confidence); "similar" = same key.
- **Write scope:** each confirmed preference is written to global OR project — the confirm prompt includes the scope choice and names the target file; default project-override for Don't-raise, global for Wording, overridable per item.
- Capture `## Don't raise` / `## Wording` / `## Confirmed valued` (inferred) and `## Rubric weighting` (**merge/preserve-only — not inferred by any interaction**; user-edited directly, merged by the same keyed model).
- **`## Declined` write (fulfils the ARTIFACT.md contract + fn-12.1's forward-reference):** when the user skips a finding at the post gate, append it to the `## Declined` section of `.data/merge/<ID>.md` (finding `F-<hash>` id + one-line summary + a short "declined at post gate" rationale), append-only, preserving every other section. This is the post-findings half of the shared `## Declined` section (fix/fn-10 owns the other half); it is distinct from — and complements — the skip→Don't-raise preference proposal.
- **Boundary:** this task OWNS the learned-preferences file + merge model AND the post-findings `## Declined` append. The review-side consumption of the merged prefs file is implemented in fn-11.3 (this task does not edit review's SKILL.md).

## Investigation targets
**Required:**
- `~/.claude/skills/gitlab-mr-review/SKILL.md` -- reading `~/.claude/gitlab-mr-feedback-preferences.md` (Don't-raise / Wording / Confirmed-valued) prior art
- `~/.claude/skills/gitlab-mr-feedback/SKILL.md` -- how the prior art learns/writes preferences
- `plugins/merge-request/ARTIFACT.md` -- finding schema (keys reference finding pattern) from fn-11.1

## Verification
- Fixture mode for `merge-prefs.sh`: given a global + project prefs file, assert same-key project entry replaces global, different keys union, a proposed Don't-raise increments `count` on a repeated same-key skip, and a confirmed write lands in the scope chosen at the prompt (global vs project). No writes without the confirm step (simulated confirm input).

## Acceptance
- [ ] Propose-then-confirm: infers updates from approve/edit/skip and writes only after per-item confirmation.
- [ ] A skip proposes a Don't-raise on the first skip; an edit proposes a generalized Wording preference; an approve of a borderline finding proposes Confirmed valued.
- [ ] Preferences live in a global base + optional project override with the keyed merge model (same-key project replaces global, different keys union); Don't-raise carries a `count` confidence; each confirmed write is scoped (global vs project) at the confirm prompt.
- [ ] Captures `## Don't raise` / `## Wording` / `## Confirmed valued` (inferred) with normalized keys; `## Rubric weighting` is merge/preserve-only (not inferred). The review-side consumption is delivered by fn-11.3 (not edited here).
- [ ] A skipped finding is appended to the `## Declined` section of `.data/merge/<ID>.md` (id + summary + rationale, append-only, other sections preserved) — fulfilling the ARTIFACT.md shared-`## Declined` contract that fn-12.1 forward-referenced here.

## Done summary
Added the post-findings learned-preferences loop: a new scripts/merge-prefs.sh implementing the keyed merge model (same-key project override replaces global, different keys union), scoped propose-then-confirm upsert with a Don't-raise count confidence, merge/preserve-only Rubric weighting, and the append-only ## Declined record fulfilling the ARTIFACT.md shared contract. Extended post-findings SKILL.md with Step 7 (skip->Don't raise, edit->Wording, approve->Confirmed valued; skip also writes ## Declined) and added merge-prefs_test.sh (68 cases). SOUL.md unchanged.
## Evidence
- Commits: 9980409, 7b3b7ea, d2285a5
- Tests: bash plugins/merge-request/skills/post-findings/tests/merge-prefs_test.sh (68 passed), bash plugins/merge-request/skills/post-findings/tests/post-findings_test.sh (83 passed), bash plugins/merge-request/skills/review/tests/*.sh (96 passed), shellcheck merge-prefs.sh + merge-prefs_test.sh (clean), codex impl-review: SHIP
- PRs:
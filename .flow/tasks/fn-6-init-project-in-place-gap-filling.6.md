---
satisfies: [R12]
---

## Description
Correct all documentation that describes the retired greenfield/refuse-on-non-empty behavior, and revise the fn-2 spec's R2/R6 + two-mode prose to point at this in-place gap-fill model. (Most scaffolded `templates/docs/*` need NO change per docs-gap analysis — they describe the generated project, not the scaffolder.)

**Size:** S
**Files:** `.flow/specs/fn-2-init-project-scaffolding-skill-init.md`, `.flow/tasks/fn-2-init-project-scaffolding-skill-init.1.md`, `.flow/tasks/fn-2-init-project-scaffolding-skill-init.6.md` (scaffold.sh header + SKILL.md frontmatter are handled in .1/.2/.4)

## Approach
- **fn-2 spec:** revise R2 (`:89` "scaffolds ./<project-name>/"), R6 (`:93` "refuse non-empty target unless --force/--update"), the Decision-context two-mode bullet (`:67`), the Early-proof-point line (`:120`), and the R2/R6 requirement-coverage rows (`:144,148`) — each updated to the in-place gap-fill model with a note "revised by fn-6". Do NOT renumber R-IDs.
- **fn-2 task prose:** fn-2.1 (`:6,14,27-31`) and fn-2.6 (`:18`) describe creating `./<name>/` + refuse-non-empty/`--force`; annotate as superseded by fn-6 (these tasks are already done — annotate, don't rewrite history destructively).
- Verify the scaffolded `templates/docs/*` (dev-container.md, config-management.md, _CLAUDE.md, README.md) need no change (docs-gap found none reference scaffold modes/target) — confirm and note.

## Investigation targets
**Required:**
- `.flow/specs/fn-2-init-project-scaffolding-skill-init.md:67,89,93,120,144,148` — the stale R2/R6/decision lines
- `.flow/tasks/fn-2-init-project-scaffolding-skill-init.1.md`, `.6.md` — stale task prose
**Optional:**
- `plugins/init-project/templates/README.md:62-89` — the `--local-llm` mention (stays valid)

## Acceptance
- [ ] fn-2 spec R2, R6, the `:67` two-mode prose, the early-proof line, and the R2/R6 coverage rows revised to the in-place gap-fill model, annotated "revised by fn-6"; R-IDs not renumbered
- [ ] fn-2.1 + fn-2.6 task prose annotated as superseded by fn-6 (non-destructive)
- [ ] Confirmed (with note) that `templates/docs/*` need no scaffold-behavior change
- [ ] `flowctl validate --spec fn-2-init-project-scaffolding-skill-init` and `--spec fn-6-init-project-in-place-gap-filling` both clean

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

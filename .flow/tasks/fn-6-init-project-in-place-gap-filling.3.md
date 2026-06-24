---
satisfies: [R10, R14]
---

## Description
Ensure the fn-3 `--local-llm` opt-in composes with the gap-fill engine and that fn-3's delivered contracts (subtree, config precedence, gated reset, jq boundary) don't regress.

**Size:** M
**Files:** `plugins/init-project/scaffold.sh`

## Approach
- The `_optional/local-llm/` subtree (appended behind `--local-llm`, `:183-189`, remapped to `etc/local-llm/` by `target_rel`) flows through the SAME classification + apply path — its files gap-fill/skip/conflict-resolve like the rest; no special-case bypass.
- **config.json precedence (R10), explicit ordering:** (1) base structured-merge preserves operator edits + existing secrets; (2) when `--local-llm` is set THIS run, its mutation (`:284-297`) is applied **last and wins** — so a user can opt in later or change the model; (3) the non-opt-in reset (`:312-326`, drop localLlm, restore real-provider URLs) applies **only** when prior-opt-in manifest evidence (`prior_llm_files`, `:229-234`) exists AND `--local-llm` is absent. Never reset on flag-absence alone (`scaffold-update-reset-must-be-gated` bug).
- Orphan `etc/local-llm/` prune on non-opt-in re-run (`:341-346`) is the **`retired` status** — manifest-recorded, present, absent from the current (non-opt-in) plan → pruned, but ONLY when **manifest-owned AND hash == recorded**. A user-edited prior local-LLM file is `retired-conflict` → kept by default, never silently deleted.
- **jq boundary (R14):** only `--apply --local-llm` preflights jq (it mutates config); `--plan --local-llm` writes nothing and stays **jq-free**. Ensure no other new jq requirement vs a plain scaffold.

## Investigation targets
**Required:**
- `plugins/init-project/scaffold.sh:183-189,229-234,284-346` — local-llm append, reset-gating, mutation, prune
- `.flow/specs/fn-3-local-llm-mock-stack-for-init-project.md` — R5 (`_optional/` subtree, removable), R6 (both services present), R8 (removal)
**Optional:**
- `plugins/init-project/templates/_optional/local-llm/` — the opt-in subtree

## Acceptance
- [ ] `--local-llm` files flow through gap-fill classification/apply (no special-case bypass)
- [ ] config.json precedence holds: base-merge preserves operator data; current-run `--local-llm` mutation wins (opt-in/model-change works on re-run); reset only when prior-opt-in manifest evidence exists + flag absent
- [ ] A never-opted-in project is never reset; orphan `etc/local-llm/` prune (the `retired` path) touches only manifest-owned paths with hash==recorded; a user-edited prior local-LLM file (`retired-conflict`) is kept
- [ ] fn-3 removal story (R8) stays coherent under the new default
- [ ] jq required only by `--apply` config.json merge / `--apply --local-llm`; `--plan --local-llm` is jq-free; `shellcheck`+`bash -n` clean

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

---
title: "Scaffold --update reset must be gated on prior-opt-in evidence, not flag absence"
date: "2026-06-15"
track: bug
category: data
module: plugins/init-project/scaffold.sh
tags: [scaffold, init-project, idempotent-update, config, opt-in, local-llm]
problem_type: data
symptoms: non-opt-in --update clobbered operator-customized provider keys/URLs back to REPLACE_ME / real-provider defaults
root_cause: the local-LLM reset fired for every non-opt-in --update instead of only over a prior opt-in
resolution_type: fix
---

## Problem
When adding a scaffold-time `--local-llm` opt-in to the init-project engine, the
"opt-in is not sticky" reset I added (restore real-provider base URLs/keys + drop
the `localLlm` block on a non-opt-in `--update`) ran for EVERY non-opt-in `--update`
— including a project that was NEVER opted into local-LLM but whose operator had
hand-customized `services.claude-api`/`openai-api` keys + base URLs. The reset
clobbered those operator edits back to `REPLACE_ME` / real-provider defaults,
silently violating the engine's existing `--update` "existing values win" contract.

## What Didn't Work
The first fix made the reset unconditional (`local_llm==0 && mode==update &&
out==config.json`). It correctly cleaned up a prior opt-in, but had no notion of
"was this project ever opted in?", so it also reset configs that should have been
preserved.

## Solution
Gate the reset on prior-opt-in EVIDENCE: the prior `.init-project-manifest.json`
listing `etc/local-llm/` files (only the opt-in path ever writes those). Capture
those paths BEFORE the loop rewrites the manifest, and fire both the config jq
reset AND the orphaned-file removal only when that list is non-empty. A
never-opted-in project's plain `--update` then preserves its config; a prior
opt-in still fully resets. plugins/init-project/scaffold.sh — `prior_llm_files`
capture + the `${#prior_llm_files[@]} -gt 0` gate on the reset branch.

## Prevention
When a scaffold/idempotent-apply engine adds a "reset to default" path, gate it on
explicit evidence that the prior state was the thing being reset — never reset
unconditionally on the absence of a flag, because the same config keys may be
legitimately operator-owned in the non-feature case. Add a regression test for the
"never had the feature + operator-customized the shared keys → update preserves
them" case, not just the "feature on → feature off" case.

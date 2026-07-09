---
title: "Forge triage: || true swallowed listing/CLI failures; die in $(subshell) didn't "
date: "2026-07-09"
track: bug
category: runtime-errors
module: plugins/merge-request/skills/review/scripts/triage.sh
tags: [bash, forge, gh, glab, error-handling, subshell, silent-failure, dependency-check]
problem_type: runtime-error
symptoms: "Batch review reports zero open PRs/MRs on an auth/network error, and single-ID review degrades to empty head SHA when the forge CLI is missing — both silently skip the review"
root_cause: "|| true swallowed forge CLI failures (only per-PR probes should degrade); die inside ids=$(list_ids) exited only the subshell; single-ID scope bypassed the CLI dependency check"
resolution_type: fix
related_to: [bug/runtime-errors/merge-requestcreate-pushed-to-origin-2026-07-09, bug/runtime-errors/mkdir-lock-helpers-released-a-lock-they-2026-07-08]
---

## Problem
Two related silent-failure bugs in the forge-agnostic triage script (`triage.sh`, the
review engine). (1) The batch list path used `gh pr list ... || true` / `glab mr list | jq ... || true`, so an auth/network/API failure was swallowed and reported as **zero open PRs/MRs** — every review silently skipped, contradicting the script's own exit contract (listing failure = operational failure; only per-PR metadata probes may degrade). (2) Single-ID scope bypassed the `gh`/`glab` dependency check (only the batch branch had it), so a missing CLI degraded `resolve_meta` (which runs `gh pr view ... || true`) to empty metadata and silently skipped the "fetch head SHA before checkout" skip-gate.

## What Didn't Work
First fix added `die` inside `list_ids`, but `list_ids` was called as `ids="$(list_ids)"` — a command substitution runs in a SUBSHELL, so `die`'s `exit` only killed the subshell and the parent continued with an empty id list (the swallow persisted).

## Solution
- Distinguish "empty result" (success) from "command failed": capture the command's own exit via `out="$(gh ...)" || die` (and for gitlab capture glab's status separately from jq's by staging JSON in a var first). `triage.sh:150-170`.
- Invoke the lister via a REDIRECT, not command substitution — `list_ids > "$ids_tmp"` runs in the current shell so `die` exits the whole script; then `while IFS= read -r one; do ... done < "$ids_tmp"`. `triage.sh:206-212`.
- Enforce the forge CLI dependency ONCE up front (after forge validation), covering both single-ID and batch scope, rather than only inside the batch branch. `triage.sh:~55`.

## Prevention
- Ban bare `|| true` on forge/CLI calls whose failure should be fatal — only degrade the specifically-allowed probe (per-PR metadata), and comment why.
- Never `die`/`exit` from a function invoked via `$(...)`; use a redirect-to-file (`func > tmp`) or check `$?` after the substitution.
- Enforce hard dependencies before ANY code path branches on scope, not per-branch.
- Test both forges for: listing-failure-is-fatal, and missing-CLI-is-fatal (isolated PATH without the CLI).

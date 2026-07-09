---
title: merge-request:create pushed to origin instead of the tracked upstream (fork left
date: "2026-07-09"
track: bug
category: runtime-errors
module: plugins/merge-request/skills/create/scripts/create.sh
tags: [git, upstream, push, fork, remote, bash]
problem_type: runtime-error
symptoms: "branch ahead of a fork upstream got pushed to origin, leaving the tracked upstream stale"
root_cause: "ahead-check keyed off @{u} but push targeted an origin-preferred remote, not the upstream's remote/ref"
resolution_type: fix
related_to: [bug/runtime-errors/mkdir-lock-helpers-released-a-lock-they-2026-07-08]
---

## Problem
In the merge-request:create helper, the "ensure HEAD is on the remote" step
checked whether the branch was ahead of its upstream via `@{u}`, but then pushed
to a remote resolved by a helper that prefers `origin`. When the branch tracks an
upstream on a different remote (e.g. a fork: `fork/feature`), the push went to
`origin` and left the actual tracked upstream stale — so the PR/MR could be
opened against stale remote state.

## Solution
When the upstream exists and the branch is ahead, resolve the upstream's own
remote and ref from branch config (`git config branch.<b>.remote` /
`branch.<b>.merge`, stripping `refs/heads/`) and `git push "$up_remote"
"HEAD:$up_ref"`. Fall back to a bare `git push` (git's own upstream resolution)
when config is absent, never guessing origin.
plugins/merge-request/skills/create/scripts/create.sh (ensure-pushed block).

## Prevention
When a decision is keyed off `@{u}`, the corresponding action must also target
`@{u}`'s remote/ref — never a separately-resolved "preferred" remote. A
fork-remote test (upstream on `fork`, assert push lands on `fork`, not `origin`)
catches the regression.

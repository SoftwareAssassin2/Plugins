---
title: "Forge feedback-gather: paginate every (nested) connection; no empty dedupe-key c"
date: "2026-07-09"
track: bug
category: integration
module: plugins/merge-request/skills/fix/scripts/gather-feedback.sh
tags: [github, gitlab, graphql, pagination, dedupe, fingerprint, bash, security]
problem_type: integration
symptoms: PR feedback silently dropped past first page; different CI failures suppressed by a prior ledger record; non-numeric --id could write outside .data/merge
root_cause: "Un-paginated forge API connections (nested comments included) plus an empty error-signature placeholder in the CI fingerprint, and an unvalidated id used as a path component"
resolution_type: fix
---

## Problem
The `/merge-request:fix` feedback gatherer (`gather-feedback.sh`) fetches PR/MR
comments, review threads, and CI failures, then dedupes them against a durable
ledger. Two correctness defects and one hardening gap surfaced in review:

1. **Un-paginated forge connections dropped feedback.** GitHub review threads
   were fetched with `reviewThreads(first:100)` and nested `comments(first:50)`
   with no pagination — a busy PR silently lost threads past 100, and a long
   thread lost replies past the cap. Since the thread `content_hash` is built
   from the comment bodies, a dropped tail also means an edited/new late reply is
   never detected as "changed".
2. **Empty placeholder in a logical dedupe key.** The GitHub CI fingerprint was
   `sha1(forge|job|commit|"")` — the required normalized-error-signature
   component was hardcoded empty. Two *different* failures of the same job at the
   same commit collapsed to one fingerprint, so a prior `reported`/`non-actionable`
   ledger record suppressed a genuinely new failure.
3. **Path-component id, unvalidated.** `stash_path="${data_dir}/${id}.md"` used
   `--id` verbatim; a malformed `--id ../../evil` would let `record`/`ledger`
   write outside `.data/merge`.

## Solution
- Paginate **every** connection, nested included. Top-level: `gh api graphql
  --paginate` with `pageInfo{hasNextPage endCursor}` + `after:$endCursor`. Nested
  comments: request the first page's `pageInfo` inline, then for any thread with
  `hasNextPage` pull the rest via a per-thread `node(id:)` query loop
  (`_gh_rest_comments`) and fold those bodies into the hash. (GitLab side already
  used `glab api --paginate`.)
- Derive a REAL signature for the CI fingerprint from the check run's
  `output.title/summary` (fetched via `repos/{o}/{r}/commits/{sha}/check-runs`),
  normalized (strip ANSI/timestamps/addresses, collapse digit-runs to `N`) and
  hashed. Never record an empty string as a logical-key component. External
  status contexts with no check-run body fall back to `job+commit` (documented).
- Validate the id is numeric before building any path:
  `case "$id" in ''|*[!0-9]*) die "--id must be a numeric PR/MR id" 2 ;; esac`.

## Prevention
- When a spec says "gather ALL feedback", treat every paginatable API connection
  (top-level AND nested) as a MUST-paginate; a bare `first:N` is a silent data
  loss bug. Test with a mock that reports `hasNextPage:true`.
- A logical dedupe/fingerprint key must never contain an empty placeholder for a
  component the spec lists — either populate it from real data or fall back to a
  documented reduced key; an empty component silently over-collapses.
- Any external input used as a filesystem path component needs a format guard.
- macOS ships bash 3.2: no `declare -A` (use a keys file + `grep -Fxq`), and
  `${var:-{}}` mis-parses (set the default on its own line). BSD `sed` label/`N`
  loops for trailing-blank trimming are non-portable — trim in awk instead.

---
title: "post-findings forge scripts: non-atomic approve, sha1sum-on-macOS, non-fence-awa"
date: "2026-07-09"
track: bug
category: integration
module: plugins/merge-request/skills/post-findings/scripts
tags: [bash, gh, glab, forge, macos, sha1sum, atomicity, awk, validation]
problem_type: integration
symptoms: Clean approval could land without its note; GitLab inline failed on macOS (no sha1sum); malformed findings approved; edit posted then failed to restage
root_cause: Approve-before-note ordering; sha1sum assumed present; zero-findings gate counted only F- lines not fenced content; edit preflight used a whole-file grep instead of the section-scoped restage matcher
resolution_type: fix
related_to: [bug/integration/forge-feedback-gather-paginate-every-2026-07-09]
---

## Problem
The `post-findings` forge-posting scripts (`approve-and-lgtm.sh`, `post-inline-comment.sh`) shipped four latent defects that impl-review caught across successive passes:
1. **Non-atomic clean sign-off.** Approve ran before the `Looks good.` note, so an approve-then-note-fails path left the PR/MR formally approved with no note — violating the "on failure, nothing approved" contract.
2. **Missing macOS portability.** GitLab inline `line_code` used `sha1sum` directly; default macOS ships only `shasum`, so GitLab inline comments failed to post on a Mac.
3. **Weak "clean" gate.** The zero-findings check counted only `"id":"F-"` lines, so a clean-marker artifact with a malformed/garbage fenced `jsonl` block (`not-json`, a non-`F-` record, or a truncated fragment) still counted 0 and got a formal approval — a malformed artifact must NOT be treated as clean.
4. **Preflight/mutation matcher mismatch.** The edit path preflighted the stable `F-<hash>` id with a bare `grep` over the whole file, but the restage only rewrites a record inside `## Findings`. An id living in `## Declined`/prose passed preflight, the comment posted, then the restage found nothing — splitting disk from the forge.

## What Didn't Work
Counting "records" by the presence of a well-formed `F-` id (or by `{`-prefixed lines only) — malformed/garbage content inside the findings fence slipped through both. A bare `grep "$id"` preflight — it matched the id anywhere in the artifact, not as a `## Findings` record.

## Solution
- **GitHub approve is atomic**: `gh pr review --approve --body "Looks good."` (the note is the review body). **GitLab has no atomic form** → post the note FIRST, then approve, so a failed approve can at worst leave a harmless stray note, never an unsigned approval. `approve-and-lgtm.sh`.
- **`sha1()` shim**: prefer `sha1sum`, fall back to `shasum` (SHA-1 by default; identical hex). Dependency check accepts either. Same shim the review engine uses for `F-<hash>`. `post-inline-comment.sh`.
- **Fence-aware clean gate**: inside `## Findings`, toggle on the ``` fence; ANY non-blank line inside the fence counts as a record (blocks), plus any `{`-opening line outside a fence. Empty/prose/empty-fence section = clean. `approve-and-lgtm.sh`.
- **Preflight uses the mutation's matcher**: the edit preflight runs the SAME in-`## Findings` + `{`-line + id-regex awk the restage uses, so "preflight passes => restage lands." `post-inline-comment.sh`.
- Removed a dead `jq` dependency check (SHAs come from the finding's args; jq was never invoked).
- Removed the `--message` override; the clean note is a hardcoded `readonly` invariant since every approval write goes through this one script.

## Prevention
- A guard meaning "post X only on failure => X did not happen" needs an atomic forge op, or an ordering where the irreversible/high-impact step (approval) is LAST; document the residual partial state honestly.
- Never assume `sha1sum`/`md5sum` on macOS — use a `sha1sum||shasum` (or `md5||md5sum`) shim; test the fallback produces the same digest.
- A "zero entries / empty section" check over a fenced block must be fence-aware — count any non-blank fenced line, not just well-formed records — so malformed/truncated content can't read as empty.
- A preflight that gates a scoped mutation must use the SAME boundary/matcher as the mutation; a broader check (bare grep vs section-scoped awk) can pass then let the mutation fail after an irreversible side effect.

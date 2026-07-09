---
satisfies: [R1, R2, R3]
---
## Description
Build the review engine: single-ID vs batch scope, the SHA skip/re-review contract applied before checkout, worktree reuse/creation against a real checkout with fork-safe head resolution, and an auto-detected build/test pass with a defined detection order.

**Size:** M
**Files:** `plugins/merge-request/skills/review/SKILL.md`, `plugins/merge-request/skills/review/scripts/triage.sh`, `plugins/merge-request/skills/review/scripts/setup-worktree.sh`, `plugins/merge-request/skills/review/scripts/build-and-test.sh`

## Approach
- `/merge-request:review <ID>` reviews one PR/MR; no argument -> batch-review all open (via `gh`/`glab` list, branching on the fn-8 contract).
- Generalize the prior-art triage `Reviewed at commit: <sha>` contract: **triage fetches each open PR/MR's head SHA and applies the skip check BEFORE any worktree setup/build**; skip when recorded SHA == head, re-review otherwise.
- **Head resolution (fork-safe):** prefer forge API/CLI metadata for the head repo/branch (`gh pr view --json headRepository,headRepositoryOwner,headRefName,headRefOid` / `glab mr view --output json`); fall back to PR/MR refs (`refs/pull/<n>/head`, `refs/merge-requests/<iid>/head`). If a checkout cannot be established, log it in `## Build` AND raise it as the first `## Findings` entry (`issue:` prefix, stable id, `kind: general`), set the header marker to `findings`, then skip build/test for that PR/MR (do not fail silently).
- **Review-status marker ownership:** the core engine (this task) is responsible for the `<!-- merge-review-status: ... -->` marker on every run — set it to `findings` whenever it writes ANY `## Findings` entry (e.g. a blocking checkout/build/test failure), even when the checkout fails before selection (fn-11.3) runs, so a stale `clean` from a prior run can never linger.
- Reuse the dedicated worktree when already inside it; else create one at `.worktrees/merge-<ID>` with checkout branch `merge/<ID>`, pulling the resolved head.
- **Build/test detection order (ecosystem):** package-manager scripts (package.json/pnpm/npm/yarn) → Makefile/justfile → Cargo → Go → .NET. **Within package scripts the selection is cumulative, not first-match:** run `ci` if present; otherwise run `build` (if present) AND then `test`/`check` (if present) — so a repo with both `build` and `test` runs both. Exclude lint/format-only commands unless they are part of the repo's normal build/test command (this skill never emits style findings). Record "no build/test command detected" in `## Build` when none matches (not a failure unless the repo clearly expects one). A failing build/test is the top blocking finding — logged in `## Build` AND surfaced as the first `## Findings` entry (`issue:` prefix, stable id, `kind: general`) so post-findings can post it as a general comment.

## Investigation targets
**Required:**
- `~/.claude/skills/gitlab-mr-review/scripts/triage.sh` -- batch listing + SHA skip/re-review contract to generalize
- `~/.claude/skills/gitlab-mr-review/scripts/setup-worktree.sh` -- worktree create/reset (adapt branch naming + fork-safe ref)
- `~/.claude/skills/gitlab-mr-review/scripts/build-and-test.sh` -- build/test pattern to make toolchain-agnostic
- `plugins/detect-source-control/SKILL.md` -- forge/cli branching
- `plugins/merge-request/ARTIFACT.md` -- artifact contract (header stamp + `## Build` section) from fn-11.1

## Acceptance
- [ ] `/merge-request:review <ID>` reviews one PR/MR; no argument batch-reviews all open.
- [ ] Triage fetches head SHAs and applies the `Reviewed at commit: <sha>` skip check BEFORE checkout/build; re-reviews when head advanced.
- [ ] Resolves the head via forge API/CLI metadata first (fork-safe), PR/MR refs fallback; if unresolvable, logs it in `## Build` AND raises the first `## Findings` `issue:` `kind: general` entry, sets the marker to `findings`, then skips build/test.
- [ ] Owns the `merge-review-status` marker: sets it to `findings` on any run that writes a `## Findings` entry (incl. a checkout/build failure before selection runs), so a prior-run `clean` never lingers stale.
- [ ] Reuses the dedicated worktree if already in it; otherwise creates `.worktrees/merge-<ID>` with branch `merge/<ID>` and pulls the resolved head.
- [ ] Runs an auto-detected build/test in the documented ecosystem order; within package scripts runs `ci` if present else `build`+`test`/`check` cumulatively (lint-only excluded); records "no build/test command detected" when none matches; a failing build/test is the top blocking finding, logged in `## Build` AND surfaced as the first `## Findings` entry.

## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:

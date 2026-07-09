---
satisfies: [R4, R5, R6, R7, R8, R10]
---
## Description
Add the decision-and-apply half of `merge-request:fix`: decide whether each (unseen) feedback item warrants a change against the spec guardrail and the repo's published standards, implement worthy ones (discover + run tests first, commit on pass), acknowledge + resolve per forge, record declined items, and update the `## Handled` ledger.

**Size:** M
**Files:** `plugins/merge-request/skills/fix/SKILL.md` (extends fn-10.1), `plugins/merge-request/skills/fix/scripts/reply-resolve.sh`

## Approach
- Consume only the unseen, MR-attributable feedback fn-10.1 surfaces (post-dedup against `## Handled`).
- Implement a feedback item only when it (a) does not change the spec, (b) is consistent with the repo's published technical standards, and (c) flags a legitimate shortcoming; otherwise decline.
- Resolve "published technical standards" from `CLAUDE.md`/`AGENTS.md` first, then `docs/`.
- **Locate the guarded "spec"** (R5) from all available sources as **cumulative guardrails** (not a replacement chain): `## Intent` in `.data/merge/<ID>.md`, PR/MR title/body, linked `.flow/specs`/tasks discoverable by id in the branch/PR, and branch diff / commit range (`<default>..HEAD`). The diff describes scope; it never overrides a discoverable epic. Ask the user when the sources conflict or are incomplete, or when spec-impact is ambiguous.
- **Test discovery + commit gate (R6):** discover the test command from `CLAUDE.md`/`AGENTS.md`, package scripts, Makefile/justfile, or CI config; run the relevant automated tests; commit + push only on pass. If no test command can be found, treat it as a **blocker**: stop and ask the user (record "no automated test command found"); never commit or push untested without explicit approval.
- **Reply + resolve per forge (R7):** post exactly `Fixed`, then resolve — GitLab: resolve the discussion; GitHub: `resolveReviewThread` GraphQL mutation (thread node id). Non-resolvable comments (plain issue comments / CI annotations): post `Fixed` where possible and skip resolve (documented fallback).
- On implement: write a `## Handled` record via `gather-feedback.sh record` (fn-10.1's canonical ledger writer — it rewrites the whole fenced `jsonl` block each call, so never hand-write records): kind, source_id, `fingerprint` for ci-job items, **`content_hash` for thread/comment items**, decision=implemented, commit SHA, timestamp. On decline: append item + rationale to `## Declined` and write a `## Handled` record (decision=declined, rationale). When spec-impact is ambiguous, ask once and write a `pending-user` record (rationale) so the loop suppresses re-asking until the user answers or the source changes. <!-- Updated by plan-sync: fn-10.1's gather-feedback.sh record requires --content-hash + --source-id for thread/comment records (die at gather-feedback.sh:261-262); carry each item's content_hash/source_id from gather's JSONL through to the record call -->
- The writer requires the per-kind dedupe key: `--fingerprint` for ci-job, `--source-id` + `--content-hash` for thread/comment — both are present on every item gather-feedback.sh emits, so thread each through unchanged.

## Investigation targets
**Required:**
- `~/.claude/skills/gitlab-mr-feedback/scripts/post-inline-comment.sh` -- threaded reply
- `~/.claude/skills/gitlab-mr-feedback/scripts/approve-and-lgtm.sh` -- glab approve/comment invocation
- `plugins/merge-request/skills/fix/SKILL.md` -- the fn-10.1 core this extends (plug in at Step 5)
- `plugins/merge-request/skills/fix/scripts/gather-feedback.sh` -- fn-10.1's canonical `## Handled` ledger writer; use its `record` subcommand for implemented/declined/pending-user (requires `--content-hash` + `--source-id` for thread/comment, `--fingerprint` for ci-job)
- `CLAUDE.md` / `AGENTS.md` (repo root, when present) -- standards source to check feedback against

## Acceptance
- [ ] Implements a feedback item only when it passes all three criteria; when spec-impact is ambiguous, asks once and records `pending-user` (loop suppresses re-asking until answered or source changes).
- [ ] Resolves published standards from CLAUDE.md/AGENTS.md then docs/.
- [ ] Locates the guarded spec from cumulative sources (Intent + PR/MR body + linked .flow specs + branch diff); diff never overrides a discoverable epic; asks on conflict/incompleteness.
- [ ] Receives only MR-attributable CI failures from fn-10.1 (fn-10.1 reports and records the non-actionable ones); acts on them per the implement criteria.
- [ ] Discovers the test command, re-runs relevant tests, commits + pushes only on pass; when no test command exists, stops and asks (blocker) rather than pushing untested.
- [ ] Implemented feedback posts exactly `Fixed` and resolves the thread via the forge-specific path, with the non-resolvable-comment fallback.
- [ ] Declined feedback recorded to `## Declined` with a rationale.
- [ ] Every acted-on item writes a `## Handled` jsonl record (kind, source_id, `fingerprint` for ci-job records, `content_hash` for thread/comment records, decision, commit, timestamp) via `gather-feedback.sh record` for idempotent resume. <!-- Updated by plan-sync: fn-10.1 writer requires content_hash for thread/comment records -->
- [ ] Records go through `gather-feedback.sh record` (never a hand-written ledger block), so the fenced `jsonl` stays canonical for the next wakeup's dedupe.

## Done summary
Added the decide-and-apply half of /merge-request:fix: SKILL.md Step 5 now assembles the cumulative spec guardrail (Intent + PR/MR body + linked .flow specs + branch diff), applies the three-criteria implement decision, gates commit/push on discovered tests (no-test-command is a blocker), acknowledges via a new reply-resolve.sh (Fixed + forge-specific resolve, with the non-resolvable-comment fallback), records declined items to ## Declined, and writes every terminal ## Handled record through fn-10.1's canonical gather-feedback.sh record with the correct per-kind dedupe keys.
## Evidence
- Commits: ccf366813f438bd09a4fd3628f37df172c9474a1, 0471a3cfb8cb1e5e7374266e4b6c4934217d847c
- Tests: bash plugins/merge-request/skills/fix/tests/reply-resolve_test.sh (33 passed), bash plugins/merge-request/skills/fix/tests/gather-feedback_test.sh (46 passed), bash plugins/merge-request/skills/create/tests/create_test.sh (31 passed)
- PRs:
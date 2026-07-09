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
- On implement: write a `## Handled` record (kind, source_id, `fingerprint` for ci-job items, decision=implemented, commit SHA, timestamp). On decline: append item + rationale to `## Declined` and write a `## Handled` record (decision=declined, rationale). When spec-impact is ambiguous, ask once and write a `pending-user` record (rationale) so the loop suppresses re-asking until the user answers or the source changes.

## Investigation targets
**Required:**
- `~/.claude/skills/gitlab-mr-feedback/scripts/post-inline-comment.sh` -- threaded reply
- `~/.claude/skills/gitlab-mr-feedback/scripts/approve-and-lgtm.sh` -- glab approve/comment invocation
- `plugins/merge-request/skills/fix/SKILL.md` -- the fn-10.1 core this extends
- `CLAUDE.md` / `AGENTS.md` (repo root, when present) -- standards source to check feedback against

## Acceptance
- [ ] Implements a feedback item only when it passes all three criteria; when spec-impact is ambiguous, asks once and records `pending-user` (loop suppresses re-asking until answered or source changes).
- [ ] Resolves published standards from CLAUDE.md/AGENTS.md then docs/.
- [ ] Locates the guarded spec from cumulative sources (Intent + PR/MR body + linked .flow specs + branch diff); diff never overrides a discoverable epic; asks on conflict/incompleteness.
- [ ] Receives only MR-attributable CI failures from fn-10.1 (fn-10.1 reports and records the non-actionable ones); acts on them per the implement criteria.
- [ ] Discovers the test command, re-runs relevant tests, commits + pushes only on pass; when no test command exists, stops and asks (blocker) rather than pushing untested.
- [ ] Implemented feedback posts exactly `Fixed` and resolves the thread via the forge-specific path, with the non-resolvable-comment fallback.
- [ ] Declined feedback recorded to `## Declined` with a rationale.
- [ ] Every acted-on item writes a `## Handled` jsonl record (kind, source_id, `fingerprint` for ci-job records, decision, commit, timestamp) for idempotent resume.

## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:

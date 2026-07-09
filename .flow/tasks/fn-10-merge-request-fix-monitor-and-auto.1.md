---
satisfies: [R1, R2, R3, R9, R11, R12]
---
## Description
Build the monitoring core of `merge-request:fix`: required `<ID>`, a session-bound scheduled-wakeup poll loop on an adaptive cadence until the PR/MR closes, reloading pre-MR intent, gathering all actionable feedback (human + bot/AI comments + CI failures classified by attribution), and deduplicating against a durable `## Handled` ledger.

**Size:** M
**Files:** `plugins/merge-request/skills/fix/SKILL.md`, `plugins/merge-request/skills/fix/scripts/gather-feedback.sh`

## Depends on
- **fn-8.2** — `merge-request` plugin shell + marketplace registration (else `/merge-request:fix` is not discoverable).
- **fn-8.1** — `detect-source-control` stdout contract.

## Approach
- Add `skills/fix/SKILL.md` -> `/merge-request:fix <ID>`. Required `<ID>`; none -> no-op with a clear message.
- Drive the interval with ScheduleWakeup on an adaptive cadence: ~2-3 min while there is recent activity (cache-warm), backing off to ~15-20 min when idle. Session-bound; resume by rerunning. Loop until the PR/MR is closed.
- **Wakeup payload** (so each wake is stateless): MR/PR `<ID>`, forge, `.data/merge/<ID>.md` path, last-activity timestamp, current cadence tier, termination condition (PR/MR closed).
- On (re)start, reload the `## Intent` summary from `.data/merge/<ID>.md` (written by create); fall back to flow-next epic + change scope when absent.
- Gather feedback via `gh`/`glab`: threads/comments, bot/AI-reviewer comments, CI status+logs. Each item carries a stable id (GitLab discussion/note id; GitHub review-thread node id / comment id; CI job/pipeline id).
- **Idempotency:** the `## Handled` ledger is a fenced ```jsonl``` block in `.data/merge/<ID>.md` (one JSON record per line; fields: kind, source_id, `fingerprint` (for ci-job), `content_hash` (for thread/comment), decision, commit, rationale, timestamp). Diff freshly-fetched feedback against it; hand only unseen-or-changed items to fn-10.2. Dedupe key: CI failures on the logical fingerprint `{job/check name, failing test/file, normalized error signature, commit SHA}` (NOT the job/pipeline id); thread/comment on `source_id` + `content_hash` (same id, changed hash = an edited comment / new reply = reconsider). (fn-10.2 writes back `## Handled` records for implemented/declined items.)
- **CI attribution:** classify each failing job as MR-attributable (failing test/file within or exercising the changed files, or job passes on target-branch baseline) vs non-actionable (network/timeout, runner/image/cache/setup, pre-existing-on-target, flaky); pass only MR-attributable failures downstream. **fn-10.1 owns the write path for reported/non-actionable CI items:** immediately after reporting one, write a `## Handled` record (kind=ci-job, decision=reported|non-actionable, fingerprint, rationale, timestamp) so the next wakeup doesn't re-report it.
- **Ambiguity / pending-user:** when spec-impact or CI attribution is ambiguous, ask the user once and write a `pending-user` `## Handled` record (with rationale); on subsequent wakeups, suppress re-asking that item while the record stands, until (a) the source changes (new commit/`fingerprint` for CI, or new `content_hash` for a thread/comment) or (b) the user answers — which supersedes the `pending-user` record and lets the item be reprocessed exactly once.

## Investigation targets
**Required:**
- `~/.claude/skills/gitlab-mr-review/SKILL.md` -- `glab api ... /discussions` fetch pattern
- `plugins/detect-source-control/SKILL.md` -- forge/cli branching contract
- `~/.claude/skills/gitlab-mr-feedback/scripts/post-inline-comment.sh` -- glab comment/thread API shape

## Key context
- Scheduled wakeups live only for the session; keep active-poll intervals under ~5 min (prompt-cache window). Termination = PR/MR closed.
- ScheduleWakeup is the harness tool driving the loop; the wakeup prompt re-enters `/merge-request:fix <ID>`.

## Acceptance
- [ ] Requires `<ID>`; with none it does nothing (clear message).
- [ ] Polls via scheduled wakeups until the PR/MR is closed; session-bound and resumable, carrying the documented wakeup payload.
- [ ] Uses an adaptive cadence (~2-3 min active / ~15-20 min idle).
- [ ] Reloads the `## Intent` summary from `.data/merge/<ID>.md` on (re)start; falls back to epic + scope when absent.
- [ ] Gathers human + bot/AI comments and CI failures, each with a stable id.
- [ ] Deduplicates against the `## Handled` jsonl ledger so already-handled feedback is never reprocessed; CI failures dedupe on the logical fingerprint (not job/pipeline id).
- [ ] Classifies CI failures as MR-attributable vs non-actionable per the attribution procedure; only MR-attributable failures go downstream.
- [ ] Writes a `## Handled` record (with fingerprint) for reported/non-actionable CI items so they are not re-reported on the next wakeup.
- [ ] Ambiguous items are asked once and recorded as `pending-user`; wakeups suppress re-asking until the user answers or the source changes.

## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:

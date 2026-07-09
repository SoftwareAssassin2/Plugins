## Conversation Evidence

> user: "will monitor the MR/PR at an interval to check for feedback. As feedback is received, determine if it's a suggestion that needs to be implemented. If so fix it and re-push ... Do not make changes as a result of this feedback that change the spec. After each change re-run automated tests before committing and pushing to the server."
> user: "it is expected that the MR or PR ID is passed as a parameter ... Without that parameter there is nothing for the skill to do."
> user: "The /merge-request-fix interval will continue until the MR/PR is closed."
> user (durability): "Accept session-bound".
> user (spec): "The flow-next epic (when one is available) ... The discussion the developer who created the MR/PR had with the AI agent before calling /merge-request:fix ... The scope of the current change. Ask when ambiguous."
> user (implement criteria): "1. It doesn't change the spec ... 2. It is consistent with the technical standards published in the repo ... 3. It points out legitimate shortcomings in the MR/PR code".
> user (thread): "Post \"Fixed\". Just \"Fixed\" ... Then mark the thread resolved."
> user (declined): "Create a file in .data/merge/<MR/PR ID>.md and make a note of the feedback and why it chose not to implement it."
> user (feedback scope): "Both 2 and 3 - Human Comments + bot/AI reviewer comments + CI failures. Pull logs, fix, re-push. Do the whole shebang."
> user (interview, poll cadence): "Adaptive (fast active / slow idle)".
> user (interview, standards source): "CLAUDE.md/AGENTS.md, then docs/".
> user (interview, intent access): "create stashes intent to .data/merge/<ID>.md".
> user (interview, CI scope): "Only MR-attributable failures".

## Goal & Context
<!-- 85% [user], 15% [paraphrase] -->

`/merge-request:fix` monitors an open PR/MR and, as feedback arrives, decides whether each item warrants a change, implements the worthy ones (tests first), and pushes — without ever drifting beyond the change's spec. It is the author-side automation that closes the review loop. [user] [paraphrase]

## Architecture & Data Models
<!-- 70% [user], 30% [paraphrase] -->

A skill in the `merge-request` plugin, invoked as `/merge-request:fix <ID>`. **Depends on fn-8.2** (plugin shell + marketplace registration) and consumes fn-8.1's `detect-source-control` contract. Polls via scheduled wakeups (wake → check feedback → act → sleep) on an adaptive cadence. Branches on `gh`/`glab` for comment/thread/CI access via `detect-source-control`. [user] [paraphrase] [interview]

**`.data/merge/<ID>.md` shared artifact** — sections:
- `## Intent` — pre-MR intent + change scope, written by `/merge-request:create` (read here).
- `## Declined` — declined items + rationale (append-only).
- `## Handled` — **durable idempotency ledger** so a wakeup never re-processes prior feedback. Serialized as a fenced ```jsonl``` block (one JSON object per line) under the heading, so scripts parse it deterministically and free-form rationale never corrupts the format. Each record: `kind` (thread|comment|ci-job), `source_id` (GitLab discussion/note id, GitHub review-thread node id or comment id, or CI job/pipeline id — provenance), `fingerprint` (**required for `kind=ci-job`**: a stable string derived from `{job/check name, failing test/file, normalized error signature, commit SHA}`), `content_hash` (**required for `kind=thread|comment`**: a hash of the comment/thread body + latest-reply state, so an edited comment or a new reply in the thread is detected as changed), `decision` (implemented|declined|reported|non-actionable|pending-user), `commit` (SHA when implemented), `rationale` (short; for declined / non-actionable / pending-user), `timestamp`. **Dedupe key per kind:** ci-job -> `fingerprint` (NOT the job/pipeline id, which changes on every rerun); thread/comment -> `source_id` + `content_hash` (same id with a changed hash counts as *changed*, not seen). **Every terminal outcome writes a record** — implemented/declined (by fn-10.2), and reported/non-actionable (by fn-10.1, immediately after reporting, with the CI fingerprint) — so nothing is re-surfaced. `pending-user` records an item the loop asked the user about but cannot yet decide (ambiguous spec-impact or CI attribution); while a `pending-user` record stands, wakeups **suppress re-asking** that item until either (a) the source changes — new commit/`fingerprint` for CI, or a new `content_hash` for a thread/comment (edit or clarifying reply) — or (b) the user answers, which supersedes the `pending-user` record and lets the item be reprocessed **exactly once**. Every wakeup diffs freshly-fetched feedback against `## Handled` and acts only on items whose dedupe key is unseen or whose source changed. [paraphrase]

## API Contracts
<!-- 75% [user], 25% [paraphrase] -->

- Required `<ID>` argument; absent → no-op with a clear message. [user]
- Feedback sources: human review comments, bot/AI-reviewer comments, and CI/pipeline failures (pull logs). [user]
- **Thread reply + resolve (forge-specific):**
  - GitLab: reply to the discussion with a note, then resolve the discussion (`glab api ... /discussions/<id>/notes` + resolve). [paraphrase]
  - GitHub: reply to the review thread, then resolve it via the `resolveReviewThread` GraphQL mutation (needs the thread node id). [paraphrase]
  - Non-resolvable comments (plain issue comments, CI check-run annotations with no thread): post `Fixed` as a reply where possible and record in `## Handled`; skip the resolve step (documented fallback). [paraphrase]
- On implemented feedback: post exactly `Fixed` to the originating thread, then resolve the thread. [user]
- On declined feedback: append the item + rationale to `## Declined`. [user]

## Edge Cases & Constraints
<!-- 70% [user], 20% [interview], 10% [paraphrase] -->

- **Session-bound:** scheduled wakeups live only for the session; if it ends before the PR/MR closes, monitoring stops and the user reruns `/merge-request:fix <ID>` to resume. `## Handled` makes resume idempotent. [user] [paraphrase]
- On **resume in a fresh session**, fix reloads the `## Intent` summary from `.data/merge/<ID>.md` (written by `/merge-request:create`); nuance from the original live discussion beyond that summary is not recoverable. [interview]
- The interval runs until the PR/MR is closed (merged or declined). [user]
- **Poll cadence:** adaptive — ~2-3 min while there is recent PR/MR activity (stays within the prompt-cache window), backing off to ~15-20 min when idle. [interview]
- **Standards source:** the repo's published technical standards are read from `CLAUDE.md`/`AGENTS.md` first, then `docs/`. [interview]
- **CI attribution procedure:** a failure is MR-attributable only when the evidence ties it to the MR's own diff — e.g. the failing test/file is within (or exercises) the changed files, or the same job passes on the target branch baseline. Treated as **non-actionable** (reported, not fixed): network/timeout, runner/image/cache/setup failures, pre-existing failures also present on the target branch, and flaky/known-intermittent jobs. When attribution is ambiguous, report and ask rather than auto-fix. [interview] [paraphrase]

## Acceptance Criteria

- **R1:** Requires an `<ID>` argument; with none, it does nothing (clear message). [user]
- **R2:** Polls the PR/MR on an interval via scheduled wakeups until it is closed; it is session-bound and resumable by rerunning `/merge-request:fix <ID>`, using `## Handled` for idempotent resume. [user] [paraphrase]
- **R3:** Treats human comments, bot/AI-reviewer comments, and CI failures (pulling logs) as actionable feedback, deduplicated against `## Handled`. [user] [paraphrase]
- **R4:** Implements a piece of feedback only when it (a) does not change the spec, (b) is consistent with the repo's published technical standards, and (c) flags a legitimate shortcoming; asks when a change's spec-impact is ambiguous. [user]
- **R5:** The "spec" it guards against comprises the flow-next epic (when one exists), the developer's pre-MR discussion with the AI agent, and the scope of the current change. These sources are **cumulative guardrails, not a replacement chain** — fix loads all available: `## Intent` in `.data/merge/<ID>.md`, the PR/MR title/body, any linked `.flow/specs`/tasks discoverable by id in the branch/PR, and the branch diff / commit range (`<default>..HEAD`). The diff describes *scope*; it never overrides a discoverable epic. When the sources conflict or are incomplete, fix asks the user rather than picking one. [user] [paraphrase]
- **R6:** Discovers the repo's test command (from `CLAUDE.md`/`AGENTS.md`, package scripts, Makefile/justfile, or CI config), re-runs the relevant automated tests before committing, and commits + pushes each change only on pass. If no test command can be found, that is a **blocker, not a warning**: fix stops and asks the user (recording "no automated test command found") and does not commit or push without explicit user approval — never an untested push. [user] [paraphrase]
- **R7:** For implemented feedback, posts exactly `Fixed` to the originating thread and marks the thread resolved using the forge-specific path (GitLab resolve-discussion / GitHub `resolveReviewThread`), with the documented fallback for non-resolvable comments; records the outcome in `## Handled`. [user] [paraphrase]
- **R8:** For declined feedback, records the item and its rationale to the `## Declined` section of `.data/merge/<ID>.md` (and notes it in `## Handled`). [user]
- **R9:** The wakeup loop uses an adaptive cadence — ~2-3 min while there is recent activity, backing off to ~15-20 min when idle. [interview]
- **R10:** Feedback is checked against the repo's published technical standards, read from `CLAUDE.md`/`AGENTS.md` first, then `docs/`. [interview]
- **R11:** fix reads a `## Intent` summary from `.data/merge/<ID>.md` (written by `/merge-request:create`) so the pre-MR intent survives a resumed session; absent it, falls back to the flow-next epic + change scope (per R5 cumulative guardrails). [interview]
- **R12:** fix acts only on CI failures attributable to the MR's own code per the attribution procedure; environmental / infra / flaky / pre-existing failures are reported, not auto-fixed. [interview]

## Boundaries
<!-- 90% [user] -->

- Never makes changes that alter the spec. [user]
- No cloud-cron/`/schedule` durability this iteration — session-bound accepted. [user]
- Does not chase CI failures that aren't caused by the MR's own code. [interview]

## Decision Context

### Motivation
<!-- scope: business -->

Session-bound scheduled wakeups chosen over durable cloud cron for simplicity; the user accepted that monitoring stops if the session ends and is resumed manually. The three-layer spec definition plus the three-part implement test keep the loop from scope-creeping on reviewer suggestions. [user] [paraphrase]

### Implementation Tradeoffs
<!-- scope: technical -->

Interview-resolved mechanism decisions: adaptive poll cadence (responsive when active, cheap when idle, cache-window-aware); standards precedence CLAUDE.md/AGENTS.md → docs/ (where conventions actually live); pre-MR intent persisted to `.data/merge/<ID>.md` by create so the intent layer survives a resumed session; CI scope limited to MR-attributable failures to avoid rabbit-holing on infra/flaky checks. A durable `## Handled` ledger was added so idempotent resume across wakeups/sessions doesn't re-comment or re-fix already-handled feedback. [interview] [paraphrase]

### ScheduleWakeup payload
<!-- scope: technical -->

Each wakeup carries enough state to run stateless: MR/PR `<ID>`, forge (`github`/`gitlab`), the `.data/merge/<ID>.md` path (holds `## Intent`/`## Declined`/`## Handled`), the last-observed activity timestamp, the current cadence tier (active/idle), and the termination condition (PR/MR closed). [paraphrase]

## Requirement coverage

| R-ID | Task |
|------|------|
| R1, R2, R3, R9, R11, R12 | fn-10-merge-request-fix-monitor-and-auto.1 |
| R4, R5, R6, R7, R8, R10 | fn-10-merge-request-fix-monitor-and-auto.2 |

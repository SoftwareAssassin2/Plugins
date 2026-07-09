---
name: merge-request:fix
description: Monitor an open pull/merge request (by id) and, as feedback arrives, gather every actionable item — human + bot/AI review comments and MR-attributable CI failures — deduplicated against a durable ledger so nothing is handled twice. Polls on an adaptive scheduled-wakeup cadence until the PR/MR closes. First runs /detect-source-control and hard-stops when the forge is unsupported. Use as "watch the PR", "monitor the MR for feedback", "fix review feedback on <id>", or the continuation of /merge-request:create.
argument-hint: "<ID>  — the PR/MR number to monitor (required)"
---

# merge-request:fix

Watch an open PR/MR and keep the review loop moving: on an adaptive interval,
gather freshly-arrived feedback (human comments, bot/AI-reviewer comments, and
CI failures), deduplicate it against a durable ledger, classify CI failures by
attribution, and hand the unseen, actionable items to the triage-and-apply half
(fn-10.2). Keep polling via scheduled wakeups until the PR/MR is closed.

This is an **assistant-executed** skill: you (the assistant) follow the steps
below. The deterministic forge work — fetching comments/threads/CI, computing
stable dedupe keys, diffing against the `## Handled` ledger, and writing ledger
records — lives in `scripts/gather-feedback.sh`. The poll loop itself is *your*
continuation driven by the harness `ScheduleWakeup` tool; a script cannot
schedule its own next wake.

> **Scope note:** the **monitoring core** (fn-10.1) is the `<ID>` gate, the
> wakeup loop, intent reload, feedback gathering + dedupe, CI attribution, and
> the reported/non-actionable CI write-back (Steps 0–4, 6, 7). The
> **decide-and-apply** loop (fn-10.2) — implement criteria, the spec guardrail,
> test-before-push, `Fixed`+resolve, and `## Declined` — is **Step 5** below.

## Step 0 — require the `<ID>` argument

`/merge-request:fix` needs the PR/MR **id** to monitor. If none was provided,
**do nothing** beyond a clear message and stop:

> `/merge-request:fix` needs a PR/MR id to monitor, e.g. `/merge-request:fix 128`.
> Nothing to do without one. (Run `/merge-request:create` first to open one.)

Never guess an id or pick "the latest" PR/MR — absence of an id means there is
nothing for this skill to do.

## Step 1 — detect the forge and hard-stop if unsupported

Invoke the shared **`/detect-source-control`** skill and capture its stdout block
**and** exit code. Apply the **fn-8 hard-stop contract** (see `../../README.md`),
exactly as `/merge-request:create` does:

- **Non-zero exit** → operational failure (not a git repo, `git` missing). Stop
  and report; nothing was changed.
- **Exit `0` and `supported=false`** → a *successful* detection of an unsupported
  forge. Stop, naming the detected `forge`/`host`.
- **Exit `0` and `supported=true`** → proceed. Remember `forge` (`github` or
  `gitlab`) — you pass it to `gather-feedback.sh`.

Never key the unsupported stop off a non-zero exit; `forge=unsupported` is a
normal exit-`0` result.

## Step 2 — reload the intent / spec context

Read the shared artifact `.data/merge/<ID>.md` (written by `/merge-request:create`).
Its `## Intent` block is the author's pre-MR intent, and it survives a resumed
session — load it so your later judgement is anchored to what the change was
*for*.

- If `## Intent` is present (and not the `[TODO] Intent not provided` placeholder),
  use it as the primary intent.
- If it is **absent or a placeholder**, fall back to the change scope: the
  flow-next epic when one is discoverable, plus the PR/MR title/body and the
  branch diff (`## Change scope` is already stashed in the file). Just make sure
  you have the best-available intent loaded before acting.

(The full **cumulative** spec guardrail — Intent + PR/MR body + linked `.flow`
specs + branch diff, asking on conflict — is assembled in **Step 5a** before you
decide anything.)

## Step 3 — gather feedback and dedupe against the ledger

Run the gather helper for the resolved forge and id:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/fix/scripts/gather-feedback.sh" gather \
  --forge <github|gitlab> --id <ID>
```

It fetches, for the PR/MR:

- **plain issue comments** (`kind=comment`, non-resolvable),
- **review threads** (`kind=thread`; `source_id` is the resolvable thread id —
  GitLab discussion id / GitHub review-thread node id — that fn-10.2 resolves),
- **failing CI jobs** (`kind=ci-job`),

each carrying a **stable id** and a **dedupe key** (`content_hash` for
thread/comment, `fingerprint` for ci-job), then **diffs them against the
`## Handled` ledger** and prints only the **unseen-or-changed** items as JSONL,
followed by a machine-readable trailer:

```
MR_STATE=open|closed|merged|unknown
MR_UPDATED=<iso8601|unknown>
MR_CADENCE=active|idle
MR_POLL_SECONDS=<int>
MR_FETCHED_COUNT=<int>
MR_ACTIONABLE_COUNT=<int>
```

Parse the JSONL lines (each begins with `{`) as your actionable feedback set, and
the `MR_*` trailer for the loop. **Dedupe is the script's job — never re-fetch or
re-diff by hand.** Its guarantees:

- **CI failures dedupe on the logical `fingerprint`** ({forge, job name, commit
  SHA, normalized error signature}) — *not* the job/pipeline id, which changes on
  every rerun. A rerun of the same failure is "seen"; a new commit re-surfaces it.
- **thread/comment dedupe on `source_id` + `content_hash`** — the same id with a
  changed hash (an edited comment or a new reply) counts as *changed* and comes
  back for reconsideration.
- A standing `pending-user` ledger record therefore **suppresses re-asking** that
  item until its source changes (Step 6).

## Step 4 — classify CI failures by attribution (and record the ones you don't act on)

For each `kind=ci-job` item, decide **MR-attributable vs non-actionable** before
anything downstream touches it:

- **MR-attributable** (pass downstream to fn-10.2): the failing test/file is
  within — or exercises — the changed files, or the same job passes on the target
  branch baseline. Use the item's `job_name`/`signature`/`commit` plus the logs
  (pull them via `gh`/`glab` when you need more than the signature) to judge.
- **Non-actionable** (do **not** fix): network/timeout, runner/image/cache/setup
  failures, failures pre-existing on the target branch, and flaky/known-intermittent
  jobs. **Report** these (surface them to the user) but never auto-fix them.
- **Ambiguous** attribution → treat as pending-user (Step 6): report and ask
  rather than auto-fixing.

**fn-10.1 owns the write path for the CI items you do NOT hand downstream.**
Immediately after reporting a non-actionable (or reported-ambiguous) CI item,
write its `## Handled` record so the next wakeup does not re-report it:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/fix/scripts/gather-feedback.sh" record \
  --id <ID> --kind ci-job --decision <non-actionable|reported> \
  --fingerprint <fingerprint-from-the-item> \
  --commit <commit-from-the-item> \
  --rationale "<why it isn't MR-attributable>"
```

The `--fingerprint` **must** be the item's own `fingerprint` (that is the CI
dedupe key). Only the **MR-attributable** failures go on to Step 5; fn-10.2 writes
their terminal `## Handled` records when it implements or declines them.

## Step 5 — decide and apply (the fn-10.2 loop)

You now hold the unseen items Step 3/4 handed you: human comments, bot/AI
comments, and **MR-attributable** CI failures. For each one, decide whether it
warrants a change, implement the worthy ones (tests first), acknowledge +
resolve, record the declined ones, and write a terminal `## Handled` record.
**Every** item you touch here ends with exactly one `## Handled` record written
through `gather-feedback.sh record` — never hand-edit the ledger.

### Step 5a — assemble the spec guardrail (cumulative, not a chain)

Before judging anything, load **all** available guardrail sources and treat them
together — none replaces another:

1. `## Intent` in `.data/merge/<ID>.md` (loaded in Step 2) — the author's pre-MR intent.
2. The **PR/MR title and body** (`gh pr view <ID>` / `glab mr view <ID>`).
3. Any **linked `.flow/specs`/tasks** discoverable by id in the branch name, the
   PR/MR body, or commit messages (e.g. `fn-10`, `fn-10.2`) — read the epic/task
   with `flowctl cat <id>` when one is discoverable.
4. The **branch diff / commit range** `<default>..HEAD` (the `## Change scope`
   stash already holds this) — it describes *scope* only.

The diff **never overrides a discoverable epic**: it tells you what this change
touches, not what the change is allowed to be. When the sources **conflict or are
incomplete** — or when a feedback item's spec-impact is genuinely ambiguous —
**ask the user once** and record `pending-user` (Step 6) rather than guessing.

### Step 5b — resolve the repo's published standards

Read the repo's technical standards in this precedence: **`CLAUDE.md` /
`AGENTS.md` first, then `docs/`.** These are what "consistent with repo
standards" (criterion 2 below) is measured against. Absence of any standard is
not license to invent one — fall back to the surrounding code's conventions.

### Step 5c — the three-criteria implement decision

Implement a feedback item **only when all three hold**:

1. **It does not change the spec** — the change stays inside the Step-5a
   guardrail (fixes/clarifies the existing scope; never adds or redefines it).
2. **It is consistent with the repo's published standards** (Step 5b).
3. **It flags a legitimate shortcoming** in the MR/PR code (a real bug, gap, or
   quality issue — not taste/preference, not already-correct code).

Outcomes:

- **All three hold → implement** (Step 5d), then acknowledge + record (Step 5e).
- **Any one fails → decline** (Step 5f).
- **Spec-impact ambiguous** (you cannot tell whether it would change the spec) →
  **ask once**, record `pending-user` (Step 6); do not implement or decline yet.

### Step 5d — implement, then the test-before-push gate

For each worthy item, make the change following the surrounding code + Step-5b
standards. Then, **before committing**:

1. **Discover the test command** — in this order: `CLAUDE.md`/`AGENTS.md`,
   package scripts (`package.json`, `pyproject.toml`, …), a `Makefile`/`justfile`
   target, or the CI config. Run the **relevant** automated tests for what you
   changed.
2. **Commit + push only on pass.** On a green run, commit the change and push to
   the PR/MR branch. Capture the commit SHA — you record it in Step 5e.
3. **No test command found → BLOCKER, not a warning.** Stop, tell the user no
   automated test command could be found, and do **not** commit or push without
   their explicit approval — never an untested push. Record the item as
   `pending-user` with rationale `"no automated test command found"` (via the
   Step 6 command) so wakeups stop re-processing it until the user answers or the
   source changes.
4. **Tests fail** → the change isn't ready: fix it and re-run, or (if the item
   can't be satisfied within the guardrail) decline it (Step 5f). Never push red.

### Step 5e — acknowledge, resolve, and record an implemented item

Once the change is committed + pushed, post exactly `Fixed` and resolve the
originating thread through the forge-specific helper:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/fix/scripts/reply-resolve.sh" \
  --forge <github|gitlab> --id <ID> \
  --kind <thread|comment> --source-id <item.source_id>
```

- `kind=thread` → it replies `Fixed` **and** resolves (GitLab resolve-discussion /
  GitHub `resolveReviewThread`). A `RESOLVED=0` in its output / a non-zero exit
  means the thread stayed open — surface it.
- `kind=comment` → non-resolvable plain comment: it posts `Fixed` as a general
  note and reports `RESOLVED=skipped` (the documented fallback).
- **`kind=ci-job` has no thread** — do **not** call `reply-resolve.sh`; the pushed
  commit *is* the acknowledgement. Go straight to the ledger record.

Then write the terminal `## Handled` record — carrying the item's dedupe key
**unchanged** from the gather JSONL (`--content-hash` + `--source-id` for
thread/comment, `--fingerprint` for ci-job):

```bash
# thread / comment:
bash "${CLAUDE_PLUGIN_ROOT}/skills/fix/scripts/gather-feedback.sh" record \
  --id <ID> --kind <thread|comment> --decision implemented \
  --source-id <item.source_id> --content-hash <item.content_hash> \
  --commit <commit-sha>

# ci-job:
bash "${CLAUDE_PLUGIN_ROOT}/skills/fix/scripts/gather-feedback.sh" record \
  --id <ID> --kind ci-job --decision implemented \
  --fingerprint <item.fingerprint> --commit <commit-sha>
```

### Step 5f — record a declined item

When an item fails any of the three criteria, **do not change code**. Append the
item and a short rationale to the `## Declined` section of `.data/merge/<ID>.md`
(create the heading if absent; it is append-only prose), e.g.:

```markdown
## Declined

- **<thread/comment/CI ref>** — <one-line why>: <declined because it would change
  the spec / conflicts with <standard> / isn't a legitimate shortcoming>.
```

Then write the terminal `## Handled` record with `--decision declined` and the
rationale, carrying the same per-kind dedupe key:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/fix/scripts/gather-feedback.sh" record \
  --id <ID> --kind <thread|comment> --decision declined \
  --source-id <item.source_id> --content-hash <item.content_hash> \
  --rationale "<why it was declined>"
# (ci-job declines use --fingerprint <item.fingerprint> instead of --source-id/--content-hash)
```

The `## Declined` prose is the human-readable record (per the user's request);
the `## Handled` record is the machine dedupe key so the next wakeup never
re-surfaces the same declined item.

## Step 6 — ambiguous items: ask once, record `pending-user`

When an item's spec-impact or CI attribution is genuinely ambiguous, **ask the
user once**, then record it so wakeups stop re-asking:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/fix/scripts/gather-feedback.sh" record \
  --id <ID> --kind <thread|comment|ci-job> --decision pending-user \
  <dedupe-key flags: --content-hash <hash> --source-id <id>  | --fingerprint <fp>> \
  --rationale "<the question you asked>"
```

While a `pending-user` record stands, the Step-3 dedupe **suppresses re-asking**
that item — until either (a) its **source changes** (a new commit / `fingerprint`
for CI, or a new `content_hash` for a thread/comment) or (b) the **user answers**.
The user's answer **supersedes** the `pending-user` record: reprocess that one
item **exactly once** (implement or decline it via fn-10.2, which writes the
terminal record), rather than waiting for the next fetch.

## Step 7 — schedule the next wakeup (or terminate)

Read `MR_STATE` from the trailer:

- **`MR_STATE=closed` or `merged`** → the PR/MR is closed. **Terminate the loop**
  and report a short summary (what was handled this session). Do not schedule
  another wakeup.
- **otherwise** → schedule the next wakeup with the harness **`ScheduleWakeup`**
  tool, after `MR_POLL_SECONDS` (the adaptive cadence hint: ~2–3 min while active,
  ~15–20 min when idle — you may adjust within that band). The wakeup **payload
  must carry enough state to run stateless**, because each wake re-enters this
  skill fresh:

  | payload field | value |
  |---------------|-------|
  | `id`          | the PR/MR `<ID>` |
  | `forge`       | `github` / `gitlab` (from Step 1) |
  | `stash`       | `.data/merge/<ID>.md` (holds `## Intent`/`## Declined`/`## Handled`) |
  | `last_activity` | `MR_UPDATED` from the trailer |
  | `cadence`     | `MR_CADENCE` (`active`/`idle`) |
  | `terminate_when` | PR/MR closed |

  The wakeup prompt re-invokes `/merge-request:fix <ID>` — which re-runs Steps 1–7
  from the top. Because gathering is deduped against the durable `## Handled`
  ledger, a fresh wake never re-handles prior feedback.

## Notes

- **Session-bound.** Scheduled wakeups live only for the current session; keep
  active-poll intervals under ~5 min (the prompt-cache window). If the session
  ends before the PR/MR closes, monitoring stops — resume by simply rerunning
  `/merge-request:fix <ID>`. The `## Handled` ledger makes resume idempotent.
- **The ledger is the source of truth for "already handled".** Every terminal
  outcome writes one record: reported / non-actionable CI here (fn-10.1);
  implemented / declined and `pending-user` in fn-10.2. Never re-derive dedupe by
  hand — always go through `gather-feedback.sh`.
- **Read-then-write ordering.** Record a CI item as reported/non-actionable
  *immediately after* you report it, before scheduling the next wakeup, so a
  quick next wake can't re-surface it.

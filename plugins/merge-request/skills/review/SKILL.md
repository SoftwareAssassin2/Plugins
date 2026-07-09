---
name: merge-request:review
description: Review a pull/merge request (by id) or batch-review every open one against Chris's own engineering standards, staging high-signal findings to .data/merge/<ID>.md for later posting. Fetches head SHAs and applies the "Reviewed at commit" skip check BEFORE any checkout, resolves the head fork-safely, builds/tests it in a dedicated worktree, and treats a failing build/checkout as the top blocking finding. First runs /detect-source-control and hard-stops when the forge is unsupported. Use as "review the PR", "review the open MRs", "any PRs need my eyes", "review <id>".
argument-hint: "[<ID>]  — a PR/MR number to review one; omit to batch-review all open"
---

# merge-request:review

Review a change the way **Chris** would (see `../../SOUL.md`) and stage only the
findings that actually matter — against a **real, buildable checkout**, not just
the unified diff. Reviews one PR/MR when given an id, or every open one when not.
It never posts to the forge; it stages to `.data/merge/<ID>.md` so a human gate
(`/merge-request:post-findings`) stands between the opinion and someone's PR.

This is an **assistant-executed** skill: you (the assistant) follow the steps
below. The deterministic, must-behave-identically forge/git work lives in three
scripts — `scripts/triage.sh` (scope + head-SHA skip check), `scripts/setup-worktree.sh`
(fork-safe head resolution + worktree), `scripts/build-and-test.sh` (auto-detected
build/test). The judgment — being Chris, applying the rubric, wording findings —
is *yours*.

> **Scope note (fn-11.2 vs fn-11.3).** This file, as delivered here, is the review
> **engine**: scope (Step 0), the pre-checkout skip check (Step 2), fork-safe
> worktree setup (Step 3), auto build/test (Step 4), and writing `## Build` + the
> `merge-review-status` marker + the blocking-failure finding (Step 5). The
> **finding-selection** half — fetching/normalizing existing threads to dedupe,
> applying `../../RUBRIC.md` + `../../SOUL.md` to pick and word findings, and
> staging the full `## Findings` set — is layered on at **Step 6** by fn-11.3.
> **Marker ownership is the engine's:** any run that writes *any* `## Findings`
> entry (including a checkout/build failure before selection runs) sets the marker
> to `findings`, so a stale `clean` from a prior run can never linger.

## Step 0 — determine scope (single vs batch)

- **`/merge-request:review <ID>`** (an id was given) → review exactly that one
  PR/MR (single-ID scope).
- **`/merge-request:review`** (no argument) → **batch-review every open PR/MR**.

Never guess an id in batch mode — "no argument" *means* "all open", which
`triage.sh` enumerates from the forge.

## Step 1 — detect the forge and hard-stop if unsupported

Invoke the shared **`/detect-source-control`** skill and capture its stdout block
**and** exit code. Go through the skill rather than reaching into another plugin's
install path — the sibling directory is not a guaranteed-stable layout.

Apply the **fn-8 hard-stop contract** (see `../../README.md`):

- **Non-zero exit** → operational failure (not a git repo, `git` missing). Stop
  and report; nothing was changed.
- **Exit `0` and `supported=false`** (`forge=unsupported`) → a *successful*
  detection of an unsupported forge. Stop with a message that names the detected
  `forge`/`host`:
  > This repository's forge is not supported (`forge=unsupported`,
  > `host=<host>`). `/merge-request:review` works only with GitHub and GitLab.
  > Nothing was changed.
- **Exit `0` and `supported=true`** → proceed. Remember `forge` (`github` or
  `gitlab`) for the scripts.

Never key the unsupported stop off a non-zero exit — `forge=unsupported` is a
normal exit-`0` result.

## Step 2 — triage: fetch head SHAs and apply the skip check BEFORE any checkout

Run `triage.sh` with the resolved forge (and the id, in single-ID scope):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/review/scripts/triage.sh" \
  --forge <github|gitlab> [--id <ID>]
```

It emits a JSON array, one object per candidate PR/MR:

```json
{ "id": 42, "title": "…", "web_url": "…",
  "current_sha": "<head sha>", "recorded_sha": "<from the artifact>",
  "action": "new|re-review|skip",
  "head_ref": "…", "head_owner": "…", "head_repo": "…",
  "stash_file": ".data/merge/42.md" }
```

`action` is the skip/re-review contract (ARTIFACT.md), decided **here, before any
worktree setup or build**, by comparing the freshly-fetched head SHA against the
`Reviewed at commit:` stamp in the artifact:

- **`skip`** — recorded SHA == head SHA. The review is current; **do nothing**
  for this PR/MR (no checkout, no build). This is the whole point of doing the
  skip check first: already-current reviews cost nothing.
- **`new`** — no artifact yet. Review it.
- **`re-review`** — the head advanced (or the stamp was missing/unparseable, or
  the head SHA could not be resolved). Review it. An unresolvable head is
  deliberately never `skip` — it flows into Step 3 where it becomes a blocking
  finding rather than being silently passed over.

Process every `new`/`re-review` entry through Steps 3–6; leave `skip` entries
untouched. In batch mode, an empty `[]` means nothing is open — report that and
stop.

## Step 3 — set up the worktree (fork-safe head resolution)

For each PR/MR to review, establish a real checkout:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/review/scripts/setup-worktree.sh" \
  --forge <github|gitlab> --id <ID>
```

The script, deterministically:

1. **Resolves the head fork-safely** — prefers forge API/CLI metadata for the
   head SHA (and, on GitHub, the fork owner/repo/branch), then transports the
   objects via the PR/MR head ref (`refs/pull/<n>/head` / `refs/merge-requests/<iid>/head`),
   with a direct-SHA and GitHub-fork-clone fallback.
2. **Reuses the dedicated worktree when already inside it** (branch `merge/<ID>`
   or a worktree dir named `merge-<ID>`) — just resetting it to the head.
   Otherwise it creates `.worktrees/merge-<ID>` (off the main worktree) with a
   checkout branch `merge/<ID>` at the resolved head, or fast-forwards an
   existing one.

Parse its machine tail:

```
WORKTREE=<path>   HEAD_SHA=<sha>   BASE_SHA=<sha|"">   [START_SHA=<sha|"">]
BRANCH=merge/<ID>
CHECKOUT=ok|unresolved   STATE=created|updated|reused   RESOLUTION=…
```

`HEAD_SHA` and `BASE_SHA` are the **diff endpoints** the review is anchored
against — they define the changed-files/diff source used in Step 6 (below) and
populate a finding's `head_sha`/`base_sha`. `START_SHA` is emitted **only on
GitLab** (its inline position needs the `base_sha`+`start_sha`+`head_sha` triple);
on GitHub it is omitted. `BASE_SHA`/`START_SHA` may be empty when forge metadata
was unavailable — the diff then falls back to the merge-base (see Step 6c).

- **`CHECKOUT=ok`** → continue to Step 4, using `WORKTREE`.
- **`CHECKOUT=unresolved`** (exit 1) → the head could **not** be resolved. Do
  **not** fail silently: go straight to Step 5's **blocking-finding** path with a
  checkout failure (`## Build` note + the first `## Findings` entry, `issue:`,
  `kind: general`), set the marker to `findings`, re-stamp `Reviewed at commit`
  (to the triage `current_sha` if known, else leave the prior stamp), and **skip
  build/test** for this PR/MR.

## Step 4 — auto-detect and run build/test in the worktree

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/review/scripts/build-and-test.sh" \
  --worktree <WORKTREE> --id <ID>
```

Detection order (first ecosystem that yields a command wins): **package-manager
scripts (package.json) → Makefile/justfile → Cargo → Go → .NET.** Within package
scripts the selection is **cumulative**: `ci` if present, else `build` (if
present) AND `test`/`check` (if present) — a repo with both runs both. Lint/
format-only commands are never selected on their own (this skill emits no style
findings). Parse the tail:

```
BUILD_TEST=pass|fail|n/a   BUILD_ECOSYSTEM=…   BUILD_COMMANDS=…   BUILD_LOG=<path>
```

- **`pass`** — build/test cleared. Fold the log into `## Build` (Step 5), no
  blocking finding.
- **`n/a`** — "no build/test command detected". Record that in `## Build`; it is
  **not** a failure (the repo may not expect one).
- **`fail`** — a failing build/test is the **top blocking finding**. Go to
  Step 5's blocking-finding path in addition to logging `## Build`.

## Step 5 — write `## Build`, the marker, the stamp (+ any blocking finding)

Update `.data/merge/<ID>.md` per `../../ARTIFACT.md`. **Replace only the
`review`-owned sections** — `## Findings` and `## Build` — and rewrite the header
`Reviewed at commit:` stamp and `<!-- merge-review-status: … -->` marker.
**Preserve `## Intent`, `## Handled`, and `## Declined` byte-for-byte.** If the
artifact does not exist yet, create it with the header + empty preserved sections.

**`## Build`** holds the run's build/test/checkout outcome: the `BUILD_COMMANDS`
that ran and the `BUILD_LOG` contents (or "no build/test command detected", or
the checkout-failure reason from `CHECKOUT=unresolved`).

**Blocking failure ⇒ the first `## Findings` entry.** An unresolvable checkout
(Step 3) or a failing build/test (Step 4) is logged in `## Build` **and** becomes
the **first** `## Findings` entry — `issue:` prefix, `kind: general` (no file/
line), with a deterministic `F-<hash>` id. Compute the id over the ARTIFACT tuple
`{PR/MR id, file path, line/range, prefix, normalized title/body}` — for a general
finding file/line are empty:

```bash
printf '%s' "<ID>|||issue:|<normalized one-line failure summary>" \
  | { command -v sha1sum >/dev/null 2>&1 && sha1sum || shasum; } \
  | cut -c1-12 | sed 's/^/F-/'
```

**Marker rule (engine-owned):** whenever this run writes **any** `## Findings`
entry — including this blocking one, before fn-11.3's selection runs — set
`<!-- merge-review-status: findings -->`. Only a run that finishes selection with
**zero** findings sets `clean` (that final decision is fn-11.3's; the engine only
ever moves the marker toward `findings`).

To rewrite the review-owned sections while preserving the rest, assemble the file
from the preserved sections + freshly-written ones (an `awk` that drops the old
`## Findings`/`## Build` and re-emits everything else, mirroring the pattern in
`../fix/scripts/gather-feedback.sh`), then re-write the header stamp/marker. Never
edit `## Intent`/`## Handled`/`## Declined`.

## Step 6 — finding selection + staging (be Chris)

With a clean checkout and `## Build` written, do the **finding-selection** half:
read the change the way **Chris** reads it (`../../SOUL.md` — read it and *be*
Chris, don't summarize it), select only findings that clear `../../RUBRIC.md`,
drop anything already covered, and stage them to `## Findings`. **Never post to
the forge** — this only writes disk.

The mechanical forge/hash work lives in `scripts/fetch-threads.sh`; the judgment
(being Chris, applying the rubric, wording the finding) is yours.

### 6a — fetch + normalize the existing threads (dedupe input)

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/review/scripts/fetch-threads.sh" \
  threads --forge <github|gitlab> --id <ID>
```

It emits one JSON object per **existing** PR/MR thread/comment —
`{author, body, file?, line?, resolved?, kind}`, with `file`/`line`/`resolved`
**null** for global comments and `kind` = `inline`|`general` — followed by a
`THREADS_FETCHED=…` trailer. It covers **GitHub** (review threads + issue
comments) and **GitLab** (discussions + notes), and **includes resolved threads**
(`resolved:true`) — a point already raised must suppress a re-raise even after it
was resolved. A missing/unauthenticated CLI degrades to zero threads (never a
hard failure).

### 6b — layer in learned preferences (optional; owned by fn-12)

Read the learned-preferences file per `../../RUBRIC.md`'s lookup contract —
global base `~/.claude/merge-request-preferences.md` then project override
`.data/merge/preferences.md` (project overrides global on conflict; additive
lists union). It is **owned by `/merge-request:post-findings` (fn-12)**; when
absent, proceed on rubric + persona alone. Apply *Don't raise* (suppress matching
findings even if they'd clear the rubric), *Wording preferences*, and *Confirmed
valued* as you select.

### 6c — select findings as Chris

**Changed-files / diff source (defined).** The diff endpoints are the `HEAD_SHA`
and `BASE_SHA` parsed in Step 3. Against the `WORKTREE` from Step 3, the review's
changed files and diff are:

```bash
# changed files (with rename detection -> old_path for renames)
git -C "<WORKTREE>" diff --name-status -M "<BASE_SHA>..<HEAD_SHA>"
# full unified diff the findings are read from
git -C "<WORKTREE>" diff "<BASE_SHA>..<HEAD_SHA>"
```

When `BASE_SHA` is empty (forge metadata was unavailable), fall back to the
merge-base: `base="$(git -C "<WORKTREE>" merge-base HEAD_SHA <default-branch>)"`
and use `"$base..<HEAD_SHA>"`. This is the single, defined base the selection uses
— there is no other "PR/MR base".

Read the change against this **real checkout** + diff, and run `../../RUBRIC.md`
over it as Chris. Raise only what passes the
one-line test — *can I name the concrete thing that breaks, and would a good
engineer nod?* Lead with the highest-ranked defensible finding. Stay silent on
everything on the rubric's silence list. **Every finding stands on universal
engineering merit only — never reference any company, brand, framework, or house
policy.**

### 6d — drop anything already covered (dedupe on substance)

For each candidate finding, check it against the 6a threads: if a human, a prior
round, or an AI reviewer **already covered it on substance** — inline *or*
general, resolved *or* not, even clumsily — **drop it**. Don't pile on to look
thorough. This is a substance match, not a string match; that judgment is yours.

### 6e — tag each surviving finding

Give each finding:

- a **Conventional Comments prefix** (`issue:`/`suggestion:`/`question:`/`todo:`/`nitpick:`) — the honest one;
- a **`kind`** — `inline` (anchored to a changed diff line) or `general` (no file/line);
- for `kind: inline`, the **inline-location fields** `file` (new-side path), `old_path` (only if renamed — from the `git diff --name-status -M` in 6c), `line` or `line_range`, `side` (`LEFT`/`RIGHT`), and `head_sha`/`base_sha` (the diff endpoints from Step 3 — `HEAD_SHA` and `BASE_SHA`, i.e. the same base the 6c diff was taken against; on GitLab also carry `START_SHA` for the position triple), so fn-12 can post it inline;
- a **deterministic `F-<hash>` id**, computed with the **same** serialization the engine pinned in Step 5 — do **not** invent your own:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/review/scripts/fetch-threads.sh" \
  finding-id --id <ID> --prefix "<prefix>" --body "<normalized one-line body>" \
  [--file <file> --line <line-or-range>]
```

`finding-id` is **byte-identical** to the Step 5 inline `printf` (tuple
`{id}|{file}|{line}|{prefix}|{normalized one-line body}` → `{ sha1sum || shasum; }`
→ `cut -c1-12` → `F-`); pass file/line **empty for a `general` finding**. Using
the same implementation is what lets a selected finding correlate with the
engine's blocking finding and with the `## Declined` ledger across re-review runs.

### 6f — stage to `## Findings` and set the marker

Replace the `review`-owned `## Findings` section wholesale (per Step 5's
preserve-the-rest `awk` pattern — **`## Intent`/`## Handled`/`## Declined` stay
byte-for-byte intact**). Write one JSON record per finding in a fenced
```` ```jsonl ```` block (mirrors `## Handled`), so fn-12 can parse and correlate
by `F-<hash>`:

```jsonl
{"id":"F-…","prefix":"issue:","kind":"inline","file":"src/config.ts","old_path":null,"line":12,"line_range":null,"side":"RIGHT","head_sha":"…","base_sha":"…","body":"…"}
{"id":"F-…","prefix":"suggestion:","kind":"general","file":null,"old_path":null,"line":null,"line_range":null,"side":null,"head_sha":null,"base_sha":null,"body":"…"}
```

- If Step 5 already staged a **blocking** build/checkout finding, it is the
  **first** record (its `F-<hash>` from Step 5, `issue:`, `kind: general`) and the
  marker stays `findings` regardless of what selection adds.
- **Marker rule:** set `<!-- merge-review-status: clean -->` **iff the run ends
  with zero `## Findings` entries** (no blocking finding, no selected finding) —
  Chris's clean-change signal; otherwise `findings`. This is the only place the
  marker is allowed to move toward `clean`.
- A clean change gets no manufactured praise here — the `Looks good.` sign-off is
  cast later by fn-12; `review` records the clean state via the marker alone.

## Notes

- **Skip check is first, always.** Head SHAs are fetched and compared in Step 2
  *before* any worktree/build, so an already-current review never pays for a
  checkout — the batch stays cheap.
- **Fork-safe by design.** Head resolution prefers forge metadata and transports
  via PR/MR head refs, so forked GitHub PRs and restricted remotes still check
  out; only a genuinely unresolvable head becomes a finding.
- **A blocking failure is a finding, not a silent skip.** An unresolvable
  checkout or a failing build/test is logged in `## Build` *and* surfaced as the
  first `## Findings` entry so `/merge-request:post-findings` can post it as a
  general comment.
- **Re-review preserves state.** A run replaces `## Findings`/`## Build` and
  rewrites the stamp/marker, but never touches `## Intent`/`## Handled`/
  `## Declined`.
- **Never posts.** This skill only stages; posting is `/merge-request:post-findings`.

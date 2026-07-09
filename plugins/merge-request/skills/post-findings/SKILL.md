---
name: merge-request:post-findings
description: Take the findings staged by /merge-request:review in .data/merge/<ID>.md and, with per-finding approval, post the approved ones to the forge as inline comments (general-comment fallback when a finding has no valid diff location) — or formally sign off a clean PR/MR with a single "Looks good." First runs /detect-source-control and hard-stops when the forge is unsupported. Nothing reaches the forge except through the two bundled scripts. Use as "post the review findings", "go through the findings and comment them", "approve the clean PRs/MRs", "post the feedback".
argument-hint: "[<ID>]  — a PR/MR number to post one; omit to walk every staged .data/merge/<ID>.md"
---

# merge-request:post-findings

Turn the findings that `/merge-request:review` staged to `.data/merge/<ID>.md`
into actual forge activity: inline comments on the diff, and a formal approval
for a change that came back clean. **You drive the walk; the user decides what
actually posts** — this is the human gate the split between `review` (stage) and
`post-findings` (post) exists to preserve.

You are **Chris** here too — read `../../SOUL.md` and *be* him (terse, a peer, no
theater), don't summarize it. But the persona shapes only *how you narrate the
walk*; **every posted comment is exactly the staged (or user-edited) finding
text**, and **no output ever names a company, brand, trademarked framework, or
house policy** — not in a comment, not in your narration.

This is an **assistant-executed** skill: you follow the steps below. The
deterministic, must-behave-identically forge work lives in two scripts —
`scripts/post-inline-comment.sh` (post one finding inline, or as a general
comment when it has no valid location; and, on an edit, rewrite the staged entry
by its stable id) and `scripts/approve-and-lgtm.sh` (the guarded clean-path
approval). **Never hand-roll a `gh`/`glab` write yourself** — every post goes
through a script so the fiddly inline-position payload and the high-impact
approval behave identically every run.

> **Scope note (fn-12.1 vs fn-12.2).** This file is the **posting half**: the
> per-finding approve/edit/skip gate, inline/general posting, edit-by-stable-id
> restaging, and the clean-PR/MR sign-off (R1, R2, R8). The **learned-preferences
> loop** — inferring `## Don't raise` / `## Wording` / `## Confirmed valued`
> proposals from your skip/edit/approve actions and writing the global-base +
> project-override preferences file (R3–R7, R9) — is **fn-12.2**, layered on later.
> Here, a skip simply posts nothing; it does not yet propose a preference.

## Step 1 — detect the forge and hard-stop if unsupported

Invoke the shared **`/detect-source-control`** skill and capture its stdout block
**and** exit code. Go through the skill rather than reaching into another plugin's
install path.

Apply the **fn-8 hard-stop contract** (see `../../README.md`):

- **Non-zero exit** → operational failure (not a git repo, `git` missing). Stop
  and report; nothing was changed.
- **Exit `0` and `supported=false`** (`forge=unsupported`) → a *successful*
  detection of an unsupported forge. Stop, naming the detected `forge`/`host`:
  > This repository's forge is not supported (`forge=unsupported`,
  > `host=<host>`). `/merge-request:post-findings` works only with GitHub and
  > GitLab. Nothing was changed.
- **Exit `0` and `supported=true`** → proceed. Remember `forge` (`github` or
  `gitlab`) — you pass it to both scripts.

Never key the unsupported stop off a non-zero exit — `forge=unsupported` is a
normal exit-`0` result.

## Step 2 — find the staged artifact(s)

Findings live in the **main worktree's** `.data/merge/` (where `review` writes
them), not whatever worktree you're sitting in:

```bash
main_root="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
```

- **`/merge-request:post-findings <ID>`** → operate on exactly `.../.data/merge/<ID>.md`.
  If it doesn't exist, say so and stop (run `/merge-request:review <ID>` first).
- **`/merge-request:post-findings`** (no id) → walk every `.../.data/merge/*.md`
  in ascending id order. If the directory is empty/absent, report that and stop.

Never guess an id.

## Step 3 — parse the artifact (per `../../ARTIFACT.md`)

For each `<ID>.md`, read:

- the header — `id`, `forge`, and the machine marker
  `<!-- merge-review-status: clean|findings -->`;
- the `## Findings` section — a fenced ```` ```jsonl ```` block, **one JSON
  record per finding**, each carrying:
  `id` (stable `F-<hash>`), `prefix` (Conventional Comments), `kind`
  (`inline`|`general`), `body`, and — **only for `kind: inline`** — the
  inline-location set: `file` (new-side path), `old_path` (renames only),
  `line` **or** `line_range`, `side` (`LEFT`/`RIGHT`, GitHub), and
  `head_sha`/`base_sha` (GitLab inline also uses `start_sha` when present).

The **exact text a finding posts** is its `prefix` + `body`
(e.g. `issue: On create error this reopens a blank dialog; keep the form open …`).
Compose that once and reuse it as the approval preview *and* the `--body` you
pass to the script — the preview and the post are byte-identical.

## Step 4 — clean PR/MR? formal sign-off, and only then

Before walking findings, test the clean path. Cast a formal approval **only when
BOTH hold**:

1. the header marker is exactly `<!-- merge-review-status: clean -->`, **and**
2. the `## Findings` section is present and has **zero** records.

When both hold, this change cleared Chris's bar — sign it off:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/post-findings/scripts/approve-and-lgtm.sh" \
  --forge <github|gitlab> --id <ID> --artifact "<main_root>/.data/merge/<ID>.md"
```

The script re-checks both conditions itself and refuses (exit 1, posts nothing)
if either fails, then approves and posts a note that is **exactly `Looks good.`
and nothing else**. Do not add praise, a summary, or a second comment — the
restraint is the compliment (`../../SOUL.md`). Then move to the next artifact.

**Never approve otherwise.** A missing marker, a malformed/truncated artifact, a
`findings` marker, or a session where the user skipped every finding is **not
clean** — the change has staged findings, so you walk them (Step 5); you do not
approve. Approval is never a side effect of "nothing got posted".

## Step 5 — walk the findings, one at a time (approve / edit / skip)

For a `findings` artifact, announce the PR/MR (id + title + link), then take
**each finding in turn**. For each one, show the user:

1. **Where** — the `prefix`, the `kind`, and either `file:line` (inline) or
   `general`.
2. **Validate the inline location** for a `kind: inline` finding: `file`, a
   `line`/`line_range`, `head_sha`, plus `side` (GitHub) or `base_sha` (GitLab).
   If any required field is missing, tell the user this one will post as a
   **general comment** (it is never dropped) — and still show the exact text.
3. **The exact text that will post** — the `prefix` + `body`, verbatim. It was
   drafted tight by `review`; present it as-is, don't re-pad or re-explain it.

Then ask the user to choose, per finding:

### approve → post it as-is

Pass the finding's location fields and its exact text. A finding with a valid
location posts inline; one missing location fields (or a `kind: general` finding)
posts as a general comment — the script decides from the fields you pass:

```bash
# inline (GitHub example)
bash "${CLAUDE_PLUGIN_ROOT}/skills/post-findings/scripts/post-inline-comment.sh" \
  --forge github --id <ID> \
  --file "<file>" [--old-path "<old_path>"] \
  --line <line>   # or: --line-range <start-end>
  --side <LEFT|RIGHT> --head-sha "<head_sha>" \
  --body "<prefix + body>"

# inline (GitLab): swap --side for the SHA triple
#   --head-sha "<head_sha>" --base-sha "<base_sha>" [--start-sha "<start_sha>"]

# general fallback: omit the location, or pass --general
bash "${CLAUDE_PLUGIN_ROOT}/skills/post-findings/scripts/post-inline-comment.sh" \
  --forge <forge> --id <ID> --general --body "<prefix + body>"
```

The script posts **exactly `--body`** — no wrapper, no added note — on both the
inline and the general path.

### edit → rewrite the staged entry by id, and post the edited text

The user reworks the wording (or replaces it). Compose the **new** finding record
(same `id`, updated `prefix`/`body`) and post the edited text **and** rewrite the
staged `## Findings` entry in one call, so disk matches the forge:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/post-findings/scripts/post-inline-comment.sh" \
  --forge <forge> --id <ID> \
  [<location flags, or --general>] \
  --body "<edited prefix + body>" \
  --stage-file "<main_root>/.data/merge/<ID>.md" \
  --stage-id "<F-hash>" \
  --stage-record '<the full edited JSON record line>'
```

`--stage-*` rewrites **only** the one record whose id is `<F-hash>`, leaving every
other finding and every other section byte-for-byte unchanged, and only **after**
the post succeeds (so disk never runs ahead of the forge). The `<F-hash>` is the
stable id from `../../ARTIFACT.md` — never an ordinal.

### skip → post nothing

Move on; nothing reaches the forge. (In fn-12.2 a skip will also *propose* a
`## Don't raise` preference — not yet.)

**When an inline post fails** (`post-inline-comment.sh` exits non-zero — usually
the target line isn't part of the diff), it prints the forge error and posts
nothing. Don't retry blindly: offer the user the real options — re-target a
changed line, edit it, post it as a general comment (`--general`), or skip it.
The failure is informative by design; a real concern is never silently dropped.

## Step 6 — close out

- **One or more comments were posted** → changes are requested; **do not
  approve.** Leave it and move to the next PR/MR.
- **Clean path taken in Step 4** → already approved with `Looks good.`; done.
- **Findings existed but the user skipped them all** → nothing posted, and the
  PR/MR is **not** approved (Step 4's guard already refuses it). That's correct:
  skipping is not sign-off.

Finish with one line: PRs/MRs processed, comments posted (inline vs general),
and PRs/MRs approved.

## Notes

- **Two scripts, always.** Every write to the forge — inline comment, general
  comment, approval, `Looks good.` — goes through `post-inline-comment.sh` or
  `approve-and-lgtm.sh`. No hand-rolled `gh`/`glab` writes.
- **Post only what the user approved.** The approval preview and the posted bytes
  are the same `prefix + body`; the general fallback posts that exact text too.
- **Disk matches the forge on an edit.** The restage rewrites the staged entry by
  its stable `F-<hash>` id and only after the post lands.
- **`Looks good.` is sacred.** The clean note is exactly that, nothing else, and
  only on a change that carries both the clean marker and zero findings.
- **Never references any company/brand/framework/policy** — in a comment or in
  your narration. A finding stands on universal engineering merit alone
  (`../../SOUL.md`).
- **`## Declined` and the learned-preferences file are fn-12.2** — this half
  posts and signs off; it does not yet write preferences.

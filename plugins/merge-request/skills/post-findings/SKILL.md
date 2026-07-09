---
name: merge-request:post-findings
description: Take the findings staged by /merge-request:review in .data/merge/<ID>.md and, with per-finding approval, post the approved ones to the forge as inline comments (general-comment fallback when a finding has no valid diff location) — or formally sign off a clean PR/MR with a single "Looks good." First runs /detect-source-control and hard-stops when the forge is unsupported. Nothing reaches the forge except through the bundled scripts. Also runs a propose-then-confirm learned-preferences loop that teaches /merge-request:review what you value (Don't-raise / Wording / Confirmed-valued), and records skipped findings to the artifact's ## Declined section. Use as "post the review findings", "go through the findings and comment them", "approve the clean PRs/MRs", "post the feedback".
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

> **Two responsibilities.** This skill (a) **posts** — the per-finding
> approve/edit/skip gate, inline/general posting, edit-by-stable-id restaging,
> and the clean-PR/MR sign-off (R1, R2, R8) — and (b) **learns** — a
> propose-then-confirm loop (**Step 7**) that infers `## Don't raise` /
> `## Wording` / `## Confirmed valued` updates from your skip/edit/approve
> actions and writes them to the global-base + project-override preferences file
> (R3–R7, R9), so `/merge-request:review` (fn-11.3, which reads the merged file)
> sharpens to Chris over time. A **skip** also appends the finding to the shared
> `## Declined` section of the artifact. A **third script** carries the
> deterministic preferences work: `scripts/merge-prefs.sh` (the keyed merge, the
> scoped confirmed write, the append-only `## Declined` record) — never hand-edit
> the preferences file or the artifact's `## Declined` yourself.

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

### skip → post nothing, record the decline, learn from it

Nothing reaches the forge. Two things still happen:

1. **Record the decline** in the artifact's shared `## Declined` section, so a
   later re-review knows this finding was already turned down at the gate and
   doesn't re-surface it (per `../../ARTIFACT.md`; `fix`/fn-10 owns the other
   half of this section). Append-only — every other section is untouched:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/skills/post-findings/scripts/merge-prefs.sh" declined-append \
     --file "<main_root>/.data/merge/<ID>.md" \
     --finding-id "<F-hash>" \
     --summary "<the finding's one-line gist>" \
     [--rationale "<why you skipped it>"]   # defaults to "declined at post gate"
   ```

2. **Note it for the preferences loop** — a skip is the signal for a
   `## Don't raise` proposal (Step 7). Don't write the preference now; hold the
   pattern and propose it at session end.

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

## Step 7 — learned-preferences loop (propose-then-confirm)

At the **end of the session** (after the last PR/MR), fold what you saw into the
learned preferences so `/merge-request:review` gets sharper. **Nothing is written
without a per-item confirmation** — you propose, the user confirms *and picks the
scope*, then you write. Deferring to a natural break keeps the walk uninterrupted.

### Where preferences live — and the merge model

Two files, both optional:

- **global base** `~/.claude/merge-request-preferences.md` — cross-project voice
  and standards that travel with Chris.
- **project override** `<main_root>/.data/merge/preferences.md` — per-repo tuning
  (gitignored; shared only via an explicit `git add -f`).

Every entry carries a normalized, **space-free `key`**. When `review` (fn-11.3)
reads them, `merge-prefs.sh merge` composes the two: a project entry with the
**same key replaces** the global one; **different keys union**. So a per-repo rule
overrides the global default for that exact pattern, and adds otherwise.

Four sections — three inferred here, one preserve-only:

| Section              | Key                                     | Inferred from                |
|----------------------|-----------------------------------------|------------------------------|
| `## Don't raise`     | `<rubric-category>/<pattern>` (+ count)  | a **skip**                   |
| `## Wording`         | `<phrasing-rule id>`                     | an **edit**                  |
| `## Confirmed valued`| `<rubric-category>/<pattern>`            | an **approve** (borderline)  |
| `## Rubric weighting`| `<flag name>`                            | **never** — hand-edited only |

### The three inferences

- **skip → `## Don't raise`.** Propose a Don't-raise on the **first** skip of a
  pattern (fast learning, still gated). Repeated skips of the **same key**
  `--increment` its `count` — the confidence signal. Generalize the *pattern*
  (rubric-category + the normalized shape of what you skipped), never the one-off
  specifics of a single line.
- **edit → `## Wording`.** The delta between what `review` staged and what the
  user posted is a phrasing rule. Propose the **generalized rule** (e.g. "frame as
  suggestions, not directives"), not the verbatim example.
- **approve of a borderline / previously-flagged finding → `## Confirmed
  valued`.** When the user approves something that sat near the bar, propose
  promoting that pattern so `review` keeps surfacing it with confidence.

`## Rubric weighting` is **never inferred** — `merge-prefs.sh upsert` refuses to
write it. The user edits it by hand; it merges through by the same keyed model.

### Propose, choose scope, then write

For each proposal, first **propose** (writes nothing) so you can show the user the
exact entry that would land:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/post-findings/scripts/merge-prefs.sh" upsert \
  --scope <global|project> --file "<that scope's path>" \
  --section <dont-raise|wording|confirmed-valued> \
  --key "<normalized key>" --text "<the rule, generalized>" [--increment]
# → prints PROPOSED=<entry> and writes nothing
```

Show the `PROPOSED=` line and ask the user to confirm **and pick the scope** — the
prompt names the target file. Sensible defaults, overridable per item:

- **Don't-raise → project override** (often a per-repo convention).
- **Wording → global** (a cross-project voice rule).

On confirmation, re-run the same command **with `--confirm`** and the chosen
`--scope`/`--file`:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/post-findings/scripts/merge-prefs.sh" upsert \
  --scope project --file "<main_root>/.data/merge/preferences.md" \
  --section dont-raise --key "<key>" --text "<rule>" --increment --confirm
# → WROTE=project  ACTION=appended|incremented  KEY=…  COUNT=…
```

The two scope paths:

- **global**  → `~/.claude/merge-request-preferences.md`
- **project** → `<main_root>/.data/merge/preferences.md`

If the user declines a proposal, write nothing and move on. Skipping the whole
loop is always fine — the preferences file is optional, and the confirm step is
the only thing that ever writes.

## Notes

- **Scripts, always.** Every write to the forge — inline comment, general
  comment, approval, `Looks good.` — goes through `post-inline-comment.sh` or
  `approve-and-lgtm.sh`; every write to the preferences file or the artifact's
  `## Declined` goes through `merge-prefs.sh`. No hand-rolled `gh`/`glab` writes,
  no hand-edited preferences.
- **Post only what the user approved.** The approval preview and the posted bytes
  are the same `prefix + body`; the general fallback posts that exact text too.
- **Disk matches the forge on an edit.** The restage rewrites the staged entry by
  its stable `F-<hash>` id and only after the post lands.
- **`Looks good.` is sacred.** The clean note is exactly that, nothing else, and
  only on a change that carries both the clean marker and zero findings.
- **Never references any company/brand/framework/policy** — in a comment or in
  your narration. A finding stands on universal engineering merit alone
  (`../../SOUL.md`).
- **A skip records a decline and teaches.** `merge-prefs.sh declined-append`
  writes the skipped finding to the artifact's append-only `## Declined` section
  (so a re-review won't re-surface it), and the skip also seeds a `## Don't raise`
  proposal for Step 7.
- **Preferences are proposed, never written silently.** Every `## Don't raise` /
  `## Wording` / `## Confirmed valued` entry lands only after a per-item confirm
  that also picks the scope (global vs project). `## Rubric weighting` is
  merge/preserve-only — hand-edited, never inferred. The keyed merge model
  (`merge-prefs.sh merge`) lets a project override the global for the same key
  while unioning different keys; `review` (fn-11.3) reads the merged view.

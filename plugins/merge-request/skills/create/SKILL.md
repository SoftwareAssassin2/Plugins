---
name: merge-request:create
description: Open a ready pull/merge request for the current branch on whichever forge the repo uses (GitHub via gh, GitLab via glab), then hand the new PR/MR to the fix-monitoring loop. First runs /detect-source-control and hard-stops when the forge is unsupported. Use to create a PR/MR for the current branch, "open a PR", "raise an MR", or start the merge-request workflow.
argument-hint: "(no arguments — run on the branch you want a PR/MR for)"
---

# merge-request:create

Open a ready-for-review pull/merge request for the **current branch** on the
repo's forge, stash the author's intent so the fix loop can read it across
sessions, then continue into `/merge-request:fix <ID>`.

This is an **assistant-executed** skill: you (the assistant) follow the steps
below. The deterministic git/CLI work (push, create, id capture, intent stash)
lives in `scripts/create.sh`; the `/merge-request:fix` handoff is *your*
continuation, not a shell call — a script cannot invoke a slash command.

## Step 1 — detect the forge and hard-stop if unsupported

Invoke the shared **`/detect-source-control`** skill and capture its stdout block
**and** exit code. Go through the skill rather than reaching into another
plugin's install path — the sibling directory is not a guaranteed-stable layout.
(A direct `bash "${CLAUDE_PLUGIN_ROOT}/../detect-source-control/scripts/detect.sh"`
is only a last-resort fallback if the skill is unavailable.)

Then apply the **fn-8 hard-stop contract** (see `../../README.md`):

- **Non-zero exit** → operational failure (not a git repo, `git` missing). Stop
  and report; nothing was changed.
- **Exit `0` and `supported=false`** (i.e. `forge=unsupported`) → a *successful*
  detection of an unsupported forge. Stop with a message that names the detected
  `forge`/`host`, e.g.:
  > This repository's forge is not supported (`forge=unsupported`,
  > `host=bitbucket.org`). `/merge-request:create` works only with GitHub and
  > GitLab. Nothing was changed.
- **Exit `0` and `supported=true`** → proceed. Remember `forge` (`github` or
  `gitlab`) for Step 3.

Never key the unsupported stop off a non-zero exit — `forge=unsupported` is a
normal exit-`0` result.

## Step 2 — capture the session's pre-MR intent

Before creating, write the author's **stated intent for this change** — the
"why", from the current session — to a scratch file so the script can stash it:

```bash
cat > /tmp/mr-intent.$$ <<'EOF'
<one short paragraph: what this branch is trying to accomplish and why>
EOF
```

If the session has no explicit stated intent, **skip this file** — the script
writes `[TODO] Intent not provided` as a defined placeholder, and preserves any
existing intent on a resume. Do not invent intent the author never expressed.

## Step 3 — create the PR/MR (push if needed, capture the id, stash intent)

Run the helper with the resolved forge:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/create/scripts/create.sh" \
  --forge <github|gitlab> \
  --intent-file /tmp/mr-intent.$$      # omit --intent-file when Step 2 was skipped
```

The script, deterministically:

1. **Ensures HEAD is on the remote** — `git push -u` when the branch has no
   upstream; pushes the unpushed commits when the upstream is behind; no-ops
   when already up to date.
2. **Creates a ready PR/MR** targeting the auto-detected default branch, titled
   **exactly** `Merge <source-branch> into <target-branch>`, with a minimal body
   (`gh pr create` / `glab mr create`, not draft).
3. **Captures the canonical id robustly** — via `gh pr view --json number` /
   `glab mr view --output json`; only if that JSON path fails does it fall back
   to parsing the trailing number from the create-command URL.
4. **Resumes on an existing open PR/MR** — if creation reports one already open
   for this branch, it resolves that id (same `view` path) and refreshes the
   stash instead of erroring, so a re-run is safe.
5. **Writes the intent stash** to `.data/merge/<ID>.md` — a `## Intent` block
   (your Step-2 text, or the `[TODO]` placeholder / preserved prior intent) plus
   a `## Change scope` section from `git log <target>..HEAD --oneline` and
   `git diff --stat <target>...HEAD`.

It prints a machine-readable tail you parse:

```
MR_ID=<number>
MR_FORGE=<github|gitlab>
MR_SOURCE=<source-branch>
MR_TARGET=<target-branch>
MR_STATE=<created|existing>
MR_STASH=<.data/merge/<ID>.md>
```

Read `MR_ID` from that output. Clean up the scratch intent file
(`rm -f /tmp/mr-intent.$$`).

If the script exits non-zero, surface its stderr message and stop — do not
attempt the handoff without a confirmed id.

## Step 4 — hand off to the fix loop

With the captured id, **continue into `/merge-request:fix <MR_ID>`** — this is an
assistant-level continuation: immediately proceed to run that skill with the id
you captured (e.g. `/merge-request:fix 128`). Report to the user what was opened
(id, title, `MR_STATE`) before continuing.

## Notes

- **Ready, not draft** — the next step starts monitoring for feedback, so the
  PR/MR is opened ready-for-review.
- **Title is fixed** — always `Merge <source> into <target>`; keep creation
  zero-friction and predictable.
- **Intent survives sessions** — the `.data/merge/<ID>.md` stash is how
  `/merge-request:fix` recovers the author's intent after a resumed session
  (fn-10 reads its `## Intent`); a re-run never clobbers a real intent with the
  placeholder.

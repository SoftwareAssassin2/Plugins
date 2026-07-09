## Conversation Evidence

> user: "1. Use /detect-source-control to determine if we're using GitLab or GitHub. 2. Create an MR for the current branch with the GitLab CLI if we're using GitLab, or a PR with the GitHub CLI if we're using GitHub. 3. Call \"/merge-request-fix <MR/PR-ID>\""
> user (title): "Use this template \"Merge <source-branch-name> into <target-branch-name>\"."
> user (state): "Ready".
> user (handoff): "Scheduled wakeups".
> user (interview, fn-10 intent access): "create stashes intent to .data/merge/<ID>.md".

## Goal & Context
<!-- 85% [user], 15% [paraphrase] -->

`/merge-request:create` opens a pull/merge request for the current branch on whichever forge the repo uses, then hands the new PR/MR to the fix-monitoring loop. It is the author-side entry point of the package. [user] [paraphrase]

## Architecture & Data Models
<!-- 70% [user], 30% [paraphrase] -->

One of four skills in the `merge-request` plugin, invoked as `/merge-request:create`. It is an **assistant-executed skill** (`SKILL.md` instructions the model follows), optionally backed by a helper script for the deterministic git/CLI steps. It composes `detect-source-control` (branch on `gh`/`glab`) and `/merge-request:fix`. **Depends on fn-8.2**, which creates the `merge-request` plugin shell (`plugin.json`) and registers it in `.claude-plugin/marketplace.json`; without that registration `/merge-request:create` is not discoverable. [user] [paraphrase]

## API Contracts
<!-- 75% [user], 25% [paraphrase] -->

- GitHub: `gh pr create`; GitLab: `glab mr create`. Target = repo default branch (auto-detected). Created ready-for-review. [user] [paraphrase]
- Title: `Merge <source-branch> into <target-branch>`. Body: minimal auto summary. [user] [inferred: body]
- **ID capture (robust):** after creation, resolve the canonical id via `gh pr view --json number` / `glab mr view --output json` rather than parsing creation stdout. Only if the JSON `view` path fails, fall back to parsing the trailing PR/MR number from the URL emitted on the `gh pr create` / `glab mr create` stdout. [paraphrase]
- **Intent stash source:** at creation, writes a brief `## Intent` block to `.data/merge/<ID>.md` composed from (a) the user's stated pre-MR intent from the current session, plus (b) change scope derived from `git log <default>..HEAD --oneline` and `git diff --stat <default>...HEAD`. If no explicit intent is available, write `[TODO] Intent not provided` so the fix loop has a defined placeholder. This lets `/merge-request:fix` read the intent across sessions. [interview] [paraphrase]
- **Handoff (assistant-level):** the handoff to `/merge-request:fix <ID>` is an assistant instruction in `SKILL.md` — after a successful creation the assistant continues into `/merge-request:fix <ID>` using the captured id. A helper script cannot invoke a slash command; if used, it emits the machine-readable id and `SKILL.md` instructs the immediate continuation. [user] [paraphrase]

## Edge Cases & Constraints
<!-- 80% [user], 20% [paraphrase] -->

- If `detect-source-control` returns `unsupported`, hard-stop. [user] [paraphrase]
- Ensure the current HEAD exists on the remote before creating: if the branch has no upstream, push with `-u`; if it has an upstream but local commits are unpushed, push them first (avoid creating from stale remote state). [paraphrase]
- **PR/MR already exists for the branch:** if creation reports an existing open PR/MR for the current branch (common on resume/retry), do not error out — resolve the existing id via the same `view --json` path, refresh the `## Intent` stash, and continue into the `/merge-request:fix <ID>` handoff. [paraphrase]

## Acceptance Criteria

- **R1:** Invokes `detect-source-control` (hard-stop if unsupported), ensures the current HEAD is on the remote (push with upstream if none; push unpushed commits if the upstream is behind), and creates a ready-for-review PR (`gh`) or MR (`glab`) targeting the repo default branch. [user] [paraphrase]
- **R2:** The created PR/MR title is exactly `Merge <source-branch> into <target-branch>`, with a minimal auto-generated body. [user] [inferred: body]
- **R3:** After creation, the assistant captures the canonical id (via `gh pr view --json number` / `glab mr view --output json`, URL-parse fallback) and continues into `/merge-request:fix <ID>` — an assistant-level handoff documented in `SKILL.md`. [user] [paraphrase]
- **R4:** At creation, it stashes a `## Intent` summary into `.data/merge/<ID>.md` composed from the session's stated intent plus `git log`/`git diff --stat` scope (fallback `[TODO] Intent not provided`), so `/merge-request:fix` can read the intent across sessions. [interview]

## Boundaries
<!-- 90% [user] -->

- Creates the PR/MR (and the `## Intent` stash); monitoring and feedback handling belong to `/merge-request:fix`. [user] [paraphrase]

## Decision Context

Ready-for-review (not draft) because the very next step starts monitoring for feedback; the templated title keeps creation zero-friction and predictable. The `## Intent` stash was added (interview) so the fix loop's pre-MR intent layer survives a resumed session. Skills are assistant-executed instruction sets, so the `/merge-request:fix` handoff is expressed as assistant continuation, not a shell call. [user] [paraphrase] [interview]

## Requirement coverage

| R-ID | Task |
|------|------|
| R1, R2, R3, R4 | fn-9-create-pullmerge-request-for-current.1 |

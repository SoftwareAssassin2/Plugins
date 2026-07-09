---
satisfies: [R4, R5]
---
## Description
Select high-signal findings and stage them to disk without posting: fetch and normalize existing threads to avoid duplicates, apply the invariant rubric and learned preferences, tag findings with Conventional Comments prefixes and stable ids.

**Size:** M
**Files:** `plugins/merge-request/skills/review/SKILL.md` (extends fn-11.2), `plugins/merge-request/skills/review/scripts/fetch-threads.sh`

## Approach
- **Thread-read adapter (forge-normalized):** fetch (a) the PR/MR changed files + diff and (b) existing review comments/discussions; normalize each to `{author, body, file?, line?, resolved?, kind}` — `file`/`line`/`resolved` nullable, `kind` = `inline`|`general` — so global/non-inline comments (GitHub issue comments, GitLab general notes) are captured too. Cover GitHub (review threads + issue comments) and GitLab (discussions + notes). Drop any candidate finding already covered on substance by anyone (human, prior round, AI reviewer), inline or general.
- Select via the RUBRIC.md invariant rubric + the SOUL.md persona; apply the learned-preferences file per the fn-11.1 lookup contract (global then project override) when it exists (owned by fn-12; proceed if absent).
- Tag each finding with a Conventional Comments prefix (`suggestion:`/`issue:`/`question:`/`nitpick:`/`todo:`), a deterministic `F-<hash>` finding id, and a `kind: inline|general`; for `kind: inline` also record the inline-location fields (file/old_path/line or line_range/side/head_sha/base_sha) so fn-12 can post it inline (per ARTIFACT.md); stage to `## Findings` in `.data/merge/<ID>.md`, preserving the other sections. Never post to the forge.
- Set the header review-status marker: `<!-- merge-review-status: clean -->` when nothing cleared the bar (zero findings), else `findings` — so fn-12 can safely gate its formal-approval path.

## Investigation targets
**Required:**
- `~/.claude/skills/gitlab-mr-review/SKILL.md` -- existing-thread dedup rule + output format
- `~/.claude/skills/gitlab-mr-feedback/scripts/post-inline-comment.sh` -- glab discussion/thread API shape (read side)
- `plugins/merge-request/SOUL.md`, `plugins/merge-request/RUBRIC.md`, `plugins/merge-request/ARTIFACT.md` -- persona + rubric + artifact contract (from fn-11.1)

## Acceptance
- [ ] Fetches and normalizes existing PR/MR threads (`{author, body, file?, line?, resolved?, kind}`, nullable for global comments) across GitHub + GitLab, and never raises a finding already covered by anyone (human, prior round, AI reviewer), inline or general.
- [ ] Selects findings via the invariant rubric, tags each with a Conventional Comments prefix, a deterministic `F-<hash>` finding id, and a `kind` (inline findings also carry file/old_path/line/line_range/side/head_sha/base_sha), and stages them to `## Findings` in `.data/merge/<ID>.md` (other sections preserved).
- [ ] Sets the header `<!-- merge-review-status: clean|findings -->` marker (`clean` iff zero findings) so fn-12's approval gate is safe.
- [ ] Never posts to the forge; applies the learned-preferences file (global then project override) when present.

## Done summary
Built finding selection + staging for /merge-request:review: added scripts/fetch-threads.sh (fetch + normalize existing GitHub review-threads+issue-comments and GitLab discussions+notes to {author, body, file?, line?, resolved?, kind}, resolved threads included for dedup; plus a finding-id subcommand emitting the deterministic F-<hash> byte-identical to the engine's Step-5 serialization). Extended review/SKILL.md Step 6 into the full be-Chris selection procedure — thread dedup on substance, RUBRIC.md/SOUL.md selection, Conventional Comments prefixes, kind + inline-location tagging, staging to ## Findings as fenced jsonl, and the clean|findings marker (clean iff zero findings). Never posts to the forge.
## Evidence
- Commits: 4ce6d47c37df9bdbf34304a60e0c0178bce0a76a
- Tests: bash plugins/merge-request/skills/review/tests/fetch-threads_test.sh (22 passed), bash plugins/merge-request/skills/review/tests/{triage,setup-worktree,build-and-test}_test.sh (regression: all pass)
- PRs:
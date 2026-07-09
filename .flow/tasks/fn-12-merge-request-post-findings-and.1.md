---
satisfies: [R1, R2, R8]
---
## Description
Build `merge-request:post-findings`: walk the staged findings interactively, post approved ones as inline comments (editing keeps disk + forge consistent, edit-by-stable-id), and formally sign off a clean PR/MR.

**Size:** M
**Files:** `plugins/merge-request/skills/post-findings/SKILL.md`, `plugins/merge-request/skills/post-findings/scripts/post-inline-comment.sh`, `plugins/merge-request/skills/post-findings/scripts/approve-and-lgtm.sh`

## Depends on
- **fn-8.2** — `merge-request` plugin shell + marketplace registration.
- **fn-11.1** — the `.data/merge/<ID>.md` ARTIFACT.md finding schema (stable `F-<hash>` ids + inline location fields).

## Approach
- Add `skills/post-findings/SKILL.md` -> `/merge-request:post-findings` (canonical namespaced command).
- Read staged findings from `## Findings` in `.data/merge/<ID>.md`; walk one at a time (approve / edit / skip).
- **Validate location metadata** per finding (file, line/line_range, side, head/base SHA, old/new path for renames) before offering approval. Post approved findings as inline comments via `gh`/`glab`, preserving the CC prefix. A finding missing required location fields falls back to a general (non-inline) comment posting **exactly the approved text (CC prefix + body), no wrapper or added note** — the approval gate shows that exact text — never dropped.
- **On edit:** rewrite the staged `## Findings` entry addressed **by its stable `F-<hash>` id / block boundary** AND post the edited text (disk matches forge); leave other findings and other sections byte-for-byte unchanged.
- **Clean PR/MR:** only when BOTH review's explicit `<!-- merge-review-status: clean -->` marker (per fn-11.1) AND a zero-entry `## Findings` section are present — formal approve (`gh pr review --approve` / `glab mr approve`) + a note that is exactly `Looks good.` and nothing else. A missing marker / malformed artifact / all-skipped session does NOT trigger approval.
- Honor `plugins/merge-request/SOUL.md` for tone.

## Investigation targets
**Required:**
- `~/.claude/skills/gitlab-mr-feedback/SKILL.md` -- per-finding walkthrough + posting workflow
- `~/.claude/skills/gitlab-mr-feedback/scripts/post-inline-comment.sh` -- inline comment posting (gh + glab) incl. location args
- `~/.claude/skills/gitlab-mr-feedback/scripts/approve-and-lgtm.sh` -- formal approve + note
- `plugins/merge-request/ARTIFACT.md` -- finding schema (stable id + location fields) from fn-11.1
- `plugins/detect-source-control/SKILL.md` -- forge branching

## Verification
- Dry-run / fixture mode: parse a fixture `.data/merge/<ID>.md`, exercise approve/edit/skip and command selection with mocked `git`/`gh`/`glab` (no real posts). Assert: edited entry is rewritten by id with all other bytes unchanged; missing-location finding falls back to a general comment posting exactly the approved text; clean path emits `Looks good.` ONLY when the clean marker + zero findings both present, and does NOT approve when the marker is absent or all findings were skipped.

## Acceptance
- [ ] Walks staged findings interactively (approve / edit / skip) and posts approved findings as inline comments via `gh`/`glab`, preserving the CC prefix and using validated location metadata.
- [ ] A finding missing required inline-location fields is posted as a general comment with exactly the approved text (no wrapper/note), not dropped.
- [ ] An edit rewrites the staged `## Findings` entry by its stable id AND posts the edited text, leaving other entries/sections unchanged.
- [ ] A clean PR/MR — requiring BOTH the `<!-- merge-review-status: clean -->` marker AND zero findings — gets a formal approval + a note that is exactly `Looks good.` with nothing else; a missing marker / malformed artifact / skipping-everything does NOT trigger approval.

## Done summary
Built the merge-request:post-findings skill (SKILL.md + post-inline-comment.sh + approve-and-lgtm.sh): an interactive per-finding approve/edit/skip gate that posts approved findings as gh/glab inline comments (preserving the CC prefix + exact body), falls back to a general comment with the exact approved text when inline-location fields are absent (never dropped), rewrites an edited finding on disk by its stable F-<hash> id after a successful post, and formally signs off a clean PR/MR with exactly "Looks good." only when both the clean marker and a zero-record ## Findings section are present. 83 scoped tests with mocked gh/glab; codex impl-review SHIP.
## Evidence
- Commits: 6f20b51, ddaf74a, 61b3c9b, 0ec9118, 17516e4, 773b5e1
- Tests: bash plugins/merge-request/skills/post-findings/tests/post-findings_test.sh (83 passed), full merge-request + detect-source-control suite: 9 suites, 0 failed
- PRs:
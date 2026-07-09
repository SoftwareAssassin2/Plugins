## Conversation Evidence

> user (need): "write to disk then post on approval. This neccessitates we add another skill to do the posting ... let's call it /merge-request-post-findings."
> user (gate): "Interactive, one at a time".
> user (clean MR): "Formal approve + note. The note should say \"Looks good.\" ... It should only say \"Looks good.\" - nothing else. It should never add any additional comments or explanation."
> user (labeling): "Full Conventional Comments".
> user (preferences storage): "Global base + project overrides".
> user (preferences learning): "Propose, then confirm".
> user (preferences captures): Don't-raise patterns, Wording preferences, Confirmed-valued, Rubric weighting.
> user (interview, skip->don't-raise): "Propose on first skip".
> user (interview, edit->wording): "Generalize into a Wording preference".
> user (interview, edit target): "Update staged file + post edited".
> user (interview, confirmed-valued): "Approve of a borderline finding".

## Goal & Context
<!-- 80% [user], 20% [paraphrase] -->

`/merge-request:post-findings` takes the findings staged by `/merge-request:review` and, with per-finding approval, posts them to the forge as inline comments — or formally signs off a clean PR/MR. It also runs the learned-preferences loop that teaches `review` what the user values over time (the generalized, renamed successor to the user's old GitLab feedback skill). [user] [paraphrase]

## Architecture & Data Models
<!-- 70% [user], 30% [paraphrase] -->

A skill in the `merge-request` plugin, invoked as `/merge-request:post-findings` (canonical, namespaced). The conversation's earlier `/merge-request-post-findings` (hyphenated) is a historical name, not the shipped command. **Depends on fn-8.2** (plugin shell + marketplace registration) and fn-8.1 (`detect-source-control`). Reads staged findings from `.data/merge/<ID>.md` (`## Findings`, per the fn-11.1 ARTIFACT.md contract) and posts via `gh`/`glab`. Honors the shared `SOUL.md` persona for tone. [user] [paraphrase]

**Staged finding location schema (defined in fn-11.1 ARTIFACT.md, produced by review, consumed here).** Inline posting needs forge-specific location metadata, so each `## Findings` entry carries: stable `F-<hash>` id, Conventional Comment prefix, `body`, `file` (new path), `old_path` (for renames), `line` or `line_range`, `side` (LEFT/RIGHT — GitHub), and the `head_sha`/`base_sha` the review ran against. `gh` inline needs commit + path + line + side; `glab` inline needs base/head SHA + old/new path + line. post-findings **validates the required location fields are present before offering a finding for approval**; a finding missing location metadata falls back to a general (non-inline) comment, never silently dropped. **The fallback posts exactly the approved finding text (its CC prefix + body) — no interpretive wrapper or added note** — so the "post only what the user approved" rule holds; the approval gate shows that exact text. [paraphrase]

**Learned preferences.** A **global base** file `~/.claude/merge-request-preferences.md` plus an optional **project override** `.data/merge/preferences.md`. Sections: `## Don't raise`, `## Wording`, `## Confirmed valued`, `## Rubric weighting` — all four read by `review` (fn-11.3) and applied to selection, phrasing, retention, and priority order. **Merge/identity model:** every preference entry has a normalized `key` (Don't-raise: rubric-category + normalized pattern; Wording: the phrasing-rule id; Confirmed-valued: rubric-category + pattern; Rubric-weighting: flag name). Project override with the same `key` **replaces** the global entry; different keys **union** (additive). Don't-raise entries carry a `count` (times the pattern was skipped) as the confidence signal; "similar findings" = same normalized key. **Write scope:** every confirmed preference is written to EITHER the global base OR the project override — the confirm prompt includes a scope choice and names the target file; default is project override for Don't-raise (often a per-repo convention) and global for Wording (a cross-project voice rule), overridable per item. `## Rubric weighting` is **merge/preserve-only** — no interaction infers it (the skip/edit/approve heuristics map to Don't-raise/Wording/Confirmed-valued); it is user-edited directly and merged by the same keyed model. [user] [paraphrase]

## API Contracts
<!-- 70% [user], 20% [interview], 10% [paraphrase] -->

- Interactive per-finding gate: approve / edit / skip; approved findings post as inline comments (with their Conventional Comments prefix) using the validated location metadata. [user]
- An **edit** at the gate rewrites the staged `## Findings` entry **by its stable `F-<hash>` id / block boundary** in `.data/merge/<ID>.md` AND posts the edited text, so disk matches what was posted; unrelated findings and other sections stay byte-for-byte unchanged. [interview]
- **Clean PR/MR** = review explicitly staged a clean result. Because a formal approval is high-impact, the executable condition requires **both**: an explicit clean marker written by review (`<!-- merge-review-status: clean -->` in the artifact header, per fn-11.1) AND a `## Findings` section with **zero** entries. A malformed/empty/manually-truncated artifact (marker absent) is NOT clean. When both hold, cast a formal approval (`gh pr review --approve` / `glab mr approve`) and post a note that is exactly `Looks good.` — nothing else, ever. A PR/MR is NOT treated as clean merely because the user skipped every finding during posting. [user] [paraphrase]
- Learned-preferences (propose-then-confirm; writes only after per-item confirmation):
  - a **skip** proposes the finding as a `## Don't raise` candidate on the first skip; repeated skips of the same-key pattern increment `count` (confidence). [interview]
  - an **edit** proposes a generalized `## Wording` preference inferred from the phrasing change. [interview]
  - an **approve** of a borderline / previously-flagged finding proposes promoting it to `## Confirmed valued`. [interview]

## Edge Cases & Constraints
<!-- 80% [user], 20% [interview] -->

- The `Looks good.` note never carries additional comments or explanation. [user]
- Project preferences file defaults to gitignored (`.data/merge/` is ignored); sharing it is a deliberate opt-in (`git add -f`). [inferred]
- All preference writes are proposed and confirmed per item — nothing is written silently. [user] [interview]
- A staged finding missing required inline-location fields is posted as a general comment with exactly the approved finding text (no wrapper/added note), not dropped. [paraphrase]

## Acceptance Criteria

- **R1:** Walks staged findings interactively (approve / edit / skip per finding) and posts approved findings as inline comments via `gh`/`glab`, preserving each finding's Conventional Comments prefix and using the validated location metadata (general-comment fallback when location fields are absent). [user] [paraphrase]
- **R2:** For a clean PR/MR — requiring BOTH review's explicit `<!-- merge-review-status: clean -->` marker AND a `## Findings` section with zero entries — casts a formal approval and posts a note that is exactly `Looks good.` with nothing else; never approves on a missing marker, a malformed artifact, or because the user skipped everything. [user] [paraphrase]
- **R3:** Runs a propose-then-confirm learned-preferences loop, proposing updates inferred from the user's approve/edit/skip actions for confirmation before writing. [user] [paraphrase]
- **R4:** Learned preferences live in a global base file (`~/.claude/merge-request-preferences.md`) plus an optional project override (`.data/merge/preferences.md`), with a keyed merge model — same-key project entry replaces global, different keys union. Each confirmed write is scoped (global vs project) at the confirm prompt, which names the target file. [user] [inferred: project path]
- **R5:** The preferences loop captures Don't-raise patterns, Wording preferences, and Confirmed-valued findings (inferred from skip/edit/approve); `## Rubric weighting` is merge/preserve-only (user-edited directly, not inferred). All four sections use normalized keys; `/merge-request:review` (implemented in fn-11.3) reads the merged file and applies all four. fn-12 owns writing the file + merge model; the review-side consumption is fn-11.3. [user] [paraphrase]
- **R6:** A skipped finding is proposed as a `## Don't raise` candidate on the first skip (confirmed via the loop); repeated skips of the same-key pattern increment its `count` confidence. [interview]
- **R7:** An edited finding is generalized into a proposed `## Wording` preference (the phrasing rule), not just stored verbatim. [interview]
- **R8:** An edit at the gate rewrites the staged `## Findings` entry by its stable id in `.data/merge/<ID>.md` AND posts the edited text, keeping disk and forge consistent and leaving other entries/sections unchanged. [interview]
- **R9:** Approving a borderline / previously-flagged finding proposes promoting that pattern to `## Confirmed valued`. [interview]

## Boundaries
<!-- 90% [user] -->

- Posts only what the user approves per finding — no auto-posting of the staged set. [user]
- Generating findings is `/merge-request:review`'s job; this skill posts and learns. [paraphrase]
- No preference is written without per-item confirmation. [user] [interview]

## Decision Context

### Motivation
<!-- scope: business -->

Splitting posting from reviewing keeps a human gate between staged findings and someone else's PR/MR. The learned-preferences loop makes the persona sharpen to the user over time; propose-then-confirm keeps the file clean and the user in control, and the global-base+project-override layout lets his standards travel across projects while allowing per-repo tuning. [user] [paraphrase]

### Implementation Tradeoffs
<!-- scope: technical -->

Interview-resolved inference heuristics: propose a Don't-raise on the *first* skip (fast learning, still human-gated); generalize edits into Wording *rules* rather than storing verbatim examples; keep staged file and posted comment consistent on edit; promote borderline-but-approved findings to Confirmed-valued. All proposals flow through propose-then-confirm, so aggressiveness in *proposing* costs nothing — the confirm step is the safety. The keyed merge model + `count` confidence make the preference file machine-mergeable rather than free-form prose. [interview]

## Requirement coverage

| R-ID | Task |
|------|------|
| R1, R2, R8 | fn-12-merge-request-post-findings-and.1 |
| R3, R4, R5, R6, R7, R9 | fn-12-merge-request-post-findings-and.2 |

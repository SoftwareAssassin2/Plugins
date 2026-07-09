---
satisfies: [R6, R7, R8]
---
## Description
Author the shared review persona and the artifacts it drives: the "Chris" `SOUL.md`, the invariant rubric it applies, and the concrete `.data/merge/<ID>.md` sectioned-artifact contract (with section ownership + stable finding ids). Foundational for the review engine (fn-11.2/.3) and honored by post-findings (fn-12).

**Size:** M
**Files:** `plugins/merge-request/SOUL.md`, `plugins/merge-request/RUBRIC.md`, `plugins/merge-request/ARTIFACT.md` (artifact contract doc), `.gitignore`

## Depends on
- **fn-8.2** — the `merge-request` plugin shell (`plugin.json`) + marketplace registration must exist (SOUL.md/RUBRIC.md live at that plugin root).

## Approach
- `plugins/merge-request/SOUL.md` — the "Chris" persona (shared by review + post-findings): peer not gatekeeper (never blocks), terse suggestions not directives, prescribes outcomes not mechanisms, leads with the objectively-defensible finding, stack-agnostic. **A drafted SOUL.md already exists at this path** (agent-drafted 2026-07-09 from the locked invariants + prior-art SOUL structure); this task's job is to keep it in place and let Chris edit the voice — do NOT re-author from scratch or overwrite it. Verify it still encodes every invariant; the SKILL.md must instruct the agent to read SOUL.md and *be* Chris (not summarize it).
- Document the invariant rubric (RUBRIC.md), and keep it in lockstep with SOUL.md. Top-tier flags ordered by objectivity: (1) hard-coded config/env values; (2) **security holes with real blast radius** — secrets in VCS reaching beyond the dev's own machine, OWASP Top 10, least-privilege violations, missing encryption/audit-logging — **with the explicit carve-out that local-only secrets (blast radius = localhost) in committed config are NOT flagged** (they make pull-and-run trivial, expose nothing beyond what the dev controls; the test is blast radius); (3) won't-run-offline (outcome not mechanism); (4) leaky component interface (abstraction itself NOT flagged); (5) layer bleed; (6) DRY; (7) thin coverage. **Suggestion-level (not a gate):** self-containment / pull-and-run in one command / migrations-included. Radar: swallowed errors, isolate risky/slow code, missing edge cases. Silence list: formatting/style/naming/comment-density/micro-perf/over-abstraction **and the author's stack/framework/library choice** (hidden deps / missing run docs still count). **Hard rule: findings never reference any company, brand, trademarked framework, or house policy — universal engineering merit only.** Posted findings use full Conventional Comments; a clean sign-off is the only praise.
- Define the `.data/merge/<ID>.md` artifact contract (ARTIFACT.md): single file with header metadata (id, forge, `Reviewed at commit: <sha>`, and a review-status marker `<!-- merge-review-status: clean|findings -->` that review sets `clean` only when nothing cleared the bar — fn-12 requires this marker AND zero `## Findings` entries before it will cast a formal approval) and one owner per section -- `## Intent` (create/fn-9), `## Handled` (fix/fn-10), `## Declined` (fix/fn-10 + post-findings/fn-12, append-only), `## Findings` (review/fn-11, replaced each run), `## Build` (review/fn-11, replaced each run). Each finding carries a **deterministic** id `F-<hash>` hashed from `{forge PR/MR id, file path, line/range, Conventional Comment prefix, normalized title/body}` (NOT an ordinal — ordinals drift as findings reorder; an `F<n>` may appear only as a display label) so post-findings and `## Declined` correlate it across runs. Each finding carries `prefix` (Conventional Comment), `body`, and `kind: inline|general`. **Inline-location fields** (`file` new path, `old_path` for renames, `line`/`line_range`, `side` LEFT/RIGHT for GitHub, `head_sha`/`base_sha`) — needed by post-findings (fn-12) to post inline comments — are required **only for `kind: inline`**. Any blocking checkout/build/test failure is logged in `## Build` AND raised as the first `## Findings` entry (`issue:` prefix, stable id, `kind: general` — no file/line — which fn-12 posts as a general comment). Rule: every skill edits only its own section(s) in place; re-review replaces `## Findings`/`## Build`, rewrites the `merge-review-status` marker, and preserves the rest.
- Document the learned-preferences lookup contract (file owned by fn-12, optional here): global base `~/.claude/merge-request-preferences.md` then project override `.data/merge/preferences.md` (project overrides global on conflict, additive lists union) — path matches fn-12 R4.
- Add `.data/merge/` to `.gitignore` — ALL per-PR/MR artifacts stay ignored, including the project prefs override, which per fn-12 defaults to gitignored. Sharing the project prefs is a deliberate opt-in (`git add -f .data/merge/preferences.md`), not an automatic unignore.

## Investigation targets
**Required:**
- `plugins/dick/SOUL.md` -- SOUL.md structure + how SKILL.md references it
- `~/.claude/skills/gitlab-mr-review/SOUL.md` -- prior-art persona to generalize
- `~/.claude/skills/gitlab-mr-review/SKILL.md` -- prior-art rubric, output format, `Reviewed at commit:` contract
- `.gitignore` -- add `.data/merge/` (project prefs shared only via opt-in `git add -f`)

## Acceptance
- [ ] `plugins/merge-request/SOUL.md` (already drafted at this path) is present and fully encodes the invariants (peer/suggestions/outcomes-not-mechanisms/objectivity-first/stack-agnostic); preserved for Chris to edit the voice, not re-authored.
- [ ] Invariant rubric documented in lockstep with SOUL.md: objectivity-ordered top-tier flags incl. security (with the local-only-secrets carve-out), suggestion-level self-containment, radar items, and silence list (incl. stack/framework choice); abstraction-per-se is not a finding; findings never reference any company/brand/framework/policy.
- [ ] `.data/merge/<ID>.md` artifact contract defined: header metadata incl. the `<!-- merge-review-status: clean|findings -->` marker, per-section ownership map (Intent/Handled/Declined/Findings/Build), deterministic `F-<hash>` finding ids, per-finding `kind: inline|general` with inline-location fields (file/old_path/line/line_range/side/head_sha/base_sha) required only for `inline`, the blocking-failure-as-a-`kind: general` `## Findings`-entry rule, and the edit-only-your-section / preserve-the-rest rule.
- [ ] Learned-preferences lookup paths + precedence documented (global then project override), even though the file is owned by fn-12.
- [ ] `.gitignore` ignores all of `.data/merge/` (project prefs default-ignored per fn-12; shared only via opt-in `git add -f`).

## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:

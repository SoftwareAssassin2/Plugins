## Conversation Evidence

> user (scope): "Single by ID, batch fallback".
> user (output): "write to disk then post on approval. This neccessitates we add another skill to do the posting ... let's call it /merge-request-post-findings."
> user (worktree/naming): "If we're already in a worktree dedicated to that MR/PR, then build/test right there ... Otherwise create a new worktree and pull the branch down into it. For new branches the naming convention can be: \"merge/<MR/PR-ID>\" ... output ... placed in .data/merge/123.md."
> user (file layout): "Single file, sections".
> user (persona): "The persona is going to be named \"Chris\" ... a digital representation of myself. Kind of like \"Gilfoyle AI\"." Values: hard-coded values; simple config; deployability; run locally without cloud deps; test coverage; layer separation; complexity inside reusable components, simplicity in consumers; readable component interfaces.
> user (voice): "Sharp but professional"; "The tone of my reviews should be that of a peer, and they should take the form of suggestions - not directives."; "rate these options from most objective to least objective ... 2, 3, 1, 4."
> user (abstraction/config/tests): "DRY-leaning"; "Wherever interface improves"; config "Flexible ... as long as the values aren't hard-coded and the config values can be applied appropriately per environment."; testing "flexible ... as long as the coverage is high."
> user (sample #1): "An interface wouldn't be the only mechanism to run this offline. A containerized S3 bucket + path to the bucket in a config would also allow this to be run offline."
> user (labeling): "Full Conventional Comments". user (praise): "Clean MR = the praise". user (AI checks): "Missing edge cases".

## Goal & Context
<!-- 75% [user], 25% [paraphrase] -->

`/merge-request:review` reviews a PR/MR (or all open ones) against the user's own engineering standards, staging high-signal findings to disk for later posting. Its judgment and voice come from a shared `SOUL.md` persona ("Chris") — a deliberate digital representation of the user, so reviews reflect his priorities rather than a generic linter. Generalizes the user's prior GitLab-only review skill to both forges and any toolchain. [user] [paraphrase]

## Architecture & Data Models
<!-- 65% [user], 25% [paraphrase], 10% [inferred] -->

A skill in the `merge-request` plugin, invoked as `/merge-request:review [<ID>]`. **Depends on fn-8.2** (plugin shell + marketplace registration) and consumes fn-8.1's `detect-source-control` contract. Reviews against a real checkout: reuse the dedicated worktree if already in it, else create one at `.worktrees/merge-<ID>` (path [inferred]) with checkout branch `merge/<ID>`. Runs an auto-detected build/test toolchain. Reads a global+project learned-preferences file (owned by `post-findings`, fn-12) to shape selection/wording. [user] [paraphrase] [inferred]

**Shared artifact — `.data/merge/<ID>.md` (single file, one owner per section).** All four skills edit this file, each writing only its own section(s) in place and preserving the rest:

| Section | Owner (skill) | Contents |
|---------|---------------|----------|
| `## Intent` | create (fn-9) | pre-MR intent + change scope |
| `## Handled` | fix (fn-10) | jsonl idempotency ledger |
| `## Declined` | fix (fn-10) / post-findings (fn-12) | declined feedback / findings + rationale (append-only) |
| `## Findings` | review (fn-11) | staged findings (replaced wholesale each review run) |
| `## Build` | review (fn-11) | build/test log for the run (replaced each run) |

- **Header metadata** (top of file, above sections): the PR/MR id, forge, `Reviewed at commit: <sha>` stamp, and a `<!-- merge-review-status: clean|findings -->` marker (fn-12 requires `clean` + zero findings before a formal approval). **Any review run that writes `## Findings` also writes this marker in the same run** — it is never left stale from a prior clean run.
- **Finding `kind`:** each `## Findings` entry has `kind: inline|general`. Inline-location fields (`file`, `old_path`, `line`/`line_range`, `side`, `head_sha`/`base_sha`) are required only for `kind: inline`. Blocking checkout/build/test failures are `kind: general` (no file/line) and fn-12 posts them as general review comments.
- **Stable finding IDs:** each `## Findings` entry has a **deterministic** id `F-<hash>`, where the hash is derived from `{forge PR/MR id, file path, line/range, Conventional Comment prefix, normalized finding title/body}` — NOT an ordinal, which would drift as findings are added/removed/reordered between runs. (An `F<n>` ordinal may appear only as a human display label alongside the stable id.) This lets `post-findings` and `## Declined` correlate the same finding across re-review runs. Note: because `line/range` is in the hash, an unrelated edit that shifts the same issue's line will mint a new id (accepted trade-off for strict locality); implementations may instead hash a normalized code/context anchor if they want stability across line drift.
- **Blocking failure is also a finding:** `## Build` holds the raw build/test/checkout logs, but any blocking checkout/build/test failure ALSO becomes the first `## Findings` entry (stable id, `issue:` prefix, `kind: general`) so it is visible to `post-findings`, which posts from `## Findings`.
- **Multi-run rule:** `review` may replace `## Findings` and `## Build` and update the `Reviewed at commit` stamp, but must preserve `## Intent`, `## Handled`, and `## Declined` untouched — re-review never clobbers create/fix/post-findings state.

**Persona (`SOUL.md`, shared with `post-findings`):** "Chris" — peer not gatekeeper; suggestions not directives; terse (1–2 sentences, no "why" lecture); **prescribes outcomes not mechanisms**; leads with the objectively-defensible finding; stack-agnostic. [user] [paraphrase]

## API Contracts
<!-- 70% [user], 30% [paraphrase] -->

- `/merge-request:review <ID>` reviews one PR/MR; no argument → batch-review all open. [user]
- **Batch ordering:** triage fetches each open PR/MR's head SHA and applies the `Reviewed at commit: <sha>` skip check **before** any worktree setup or build — already-current reviews are skipped early, avoiding wasted checkout/build. [paraphrase]
- Skip/re-review contract: stamp `Reviewed at commit: <sha>`; skip when recorded SHA == head, re-review otherwise. [paraphrase]
- **Thread-read adapter (forge-normalized):** before selecting findings, fetch (a) the PR/MR changed files + diff and (b) the existing review comments/discussions, and normalize each to `{author, body, file?, line?, resolved?, kind}` — `file`/`line`/`resolved` are **nullable** because global/non-inline comments (GitHub issue comments, GitLab general notes) have no file/line; `kind` distinguishes `inline` vs `general`. Duplicate suppression considers both inline and general comments. Covers GitHub (review threads + issue comments) and GitLab (discussions + notes). [paraphrase]
- Findings carry Conventional Comments prefixes (`suggestion:`/`issue:`/`question:`/`nitpick:`/`todo:`); a clean review's only positive signal is the `Looks good.` sign-off (cast later by `post-findings`) — no manufactured `praise:`. [user]
- `review` never posts to the forge; it only stages. [user] [paraphrase]
- **Learned-preferences lookup (contract, file owned by fn-12, optional here):** global base `~/.claude/merge-request-preferences.md` then project override `.data/merge/preferences.md` (project overrides global on conflict, additive lists union); when absent, review proceeds with rubric + persona only. Path matches fn-12 R4. [paraphrase]

## Edge Cases & Constraints
<!-- 80% [user], 20% [paraphrase] -->

- Read existing PR/MR threads and never raise a finding already covered by anyone (human, prior round, or AI reviewer). [paraphrase]
- **Checkout head resolution:** prefer forge API/CLI metadata for the head repo/branch (handles forked GitHub PRs and restricted remotes); fall back to PR/MR refs (`refs/pull/<n>/head`, `refs/merge-requests/<iid>/head`); if a checkout still cannot be established, log it in `## Build` AND raise it as the first `## Findings` entry (`issue:` prefix, stable id) so post-findings surfaces it, then skip build/test for that PR/MR rather than failing silently. [paraphrase]
- A failing build/test is the top blocking finding. [user] [paraphrase]
- **Build/test detection order (ecosystem):** package-manager scripts (package.json/pnpm/npm/yarn) → Makefile/justfile targets → Cargo → Go → .NET. **Within package scripts the selection is cumulative:** run `ci` if present; otherwise run `build` (if present) AND then `test`/`check` (if present) — a repo with both `build` and `test` runs both. **Lint/format-only commands are excluded** unless part of the repo's normal build/test command (this skill never generates style findings). If none is recognizable, record "no build/test command detected" in `## Build` — NOT treated as a failing build unless the repo clearly expects one. [paraphrase]
- Findings prescribe outcomes, not a specific pattern (e.g. "run offline" can be met by a containerized backing service + config path OR an adapter/fake). [user]
- Abstraction itself is never flagged — only leaky interfaces (the user is DRY-leaning and abstracts wherever it improves the interface). [user]

## Acceptance Criteria

- **R1:** `/merge-request:review <ID>` reviews one PR/MR; with no argument it batch-reviews all open PRs/MRs, applying the `Reviewed at commit` skip check on fetched head SHAs **before** worktree/build. [user] [paraphrase]
- **R2:** Uses a `Reviewed at commit: <sha>` header stamp to skip PRs/MRs whose recorded review matches head and re-review those with new commits. [paraphrase]
- **R3:** Builds/tests in the existing dedicated worktree when already in it; otherwise resolves the head (forge API/CLI metadata first, PR/MR refs fallback; if unresolvable, log in `## Build` and raise as the first `## Findings` `issue:` entry, then skip build/test), creates a worktree (checkout branch `merge/<ID>`), and runs an auto-detected build/test toolchain (detection order defined; no-toolchain recorded, not failed). A failing build/test is the top blocking finding, recorded in `## Build` AND surfaced as the first `## Findings` entry. [user] [paraphrase] [inferred: worktree path]
- **R4:** Fetches and normalizes existing PR/MR threads via the forge adapter (`{author, body, file?, line?, resolved?, kind}`, nullable for global comments) and never raises a finding already covered by anyone (human, prior round, or AI reviewer), inline or general. [paraphrase]
- **R5:** Selects findings via the persona invariant rubric, tags each with a Conventional Comments prefix, a **deterministic** `F-<hash>` finding id, and a `kind` (inline findings carry the inline-location fields; blocking build/checkout failures are `kind: general`), and stages them to the `## Findings` section of `.data/merge/<ID>.md` (preserving other sections); it never posts to the forge. [user] [paraphrase]
- **R6:** A shared `SOUL.md` persona ("Chris") governs review judgment and voice: peer not gatekeeper, terse suggestions not directives, prescribes outcomes not mechanisms, leads with the objectively-defensible finding, and stays stack-agnostic. The initial `SOUL.md` fully encodes these invariants (later wording refinement is a separate iteration, not a gap in this task). [user] [paraphrase]
- **R7:** The review invariant rubric flags (ordered by objectivity): hard-coded config/env values; **security holes with real blast radius** (secrets in VCS that reach beyond the developer's own machine, OWASP Top 10, least-privilege violations, missing encryption/audit-logging — with the deliberate exception that local-only secrets whose blast radius dies on localhost, checked into committed config, are NOT flagged because they make pull-and-run trivial and expose nothing beyond what the dev already controls); code that will not run locally/offline; leaky component interfaces (abstraction per se is not flagged); layer bleed; DRY violations; thin coverage of risky behavior — plus a **suggestion-level** self-containment nudge (single-command run / everything-in-repo / migrations-included, raised as `suggestion:` not a gate) and radar items (swallowed errors, isolation of risky/slow code, missing edge cases). Stays silent on formatting/style/naming/comment-density/speculative micro-perf/over-abstraction **and the author's choice of stack/framework/library** (hidden deps / missing run docs still count). **Findings are framed on universal engineering merit only — no company/brand/framework/policy is ever referenced in a review.** [user]
- **R8:** The per-PR/MR artifact is a single `.data/merge/<ID>.md` with header metadata (id, forge, `Reviewed at commit`, `merge-review-status` marker) plus the documented section-ownership map; findings carry `kind` + (for inline) location fields; each skill edits only its own section(s) in place, and re-review replaces `## Findings`/`## Build` and rewrites the status marker while preserving `## Intent`/`## Handled`/`## Declined`. [user] [paraphrase]

## Boundaries
<!-- 90% [user] -->

- Reviews and stages only; posting is `/merge-request:post-findings`. [user]
- AI-code checks limited to "missing edge cases"; nonexistent-API and gamed-test detection are left to the build/test step; plausible-but-wrong logic is out (too subjective). [user] [paraphrase]
- No linter/formatter/style/naming/comment-density/micro-perf/over-abstraction findings. [user]

## Decision Context

### Motivation
<!-- scope: business -->

The persona is a "digital representation of myself" so reviews carry the user's judgment on teams where he often can't block. Locked judgment calls: peer suggestions never gates; outcomes not mechanisms; lead with the objectively-defensible (his ordering: env-coupling/hardcoding > leaky API > layer separation > tests); DRY-leaning and pro-abstraction so only leaky interfaces are flagged; config/testing flexible so long as the invariants hold (nothing hard-coded / per-env applicable; coverage high); full Conventional Comments on posted findings; a clean PR/MR's `Looks good.` is the only praise. The `SOUL.md` content is authored by the user; a neutral-senior voice is only the fallback. [user] [paraphrase]

## Requirement coverage

| R-ID | Task |
|------|------|
| R6, R7, R8 | fn-11-merge-request-review-with-the-chris.1 |
| R1, R2, R3 | fn-11-merge-request-review-with-the-chris.2 |
| R4, R5 | fn-11-merge-request-review-with-the-chris.3 |

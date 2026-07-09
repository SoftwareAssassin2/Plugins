# ARTIFACT — the `.data/merge/<ID>.md` contract

The four `merge-request:*` skills coordinate through **one file per PR/MR**:
`.data/merge/<ID>.md`, where `<ID>` is the forge's PR/MR identifier. It is the
single shared artifact — `create`, `fix`, `review`, and `post-findings` each own
specific sections and **edit only their own section(s) in place, preserving the
rest**. `SOUL.md`/`RUBRIC.md` decide *what* a finding is; this file decides *how it
is written to disk* so the other skills can correlate it across runs.

The whole `.data/merge/` directory is gitignored (see `.gitignore`) — these are
per-PR/MR working artifacts, not committed state.

## File shape

```markdown
# Merge review: <ID>

id: <forge PR/MR id>
forge: github|gitlab
Reviewed at commit: <head-sha>
<!-- merge-review-status: clean|findings -->

## Intent
<owned by create — fn-9>

## Handled
<owned by fix — fn-10>

## Declined
<owned by fix — fn-10 — and post-findings — fn-12; append-only>

## Findings
<owned by review — fn-11; replaced wholesale each run>

## Build
<owned by review — fn-11; replaced wholesale each run>
```

## Header metadata (above the first `##` section)

| Field                       | Meaning                                                                 |
|-----------------------------|-------------------------------------------------------------------------|
| `id`                        | the forge PR/MR identifier (`<ID>`)                                      |
| `forge`                     | `github` or `gitlab`                                                     |
| `Reviewed at commit: <sha>` | head SHA the last review ran against — the skip/re-review stamp          |
| `<!-- merge-review-status: clean\|findings -->` | machine marker: the state of the last review run    |

**Skip/re-review contract.** `review` compares the PR/MR's current head SHA against
`Reviewed at commit`: equal → skip (review still current); different (or file
missing/unparseable) → re-review and re-stamp.

**Status marker contract.** `merge-review-status` is `clean` **only** when a review
run cleared the bar with **zero `## Findings` entries**; otherwise `findings`. Any
review run that writes `## Findings` **rewrites this marker in the same run** — it
is never left stale from a prior clean run. `/merge-request:post-findings` (fn-12)
will only cast a formal approval when the marker is `clean` **and** `## Findings`
has zero entries — the marker and the section must agree.

## Section ownership map

Each section has an explicit set of allowed writers, and a skill edits only the
section(s) it is allowed to write — leaving every other section byte-for-byte
intact. Most sections have a single owner; **`## Declined` is the one shared,
append-only section**, written by both `fix` (fn-10) and `post-findings` (fn-12).

| Section        | Allowed writer(s)                | Write mode                          | Contents                                             |
|----------------|----------------------------------|-------------------------------------|------------------------------------------------------|
| `## Intent`    | create (fn-9)                    | write once / preserve               | pre-MR intent + change scope                         |
| `## Handled`   | fix (fn-10)                      | append-only ledger (JSONL)          | idempotency records (dedupe keys) for handled items  |
| `## Declined`  | fix (fn-10) + post-findings (fn-12) | append-only                      | declined feedback / findings + rationale             |
| `## Findings`  | review (fn-11)                   | **replaced wholesale each run**     | staged findings for this run                         |
| `## Build`     | review (fn-11)                   | **replaced wholesale each run**     | build/test/checkout log for this run                 |

**Multi-run rule.** A `review` run may replace `## Findings` and `## Build` and
update `Reviewed at commit` + the status marker, but MUST preserve `## Intent`,
`## Handled`, and `## Declined` untouched — re-review never clobbers create/fix/
post-findings state.

## Finding format (`## Findings`)

Each finding in `## Findings` carries:

| Field                | Required            | Meaning                                                        |
|----------------------|---------------------|----------------------------------------------------------------|
| stable id `F-<hash>` | always              | deterministic id (see below) — how findings correlate across runs |
| `prefix`             | always              | Conventional Comments prefix (`issue:`/`suggestion:`/`question:`/`todo:`/`nitpick:`) |
| `body`               | always              | the finding text — a peer's terse read (see `SOUL.md`)         |
| `kind`               | always              | `inline` (anchored to a diff line) or `general` (no file/line) |
| inline-location set  | **only `kind: inline`** | see below — needed by post-findings to place an inline comment |

**Inline-location fields (required only for `kind: inline`):**

| Field                 | Meaning                                                          |
|-----------------------|------------------------------------------------------------------|
| `file`                | new-side path of the changed file                                |
| `old_path`            | pre-rename path, when the file was renamed                       |
| `line` / `line_range` | single line or start–end range the finding anchors to            |
| `side`                | `LEFT`/`RIGHT` (GitHub) — which side of the diff the line is on   |
| `head_sha` / `base_sha` | the diff endpoints the line numbers are resolved against       |

A `kind: general` finding carries **no** file/line — it is posted as a general
review comment.

### Deterministic finding ids — `F-<hash>`

The id is a **hash, not an ordinal**. Hash over the tuple:

```
{ forge PR/MR id, file path, line/range, Conventional Comment prefix, normalized title/body }
```

Ordinals (`F1`, `F2`, …) drift as findings are added/removed/reordered between
runs; a hash is stable, so `post-findings` and `## Declined` can correlate the
**same** finding across re-review runs (e.g. to know a finding was already
declined and not re-post it). An `F<n>` ordinal MAY appear only as a **human
display label** alongside the stable `F-<hash>` id — never as the identity.

Trade-off to note: because `line/range` is in the hash, an unrelated edit that
shifts the same issue's line mints a **new** id (accepted, for strict locality).
An implementation that wants stability across line drift MAY instead hash a
normalized code/context anchor in place of the raw line.

### Blocking failure is also the first finding

`## Build` holds the raw build/test/checkout logs. But **any blocking checkout,
build, or test failure ALSO becomes the first `## Findings` entry** — with a
stable `F-<hash>` id, the `issue:` prefix, and `kind: general` (no file/line, so
`post-findings` posts it as a general review comment). This guarantees a blocking
failure is visible to `post-findings`, which posts from `## Findings`, not from
`## Build`.

## The invariant, restated

- Explicit allowed writers per section; **edit only the section(s) you may write,
  preserve the rest.** `## Declined` is the one shared append-only section (`fix`
  + `post-findings`); every other section has a single owner.
- `review` replaces `## Findings` + `## Build`, rewrites `merge-review-status`,
  re-stamps `Reviewed at commit`; never touches `## Intent`/`## Handled`/
  `## Declined`.
- Finding identity is the deterministic `F-<hash>`, never an ordinal.
- Inline-location fields exist only for `kind: inline`.
- A blocking failure lives in `## Build` **and** as the first `## Findings`
  (`issue:`, `kind: general`) entry.

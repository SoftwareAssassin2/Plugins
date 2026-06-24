---
satisfies: [R2, R3, R14, R15]
---

## Description
Add a read-only **`--plan`** pass to `scaffold.sh` that classifies every template path against the current directory and emits **hand-built JSON (no `jq`)**. This is the early proof point. To avoid a half-migrated engine, in .1 **only `--plan` is accepted** — a bare invocation, `--apply`, AND `--diff` all **error clearly** ("migration pending — use --plan; apply/diff land in .2") rather than running old greenfield logic against `.`; `--apply`/`--diff` are implemented in .2.

**Size:** M
**Files:** `plugins/init-project/scaffold.sh` (incl. header comment + `usage()`)

## Approach
- **CLI grammar (final, R1):** `scaffold.sh [--name <name>] "<description>" {--plan | --apply | --diff <path>} …` — a single positional = description; project name is the `--name` flag (default = CWD basename); default mode = `--apply`. .1 implements `--plan` + `--name`; bare/`--apply` errors "migration pending (.2)".
- **`--plan` classifier (read-only):** classify the **union of current template paths AND prior-manifest-recorded paths** (so `deleted`/manifest-only entries surface). For each, stamp the template in memory (reuse `stamp_file` `:76-85`) and stat/read `./$out` in the CWD. Emit JSON array `[{"path","status","reason"}]`, **hand-built with printf** (paths are repo-relative + safe) — NOT jq, so a plain scaffold stays jq-free (fn-3).
- **Taxonomy (R3):** `missing` | `identical` (normalized==template) | `managed-update` (==recorded sha256 but !=template) | `conflict` (differs from template AND (no record OR !=recorded hash)) | `create-once-present` (volatile, not config.json) | `merge` (config.json present) | `deleted` (**manifest-recorded**, in-plan, absent — restorable; a fresh absent file with NO manifest record is `missing`, not `deleted`) | `retired` (manifest-recorded, not-in-plan, present, hash==recorded — prune) | `retired-conflict` (manifest-recorded, not-in-plan, present, hash!=recorded — keep) | `gone` (manifest-recorded, not-in-plan, absent — drop). config.json: manifest-owned→`merge`, unowned→`conflict`. **Text** files (token-bearing / detected text) → normalize (strip trailing whitespace + force LF) before the `shasum -a 256` compare (`:328` idiom) so newline/CRLF-only diffs are never `conflict`. **Binary / no-token** files (engine preserves byte-verbatim) → **raw byte hash**, no normalization. A content-identical file whose exec bit differs from the template classifies **`mode-update`** (its own status / a `mode_drift:true` field), NOT `identical` (so .2 chmods it — R7). `--plan` stdout carries ONLY the JSON array.
- **Volatile detection (R4):** a template file containing `__SCAFFOLD_GEN_URLSAFE__` (grep the source) is volatile → never hash-diffed; present → `create-once-present`, except `config.json` → `merge`; absent → `missing`.
- **Ownership oracle:** read the prior `.init-project-manifest.json` (if any) via `manifest_has`/recorded hash to decide `managed-update` vs `conflict` and to detect `deleted`/`retired`/`gone`.
- **Manifest grammar + validation (R15):** the manifest is **canonical line-oriented** (one entry per line matching a strict regex `    {"path": "<safe>", "sha256": "<64-hex>"}`), parsed with grep/regex — **no jq**. Validate as untrusted data: safe CWD-relative path (no `..`/absolute/control chars), sha256-regex hash, **no duplicate paths**; a **non-canonical line / corrupt path-or-hash / duplicate → exit 65** before plan. Escape emitted JSON strings (or reject an unsafely-emittable path).
- **Guards (R1 classify side):** the classifier reads per-template paths under CWD (it never descends `.git/`); reject any `target_rel` output that escapes CWD (`..`/absolute). Project-name default = CWD basename (validate `^[a-z0-9][a-z0-9-]*$`, `:135`), explicit arg overrides — needed because `--plan` stamps templates.
- Evolve the `--dry-run` early-return (`:218-222`) into `--plan`. Update header (`:2,15-23`) + `usage()` (`:68`) to describe the classifier; note the jq boundary (R14): `--plan` is jq-free.

## Investigation targets
**Required:**
- `plugins/init-project/scaffold.sh:160-222` — target/dry-run gate (where `--plan` slots in)
- `plugins/init-project/scaffold.sh:76-103,328` — stamp_file, target_rel, manifest_has, shasum idiom
- `plugins/init-project/templates/src/system-cli/build-config.sh:446-486` — atomic-write reference (used in .2)
**Optional:**
- `.flow/specs/fn-3-local-llm-mock-stack-for-init-project.md` — the jq-free-plain-scaffold contract

## Key context
- `__SCAFFOLD_GEN_URLSAFE__` is fresh per occurrence per run (`:81-83`) → re-stamp never hash-matches a prior write; this is WHY volatile files are create-once, not hash-diffed.
- `--plan` must emit valid JSON without jq — **even with `--local-llm`** (it writes nothing, so it NEVER preflights jq; R14). Hand-escape is safe: paths match the template tree (no quotes/control chars); assert this.

## Acceptance
- [ ] `--plan` emits a hand-built JSON array (no `jq` invoked) classifying every planned path with a taxonomy status + reason, writing **nothing**
- [ ] Taxonomy correct: `missing`/`identical`/`managed-update`/`conflict`/`create-once-present`/`merge`/`deleted` per the spec table
- [ ] `managed-update` vs `conflict` decided against recorded sha256; `deleted`=in-plan+absent; `retired`=not-in-plan+present+hash==recorded; `retired-conflict`=not-in-plan+present+hash!=recorded; `gone`=not-in-plan+absent; unowned config.json → `conflict` (not `merge`)
- [ ] Non-volatile compare normalized (trailing-ws strip + LF) → newline/CRLF-only differences classify `identical`, never `conflict`
- [ ] Files containing `__SCAFFOLD_GEN_URLSAFE__` classify `create-once-present` (never `conflict`); manifest-owned `config.json`→`merge`, unowned→`conflict`
- [ ] Text files compared normalized; binary/no-token files compared by raw byte hash; content-identical-but-exec-bit-drift classifies `mode-update` (not `identical`)
- [ ] `deleted` requires a prior manifest record (a clean dir → all `missing`, never `deleted`)
- [ ] Manifest is canonical line-oriented, parsed grep/regex (no jq); entries validated (safe rel path + sha256 regex + no duplicates); non-canonical/corrupt/duplicate → exit 65; emitted JSON strings escaped (R15)
- [ ] Classifier never descends `.git/`; paths escaping CWD rejected; name defaults to CWD basename (invalid → exit 64)
- [ ] CLI grammar = `--name` flag + single description positional; in .1 ONLY `--plan` works — bare/`--apply`/`--diff` all error clearly ("migration pending — .2"); `--plan` is read-only and stdout-only-JSON
- [ ] `--plan` classifies the **union** of current template paths and prior-manifest paths (`deleted`/`retired`/manifest-only surface); `--plan` never preflights jq even with `--local-llm`
- [ ] header + `usage()` describe `--plan` + the grammar; `shellcheck`+`bash -n` clean

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

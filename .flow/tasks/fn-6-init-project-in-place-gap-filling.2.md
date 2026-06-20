---
satisfies: [R1, R4, R5, R6, R7, R8, R13, R14, R15]
---

## Description
Flip apply to **in-place**, turn the classification into action (gap-fill apply + conflict resolution + `--diff`), make the **manifest an atomic output**, and **retire** strict/`--force`/`--update` into the single gap-fill default.

**Size:** M
**Files:** `plugins/init-project/scaffold.sh`

## Approach
- **In-place target + grammar (R1):** replace `target="./$name"` (`:166`) with the CWD; `existing_manifest="./$MANIFEST"`. Finalize the grammar — `--name` flag (default CWD basename) + single description positional; `--apply` becomes the **default mode**; remove the legacy two-positional/subdir path, the old `mode` gate (`:106,196-211`), and the subdir `mkdir`. Gap-fill is unconditional.
- **Apply (R5):** auto-write `missing` + `managed-update` (stamped); skip `identical`/`create-once-present`; **manifest-owned** `config.json` → existing structured-merge (`:248-266`); **unowned** `config.json` → `conflict` (keep-mine; skill may resolve `merge`/`overwrite`); `--replace-config` → **stamped overwrite** of a **manifest-owned** config (rotate secrets, jq-free); an **unowned** config.json is a `conflict` even under `--replace-config` (requires explicit `overwrite`/`merge` resolution — never auto-clobbered); prune `retired` (manifest-owned AND hash==recorded only — `:341-346`), keep `retired-conflict` (user-edited) by default, drop `gone` from manifest; `conflict` resolved per `--on-conflict keep|overwrite|fail` (default `keep`) and/or `--resolutions`; `deleted` surfaced and re-added ONLY via an explicit `restore` resolution. Keep `--replace-config`.
- **`--resolutions <file>` (R13):** jq-free text, one `<action>\t<path>` per line (action ∈ keep|overwrite|restore|**merge**|**delete**). keep/overwrite → a `conflict`; `restore` → a `deleted` path (stamps the template); **`merge` → an unowned-`config.json` conflict**; **`delete` → a `retired-conflict`** (removes the user-edited orphan on explicit request). Validate each path is within CWD + status-appropriate (delete→`retired-conflict` only); unknown / out-of-CWD / invalid-action / wrong-status / duplicate → exit 64. Prior-manifest is canonical line-oriented + validated (safe rel path + sha256 + no duplicates) → exit 65 on violation (R15). Unlisted conflicts fall back to `--on-conflict`. `fail` → non-zero exit if any conflict unresolved.
- **`--diff <path>` (R4/R13):** for a **text** conflict, unified diff of on-disk vs stamped template with secret/volatile-derived lines redacted (mask lines that would contain a generated URL-safe token or known secret field); for a **binary** conflict, a deterministic "binary files differ" report (no byte dump). jq-free (diff(1) + sed/grep).
- **Atomic, mode-preserving writes (R7):** classify all first; write each via temp-file-then-`mv` within the target dir (mirror `build-config.sh:446-486`), **preserving the template file's mode**. **Apply `mode-update`:** a content-identical file with exec-bit drift is `chmod`-ed to the template mode and emitted in the report with the **`chmod`** verb (not skipped).
- **Touched-path report (R9/R13):** `--apply` emits (on **stdout only**) jq-free tab-separated `<verb>\t<path>` lines (verb ∈ `wrote|deleted|merged|restored|chmod|manifest`); ALL human/diagnostic prose goes to **stderr** so the skill (.4) can parse stdout deterministically and stage only scaffold-touched paths.
- **Manifest as atomic output (R6) — CRITICAL per-entry rule:** record the **newly-written hash** for `missing`/`managed-update`/`overwrite`-conflict/restored-`deleted`/config-after-merge-or-replace; record the **current hash** for `identical` + previously-owned `create-once-present`. For a **kept `conflict`, NEVER record the user-edited hash** — preserve the prior manifest entry verbatim if previously owned, else omit (else next run mis-classifies it as `managed-update` and silently overwrites the user's edit — data loss). A **declined `deleted`** keeps its prior entry (stays `deleted`, never resurrected). Drop `retired`-pruned + not-in-plan-absent paths. Write the manifest **once atomically (temp+rename) at the very end** after all writes succeed; mid-run failure → prior manifest intact. The `--update` ownership gate (`:243-245`) is the conceptual seed.
- **jq boundary (R14):** only `--apply` preflights jq, and only when a `config.json` structured-**merge** actually runs (present + reconciled, NOT `--replace-config`) or `--apply --local-llm` mutates config. `--plan` (even with `--local-llm`), `--diff`, resolutions, `--replace-config` overwrite, and a clean first scaffold stay jq-free.

## Investigation targets
**Required:**
- `plugins/init-project/scaffold.sh:196-336` — mode gate, per-file loop, config merge, manifest write (rewrite)
- `plugins/init-project/scaffold.sh:243-245` — ownership gate (conflict seed)
- `plugins/init-project/templates/src/system-cli/build-config.sh:446-486` — atomic temp-rename idiom
**Optional:**
- `.flow/memory/.../docker-compose-env-file-silently-2026-06-15` — validate-before-write principle

## Key context
- Record manifest entries only for successfully-written/retained files; write the file once at the end — never claim ownership of an unwritten file.
- Deleted-files-not-resurrected (copier rule): "add what's missing" means genuinely-absent paths, not manifest-recorded-then-deleted (`deleted`).

## Acceptance
- [ ] Apply targets the **current directory** as the default mode; grammar = `--name` + description positional; legacy two-positional/subdir + strict/`--force`/`--update` removed; `--replace-config` retained; gap-fill unconditional
- [ ] `missing`+`managed-update` auto-written (stamped); `identical`/`create-once-present` skipped; **manifest-owned** `config.json` merged (unowned → `conflict`; `--replace-config` → stamped overwrite); `deleted` surfaced not re-added; `retired` pruned (manifest-owned AND hash==recorded); `retired-conflict` kept; `gone` dropped
- [ ] `--resolutions` parses jq-free `<action>\t<path>` (keep|overwrite|restore|merge|delete); keep/overwrite→`conflict`, restore→`deleted`, merge→unowned-config.json conflict, delete→`retired-conflict`; validates within-CWD + status-appropriate; unknown/out-of-CWD/invalid-action/wrong-status/duplicate → exit 64; `--on-conflict fail` → non-zero on unresolved conflict
- [ ] `--diff` emits a redacted unified diff for text conflicts and a "binary files differ" report for binary; manifest parsed from the canonical line grammar (no jq)
- [ ] `--diff <path>` prints a redacted unified diff (secret/volatile lines masked), jq-free
- [ ] All classification precedes any write; writes are temp-file-then-rename in the target dir
- [ ] Manifest per-entry rule holds: kept `conflict`/`retired-conflict` NEVER adopt the user hash; declined `deleted` keeps its entry; `retired`-pruned/`gone` dropped; written once atomically at end; forced mid-run failure leaves prior manifest intact; prior-manifest entries validated, corrupt → exit 65 (R15)
- [ ] Writes preserve template file mode; `mode-update` files are chmod-ed + reported with the `chmod` verb; `--apply` emits the stdout-only jq-free report `<verb>\t<path>` (wrote/deleted/merged/restored/chmod/manifest), diagnostics to stderr; `--replace-config` overwrites only manifest-owned config; prior-manifest validated (dup paths → exit 65)
- [ ] jq preflighted only by `--apply` for an actual config.json merge or `--apply --local-llm`; `--plan`/`--diff`/`--replace-config`/clean-first-scaffold jq-free; `shellcheck`+`bash -n` clean

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

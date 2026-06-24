---
satisfies: [R11]
---

## Description
Re-root the test harness to in-place scaffolding and add the full taxonomy/gap-fill/conflict matrix, holding the 100% kcov line gate with an explicit test per branch.

**Size:** M
**Files:** `plugins/init-project/tests/scaffold_test.sh`, `plugins/init-project/tests/coverage.sh`

## Approach
- **Re-root `run()` (`scaffold_test.sh:34`):** today `( cd "$WORK" && scaffold demo-app … )` → `$WORK/demo-app`. Flip to scaffold in place inside a fresh per-scenario dir (e.g. `mkdir $WORK/demo-app && cd $WORK/demo-app && scaffold …`), keeping the ~200 `$WORK/demo-app/...` assertion paths valid. The local-llm sub-tests (`:498-623`) each build their own `cd`/rooting — update in lockstep.
- **Matrix (R11):** empty → all `missing` (full scaffold); fully-scaffolded → non-volatile `identical` + volatile `create-once-present`, **no writes** (split these assertions — don't lump volatile `config.json` under content-identity); partial → mix; `managed-update` (write file, edit template/manifest so on-disk==recorded-hash but !=template → auto-overwrite, no prompt); each `conflict` outcome (`--on-conflict keep` preserves, `overwrite` replaces, `fail` non-zero; `--resolutions` per-file); `deleted` non-resurrection, explicit `restore` (re-adds the stamped file), AND a **declined `deleted` stays `deleted` on the next run** (not resurrected as `missing`); a **kept `conflict` does NOT become `managed-update` on re-run** (the critical no-data-loss regression — manifest never adopts the user-edited hash); `retired` pruning (local-llm removal, only when hash==recorded) AND `retired-conflict` (user-edited prior local-LLM file kept, not deleted); `gone` paths dropped from manifest (no file action); an **unowned** existing `config.json` classified `conflict` (not auto-merged, and NOT auto-overwritten by `--replace-config`) while a manifest-owned one merges (and `--replace-config` rotates owned config); a `merge` resolution on unowned config; **binary/no-token** file compared by raw hash (not normalized); **`mode-update`** (content-identical but exec bit differs → classified `mode-update`, chmod-ed, emitted with the `chmod` report verb); a **`merge`** resolution on an unowned config.json; **corrupt/duplicate prior manifest** (bad path/hash/dup) → exit 65 (R15); `--apply` stdout carries ONLY `<verb>\t<path>` report lines (diagnostics on stderr) and `--plan` stdout ONLY JSON; executable-bit preservation after write/managed-update/restore; the `--apply` touched-path report contents; manifest-only/union surfacing in `--plan`; previously-owned `create-once-present` retained in the rewritten manifest; `config.json` merge (present → merged) AND `--replace-config` stamped-overwrite secret rotation (jq-free); manifest-as-output; **forced mid-run-failure** leaves prior manifest intact; `--plan` JSON shape (incl. jq-free with `--local-llm`); `--diff` redaction; `--local-llm` under gap-fill.
- **Replace** the retired refuse-non-empty/`--force`/`--update` exit-65 tests (`:434,446-468`) with conflict/taxonomy assertions.
- **Coverage:** keep `tests/coverage.sh` kcov 100% line gate; update its branch-target comment (`:12`); explicit test per new branch (kcov branch metric unreliable per `docs/tdd.md`).

## Investigation targets
**Required:**
- `plugins/init-project/tests/scaffold_test.sh:34-48,433-489,498-623` — harness, mode/exit tests, local-llm matrix
- `plugins/init-project/tests/coverage.sh` — kcov wrapper + branch-target comment
**Optional:**
- `plugins/init-project/scaffold.sh` (final) — every branch needing a test

## Acceptance
- [ ] `run()` + local-llm sub-tests re-rooted to in-place; still-valid assertions pass
- [ ] Matrix covers: empty(all missing, never `deleted`), full(non-volatile identical + volatile create-once-present, no writes), partial, managed-update auto-overwrite, keep/overwrite/fail + `--resolutions` conflict outcomes, **kept-conflict-stays-conflict on re-run (critical)**, deleted non-resurrection + `restore` + declined-deleted-stays-deleted, `retired` prune (hash==recorded) vs `retired-conflict` keep, `gone` dropped, **unowned config.json → conflict** (+ `merge` resolution; `--replace-config` does NOT clobber it) vs owned → merge/rotate, **binary raw-hash compare**, **`mode-update` chmod + `chmod` report verb**, **corrupt/duplicate manifest → exit 65**, **`delete` resolution removes a `retired-conflict`** (engine behavior); **canonical-manifest parse** (a non-canonical/duplicate manifest → exit 65); **stdout channel purity** (apply=report-only `<verb>\t<path>`, plan=JSON-only, diagnostics→stderr); (skill git-staging behavior is verified in fn-6.4, not here — it lives in SKILL.md prose, not engine code); exec-bit preservation, `--apply` touched-path report, manifest-only union in `--plan`, previously-owned create-once-present retained, manifest-as-output, forced mid-run-failure integrity, `--plan` JSON (jq-free incl. `--local-llm`), `--diff` redaction, `--local-llm` under gap-fill
- [ ] Volatile vs non-volatile `identical` assertions are split (volatile not asserted by content-identity)
- [ ] Retired refuse-non-empty/`--force`/`--update` tests removed/replaced
- [ ] 100% kcov line coverage holds; one explicit test per new branch; `coverage.sh` branch comment updated; suite green; `shellcheck` clean

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

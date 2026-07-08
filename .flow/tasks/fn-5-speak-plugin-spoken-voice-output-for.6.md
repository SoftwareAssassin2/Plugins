---
satisfies: [R26, R29]
---

## Description

Ship the automated test suite for the pure-logic units, a `coverage.sh` harness mirroring the repo convention, and the `/speak:test` slash command that runs them.

**Prerequisite:** fn-5.3's container→host proof is green (or the fallback transport is recorded) before this task starts. Also depends on `.5` (full command surface) and `.9` (bounded-capture helpers under test; `.9` transitively brings `.8`'s identity helpers).

**Size:** M
**Files:** `plugins/speak/tests/*_test.sh`, `plugins/speak/tests/coverage.sh`, `plugins/speak/commands/test.md`

## Approach

**Contracts:** the constants and rules under test (frame shape, caps, reason set, precedence, classifications) are defined once in epic §Canonical Contracts (C1–C9) — tests assert those values, not locally restated copies.

- Mirror the init-project test harness: `PASS`/`FAIL` counters, `ok()`/`bad()`/`check()`, a `RESULT:` line, and `set +e +u` after sourcing the script-under-test. Source `bin/speak` via its source-guard so functions are testable without running `main`.
- Cover pure-logic only (no audio assertions): cleaning rules, **argv-vs-stdin input + precedence**, **base64 round-trip with newline-stripping (payload >76 chars) + decode-flag detection (`-d`/`-D`)**, **frame validation (exactly one tab; reject zero/>1 tab, empty id, empty payload)**, **spool drop-oldest at cap (default 50) + session-window (default 60s) expiry**, **`SPEAK_PORT` validation (1..65535) incl. the hook's `invalid-port` debounced notice path**, **invalid `SPEAK_MODE` → `invalid-config` notice + non-Darwin forced-local "unsupported local TTS backend"**, **CLI dispatch precedence (reserved first arg vs `speak -- <word>` vs stdin)**, **forward over-cap truncation on a UTF-8 boundary (multibyte text near the 64 KiB cap, no mid-char cut)**, **listener locking/ordering/drop-oldest/counters + identity/lock validation + bounded capture via the sourceable helpers (`.6` owns these repeatable unit tests; `.3`/`.9` own the live proofs; `.8` owns the identity helpers)**, **zero-byte probe ignored (not counted)**, **listener-side bounded capture / oversized-frame drop (`SPEAK_MAX_FRAME_BYTES`=65536, incl. oversized newline-less input)**, **debounce stale-marker pruning at 7 days**, **shared JSON emitter (jq `--arg` + jq-free static) handling `SPEAK_PORT` with quotes/newlines**, **path-normalization-resilient listener identity check (pid + ps-cmd-shape + recorded-port + lifetime lock, no token; missing/stale lock FAILS identity; reachability NOT folded into identity; `listener_stale_cleanup` rc 10 valid-untouched vs rc 11 live-different-port-untouched; startup grace window `SPEAK_LOCK_GRACE_SECS`; pidfile-only-after-bind; fatal pidfile-write-failure aborts `--serve`)**, **jq-less hook order**, mode detection, **transcript last-conversation-message extraction** (this task OWNS the fixtures under `plugins/speak/tests/fixtures/`, built from `.4`'s VERIFIED real schema (Claude Code 2.1.203 — NOT the epic's original assumed schema): the FINAL JSONL line is a bookkeeping trailer (attachment/system/ai-title), NOT the assistant record, and one response spans MULTIPLE records sharing one `message.id` (thinking + text as separate records) — so extraction = find the last main-chain conversation-message record, require it to be assistant, then join the text parts of its `message.id` cluster; last conversation-message assistant → joined text; user/tool_use/thinking-only → nothing; never scan backward past a user record. Fixtures must model a trailing trailer line + a multi-record assistant `message.id` cluster, NOT a single assistant-final record) <!-- Updated by plan-sync: fn-5.4 verified real transcript schema (final line is a bookkeeping trailer; one response spans multiple records sharing message.id) — extraction targets the last main-chain conversation-message record, not the raw FINAL line -->, dispatcher/exit codes, toggle read/write (**missing flag, corrupt flag → OFF; outside Claude with no `SPEAK_DATA_DIR`/`CLAUDE_PLUGIN_DATA` → "toggle unavailable"**), debounce marker logic, `SPEAK_MAX_CHARS` boundaries (0/negative/non-numeric), and nc connect/EOF/`-z` capability detection (NOT an authoritative `-l` probe — listen is proven only by an actual bind).
- `coverage.sh`: `suites=()` array, run each under `kcov --include-pattern` (**intentionally NOT `--include-path`** — the embedded init-project `coverage.sh` uses `--include-path`, which misses the executed temp copies; document this deliberate divergence, justified by memory `kcov-shell-coverage-ci-gate-wrong`). Degrade gracefully to plain runs when kcov is absent (NOTICE, not fail) unless `--require-kcov`, strip the `LD_PRELOAD ... libkcov` stderr warning, `mktemp -d` + `trap` cleanup. **Exact zero-lines rule:** fail on `total_lines==0` ONLY when `uname -s` = `Linux` and not Docker-on-macOS; on macOS / Docker-on-macOS, warn and run plain tests (kcov records 0 shell lines there) — never fail on zero lines on macOS. Do NOT use `CI` alone as the trigger (CI can run on macOS).
- `commands/test.md` → runs **`"${CLAUDE_PLUGIN_ROOT}/tests/coverage.sh" --plain`** (explicit path — plugin commands run from arbitrary CWDs; plain mode = skip kcov, fast + deterministic); exits 0 all-pass, non-zero on any failure. The `--plain` flag is defined in `coverage.sh` (forces skipping kcov even when present).

## Investigation targets
**Required:**
- `plugins/init-project/tests/coverage.sh:32-76` — coverage harness to mirror
- `plugins/init-project/tests/dispatcher_test.sh:15-24,49-89,223-226` — test harness boilerplate + branch-completeness
- `plugins/init-project/tests/scaffold_test.sh:13-25` — source-then-`set +e +u`
**Optional:**
- memory `bug/build-errors/kcov-shell-coverage-ci-gate-wrong-2026-06-14`

## Acceptance
- [ ] `tests/*_test.sh` cover cleaning, base64 round-trip (>76-char payload), mode detection, transcript last-conversation-message extraction (last main-chain conversation-message record → if assistant, join its `message.id` text-part cluster; user/tool_use/thinking-only → nothing; trailing bookkeeping-trailer line skipped; never scan backward past a user record) <!-- Updated by plan-sync: fn-5.4 verified real schema — extract targets the last main-chain conversation-message record + message.id cluster, not the raw FINAL line -->, exit codes, toggle (missing/corrupt/unset-data-dir → OFF), debounce, `SPEAK_MAX_CHARS` bounds, nc-flag detection (R26)
- [ ] `coverage.sh` uses `--include-pattern` (deliberate divergence from init-project's `--include-path`, justified inline), graceful degrade, `--require-kcov`; fails on `total_lines==0` only when `uname -s`=Linux and not Docker-on-macOS (never keyed off `CI` alone), warns + runs plain on macOS/Docker-on-macOS (R26)
- [ ] tests cover empty-after-sanitize session id → safe non-empty fallback (no empty-id frame)
- [ ] `/speak:test` runs `"${CLAUDE_PLUGIN_ROOT}/tests/coverage.sh" --plain` (explicit path, kcov skipped, deterministic); exits 0 all-pass, non-zero on failure; `--plain` flag implemented in `coverage.sh` (R26, R29)
- [ ] Tests source `bin/speak` via the source-guard and `set +e +u` after sourcing
- [ ] `plugins/speak/tests/coverage.sh` (and `*_test.sh`) are committed executable (`test -x`)

## Done summary
Shipped the speak plugin's automated test suite (241 checks across cli_test.sh / listener_test.sh / hook_test.sh + transcript fixtures modeling the fn-5.4 verified real schema), a kcov coverage harness using --include-pattern with a native-Linux-only zero-lines gate and a --plain mode, and the /speak:test command running "${CLAUDE_PLUGIN_ROOT}/tests/coverage.sh" --plain.
## Evidence
- Commits: d00e42256bd283eb00fe662246e14f762e07a772
- Tests: bash plugins/speak/tests/coverage.sh --plain (cli 113 + listener 82 + hook 46 = 241 checks, 0 failed), bash plugins/speak/tests/coverage.sh (kcov mode on macOS: zero-lines WARN + plain fallback, exit 0)
- PRs:
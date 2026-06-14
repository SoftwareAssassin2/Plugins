---
title: "kcov shell-coverage CI gate: wrong fileset, nested-bash, partial suite"
date: "2026-06-14"
track: bug
category: build-errors
module: templates/.github/workflows/ci.yml
tags: [kcov, shell, coverage, ci, github-actions, bash, gate]
problem_type: build-error
symptoms: 100% shell coverage gate measured 0/wrong files or could never reach 100%
root_cause: kcov include-path vs executed copies + non-instrumented nested bash + partial suite (subcommands never exercised)
resolution_type: fix
---

## Problem
A CI "100% shell line coverage" gate over a bash test harness was effectively
broken in two ways the first review caught: (1) the harness runs COPIES of the
scripts in a temp `$WORK` dir, but kcov's `--include-path` pointed at the repo
originals, so kcov measured an empty/wrong file set; (2) the harness invoked the
scripts via `$( cd "$WORK" && bash "$script" )` — kcov does NOT reliably instrument
deeply-nested grandchild bash, so coverage stayed 0 even when paths matched. A second
review found the suite only exercised the dispatcher + one subcommand, so the other
subcommands (up/down/status/migrate) were never covered — the gate could never reach
100% and (correctly) failed closed forever.

## What Didn't Work
- `kcov --include-path="$PWD/system.sh,..."` while the suite executes temp COPIES:
  paths don't match -> 0 files measured.
- Relying on kcov to follow `$(bash child)` subshells for coverage: it doesn't.
- A shell-variable run counter in a `runner()` helper: each call is wrapped in
  `$(...)` (a subshell), so the increment never persists — use a counter FILE.

## Solution
- Run each script as a DIRECT kcov child: a `runner()` indirection keyed on an env
  var (`SYSTEM_CLI_KCOV_DIR`) wraps each invocation in `kcov --collect-only
  --include-pattern=/system.sh,/src/system-cli/ <unique-dir> bash "$script"`, then CI
  `kcov --merge`es the per-call dirs. `--include-pattern` (substring) matches the
  executed copies wherever the temp dir lands; `--include-path` (prefix) does not.
- Unique per-call dir from a COUNTER FILE under the kcov dir (subshell-safe).
- Strip kcov's `LD_PRELOAD ... libkcov ... cannot be preloaded` warning line from
  captured stderr, or it corrupts exact-prefix stderr assertions; preserve the
  script's real exit code across the filter pipe (capture rc, re-exit).
- Stub external commands (`docker`, `dotnet`) on PATH and exercise EVERY subcommand
  across BOTH branches so line coverage can actually reach 100%.
- Make the parse-gate FAIL on `total_lines == 0` (broken instrumentation must never
  be a silent pass).

## Prevention
- When authoring a kcov line gate, prove it measures the RIGHT files (jq the merged
  `coverage.json` `.files[].file`) and a non-zero `total_lines` before trusting it.
- kcov bash line tracing is environment-fragile: it cannot trace `/bin/bash` under
  macOS SIP, and records 0 covered lines even for a trivial script under
  Docker-on-macOS (ptrace single-step fails in nested virt). It works on native
  Linux runners. Verify the harness PASSES + the per-call collect/merge MECHANISM
  runs locally; verify the line COUNT on a Linux runner.
- A coverage gate is only meaningful if the suite EXERCISES every unit — a green
  number over a partial suite is a false signal.

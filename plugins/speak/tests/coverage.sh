#!/usr/bin/env bash
# Description: Run the speak plugin shell test suites, under kcov when useful.
#
# Mirrors plugins/init-project/tests/coverage.sh with two DELIBERATE divergences:
#
#   1. `kcov --include-pattern` (substring match), NOT `--include-path`
#      (prefix match). The embedded init-project harness uses --include-path,
#      which silently measures an EMPTY fileset whenever the executed script
#      paths don't prefix-match (memory: bug/build-errors/
#      kcov-shell-coverage-ci-gate-wrong-2026-06-14). These suites execute
#      bin/speak and hooks/stop-speak.sh by absolute path but also source and
#      shim from temp dirs — the substring patterns below match the scripts
#      under test wherever they run from.
#
#   2. An exact zero-lines gate that fires on NATIVE LINUX ONLY. kcov records
#      0 covered shell lines on macOS (SIP blocks tracing the system bash) and
#      under Docker-on-macOS (ptrace single-step fails in nested virt), so
#      total_lines==0 there is an environment artifact: WARN and fall back to
#      plain runs. On native Linux, 0 lines means broken instrumentation and
#      MUST fail. Detection is uname + linuxkit markers — deliberately NEVER
#      keyed on $CI alone (CI can run on macOS).
#
# Usage:
#   coverage.sh                 run all suites (under kcov if available)
#   coverage.sh --plain         skip kcov even when installed — fast and
#                               deterministic; /speak:test runs this
#   coverage.sh --require-kcov  FAIL if kcov is absent (use in Linux CI)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

require_kcov=0
plain=0
for arg in "$@"; do
  case "$arg" in
    --require-kcov) require_kcov=1 ;;
    --plain) plain=1 ;;
    *)
      echo "ERROR: unknown option '$arg' (usage: coverage.sh [--plain|--require-kcov])" >&2
      exit 1
      ;;
  esac
done
if [[ "$plain" -eq 1 && "$require_kcov" -eq 1 ]]; then
  echo "ERROR: --plain and --require-kcov are mutually exclusive" >&2
  exit 1
fi

# The shell test suites this package owns.
suites=(
  "$SCRIPT_DIR/cli_test.sh"
  "$SCRIPT_DIR/listener_test.sh"
  "$SCRIPT_DIR/hook_test.sh"
)
for s in "${suites[@]}"; do
  [[ -f "$s" ]] || { echo "ERROR: test suite not found: $s" >&2; exit 1; }
done

run_plain() {
  echo "== running suites WITHOUT coverage =="
  local rc=0 s
  for s in "${suites[@]}"; do
    echo "--- $(basename "$s") ---"
    bash "$s" || rc=1
  done
  return "$rc"
}

if [[ "$plain" -eq 1 ]]; then
  run_plain
  exit $?
fi

if ! command -v kcov >/dev/null 2>&1; then
  if [[ "$require_kcov" -eq 1 ]]; then
    echo "ERROR: --require-kcov set but kcov is not installed" >&2
    exit 1
  fi
  echo "NOTICE: kcov not installed — running suites without coverage." >&2
  echo "NOTICE: install kcov (e.g. 'brew install kcov' / 'apt-get install kcov') for line-coverage reporting." >&2
  run_plain
  exit $?
fi

# native_linux — true only on real Linux, NOT under Docker Desktop's linuxkit
# VM (Docker-on-macOS/Windows), where kcov's ptrace tracing records 0 lines.
# Never keyed on $CI: CI can run on macOS.
native_linux() {
  [[ "$(uname -s)" == "Linux" ]] || return 1
  case "$(uname -r 2>/dev/null)$(cat /proc/version 2>/dev/null || true)" in
    *linuxkit* | *LinuxKit*) return 1 ;;
  esac
  return 0
}

# kcov is available — measure line coverage of the scripts under test.
# --include-pattern (substring), deliberately NOT --include-path: see header.
cov_out="$(mktemp -d)"
trap 'rm -rf "$cov_out"' EXIT

rc=0
total_lines=0
for s in "${suites[@]}"; do
  name="$(basename "$s" .sh)"
  echo "== kcov: $(basename "$s") =="
  errf="$cov_out/$name.stderr"
  krc=0
  kcov --include-pattern=bin/speak,hooks/stop-speak.sh \
    "$cov_out/$name" bash "$s" 2>"$errf" || krc=$?
  # kcov's harmless "LD_PRELOAD ... libkcov ... cannot be preloaded" noise
  # corrupts stderr assertions/log scraping — strip it, keep everything else.
  grep -v 'libkcov' "$errf" >&2 || true
  [[ "$krc" -eq 0 ]] || rc=1
  # Sum total_lines across the per-suite coverage.json reports.
  while IFS= read -r covjson; do
    n="$(grep -o '"total_lines"[^0-9]*[0-9]*' "$covjson" 2>/dev/null | tr -cd '0-9' || true)"
    [[ -n "$n" ]] && total_lines=$((total_lines + n))
  done < <(find "$cov_out/$name" -name coverage.json 2>/dev/null)
done

if [[ "$total_lines" -eq 0 ]]; then
  if native_linux; then
    echo "ERROR: kcov recorded total_lines==0 on native Linux — instrumentation is broken (a zero-line pass must never be silent)" >&2
    exit 1
  fi
  echo "WARNING: kcov recorded 0 covered shell lines — expected on macOS (SIP) and Docker-on-macOS (nested-virt ptrace); coverage is only meaningful on native Linux." >&2
  echo "WARNING: falling back to plain (uninstrumented) suite runs for the authoritative result." >&2
  run_plain
  exit $?
fi

echo "kcov line coverage written under: $cov_out (total_lines=$total_lines; see index.html per suite)"
exit "$rc"

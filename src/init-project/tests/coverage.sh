#!/usr/bin/env bash
# Description: Run the init-project shell test suites under kcov for line coverage.
#
# This is the skill-package coverage harness. It runs scaffold_test.sh and
# dispatcher_test.sh under kcov (https://github.com/SimonKagstrom/kcov) to measure
# LINE coverage of the scripts under test (scaffold.sh + the system.sh dispatcher
# template + its src/system-cli/*.sh subcommands).
#
# Branch completeness is NOT enforced by kcov here: kcov's bash branch metric is
# not portable/reliable across hosts, so per docs/tdd.md the suites instead carry
# an EXPLICIT test for each branch (usage / unknown / underscore-rejection /
# refuse-non-empty / --force / --update / --dry-run / alphabet-reject / realm-stamp).
# kcov gives us the line-coverage signal; the explicit per-branch tests give us
# branch completeness.
#
# Degradation: if kcov is not installed on the host, this wrapper runs the test
# suites WITHOUT coverage and prints a clear notice — it never hard-fails the
# suite merely because kcov is absent (CI installs kcov; local dev may not).
#
# Usage:
#   coverage.sh                # run all suites (under kcov if available)
#   coverage.sh --require-kcov # FAIL if kcov is absent (use in CI)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"   # src/init-project

require_kcov=0
[[ "${1:-}" == "--require-kcov" ]] && require_kcov=1

# The shell test suites this package owns.
suites=(
  "$SCRIPT_DIR/scaffold_test.sh"
  "$SCRIPT_DIR/dispatcher_test.sh"
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

# kcov is available — measure line coverage of the package's shell scripts.
cov_out="$(mktemp -d)"
trap 'rm -rf "$cov_out"' EXIT

rc=0
for s in "${suites[@]}"; do
  echo "== kcov: $(basename "$s") =="
  # --include-path limits instrumentation to the package's own scripts.
  if ! kcov --include-path="$PKG_DIR" "$cov_out/$(basename "$s" .sh)" bash "$s"; then
    rc=1
  fi
done

echo "kcov coverage written under: $cov_out (line coverage; see index.html per suite)"
exit "$rc"

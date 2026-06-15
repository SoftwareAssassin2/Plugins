#!/usr/bin/env bash
# Description: Run the shell suite under kcov and enforce 100% line coverage.
#
# This is the generated project's SHELL coverage gate (docs/tdd.md §6). It runs the
# system.sh-dispatcher + src/system-cli/*.sh suite (tests/system-cli/system_cli_test.sh)
# under kcov for LINE coverage, then fails if line coverage is below 100%.
#
# Mechanism: the suite invokes each script as a DIRECT kcov child (kcov instruments
# its immediate target reliably; deeply-nested bash is not) when SYSTEM_CLI_KCOV_DIR
# is set, writing one collect dir per invocation. This wrapper sets that env var,
# runs the suite (which must also pass its CORRECTNESS + per-branch assertions),
# merges the per-call collect dirs, and runs the parse-summary gate.
#
# Branch completeness is NOT a kcov number (bash branch metrics aren't portable —
# docs/tdd.md §6): the suite carries an EXPLICIT test per branch. So this gate pairs
# kcov LINE coverage with the suite's per-branch correctness assertions.
#
# Degradation: without --require-kcov, a missing kcov runs the suite WITHOUT coverage
# and prints a notice (local dev convenience). CI passes --require-kcov so an absent
# or non-measuring kcov is a hard failure (never a silent pass).
#
# Usage:
#   tests/coverage.sh                # suite + coverage if kcov present (soft)
#   tests/coverage.sh --require-kcov # CI: kcov mandatory, 100% line gate enforced

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"          # repo root
GATE="$ROOT/.github/scripts/kcov-gate.sh"

# Every shell suite under tests/system-cli/ (system_cli_test.sh, local_llm_test.sh,
# …). They share ONE kcov collect dir so the merged summary spans all of them — a
# single 100%-line gate over all new/changed shell. local_llm_test.sh self-skips
# (exit 0) when the local-llm stack is not installed, so a non-opt-in project's CI
# stays green; it still contributes nothing to the merge in that case.
SUITES=()
while IFS= read -r s; do SUITES+=("$s"); done \
  < <(find "$SCRIPT_DIR/system-cli" -maxdepth 1 -name '*_test.sh' -type f | sort)
[[ ${#SUITES[@]} -gt 0 ]] || { echo "ERROR: no shell suites found under $SCRIPT_DIR/system-cli" >&2; exit 1; }

require_kcov=0
[[ "${1:-}" == "--require-kcov" ]] && require_kcov=1

if ! command -v kcov >/dev/null 2>&1; then
  if [[ "$require_kcov" -eq 1 ]]; then
    echo "ERROR: --require-kcov set but kcov is not installed" >&2
    exit 1
  fi
  echo "NOTICE: kcov not installed — running the shell suites WITHOUT coverage." >&2
  echo "NOTICE: install kcov (apt-get install kcov / brew install kcov) for the line-coverage gate." >&2
  for suite in "${SUITES[@]}"; do bash "$suite" || exit $?; done
  exit 0
fi

# kcov present — run every suite in coverage mode into ONE shared collect dir.
KDIR="$(mktemp -d)"; trap 'rm -rf "$KDIR"' EXIT
echo "== running shell suites under kcov (collect dir: $KDIR) =="
for suite in "${SUITES[@]}"; do
  echo "-- $suite"
  SYSTEM_CLI_KCOV_DIR="$KDIR" bash "$suite"   # each asserts correctness + per-branch
done

# Merge every per-call collect dir into one summary.
runs=("$KDIR"/run-*)
if [[ ! -e "${runs[0]}" ]]; then
  echo "ERROR: kcov produced no collect dirs under $KDIR — coverage was not measured." >&2
  exit 1
fi
MERGED="$KDIR/merged"
kcov --merge "$MERGED" "${runs[@]}"

# Enforce 100% line via the shared parse-summary gate.
if [[ -x "$GATE" ]]; then
  bash "$GATE" "$MERGED"
else
  echo "ERROR: coverage gate not found at $GATE" >&2
  exit 1
fi

#!/usr/bin/env bash
# Description: Fail CI if kcov's merged line coverage is below 100% for the shell suite.
#
# kcov has no built-in pass/fail gate (and its bash branch metric is not portable —
# see docs/tdd.md), so this parses kcov's merged JSON summary and enforces the
# 100%-LINE rule. Branch completeness for the shell suite is enforced separately by
# an explicit test-per-branch in tests/system-cli/system_cli_test.sh, not by a kcov
# branch number.
#
# Usage: kcov-gate.sh <kcov-output-dir>
# The <kcov-output-dir> is what was passed to `kcov <dir> ...`. kcov writes a merged
# summary at <dir>/kcov-merged/coverage.json (older kcov: <dir>/<run>/coverage.json).
# We read `percent_covered` and require it to be exactly 100.

set -euo pipefail

cov_dir="${1:?usage: kcov-gate.sh <kcov-output-dir>}"

# Locate the merged coverage summary. kcov >= 38 writes kcov-merged/coverage.json;
# fall back to any coverage.json under the output dir if the merged name differs.
summary=""
for cand in "$cov_dir/kcov-merged/coverage.json" "$cov_dir"/*/coverage.json; do
  if [[ -f "$cand" ]]; then summary="$cand"; break; fi
done
[[ -n "$summary" ]] || {
  echo "ERROR: no kcov coverage.json found under $cov_dir" >&2
  exit 1
}

echo "Reading kcov summary: $summary"

# `percent_covered` is a string like "100" or "97.5"; covered/total are integers.
pct="$(jq -r '.percent_covered // empty' "$summary")"
covered="$(jq -r '.covered_lines // empty' "$summary")"
total="$(jq -r '.total_lines // empty' "$summary")"

[[ -n "$pct" ]] || { echo "ERROR: percent_covered missing from $summary" >&2; exit 1; }

# A summary with zero total lines means kcov did not actually instrument the scripts
# (wrong include scope, or a runner that can't trace bash). That is a BROKEN gate, not
# a pass — fail loudly rather than report a misleading 0%.
if [[ "${total:-0}" -eq 0 ]]; then
  echo "FAIL: kcov measured 0 total lines — the shell scripts were not instrumented." >&2
  echo "      (check the kcov include scope / that the suite runs scripts as kcov children)" >&2
  exit 1
fi

echo "Shell line coverage: $pct% ($covered/$total lines)"

# Require 100% line coverage. Use awk for the float compare (pct may be e.g. 99.9).
if awk -v p="$pct" 'BEGIN { exit (p >= 100) ? 0 : 1 }'; then
  echo "PASS: shell line coverage is 100%."
else
  echo "FAIL: shell line coverage $pct% is below the required 100% (docs/tdd.md)." >&2
  exit 1
fi

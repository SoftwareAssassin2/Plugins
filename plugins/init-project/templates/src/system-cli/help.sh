#!/usr/bin/env bash
# Description: List all available system CLI commands with their descriptions.
#
# Convention: each command script includes a line near the top of the form
#   # Description: <one-line summary>
# which this script extracts (first match only) to build the listing.
#
# Files in this directory whose basename begins with `_` are PRIVATE helpers and
# intentionally do not appear here. The dispatcher also rejects underscore-prefixed
# subcommands at exit 64.

set -euo pipefail

cli_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# `nullglob` so an unmatched glob yields an empty list rather than the literal
# `*.sh` string.
shopt -s nullglob

# Collect candidate command files, filter out private helpers (basename `_*`).
candidates=()
for f in "$cli_dir"/*.sh; do
  base=$(basename "$f")
  [[ $base == _* ]] && continue
  candidates+=("$f")
done

# Compute alignment width across surviving names (extension stripped).
max=0
for f in "${candidates[@]}"; do
  name=$(basename "$f" .sh)
  (( ${#name} > max )) && max=${#name}
done

echo "Available commands:"
echo
for f in "${candidates[@]}"; do
  name=$(basename "$f" .sh)
  desc=$(sed -nE 's/^#[[:space:]]*Description:[[:space:]]*(.*)$/\1/p' "$f" | head -n1)
  [[ -z $desc ]] && desc="(no description)"
  printf "  %-*s  %s\n" "$max" "$name" "$desc"
done

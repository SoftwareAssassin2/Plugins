#!/usr/bin/env bash
# Description: Fail CI if config.json and config.deploy.json have drifted key sets.
#
# config.json (local dev) and config.deploy.json (deploy template) must share the
# SAME shape so a value present in one is renderable in the other — only scalar
# VALUES differ (generated local secrets vs {{VAR-NAME}} placeholders). This gate
# normalizes both files to a sorted set of structural PATHS and fails only on a
# missing/extra path. It deliberately IGNORES scalar values (so secrets vs
# placeholders never trip it) and matches `systems[]` entries BY `.name` (array
# order is irrelevant) and `services{}` by key.
#
# Usage: config-drift.sh [config.json] [config.deploy.json]

set -euo pipefail

local_cfg="${1:-config.json}"
deploy_cfg="${2:-config.deploy.json}"

for f in "$local_cfg" "$deploy_cfg"; do
  [[ -f "$f" ]] || { echo "ERROR: $f not found" >&2; exit 1; }
  jq -e . "$f" >/dev/null 2>&1 || { echo "ERROR: $f is not valid JSON" >&2; exit 1; }
done

# Emit the structural path set of a config file, scalar values ignored:
#   - systems[] is re-keyed BY .name (so order doesn't matter and the path is stable)
#   - leaf scalars collapse to their path only (value dropped) so secrets vs
#     {{VAR}} placeholders never register as drift
#   - leaf-only paths are emitted (container nodes are implied by their children)
paths_of() {
  # Re-key systems[] by .name so paths are name-addressed (order-independent), then
  # emit the path of every SCALAR leaf, value dropped. We do NOT use paths(scalars):
  # paths(f) filters on the truthiness of f, so a false leaf is silently dropped
  # (a jq gotcha). Instead we enumerate every path and keep those whose node is a
  # scalar by TYPE, which correctly covers false / null / 0 / empty-string.
  jq -r '
    (if (.systems | type) == "array"
       then .systems |= (map({ (.name // "?"): . }) | add)
       else . end)
    | . as $root
    | [ paths as $p
        | ($root | getpath($p) | type) as $t
        | select($t != "array" and $t != "object")
        | $p | map(tostring) | join(".") ]
    | sort | .[]
  ' "$1"
}

local_paths="$(paths_of "$local_cfg")"
deploy_paths="$(paths_of "$deploy_cfg")"

missing="$(comm -23 <(printf '%s\n' "$local_paths") <(printf '%s\n' "$deploy_paths"))"
extra="$(comm -13 <(printf '%s\n' "$local_paths") <(printf '%s\n' "$deploy_paths"))"

status=0
if [[ -n "$missing" ]]; then
  echo "FAIL: paths in $local_cfg but MISSING from $deploy_cfg:" >&2
  printf '  - %s\n' $missing >&2
  status=1
fi
if [[ -n "$extra" ]]; then
  echo "FAIL: paths in $deploy_cfg but MISSING from $local_cfg:" >&2
  printf '  - %s\n' $extra >&2
  status=1
fi

if [[ "$status" -eq 0 ]]; then
  echo "PASS: config.json and config.deploy.json share the same structural path set."
fi
exit "$status"

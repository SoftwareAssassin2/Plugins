#!/usr/bin/env bash
# Dispatcher for the system CLI.
#
# Subcommands live under src/system-cli/ as *.sh files. Files whose
# basename starts with `_` are private helpers and MUST NOT be invokable
# from the dispatcher.
#
# Failure contract:
# the underscore-rejection stderr line is pinned exactly to
#   ERROR: '<subcommand>' <error-message>
# Exit code 64 for usage errors; 127 for unknown subcommands.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "ERROR: usage: $(basename "$0") <subcommand> [args...]" >&2
  exit 64
fi

subcommand=$1
shift

# Private helpers (basenames starting with `_`) are never dispatchable
# from the CLI surface.
if [[ $subcommand == _* ]]; then
  echo "ERROR: '$subcommand' is a private helper (starts with underscore)" >&2
  exit 64
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
target="$script_dir/src/system-cli/$subcommand.sh"

if [[ ! -f $target ]]; then
  echo "ERROR: no such subcommand '$subcommand' (expected $target)" >&2
  exit 127
fi

exec "$target" "$@"

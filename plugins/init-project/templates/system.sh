#!/usr/bin/env bash
# Description: Dispatch a system CLI subcommand to src/system-cli/<subcommand>.sh.
#
# The single entry point for repo tooling. This file lives at the REPO ROOT, so
# its directory IS the repo root and `$script_dir/src/system-cli/<sub>.sh`
# resolves the subcommand scripts directly (no `cd ..`). Subcommands live under
# src/system-cli/ as *.sh files; files whose basename starts with `_` are private
# helpers and MUST NOT be invokable from the dispatcher.
#
# Failure contract:
#   - no subcommand              -> exit 64, usage line on stderr
#   - `_`-prefixed subcommand    -> exit 64, pinned stderr: ERROR: '<sub>' ...
#   - unknown subcommand         -> exit 127
# On a valid subcommand it `exec`s the target with the remaining args.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "ERROR: usage: $(basename "$0") <subcommand> [args...]" >&2
  exit 64
fi

subcommand=$1
shift

# Private helpers (basenames starting with `_`) are never dispatchable from the
# CLI surface — they exist only for other subcommands to source.
if [[ $subcommand == _* ]]; then
  echo "ERROR: '$subcommand' is a private helper (starts with underscore)" >&2
  exit 64
fi

# This script sits at the repo root; subcommands live under src/system-cli/.
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
target="$script_dir/src/system-cli/$subcommand.sh"

if [[ ! -f $target ]]; then
  echo "ERROR: no such subcommand '$subcommand' (expected $target)" >&2
  exit 127
fi

exec "$target" "$@"

#!/usr/bin/env bash
# Description: Open an interactive psql session to a database using config.json connection settings.
#
# Reads the postgres connection settings from the single source config.json and
# opens psql against the named database. By default it connects as the `migrator`
# LOGIN role — the right role for interactive work: it has full schema access
# (member of owner; can `SET ROLE owner` for DDL) and, unlike `api`, is not
# constrained by row-level security. `owner` is NOLOGIN and cannot connect; pass
# `--role api` to connect as the RLS-constrained runtime role (e.g. to reproduce
# what the Api sees). See docs/config-management.md §3 for the role model.
#
# Usage:
#   system.sh psql <database> [--role migrator|api] [--config <path>] [psql-args...]
#
# Examples:
#   ./system.sh psql platform                  # interactive shell as migrator
#   ./system.sh psql platform --role api        # connect as the RLS-constrained api role
#   ./system.sh psql platform -c 'SELECT 1'     # run one statement and exit (psql passthrough)
#
# Connection settings come from the `postgres` system in config.json: `host` and
# `port` (the host-facing 127.0.0.1:<port> the dev container reaches) plus the
# role's password (migrator_password / api_password). The db name and role names
# are fixed scaffold constants. The password is handed to psql via PGPASSWORD so it
# never appears in the process arg list (visible in `ps`).
#
# Exit codes follow the CLI contract: 64 = usage/config error, 127 = required tool
# missing. On success it `exec`s psql, so psql's own exit code is returned.

set -euo pipefail

die()   { echo "ERROR: $*" >&2; exit "${2:-64}"; }
usage() { echo "usage: system.sh psql <database> [--role migrator|api] [--config <path>] [psql-args...]" >&2; exit 64; }

cli_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$cli_dir/../.." && pwd)
cd "$repo_root"

config="config.json"
role="migrator"
database=""

# Parse OUR leading options. The first non-option token is the database name; every
# token after it is forwarded verbatim to psql (so `psql platform -c '...'` works).
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)   [[ $# -ge 2 ]] || usage; config="$2"; shift 2 ;;
    --config=*) config="${1#--config=}"; shift ;;
    --role)     [[ $# -ge 2 ]] || usage; role="$2"; shift 2 ;;
    --role=*)   role="${1#--role=}"; shift ;;
    -h|--help)  usage ;;
    --)         shift; break ;;
    --*)        die "unknown flag '$1'" ;;
    *)          database="$1"; shift; break ;;
  esac
done

[[ -n "$database" ]] || usage
[[ "$database" =~ ^[A-Za-z0-9_-]+$ ]] || die "invalid database name '$database' (^[A-Za-z0-9_-]+)"

# Map the role to its config.json password field. owner is NOLOGIN by design.
case "$role" in
  migrator) pw_field="migrator_password" ;;
  api)      pw_field="api_password" ;;
  owner)    die "role 'owner' is NOLOGIN and cannot connect — use migrator (default) or api" ;;
  *)        die "invalid --role '$role' (expected migrator or api)" ;;
esac

command -v jq   >/dev/null 2>&1 || die "jq not found on PATH" 127
command -v psql >/dev/null 2>&1 || die "psql not found on PATH — install postgresql-client or rebuild the dev container" 127

[[ -f "$config" ]] || die "config file not found: $config"
jq -e . "$config" >/dev/null 2>&1 || die "config is not valid JSON: $config"

# Read the postgres connection settings from the single source config.
pg='(.systems[] | select(.name=="postgres"))'
read_cfg() {  # filter, human-label -> value (dies if null/absent)
  local out
  out="$(jq -r "$1 // empty" "$config")"
  [[ -n "$out" ]] || die "missing config field: $2 (config.json postgres system)"
  printf '%s' "$out"
}

host="$(read_cfg "$pg.host" "postgres.host")"
port="$(read_cfg "$pg.port" "postgres.port")"
password="$(read_cfg "$pg.$pw_field" "postgres.$pw_field")"

[[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]] || die "postgres.port invalid (1..65535): '$port'"

# PGPASSWORD keeps the secret off psql's argv. exec replaces this shell so psql owns
# the tty directly (clean signals + job control) and its exit code propagates.
export PGPASSWORD="$password"
exec psql -h "$host" -p "$port" -U "$role" -d "$database" "$@"

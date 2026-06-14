#!/usr/bin/env bash
# Description: Apply EF Core migrations as the migrator role (dotnet ef database update).
#
# Migrations run as the least-privilege `migrator` LOGIN role (a member of the
# NOLOGIN `owner`), via EF Core's design-time factory. .NET does NOT read .env
# files, so this script sources the generated src/DataAccess/.env and EXPORTS
# MIGRATOR_CONNECTION_STRING into the environment before invoking the EF tool.
# Run `system.sh build-config` first to generate src/DataAccess/.env.

set -euo pipefail

cli_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$cli_dir/../.." && pwd)
cd "$repo_root"

env_file="src/DataAccess/.env"
[[ -f "$env_file" ]] || {
  echo "ERROR: $env_file not found — run './system.sh build-config' first" >&2
  exit 64
}

# Source the generated env and export the migrator connection string for `dotnet ef`.
set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

[[ -n "${MIGRATOR_CONNECTION_STRING:-}" ]] || {
  echo "ERROR: MIGRATOR_CONNECTION_STRING missing from $env_file" >&2
  exit 64
}
export MIGRATOR_CONNECTION_STRING

# Restore the pinned dotnet-ef local tool, then apply migrations via the
# DataAccess design-time factory (which reads MIGRATOR_CONNECTION_STRING).
dotnet tool restore
dotnet ef database update --project src/DataAccess

#!/usr/bin/env bash
# Description: Bring up the service stack (postgres, keycloak, observability) via docker compose.
#
# Brings up each compose-managed service component. Every service component owns
# its own compose file under src/<component>/docker-compose.yml (postgres,
# keycloak) plus the observability stack under etc/observability/. Run
# `system.sh build-config` first so the generated .env files exist.

set -euo pipefail

cli_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$cli_dir/../.." && pwd)
cd "$repo_root"

# Compose stacks brought up, in dependency order.
stacks=(
  "src/postgres/docker-compose.yml"
  "src/keycloak/docker-compose.yml"
  "etc/observability/docker-compose.yml"
)

started=0
for stack in "${stacks[@]}"; do
  if [[ -f "$stack" ]]; then
    echo "up: $stack"
    docker compose -f "$stack" up -d
    started=$((started + 1))
  fi
done

if [[ "$started" -eq 0 ]]; then
  echo "up: no compose stacks present yet (nothing to start)" >&2
fi

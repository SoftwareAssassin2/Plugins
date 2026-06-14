#!/usr/bin/env bash
# Description: Stop the service stack (observability, keycloak, postgres) via docker compose.
#
# Tears down the compose-managed service components in reverse dependency order.
# Each service component owns its own compose file under
# src/<component>/docker-compose.yml; the observability stack lives under
# etc/observability/.

set -euo pipefail

cli_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$cli_dir/../.." && pwd)
cd "$repo_root"

# Reverse of `up` order.
stacks=(
  "etc/observability/docker-compose.yml"
  "src/keycloak/docker-compose.yml"
  "src/postgres/docker-compose.yml"
)

stopped=0
for stack in "${stacks[@]}"; do
  if [[ -f "$stack" ]]; then
    echo "down: $stack"
    docker compose -f "$stack" down
    stopped=$((stopped + 1))
  fi
done

if [[ "$stopped" -eq 0 ]]; then
  echo "down: no compose stacks present yet (nothing to stop)" >&2
fi

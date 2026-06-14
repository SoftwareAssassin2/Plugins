#!/usr/bin/env bash
# Description: Show the status of the service stack (compose services + ports).
#
# Reports the running state of each compose-managed service component
# (postgres, keycloak, observability). A thin operator-visibility wrapper over
# `docker compose ps`.

set -euo pipefail

cli_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$cli_dir/../.." && pwd)
cd "$repo_root"

stacks=(
  "src/postgres/docker-compose.yml"
  "src/keycloak/docker-compose.yml"
  "src/otel-collector/docker-compose.yml"
  "src/prometheus/docker-compose.yml"
  "src/grafana/docker-compose.yml"
)

found=0
for stack in "${stacks[@]}"; do
  if [[ -f "$stack" ]]; then
    echo "== $stack =="
    docker compose -f "$stack" ps
    found=$((found + 1))
  fi
done

if [[ "$found" -eq 0 ]]; then
  echo "status: no compose stacks present yet" >&2
fi

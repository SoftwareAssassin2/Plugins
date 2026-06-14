#!/usr/bin/env bash
# Description: Stop the service stack (observability, keycloak, postgres) via docker compose.
#
# Tears down the compose-managed service components in reverse dependency order.
# Each component owns its own compose file under src/<component>/docker-compose.yml:
# the observability stack (grafana + prometheus + otel-collector), then keycloak,
# then postgres.
#
# After the observability stacks are down, the shared `observability` Docker network
# they joined is removed (best-effort — `docker network rm` fails harmlessly if the
# network is gone or still has endpoints).

set -euo pipefail

cli_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$cli_dir/../.." && pwd)
cd "$repo_root"

# Reverse of `up` order (grafana -> prometheus -> otel-collector, then identity, then datastore).
stacks=(
  "src/grafana/docker-compose.yml"
  "src/prometheus/docker-compose.yml"
  "src/otel-collector/docker-compose.yml"
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

# Remove the shared observability network once its stacks are down (best-effort).
obs_present=0
for stack in "src/otel-collector/docker-compose.yml" "src/prometheus/docker-compose.yml" "src/grafana/docker-compose.yml"; do
  [[ -f "$stack" ]] && obs_present=1
done
if [[ "$obs_present" -eq 1 ]]; then
  echo "down: removing shared 'observability' network"
  docker network rm observability >/dev/null 2>&1 || true
fi

if [[ "$stopped" -eq 0 ]]; then
  echo "down: no compose stacks present yet (nothing to stop)" >&2
fi

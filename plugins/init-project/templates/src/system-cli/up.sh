#!/usr/bin/env bash
# Description: Bring up the service stack (postgres, keycloak, observability) via docker compose.
#
# Brings up each compose-managed service component. Every component owns its own
# compose file under src/<component>/docker-compose.yml: the postgres database, the
# keycloak identity provider, and the observability stack (otel-collector +
# prometheus + grafana). Run `system.sh build-config` first so the generated .env
# files exist.
#
# The three observability components are separate compose projects that resolve one
# another by service name over a SHARED Docker network named `observability`. That
# user-defined network is created here (idempotently) before the stacks start, since
# their compose files declare it `external`.

set -euo pipefail

cli_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$cli_dir/../.." && pwd)
cd "$repo_root"

# Compose stacks brought up, in dependency order (datastore + identity first, then
# the telemetry pipeline collector -> prometheus -> grafana).
stacks=(
  "src/postgres/docker-compose.yml"
  "src/keycloak/docker-compose.yml"
  "src/otel-collector/docker-compose.yml"
  "src/prometheus/docker-compose.yml"
  "src/grafana/docker-compose.yml"
)

# The shared `observability` network must exist before the (external-network)
# observability stacks come up. Create it only when at least one of them is present,
# idempotently — `|| true` swallows the "already exists" case.
obs_present=0
for stack in "src/otel-collector/docker-compose.yml" "src/prometheus/docker-compose.yml" "src/grafana/docker-compose.yml"; do
  [[ -f "$stack" ]] && obs_present=1
done
if [[ "$obs_present" -eq 1 ]]; then
  echo "up: ensuring shared 'observability' network"
  docker network create observability >/dev/null 2>&1 || true
fi

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

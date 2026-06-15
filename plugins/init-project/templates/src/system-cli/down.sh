#!/usr/bin/env bash
# Description: Stop the service stack (observability, keycloak, postgres; opt-in local-llm) via docker compose.
#
# Tears down the compose-managed service components in reverse dependency order.
# Each component owns its own compose file under src/<component>/docker-compose.yml:
# the observability stack (grafana + prometheus + otel-collector), then keycloak,
# then postgres.
#
# After the observability stacks are down, the shared `observability` Docker network
# they joined is removed (best-effort — `docker network rm` fails harmlessly if the
# network is gone or still has endpoints).
#
# OPT-IN local LLM stack (etc/local-llm/): down is NOT profile-gated — it ALWAYS
# tears down the stack (under BOTH ai and ai-mock) when its compose file is present,
# so containers started under EITHER profile are removed. down starts nothing,
# succeeds with the generated litellm/config.yaml absent, and on a not-installed
# stack is a harmless no-op. It mirrors up's profile grammar (the args are accepted
# but ignored — down always tears down both) and rejects any OTHER arg (exit 64).

set -euo pipefail

cli_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$cli_dir/../.." && pwd)
cd "$repo_root"

# shellcheck source=src/system-cli/_local-llm.sh
source "$cli_dir/_local-llm.sh"

# Mirror up's profile grammar (only ai/ai-mock, repeatable, = / space forms; rejects
# any other arg with exit 64). down ignores WHICH profiles were named — it always
# tears down both — so duplicates or both-together are harmless no-ops here.
ll_parse_profiles down "$@"

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

# --- opt-in local-llm teardown (NOT profile-gated) ---------------------------------
# Tear down the stack under BOTH profiles so containers started under either are
# removed; COMPOSE_PROFILES is cleared so an ambient value can't change what is torn
# down. Export the model env (type-safe; tolerates absent/wrong-typed localLlm) so
# compose interpolation has values — but down needs NO generated config.yaml (the
# bind-mount with create_host_path:false is only consulted on up). The `[[ -f ]]`
# guard makes a not-installed stack a no-op.
if [[ -f "$LOCAL_LLM_COMPOSE" ]]; then
  ll_export_models
  echo "down: $LOCAL_LLM_COMPOSE (ai + ai-mock)"
  # COMPOSE_PROFILES= clears the ambient var for THIS command only (intentional space;
  # not an assignment typo).
  # shellcheck disable=SC1007
  COMPOSE_PROFILES= docker compose -f "$LOCAL_LLM_COMPOSE" --profile ai --profile ai-mock down
  stopped=$((stopped + 1))
fi

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

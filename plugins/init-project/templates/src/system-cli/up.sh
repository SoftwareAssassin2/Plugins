#!/usr/bin/env bash
# Description: Bring up the service stack (postgres, keycloak, observability; opt-in local-llm) via docker compose.
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
#
# OPT-IN local LLM stack (etc/local-llm/, LiteLLM + Ollama): activated ONLY by an
# explicit `--profile ai` (real inference) or `--profile ai-mock` (deterministic
# mock); the default `up` (no --profile) starts NONE of it. Selecting BOTH at once
# is rejected (both LiteLLM instances bind :4000). See _local-llm.sh.

set -euo pipefail

cli_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$cli_dir/../.." && pwd)
cd "$repo_root"

# shellcheck source=src/system-cli/_local-llm.sh
source "$cli_dir/_local-llm.sh"

# --- parse the opt-in local-llm profile grammar (only ai/ai-mock; default none) ----
ll_parse_profiles up "$@"

# `up` rejects selecting BOTH ai and ai-mock — both LiteLLM instances publish :4000,
# so the second container would fail to bind (port conflict). Usage error, exit 64.
have_ai=0 have_mock=0
for p in ${LL_PROFILES[@]+"${LL_PROFILES[@]}"}; do
  [[ "$p" == "ai" ]] && have_ai=1
  [[ "$p" == "ai-mock" ]] && have_mock=1
done
if [[ "$have_ai" -eq 1 && "$have_mock" -eq 1 ]]; then
  ll_die "cannot select both 'ai' and 'ai-mock' on up — both LiteLLM instances bind :4000 (port conflict)"
fi

# --- local-llm ALL preflights run BEFORE any docker compose up ---------------------
# A failed `--profile ai` must NOT leave postgres/keycloak/observability partially
# started, so every local-llm check happens here, ahead of the core-stack loop.
if [[ ${#LL_PROFILES[@]} -gt 0 ]]; then
  # An explicit profile to a NOT-INSTALLED stack is a usage error (the stack was not
  # opted into at scaffold time). down is exempt; up is not.
  [[ -f "$LOCAL_LLM_COMPOSE" ]] \
    || ll_die "local LLM stack not installed ($LOCAL_LLM_COMPOSE absent) — re-scaffold with --local-llm"
  # Export the model env now (needed by both the ai preflight and the compose run).
  ll_export_models
  # `--profile ai` requires a present, non-stale generated config + a model; ai-mock
  # is static (no model, committed config.mock.yaml) so it skips the preflight.
  if [[ "$have_ai" -eq 1 ]]; then
    ll_preflight_ai
  fi
fi

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

# --- opt-in local-llm bring-up (preflighted above) ---------------------------------
# Pass ONLY the parsed --profile(s) through, with COMPOSE_PROFILES CLEARED so an
# ambient COMPOSE_PROFILES=ai can neither start the stack on a default up (we don't
# invoke the local compose at all then) nor merge `ai` into an `ai-mock` run. A
# compose / model-pull failure propagates as a non-zero exit (set -e; R13).
if [[ ${#LL_PROFILES[@]} -gt 0 ]]; then
  profile_args=()
  for p in "${LL_PROFILES[@]}"; do profile_args+=(--profile "$p"); done
  echo "up: $LOCAL_LLM_COMPOSE (${LL_PROFILES[*]})"
  # COMPOSE_PROFILES= clears the ambient var for THIS command only (intentional space;
  # not an assignment typo).
  # shellcheck disable=SC1007
  COMPOSE_PROFILES= docker compose -f "$LOCAL_LLM_COMPOSE" "${profile_args[@]}" up -d
  started=$((started + 1))
fi

if [[ "$started" -eq 0 ]]; then
  echo "up: no compose stacks present yet (nothing to start)" >&2
fi

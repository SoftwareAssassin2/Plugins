#!/usr/bin/env bash
# Description: Distribute config.json into per-component .env files, SPA public config, and the Keycloak realm import.
#
# `build-config` is the config-distribution step of the 12-factor flow (see
# docs/config-management.md). It reads a SINGLE source config file (default
# ./config.json) and writes the downstream artifacts:
#   - src/<component>/.env            per-component env files
#   - src/DataAccess/.env             MIGRATOR_CONNECTION_STRING (EF design-time)
#   - src/Api/.env                    API_CONNECTION_STRING + keycloak/Api values
#   - src/<SPA>/public/config.json    non-secret public runtime config
#   - src/keycloak/import/<realm>-realm.json  generated realm import (from template)
#
# Usage:
#   build-config [--config <path>]
#
# The --config form is the DEPLOY HANDOFF: CI renders config.deploy.json's
# {{VAR-NAME}} placeholders to a concrete file, then runs `build-config --config
# <rendered>`. The raw config.deploy.json template (with {{VAR-NAME}} literals) is
# NEVER fed here — only a concrete, rendered config.
#
# Validation (a violation exits 64 with a descriptive stderr line):
#   - every schema-declared URL-safe secret    ^[A-Za-z0-9_-]+$
#   - host fields                              ^[A-Za-z0-9.-]+$
#   - container_host fields                    ^[a-zA-Z0-9][a-zA-Z0-9_.-]+$
#   - realm / *_client_id                      ^[A-Za-z0-9._-]+$
#   - public_url / realm_url                   ^https?://[^[:space:]]+$
#   - every *port field                        integer 1..65535
# External service credentials (services{}) are OPAQUE and exempt from validation.
# Postgres role names (owner/migrator/api) and the db name (platform) are FIXED
# scaffold constants — not in config.json, never validated/injected.

set -euo pipefail

# --- fixed scaffold constants (see docs/config-management.md §3) -------------
readonly DB_NAME="platform"
readonly ROLE_MIGRATOR="migrator"
readonly ROLE_API="api"
readonly ABSENT_SENTINEL="__BUILD_CONFIG_ABSENT__"

die() { echo "ERROR: $*" >&2; exit "${2:-64}"; }
usage() { echo "usage: build-config [--config <path>]" >&2; exit 64; }

# Validators. Each takes (value, human-label) and dies 64 on a violation.
v_urlsafe()   { [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]               || die "$2 not URL-safe (^[A-Za-z0-9_-]+): '$1'"; }
v_host()      { [[ "$1" =~ ^[A-Za-z0-9.-]+$ ]]               || die "$2 invalid host (^[A-Za-z0-9.-]+): '$1'"; }
v_container() { [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]+$ ]]   || die "$2 invalid container name: '$1'"; }
v_clientid()  { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]              || die "$2 invalid (^[A-Za-z0-9._-]+): '$1'"; }
v_url()       { [[ "$1" =~ ^https?://[^[:space:]]+$ ]]       || die "$2 invalid URL (^https?://...): '$1'"; }
v_port()      { [[ "$1" =~ ^[0-9]+$ && "$1" -ge 1 && "$1" -le 65535 ]] || die "$2 invalid port (1..65535): '$1'"; }

# Read a jq path from the source config; dies if the result is null/absent. The
# absent-sentinel is passed via --arg (never inline-quoted in the filter) so the
# function carries no nested escaped quotes (bash 3.2 mis-parses those).
cfg() {
  local filter out
  filter="$1 // \$sentinel"
  out="$(jq -r "$filter" --arg sentinel "$ABSENT_SENTINEL" "$CONFIG")"
  [[ "$out" == "$ABSENT_SENTINEL" ]] && die "missing config field: $2"
  printf '%s' "$out"
}

# Locate the named system entry's object (by .name) and emit a jq filter prefix.
sys() { printf '(.systems[] | select(.name=="%s"))' "$1"; }

# Write a .env file from stdin (KEY=VALUE lines), creating its directory.
write_env() {
  local path="$1"; mkdir -p "$(dirname "$path")"
  cat > "$path"
  echo "  wrote $path"
}

main() {
  local config="config.json"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config) [[ $# -ge 2 ]] || usage; config="$2"; shift 2 ;;
      --config=*) config="${1#--config=}"; shift ;;
      -h|--help) usage ;;
      --*) die "unknown flag '$1'" ;;
      *) die "unexpected argument '$1'" ;;
    esac
  done

  CONFIG="$config"
  [[ -f "$CONFIG" ]] || die "config file not found: $CONFIG" 64
  jq -e . "$CONFIG" >/dev/null 2>&1 || die "config is not valid JSON: $CONFIG" 64

  # A raw deploy template (unrendered {{VAR-NAME}} placeholders) must never be
  # validated/distributed — fail fast with a clear message.
  if grep -qE '\{\{[A-Za-z0-9_-]+\}\}' "$CONFIG"; then
    die "config contains unrendered {{VAR-NAME}} deploy placeholders; render config.deploy.json to a concrete file first" 64
  fi

  local pg kc api ms wa
  pg="$(sys postgres)"; kc="$(sys keycloak)"; api="$(sys Api)"
  ms="$(sys MarketingSite)"; wa="$(sys WebApp)"

  # --- postgres (structural + secrets) ---------------------------------------
  local pg_host pg_chost pg_cport pg_port pg_owner pg_mig pg_api
  pg_host="$(cfg "$pg.host" "postgres.host")"
  pg_chost="$(cfg "$pg.container_host" "postgres.container_host")"
  pg_cport="$(cfg "$pg.container_port" "postgres.container_port")"
  pg_port="$(cfg "$pg.port" "postgres.port")"
  pg_owner="$(cfg "$pg.owner_password" "postgres.owner_password")"
  pg_mig="$(cfg "$pg.migrator_password" "postgres.migrator_password")"
  pg_api="$(cfg "$pg.api_password" "postgres.api_password")"
  v_host "$pg_host" "postgres.host"
  v_container "$pg_chost" "postgres.container_host"
  v_port "$pg_cport" "postgres.container_port"
  v_port "$pg_port" "postgres.port"
  v_urlsafe "$pg_owner" "postgres.owner_password"
  v_urlsafe "$pg_mig" "postgres.migrator_password"
  v_urlsafe "$pg_api" "postgres.api_password"

  # --- keycloak (structural + secrets) ---------------------------------------
  local kc_host kc_chost kc_cport kc_port kc_realm kc_url kc_admin kc_adminpw
  local kc_webcid kc_mscid kc_apicid kc_apisecret
  kc_host="$(cfg "$kc.host" "keycloak.host")"
  kc_chost="$(cfg "$kc.container_host" "keycloak.container_host")"
  kc_cport="$(cfg "$kc.container_port" "keycloak.container_port")"
  kc_port="$(cfg "$kc.port" "keycloak.port")"
  kc_realm="$(cfg "$kc.realm" "keycloak.realm")"
  kc_url="$(cfg "$kc.public_url" "keycloak.public_url")"
  kc_admin="$(cfg "$kc.admin_user" "keycloak.admin_user")"
  kc_adminpw="$(cfg "$kc.admin_password" "keycloak.admin_password")"
  kc_webcid="$(cfg "$kc.webapp_client_id" "keycloak.webapp_client_id")"
  kc_mscid="$(cfg "$kc.marketingsite_client_id" "keycloak.marketingsite_client_id")"
  kc_apicid="$(cfg "$kc.api_client_id" "keycloak.api_client_id")"
  kc_apisecret="$(cfg "$kc.api_client_secret" "keycloak.api_client_secret")"
  v_host "$kc_host" "keycloak.host"
  v_container "$kc_chost" "keycloak.container_host"
  v_port "$kc_cport" "keycloak.container_port"
  v_port "$kc_port" "keycloak.port"
  v_clientid "$kc_realm" "keycloak.realm"
  v_url "$kc_url" "keycloak.public_url"
  v_urlsafe "$kc_adminpw" "keycloak.admin_password"
  v_clientid "$kc_webcid" "keycloak.webapp_client_id"
  v_clientid "$kc_mscid" "keycloak.marketingsite_client_id"
  v_clientid "$kc_apicid" "keycloak.api_client_id"
  v_urlsafe "$kc_apisecret" "keycloak.api_client_secret"

  # --- Api (structural) ------------------------------------------------------
  local api_host api_port
  api_host="$(cfg "$api.host" "Api.host")"
  api_port="$(cfg "$api.port" "Api.port")"
  v_host "$api_host" "Api.host"
  v_port "$api_port" "Api.port"

  # --- SPA public config (non-secret, structural) ----------------------------
  local ms_realm ms_cid wa_realm wa_cid
  ms_realm="$(cfg "$ms.realm_url" "MarketingSite.realm_url")"
  ms_cid="$(cfg "$ms.public_client_id" "MarketingSite.public_client_id")"
  wa_realm="$(cfg "$wa.realm_url" "WebApp.realm_url")"
  wa_cid="$(cfg "$wa.public_client_id" "WebApp.public_client_id")"
  v_url "$ms_realm" "MarketingSite.realm_url"
  v_clientid "$ms_cid" "MarketingSite.public_client_id"
  v_url "$wa_realm" "WebApp.realm_url"
  v_clientid "$wa_cid" "WebApp.public_client_id"

  # =========================================================================
  # All validation passed — now WRITE downstream artifacts.
  # =========================================================================
  echo "build-config: distributing $CONFIG"

  write_env "src/postgres/.env" <<EOF
POSTGRES_HOST=$pg_chost
POSTGRES_PORT=$pg_cport
POSTGRES_OWNER_PASSWORD=$pg_owner
POSTGRES_MIGRATOR_PASSWORD=$pg_mig
POSTGRES_API_PASSWORD=$pg_api
EOF

  # DataAccess .env — migrator design-time connection string (.NET reads env, not .env)
  write_env "src/DataAccess/.env" <<EOF
MIGRATOR_CONNECTION_STRING=Host=$pg_chost;Port=$pg_cport;Database=$DB_NAME;Username=$ROLE_MIGRATOR;Password=$pg_mig
EOF

  # Api .env — runtime api-role connection + keycloak issuer/client values
  write_env "src/Api/.env" <<EOF
API_HOST=$api_host
API_PORT=$api_port
API_CONNECTION_STRING=Host=$pg_chost;Port=$pg_cport;Database=$DB_NAME;Username=$ROLE_API;Password=$pg_api
KEYCLOAK_REALM=$kc_realm
KEYCLOAK_PUBLIC_URL=$kc_url
KEYCLOAK_API_CLIENT_ID=$kc_apicid
KEYCLOAK_API_CLIENT_SECRET=$kc_apisecret
EOF

  # keycloak .env — container bootstrap admin + host/port references
  write_env "src/keycloak/.env" <<EOF
KEYCLOAK_HOST=$kc_chost
KEYCLOAK_PORT=$kc_cport
KEYCLOAK_ADMIN=$kc_admin
KEYCLOAK_ADMIN_PASSWORD=$kc_adminpw
KEYCLOAK_REALM=$kc_realm
KEYCLOAK_PUBLIC_URL=$kc_url
EOF

  # SPA public config (non-secret) — jq structured edit, never string replacement.
  stamp_spa_config "src/MarketingSite/public/config.json" "$ms_realm" "$ms_cid"
  stamp_spa_config "src/WebApp/public/config.json" "$wa_realm" "$wa_cid"

  # Keycloak realm import — stamp from the committed template, if present.
  stamp_realm_import "$kc_realm" "$kc_webcid" "$kc_mscid" "$kc_apicid" "$kc_apisecret"

  echo "build-config: done"
}

# Stamp a SPA's gitignored public config.json (non-secret realmUrl + clientId) via
# a structured jq --arg edit on the existing committed sample (or a fresh object).
stamp_spa_config() {
  local path="$1" realm_url="$2" client_id="$3" base tmp
  mkdir -p "$(dirname "$path")"
  base="{}"
  if [[ -f "$path" ]] && jq -e . "$path" >/dev/null 2>&1; then base="$(cat "$path")"; fi
  tmp="$(mktemp)"
  if ! printf '%s' "$base" | jq --arg r "$realm_url" --arg c "$client_id" \
       '.realmUrl=$r | .clientId=$c' > "$tmp"; then
    rm -f "$tmp"; die "failed to stamp SPA config $path" 65
  fi
  mv "$tmp" "$path"
  echo "  stamped $path"
}

# Stamp the gitignored Keycloak realm import from the committed template via
# deterministic jq --arg field replacement. Removes any prior generated
# *-realm.json first so a realm rename never leaves a stale import behind.
# The committed template is owned by the keycloak task; if it is not present yet,
# skip (this task ships the stamping MECHANISM; the keycloak task wires it).
stamp_realm_import() {
  local realm="$1" web_cid="$2" ms_cid="$3" api_cid="$4" api_secret="$5"
  local template="src/keycloak/realm.template.json"
  local import_dir="src/keycloak/import"

  if [[ ! -f "$template" ]]; then
    echo "  (no $template yet — skipping realm stamp)"
    return 0
  fi
  jq -e . "$template" >/dev/null 2>&1 || die "realm template is not valid JSON: $template" 65

  mkdir -p "$import_dir"
  # Clean prior generated realm imports (no stale-on-rename).
  local old
  for old in "$import_dir"/*-realm.json; do
    [[ -e "$old" ]] && rm -f "$old"
  done

  local out="$import_dir/$realm-realm.json" tmp
  tmp="$(mktemp)"
  # Deterministic field replacement: realm name/id, the two public SPA client ids
  # (matched by template clientId == "webapp"/"marketingsite"), the Api client id,
  # and the Api confidential client secret (matched by clientId == "api" or the
  # configured id). The committed template carries dummy secrets only.
  if ! jq \
        --arg realm "$realm" \
        --arg web "$web_cid" \
        --arg ms "$ms_cid" \
        --arg apicid "$api_cid" \
        --arg apisecret "$api_secret" \
        '.realm=$realm
         | .id=$realm
         | (.clients[]? | select(.clientId=="webapp"))       |= (.clientId=$web)
         | (.clients[]? | select(.clientId=="marketingsite")) |= (.clientId=$ms)
         | (.clients[]? | select(.clientId=="api" or .clientId==$apicid))
             |= (.clientId=$apicid | .secret=$apisecret)' \
        "$template" > "$tmp"; then
    rm -f "$tmp"; die "failed to stamp realm import from $template" 65
  fi
  mv "$tmp" "$out"
  echo "  stamped $out (cleaned prior *-realm.json)"
}

# Source-guard so tests can source this file and exercise validators/helpers
# without running main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

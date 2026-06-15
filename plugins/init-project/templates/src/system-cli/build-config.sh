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
#   - src/Api/.env                    ALSO carries the LLM endpoint vars
#                                     (ANTHROPIC_BASE_URL/API_KEY, OPENAI_BASE_URL/API_KEY,
#                                     and OPENAI_EMBEDDING_MODEL when embeddings opted in)
#   - etc/local-llm/litellm/config.yaml  generated LiteLLM config (opt-in: localLlm.model)
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
#   - services{}.*.base_url                    ^https?://[host][:port][/path]$ + port 1..65535
#   - localLlm.model / .embeddingModel         ^[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?$
#   - all four emitted LLM .env values         transport-safe (reject CR/LF/control/$)
# External service credentials (services{}.*.api_key) are OPAQUE and exempt from
# grammar validation (only transport-safety checked, not the URL-safe alphabet).
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

# Ollama model-name grammar (R6/R12). Rejects whitespace, shell metacharacters, and
# YAML-sensitive characters so a hostile localLlm.model/embeddingModel cannot corrupt
# the stamped litellm/config.yaml. Accepts the legitimate `/` (namespaced repo) and a
# single `:tag` suffix.
v_modelname() { [[ "$1" =~ ^[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?$ ]] || die "$2 invalid model name (^[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?): '$1'"; }

# Service base-URL grammar (R6). An INJECTION-RESISTANT host char-whitelist + a
# SEPARATE port range-check — NOT full RFC-1123 hostname validation. Odd-but-harmless
# hosts (`.example.com`, `-bad`) are accepted (they'd simply fail to resolve); the goal
# is preventing .env injection, not URL correctness. The host class `[A-Za-z0-9.-]+`
# rejects `?#@[]:` etc. in the host portion; an optional path may follow. The
# `[0-9]{1,5}` class alone would accept `99999`, so the captured port is range-checked
# 1..65535 separately. This is STRICTER than the permissive v_url.
v_base_url() {
  local url="$1" label="$2" port
  [[ "$url" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[^[:space:]]*)?$ ]] \
    || die "$label invalid base URL (^https?://<host>[:<port>][/<path>]): '$url'"
  # Range-check the port if one was captured ("${BASH_REMATCH[1]}" is ":<digits>").
  if [[ -n "${BASH_REMATCH[1]}" ]]; then
    port="${BASH_REMATCH[1]#:}"
    [[ "$port" -ge 1 && "$port" -le 65535 ]] || die "$label base URL port out of range (1..65535): '$url'"
  fi
}

# Transport-safe check for a value emitted into a .env line consumed by docker
# compose's `env_file:` parser (the confirmed consumer of src/Api/.env — see
# docs/config-management.md §4/§7 + src/Api/Program.cs). That parser takes the value
# RAW (no shell close-reopen quoting; surrounding quotes are STRIPPED, so KEY='value'
# would lose the quotes) and performs `$`/`${VAR}` interpolation, and it cannot
# represent embedded newlines. We therefore emit values verbatim and REJECT any char
# that cannot round-trip across the consumer set:
#   - CR / LF / other control chars (break line parsing / multi-line not supported)
#   - `$` (compose variable interpolation; cannot round-trip raw, and the `$$` escape
#     is compose-only and would corrupt a plain shell `source` consumer)
# Empirically grounded against `docker compose config` (v2). space/#/"/' round-trip raw.
v_env_value() {
  local value="$1" label="$2"
  [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]] && die "$label contains a newline/CR (cannot be encoded in a .env value)"
  [[ "$value" =~ [[:cntrl:]] ]] && die "$label contains a control character (cannot be encoded in a .env value)"
  [[ "$value" == *'$'* ]] && die "$label contains '\$' (docker compose env_file interpolates it; cannot round-trip): '$value'"
  return 0
}

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

  # --- services{} LLM endpoints (always present — no opt-in branch, R6) -------
  # base_url is grammar-validated (injection-resistant); api_key stays OPAQUE
  # (unvalidated — provider keys may be any chars) but is transport-safe-checked.
  # ALL four emitted values pass v_env_value (a validated base_url PATH may still
  # carry punctuation), encoded for the docker-compose env_file consumer of Api/.env.
  local claude_base claude_key openai_base openai_key
  claude_base="$(cfg '.services."claude-api".base_url' 'services.claude-api.base_url')"
  claude_key="$(cfg '.services."claude-api".api_key' 'services.claude-api.api_key')"
  openai_base="$(cfg '.services."openai-api".base_url' 'services.openai-api.base_url')"
  openai_key="$(cfg '.services."openai-api".api_key' 'services.openai-api.api_key')"
  v_base_url "$claude_base" "services.claude-api.base_url"
  v_base_url "$openai_base" "services.openai-api.base_url"
  v_env_value "$claude_base" "services.claude-api.base_url"
  v_env_value "$claude_key" "services.claude-api.api_key"
  v_env_value "$openai_base" "services.openai-api.base_url"
  v_env_value "$openai_key" "services.openai-api.api_key"

  # --- localLlm (opt-in only) — validate type + model-name grammar (R6/R12) ---
  # build-config FAILS clearly on a malformed `.localLlm` (present but not an object):
  # a hand-edit must not silently skip stamping while the project points at the local
  # gateway. Genuinely-absent localLlm is a no-op (empty model/embed below).
  local ll_kind ll_model ll_embed
  ll_kind="$(jq -r 'if has("localLlm") then (.localLlm|type) else "absent" end' "$CONFIG")"
  if [[ "$ll_kind" != "absent" && "$ll_kind" != "object" ]]; then
    die "config.localLlm must be an object (got $ll_kind)"
  fi
  ll_model="$(jq -r '.localLlm.model // ""' "$CONFIG")"
  ll_embed="$(jq -r '.localLlm.embeddingModel // ""' "$CONFIG")"
  # Embeddings require a chat opt-in (R12): embeddingModel without model is invalid.
  if [[ -n "$ll_embed" && -z "$ll_model" ]]; then
    die "config.localLlm.embeddingModel set without localLlm.model (embeddings require a chat model)"
  fi
  [[ -n "$ll_model" ]] && v_modelname "$ll_model" "localLlm.model"
  [[ -n "$ll_embed" ]] && v_modelname "$ll_embed" "localLlm.embeddingModel"

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

  # Api .env — runtime api-role connection + keycloak issuer/client values + the
  # LLM endpoint vars (SDK-standard names). Values are emitted RAW (no shell quoting):
  # the consumer is docker compose's env_file parser, which takes values verbatim and
  # strips wrapping quotes — every value already passed v_env_value above. When
  # embeddings are opted in, ALSO emit OPENAI_EMBEDDING_MODEL=local-embed (the explicit
  # embeddings alias, R2/R12); chat callers need no model var (the wildcard route
  # serves any name).
  {
    cat <<EOF
API_HOST=$api_host
API_PORT=$api_port
API_CONNECTION_STRING=Host=$pg_chost;Port=$pg_cport;Database=$DB_NAME;Username=$ROLE_API;Password=$pg_api
KEYCLOAK_REALM=$kc_realm
KEYCLOAK_PUBLIC_URL=$kc_url
KEYCLOAK_API_CLIENT_ID=$kc_apicid
KEYCLOAK_API_CLIENT_SECRET=$kc_apisecret
ANTHROPIC_BASE_URL=$claude_base
ANTHROPIC_API_KEY=$claude_key
OPENAI_BASE_URL=$openai_base
OPENAI_API_KEY=$openai_key
EOF
    if [[ -n "$ll_embed" ]]; then echo "OPENAI_EMBEDDING_MODEL=local-embed"; fi
  } | write_env "src/Api/.env"

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

  # LiteLLM runtime config — stamp the gitignored litellm/config.yaml from its
  # committed template when the local LLM stack is opted in (localLlm.model present).
  stamp_litellm_config "$ll_model" "$ll_embed"

  echo "build-config: done"
}

# Stamp the gitignored LiteLLM runtime config (etc/local-llm/litellm/config.yaml) from
# the committed config.yaml.template when localLlm.model is present (opt-in). NO .env
# is written here — system.sh up/down export LLM_MODEL/LLM_EMBED_MODEL from config.json
# (owned by .3). Genuinely-absent localLlm (empty model) is a no-op. Mirrors the
# realm-import stamp responsibility.
#
#   - @@LLM_MODEL@@        replaced (ALL occurrences — wildcard "*" route AND the
#                          explicit `local` alias) with the RAW validated model name
#                          (the template line already carries `ollama_chat/`, so this
#                          does NOT re-prefix it).
#   - the embeddings block between `# >>> embeddings` / `# <<< embeddings` sentinels is
#     a BLOCK operation, not a naive token replace: kept (markers stripped,
#     @@LLM_EMBED_MODEL@@ substituted) when embeddingModel is present; otherwise the
#     ENTIRE marked block is deleted (no orphan entry, no leftover token, valid YAML
#     either way).
#
# Template structural validation (fail clearly, never emit broken YAML): @@LLM_MODEL@@
# present at least once; embeddings markers present, balanced, non-duplicated;
# @@LLM_EMBED_MODEL@@ present within the block when kept; and a post-stamp scan that NO
# @@…@@ token remains in the generated config.yaml (the definitive check).
stamp_litellm_config() {
  local model="$1" embed="$2"
  local template="etc/local-llm/litellm/config.yaml.template"
  local out="etc/local-llm/litellm/config.yaml"

  # Genuinely-absent localLlm → no-op (no model, nothing to stamp).
  [[ -z "$model" ]] && return 0

  # Opt-in invariant: model present but template missing → fail clearly (R6).
  [[ -f "$template" ]] || die "localLlm.model is set but $template is missing (cannot stamp litellm config)" 65

  # --- template structural validation (pre-stamp) ---------------------------
  grep -q '@@LLM_MODEL@@' "$template" \
    || die "litellm template missing @@LLM_MODEL@@ token: $template" 65
  local open_cnt close_cnt
  open_cnt="$(grep -c '^[[:space:]]*# >>> embeddings[[:space:]]*$' "$template")"
  close_cnt="$(grep -c '^[[:space:]]*# <<< embeddings[[:space:]]*$' "$template")"
  [[ "$open_cnt" -eq 1 && "$close_cnt" -eq 1 ]] \
    || die "litellm template embeddings markers must appear exactly once each (open=$open_cnt close=$close_cnt): $template" 65

  local tmp; tmp="$(mktemp)"

  if [[ -n "$embed" ]]; then
    # Embeddings KEPT: the block must carry the @@LLM_EMBED_MODEL@@ token.
    grep -q '@@LLM_EMBED_MODEL@@' "$template" \
      || { rm -f "$tmp"; die "litellm template missing @@LLM_EMBED_MODEL@@ within the embeddings block: $template" 65; }
    # Strip ONLY the two marker comment lines; keep the block body.
    if ! grep -vE '^[[:space:]]*# (>>>|<<<) embeddings[[:space:]]*$' "$template" \
         | LLM_MODEL="$model" LLM_EMBED_MODEL="$embed" awk '
             { gsub(/@@LLM_MODEL@@/, ENVIRON["LLM_MODEL"]);
               gsub(/@@LLM_EMBED_MODEL@@/, ENVIRON["LLM_EMBED_MODEL"]); print }' > "$tmp"; then
      rm -f "$tmp"; die "failed to stamp litellm config from $template" 65
    fi
  else
    # Embeddings ABSENT: delete the ENTIRE marked block (markers inclusive).
    if ! awk '
           /^[[:space:]]*# >>> embeddings[[:space:]]*$/ { skip=1; next }
           /^[[:space:]]*# <<< embeddings[[:space:]]*$/ { skip=0; next }
           skip { next }
           { print }' "$template" \
         | LLM_MODEL="$model" awk '{ gsub(/@@LLM_MODEL@@/, ENVIRON["LLM_MODEL"]); print }' > "$tmp"; then
      rm -f "$tmp"; die "failed to stamp litellm config from $template" 65
    fi
  fi

  # --- post-stamp scan (definitive): no replacement token may remain ---------
  if grep -q '@@[A-Za-z_]*@@' "$tmp"; then
    rm -f "$tmp"; die "generated litellm config still contains an unreplaced @@...@@ token (template malformed): $template" 65
  fi

  mkdir -p "$(dirname "$out")"
  mv "$tmp" "$out"
  echo "  stamped $out"
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

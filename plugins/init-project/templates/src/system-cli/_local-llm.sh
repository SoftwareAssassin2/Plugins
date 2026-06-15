#!/usr/bin/env bash
# Description: Private helper — local-llm (LiteLLM + Ollama) profile orchestration for up/down.
#
# SOURCED (never dispatched — the leading `_` makes it a private helper the
# dispatcher refuses and `help` hides). up.sh / down.sh source this for the shared
# `ai`/`ai-mock` compose-profile machinery so the two scripts stay in lock-step on
# the grammar, the COMPOSE_PROFILES sanitization, and the LLM_MODEL/LLM_EMBED_MODEL
# export — without duplicating it.
#
# The opt-in stack lives at etc/local-llm/docker-compose.yml (copied from the
# plugin's _optional/local-llm/ ONLY on --local-llm). When that file is ABSENT the
# stack is not installed: default up/down silently skip it; an explicit `up
# --profile ...` is a usage error (exit 64); an explicit `down --profile ...` is a
# harmless no-op (teardown can never leave anything running).
#
# Model selection flows from config.json -> localLlm.model (single source of truth);
# the compose file interpolates ${LLM_MODEL:-} / ${LLM_EMBED_MODEL:-} from the
# exported environment (NO env_file / generated .env — portable across compose
# versions, and keeps `down` working with no generated artifacts).

# Paths (relative to repo_root, which the caller has cd'd into). These are read by
# the sourcing scripts (up.sh/down.sh), so shellcheck's per-file unused check is moot.
# shellcheck disable=SC2034
LOCAL_LLM_COMPOSE="etc/local-llm/docker-compose.yml"
LOCAL_LLM_CONFIG_YAML="etc/local-llm/litellm/config.yaml"
LOCAL_LLM_CONFIG_JSON="config.json"

# ll_die <message> [exit-code] — usage errors default to 64 (EX_USAGE).
ll_die() {
  echo "ERROR: $1" >&2
  exit "${2:-64}"
}

# ll_usage <command> — pinned usage line for a profile-grammar violation, exit 64.
ll_usage() {
  echo "usage: ./system.sh $1 [--profile ai|ai-mock] ..." >&2
  exit 64
}

# ll_parse_profiles <command> "$@" — parse the profile grammar shared by up/down.
#
# Accepts ONLY `ai` and `ai-mock`, via repeatable `--profile <name>` AND
# `--profile=<name>` forms. ANY other arg/flag (or an unknown profile name) is a
# usage error (exit 64). Sets the global array LL_PROFILES (deduplicated, in first-
# seen order). Default (no --profile) leaves LL_PROFILES empty.
#
# Caller-specific policy (e.g. up rejecting BOTH ai+ai-mock; down allowing both as
# no-ops) is enforced by the caller AFTER this returns.
ll_parse_profiles() {
  local cmd="$1"; shift
  LL_PROFILES=()
  local p
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile)
        [[ $# -ge 2 ]] || ll_usage "$cmd"
        p="$2"; shift 2 ;;
      --profile=*)
        p="${1#--profile=}"; shift ;;
      *)
        ll_usage "$cmd" ;;
    esac
    case "$p" in
      ai|ai-mock) ;;
      *) ll_usage "$cmd" ;;
    esac
    # Dedup: only append a profile we have not already recorded.
    local seen=0 existing
    for existing in ${LL_PROFILES[@]+"${LL_PROFILES[@]}"}; do
      [[ "$existing" == "$p" ]] && seen=1 && break
    done
    [[ "$seen" -eq 0 ]] && LL_PROFILES+=("$p")
  done
}

# ll_export_models — export LLM_MODEL / LLM_EMBED_MODEL from config.json via a
# TYPE-SAFE jq so the compose ${LLM_MODEL:-} / ${LLM_EMBED_MODEL:-} interpolation
# reaches the model-pull container. The `if (.localLlm|type)=="object"` guard means
# an ABSENT or WRONG-TYPED localLlm (a hand-edited string/array) yields empty rather
# than a jq error — harmless for `down` and `--profile ai-mock` (which need no
# model). Only the `--profile ai` preflight requires a non-empty model.
#
# Missing config.json -> both empty (a non-build-config'd checkout; the ai preflight
# catches the real problem). jq is a devcontainer prerequisite (fn-2 R4); behavior
# on missing jq / invalid JSON follows the dispatcher convention (jq errors surface).
ll_export_models() {
  LLM_MODEL=""
  LLM_EMBED_MODEL=""
  if [[ -f "$LOCAL_LLM_CONFIG_JSON" ]]; then
    LLM_MODEL="$(jq -r 'if (.localLlm | type) == "object" then (.localLlm.model // "") else "" end' "$LOCAL_LLM_CONFIG_JSON")"
    LLM_EMBED_MODEL="$(jq -r 'if (.localLlm | type) == "object" then (.localLlm.embeddingModel // "") else "" end' "$LOCAL_LLM_CONFIG_JSON")"
  fi
  export LLM_MODEL LLM_EMBED_MODEL
}

# ll_stamped_chat_models — print every chat model stamped into the generated
# config.yaml, one per line, with the known `ollama_chat/` prefix stripped. ANCHORED,
# FIXED-STRING parse of the deterministic generated YAML: read each
# `model: ollama_chat/<x>` line (the wildcard "*" route AND the explicit `local`
# alias — TWO routes) and strip the literal prefix. Compared as literal strings by
# the caller (model names carry ./:/ — a loose regex would mis-match).
ll_stamped_chat_models() {
  # Match lines of the form `<ws>model: ollama_chat/<value>`; emit just <value>.
  sed -n 's/^[[:space:]]*model:[[:space:]]*ollama_chat\///p' "$LOCAL_LLM_CONFIG_YAML"
}

# ll_stamped_embed_model — print the embed model stamped into config.yaml (the
# `model: ollama/<x>` line of the local-embed entry) with the `ollama/` prefix
# stripped, or nothing when there is no embed route. Same anchored fixed-string
# parse. NOTE: the chat routes use `ollama_chat/` (a different prefix), so this
# `ollama/`-only match never picks up a chat line.
ll_stamped_embed_model() {
  sed -n 's/^[[:space:]]*model:[[:space:]]*ollama\/\(.*\)$/\1/p' "$LOCAL_LLM_CONFIG_YAML"
}

# ll_preflight_ai — the `--profile ai` preflight (stack installed). Run BEFORE any
# `docker compose up` so a failure NEVER leaves postgres/keycloak/observability
# partially started. `--profile ai-mock` is EXEMPT (static config, no model).
#
# Requires: generated config.yaml present; localLlm.model non-empty; and the stamped
# config matches config.json in BOTH directions, chat AND embeddings (R12 stale-config
# guard) — else `up --profile ai` would pull one model while LiteLLM serves another.
# Assumes ll_export_models already populated LLM_MODEL / LLM_EMBED_MODEL.
ll_preflight_ai() {
  [[ -n "$LLM_MODEL" ]] \
    || ll_die "local LLM chat model not configured — set config.json localLlm.model and run './system.sh build-config' first" 65
  [[ -f "$LOCAL_LLM_CONFIG_YAML" ]] \
    || ll_die "generated $LOCAL_LLM_CONFIG_YAML is missing — run './system.sh build-config' first" 65

  # (a) EVERY stamped chat-route model must equal localLlm.model. The real template
  # has TWO chat routes (wildcard "*" + explicit `local`), so check ALL of them.
  local found_chat=0 m
  while IFS= read -r m; do
    found_chat=1
    [[ "$m" == "$LLM_MODEL" ]] \
      || ll_die "generated $LOCAL_LLM_CONFIG_YAML is stale — chat model '$m' != config.json localLlm.model '$LLM_MODEL'; rerun './system.sh build-config'" 65
  done < <(ll_stamped_chat_models)
  [[ "$found_chat" -eq 1 ]] \
    || ll_die "generated $LOCAL_LLM_CONFIG_YAML has no ollama_chat route — rerun './system.sh build-config'" 65

  # (b/c/d) Embeddings consistency in BOTH directions + stale VALUE.
  local stamped_embed
  stamped_embed="$(ll_stamped_embed_model)"
  if [[ -n "$LLM_EMBED_MODEL" ]]; then
    # (c) config has an embed model but the YAML has no local-embed route.
    [[ -n "$stamped_embed" ]] \
      || ll_die "generated $LOCAL_LLM_CONFIG_YAML is stale — config.json localLlm.embeddingModel is set but the YAML has no local-embed route; rerun './system.sh build-config'" 65
    # (d) stamped embed VALUE differs from config.
    [[ "$stamped_embed" == "$LLM_EMBED_MODEL" ]] \
      || ll_die "generated $LOCAL_LLM_CONFIG_YAML is stale — embed model '$stamped_embed' != config.json localLlm.embeddingModel '$LLM_EMBED_MODEL'; rerun './system.sh build-config'" 65
  else
    # (b) config has no embed model but the YAML still carries a local-embed route.
    [[ -z "$stamped_embed" ]] \
      || ll_die "generated $LOCAL_LLM_CONFIG_YAML is stale — config.json has no localLlm.embeddingModel but the YAML has a local-embed route; rerun './system.sh build-config'" 65
  fi
}

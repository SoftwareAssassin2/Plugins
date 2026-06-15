#!/usr/bin/env bash
# Description: Docker-gated integration proof for the local LLM mock stack (--profile ai-mock).
#
# This is NOT the unit gate (that is tests/system-cli/local_llm_test.sh — no daemon).
# It brings up the MOCK LiteLLM (no Ollama, no model) and asserts canned responses on
# BOTH chat surfaces, plus that a tools-bearing request is TOLERATED (no 5xx,
# well-formed) — a request-parsing/endpoint regression signal, NOT a structured
# tool-use round-trip (a canned mock_response cannot emit tool_calls/tool_use; that
# fidelity is a MANUAL --profile ai check).
#
# SELF-SKIPS (exit 0, clear notice) when:
#   - Docker is unavailable (no daemon) — so a runner without Docker stays green.
#   - the stack is not installed (generated-project path, R5): no etc/local-llm/
#     docker-compose.yml AND no plugin _optional source.
#
# Stack resolution mirrors the unit suite: LOCAL_LLM_SRC override wins (the plugin
# proof harness passes it), else a generated project's etc/local-llm/, else the
# plugin source _optional/local-llm/. At PLUGIN level we TEMP-INSTALL the source
# subtree into a temp etc/local-llm/ fixture and bring THAT up, so the proof is never
# vacuous. We invoke `docker compose` DIRECTLY (NOT ./system.sh — that path + its
# preflights are fn-3….3's scope) with COMPOSE_PROFILES= cleared so an ambient
# profile can't leak in.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"       # repo root (tests/integration/ -> repo)

# --- Docker gate -----------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "NOTICE: Docker unavailable — skipping local-llm-mock integration proof (exit 0)."
  exit 0
fi

# --- Resolve the stack source ----------------------------------------------------
if [[ -n "${LOCAL_LLM_SRC:-}" ]]; then
  SRC="$LOCAL_LLM_SRC"
elif [[ -f "$ROOT/etc/local-llm/docker-compose.yml" ]]; then
  SRC="$ROOT/etc/local-llm"
elif [[ -f "$ROOT/_optional/local-llm/docker-compose.yml" ]]; then
  SRC="$ROOT/_optional/local-llm"
else
  echo "NOTICE: local LLM stack not installed (no etc/local-llm/) — skipping (exit 0)."
  exit 0
fi

# --- Temp-install the stack into a fixture etc/local-llm/ -------------------------
# Bringing up the mock from a COPY proves the committed config.mock.yaml works from a
# clean clone (no build-config, no generated config.yaml needed for ai-mock).
FIX="$(mktemp -d)"; PROJECT="local-llm-mock-itest-$$"
cleanup() {
  COMPOSE_PROFILES= docker compose -p "$PROJECT" -f "$FIX/docker-compose.yml" \
    --profile ai-mock down -v >/dev/null 2>&1 || true
  rm -rf "$FIX"
}
trap cleanup EXIT
cp -R "$SRC/." "$FIX/"
COMPOSE="$FIX/docker-compose.yml"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }

echo "== bringing up --profile ai-mock (LiteLLM only, no Ollama, no model) =="
if ! COMPOSE_PROFILES= docker compose -p "$PROJECT" -f "$COMPOSE" --profile ai-mock up -d; then
  echo "ERROR: docker compose up --profile ai-mock failed" >&2
  exit 1
fi

# Wait for LiteLLM to answer on the loopback port (model-list is cheap + auth-free).
BASE="http://127.0.0.1:4000"
echo "== waiting for LiteLLM to become ready =="
ready=0
for _ in $(seq 1 60); do
  if curl -fsS "$BASE/v1/models" >/dev/null 2>&1; then ready=1; break; fi
  sleep 2
done
if [[ "$ready" -ne 1 ]]; then
  echo "ERROR: LiteLLM mock did not become ready on $BASE within timeout" >&2
  COMPOSE_PROFILES= docker compose -p "$PROJECT" -f "$COMPOSE" --profile ai-mock logs >&2 || true
  exit 1
fi

# Confirm NO Ollama container is running under this project (ai-mock excludes it).
echo "== asserting Ollama is NOT running under ai-mock =="
running="$(COMPOSE_PROFILES= docker compose -p "$PROJECT" -f "$COMPOSE" ps --services --filter status=running 2>/dev/null)"
if grep -q '^ollama$' <<<"$running"; then bad "ollama must NOT run under ai-mock"; else ok "ollama not running under ai-mock"; fi

echo "== OpenAI surface: /v1/chat/completions returns a canned completion =="
RESP="$(curl -fsS "$BASE/v1/chat/completions" \
  -H 'content-type: application/json' \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"ping"}]}' 2>/dev/null)"
if jq -e '.choices[0].message.content | type == "string"' >/dev/null 2>&1 <<<"$RESP"; then
  ok "/v1/chat/completions returned a string completion"
else
  bad "/v1/chat/completions did not return a well-formed completion"; echo "    resp: $RESP"
fi

echo "== Anthropic surface: unified /v1/messages returns a canned completion =="
RESP="$(curl -fsS "$BASE/v1/messages" \
  -H 'content-type: application/json' \
  -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"claude-sonnet-4-6","max_tokens":16,"messages":[{"role":"user","content":"ping"}]}' 2>/dev/null)"
if jq -e '.content[0].text | type == "string"' >/dev/null 2>&1 <<<"$RESP"; then
  ok "/v1/messages returned a string completion"
else
  bad "/v1/messages did not return a well-formed completion"; echo "    resp: $RESP"
fi

# Tools-bearing requests TOLERATED (no 5xx, well-formed) on BOTH surfaces. We capture
# the HTTP status separately so a 5xx (regression) is caught even though curl -f hides
# the body. A canned mock_response cannot emit structured tool_calls/tool_use — this
# is purely a request-parsing/endpoint regression signal.
echo "== tools-bearing request tolerated on /v1/chat/completions (no 5xx) =="
CODE="$(curl -s -o /tmp/llm_tools_oa.json -w '%{http_code}' "$BASE/v1/chat/completions" \
  -H 'content-type: application/json' \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"weather?"}],
       "tools":[{"type":"function","function":{"name":"get_weather","description":"w","parameters":{"type":"object","properties":{"city":{"type":"string"}}}}}]}' 2>/dev/null)"
if [[ "$CODE" =~ ^2 ]] && jq -e '.choices[0].message' >/dev/null 2>&1 < /tmp/llm_tools_oa.json; then
  ok "tools request on /v1/chat/completions tolerated (HTTP $CODE, well-formed)"
else
  bad "tools request on /v1/chat/completions not tolerated (HTTP $CODE)"; cat /tmp/llm_tools_oa.json
fi

echo "== tools-bearing request tolerated on /v1/messages (no 5xx) =="
CODE="$(curl -s -o /tmp/llm_tools_anth.json -w '%{http_code}' "$BASE/v1/messages" \
  -H 'content-type: application/json' \
  -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"claude-sonnet-4-6","max_tokens":16,"messages":[{"role":"user","content":"weather?"}],
       "tools":[{"name":"get_weather","description":"w","input_schema":{"type":"object","properties":{"city":{"type":"string"}}}}]}' 2>/dev/null)"
if [[ "$CODE" =~ ^2 ]] && jq -e '.content' >/dev/null 2>&1 < /tmp/llm_tools_anth.json; then
  ok "tools request on /v1/messages tolerated (HTTP $CODE, well-formed)"
else
  bad "tools request on /v1/messages not tolerated (HTTP $CODE)"; cat /tmp/llm_tools_anth.json
fi

rm -f /tmp/llm_tools_oa.json /tmp/llm_tools_anth.json
echo
echo "RESULT: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

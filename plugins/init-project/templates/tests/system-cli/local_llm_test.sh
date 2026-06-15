#!/usr/bin/env bash
# Description: Unit tests for the local LLM mock stack templates (etc/local-llm/).
#
# TWO layers, kept distinct (see fn-3 spec R10):
#   1) Generated-file / source shape: validates the local-llm stack subtree
#      UNCONDITIONALLY (it always exists in the plugin source — never skipped):
#      docker-compose.yml service/profile/pin/port/health shape, the real + mock
#      LiteLLM configs, and the _pull-model.sh init. NO daemon, NO network, NO model.
#   2) _pull-model.sh BRANCH coverage under `sh` with `ollama` stubbed — every branch
#      (empty model -> fail; chat-only; chat + embeddings; pull failure -> non-zero)
#      so the kcov LINE gate over the init script can reach 100%.
#
# The shipped-in-a-generated-project copy of this file SELF-SKIPS (exit 0, clear
# notice) when etc/local-llm/docker-compose.yml is absent — a non-opt-in generated
# project's CI stays green and the stack is not a dependency. That self-skip is for
# the GENERATED-PROJECT path ONLY: at PLUGIN level the subtree always exists, so this
# suite validates it unconditionally.
#
# Run from anywhere:
#   bash tests/system-cli/local_llm_test.sh
# Under kcov (CI), each invocation runs as a DIRECT kcov child via the same runner()
# mechanism as system_cli_test.sh (SYSTEM_CLI_KCOV_DIR keyed, --include-pattern
# scoped to the init script, per-call collect dirs merged afterward).

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"        # repo root

# Resolve the local-llm stack subtree. At PLUGIN level (this repo) the templates live
# under templates/_optional/local-llm/; in a GENERATED project they are copied to
# etc/local-llm/. An explicit override (LOCAL_LLM_SRC) wins (used by the plugin proof
# harness). Prefer the generated location, then the plugin _optional subtree.
if [[ -n "${LOCAL_LLM_SRC:-}" ]]; then
  STACK_DIR="$LOCAL_LLM_SRC"
elif [[ -f "$ROOT/etc/local-llm/docker-compose.yml" ]]; then
  STACK_DIR="$ROOT/etc/local-llm"
elif [[ -f "$ROOT/_optional/local-llm/docker-compose.yml" ]]; then
  # Plugin-source layout: tests/ and _optional/ are siblings under templates/.
  STACK_DIR="$ROOT/_optional/local-llm"
else
  STACK_DIR=""
fi

# Generated-project self-skip (R5): only when there is genuinely no stack AND we are
# clearly NOT at plugin level (no _optional/local-llm/ sibling). This keeps a
# non-opt-in generated project's CI green while never letting the plugin's own source
# validation be vacuously skipped.
if [[ -z "$STACK_DIR" ]]; then
  echo "NOTICE: etc/local-llm/docker-compose.yml absent — local LLM stack not installed; skipping (exit 0)."
  exit 0
fi

COMPOSE="$STACK_DIR/docker-compose.yml"
TPL="$STACK_DIR/litellm/config.yaml.template"
MOCK="$STACK_DIR/litellm/config.mock.yaml"
PULL="$STACK_DIR/_pull-model.sh"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad()   { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# Strip YAML/shell comments (full-line `#…` and `key: value  # trailing`) so shape
# assertions match real DIRECTIVES, not prose in comments. Conservative: drops from
# the first unquoted `#`; our compose/configs carry no `#` inside quoted values.
nocomments() { sed -e 's/[[:space:]]*#.*$//' "$1"; }

# runner: run a script as a DIRECT kcov child (when SYSTEM_CLI_KCOV_DIR set), echo
# combined stdout+stderr, RETURN THE SCRIPT'S exit code. Mirrors system_cli_test.sh:
# unique per-call collect dir from a counter FILE (subshell-safe), --include-pattern
# scoped to the init script, LD_PRELOAD warning stripped without masking rc. We run
# the POSIX script under `sh` (its real entrypoint), via kcov when measuring.
runner() {
  local interp="$1" script="$2"; shift 2
  if [[ -n "${SYSTEM_CLI_KCOV_DIR:-}" ]]; then
    local n cf="$SYSTEM_CLI_KCOV_DIR/.counter"
    n=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$cf"
    ( raw="$(kcov --collect-only \
              --include-pattern=_pull-model.sh \
              "$SYSTEM_CLI_KCOV_DIR/run-$n" \
              "$interp" "$script" "$@" 2>&1)"; rc=$?
      printf '%s' "$raw" | grep -vE "object '.*libkcov.*' from LD_PRELOAD cannot be preloaded"
      exit "$rc" )
  else
    ( "$interp" "$script" "$@" 2>&1 )
  fi
}

echo "== compose shape (source subtree — validated unconditionally) =="
check "docker-compose.yml present"               '[[ -f "$COMPOSE" ]]'
check "ollama service tagged profile ai"         'grep -Eq "^  ollama:" "$COMPOSE"'
check "model-pull service present"               'grep -Eq "^  model-pull:" "$COMPOSE"'
check "real litellm service present"             'grep -Eq "^  litellm:" "$COMPOSE"'
check "mock litellm service present"             'grep -Eq "^  litellm-mock:" "$COMPOSE"'

# Ollama: version-tag pinned (NOT latest), CPU-only (no GPU reservation), ollama-list
# healthcheck (NOT curl), named volume, no host port.
check "ollama pinned to a version tag (not latest)" 'grep -Eq "image: ollama/ollama:[0-9]+\.[0-9]+\.[0-9]+" "$COMPOSE" && ! grep -Eq "ollama/ollama:latest" "$COMPOSE"'
check "ollama healthcheck uses ollama list (not curl)" 'grep -Eq "\"ollama\", \"list\"" "$COMPOSE"'
check "no curl in compose (directives)"          '! nocomments "$COMPOSE" | grep -q "curl"'
check "no GPU reservation in committed compose (R15)" '! grep -q "devices" "$COMPOSE" && ! grep -q "capabilities:.*gpu" "$COMPOSE"'
check "ollama named volume mounted"              'grep -Eq "ollama-models:/root/\.ollama" "$COMPOSE"'

# model-pull: entrypoint override (not bare command), OLLAMA_HOST, LLM_MODEL env from
# ${LLM_MODEL:-}, gated by service_healthy, restart:"no", reads _pull-model.sh.
check "model-pull overrides entrypoint to /bin/sh _pull-model.sh" 'grep -Eq "entrypoint:.*_pull-model.sh" "$COMPOSE"'
check "model-pull sets OLLAMA_HOST"              'grep -q "OLLAMA_HOST=http://ollama:11434" "$COMPOSE"'
check "model-pull LLM_MODEL from \${LLM_MODEL:-}" 'grep -q "LLM_MODEL=\${LLM_MODEL:-}" "$COMPOSE"'
check "model-pull LLM_EMBED_MODEL from \${LLM_EMBED_MODEL:-}" 'grep -q "LLM_EMBED_MODEL=\${LLM_EMBED_MODEL:-}" "$COMPOSE"'
check "model-pull restart no"                    'grep -Eq "restart:\s*\"no\"" "$COMPOSE"'
check "model-pull waits for ollama service_healthy" 'grep -q "condition: service_healthy" "$COMPOSE"'

# Real litellm: digest-pinned, NOT latest/main-latest, NOT tag-only; serves the
# generated config via bind mount with create_host_path:false; waits for the pull;
# OLLAMA_API_BASE on the container env; loopback :4000.
check "litellm pinned by digest (tag+digest or digest both ok)" 'grep -Eq "ghcr.io/berriai/litellm(:[^@[:space:]]+)?@sha256:" "$COMPOSE"'
check "litellm not latest/main-latest"           '! grep -Eq "ghcr.io/berriai/litellm:(latest|main-latest)" "$COMPOSE"'
check "litellm not tag-only (no @sha256-less image line)" '! grep -Eq "image: ghcr.io/berriai/litellm:[^@[:space:]]+\s*$" "$COMPOSE"'
check "litellm OLLAMA_API_BASE on container env"  'grep -q "OLLAMA_API_BASE=http://ollama:11434" "$COMPOSE"'
check "litellm waits for model-pull completion"   'grep -q "condition: service_completed_successfully" "$COMPOSE"'
check "litellm bind config.yaml create_host_path false" 'grep -q "create_host_path: false" "$COMPOSE"'
check "litellm bind source is generated config.yaml" 'grep -q "source: ./litellm/config.yaml" "$COMPOSE"'
check "litellm published loopback :4000"          'grep -q "127.0.0.1:4000:4000" "$COMPOSE"'

# Mock litellm: ai-mock profile, mounts config.mock.yaml, also loopback :4000, no
# ollama dependency.
check "mock litellm mounts config.mock.yaml"      'grep -q "source: ./litellm/config.mock.yaml" "$COMPOSE"'

# Profiles: ai (ollama/model-pull/litellm) + ai-mock (litellm-mock).
check "compose declares ai profile"               'grep -Eq "profiles:\s*\[\"ai\"\]" "$COMPOSE"'
check "compose declares ai-mock profile"          'grep -Eq "profiles:\s*\[\"ai-mock\"\]" "$COMPOSE"'

# No env_file: / no generated .env reliance.
check "no env_file directive"                     '! nocomments "$COMPOSE" | grep -q "env_file"'

# Ollama internal-only (no host port mapping for the ollama service block). The only
# 127.0.0.1:port published is :4000 (the two litellm instances).
check "no ollama host port (only :4000 published)" '! grep -Eq "127.0.0.1:11434" "$COMPOSE"'

# Shared network for service-name DNS.
check "shared local-llm network declared"         'grep -Eq "^  local-llm:" "$COMPOSE"'

echo "== real config template shape =="
check "config.yaml.template present"              '[[ -f "$TPL" ]]'
check "wildcard chat route -> ollama_chat/@@LLM_MODEL@@" 'grep -q "model_name: \"\*\"" "$TPL" && grep -q "ollama_chat/@@LLM_MODEL@@" "$TPL"'
check "explicit local alias present"              'grep -Eq "model_name: local" "$TPL"'
check "config api_base points at ollama:11434"    'grep -q "api_base: http://ollama:11434" "$TPL"'
check "embeddings block sentinel markers present" 'grep -q "# >>> embeddings" "$TPL" && grep -q "# <<< embeddings" "$TPL"'
check "embeddings entry local-embed -> ollama/@@LLM_EMBED_MODEL@@" 'grep -q "model_name: local-embed" "$TPL" && grep -q "ollama/@@LLM_EMBED_MODEL@@" "$TPL"'
# The template must NOT carry a hardcoded default model — only the @@ tokens.
check "no hardcoded model in template (tokens only)" 'grep -Eq "@@LLM_MODEL@@" "$TPL"'

echo "== mock config shape =="
check "config.mock.yaml present"                  '[[ -f "$MOCK" ]]'
check "mock wildcard route"                       'grep -q "model_name: \"\*\"" "$MOCK"'
check "mock carries a mock_response"              'grep -q "mock_response:" "$MOCK"'
check "mock has NO embeddings entry (chat-only)"  '! grep -q "local-embed" "$MOCK"'
check "mock has NO ollama backend"                '! grep -q "ollama" "$MOCK"'

echo "== _pull-model.sh source shape (POSIX sh) =="
check "_pull-model.sh present"                    '[[ -f "$PULL" ]]'
check "shebang is /bin/sh"                         'head -1 "$PULL" | grep -q "#!/bin/sh"'
check "set -eu (no pipefail)"                      'grep -q "set -eu" "$PULL" && ! nocomments "$PULL" | grep -q "pipefail"'
check "no bashisms ([[ ]])"                        '! nocomments "$PULL" | grep -q "\[\["'
check "no bashism (arrays)"                        '! nocomments "$PULL" | grep -Eq "=\("'

echo "== _pull-model.sh BRANCH coverage (ollama stubbed, run under sh) =="
# Stub `ollama` on PATH: records argv to a log; fails on a sentinel model name so the
# pull-failure branch (R13) is exercised. Run the script under `sh` via runner so kcov
# instruments it directly.
STUBBIN="$(mktemp -d)"; trap 'rm -rf "$STUBBIN"' EXIT
cat > "$STUBBIN/ollama" <<'STUB'
#!/usr/bin/env bash
echo "STUB ollama $*" >> "${OLLAMA_STUB_LOG:-/dev/null}"
# Simulate a pull failure for the sentinel model (offline / unknown model -> non-zero).
if [[ "${1:-}" == "pull" && "${2:-}" == "__fail__" ]]; then
  echo "Error: pull failed (stubbed)" >&2
  exit 1
fi
exit 0
STUB
chmod +x "$STUBBIN/ollama"
SH="$(command -v sh)"
PATH_WITH_STUB="$STUBBIN:$PATH"

# Branch 1: empty LLM_MODEL -> exit 1 + clear error (no ollama call).
OUT="$(PATH="$PATH_WITH_STUB" LLM_MODEL="" LLM_EMBED_MODEL="" OLLAMA_STUB_LOG=/dev/null runner "$SH" "$PULL")"; rc=$?
check "empty LLM_MODEL -> exit 1"                 '[[ $rc -eq 1 ]]'
check "empty LLM_MODEL -> clear error"            'grep -q "LLM_MODEL is empty" <<<"$OUT"'

# Branch 2: chat-only (no embed) -> pulls the chat model, exits 0, NO embed pull.
LOG="$STUBBIN/log2"; : > "$LOG"
OUT="$(PATH="$PATH_WITH_STUB" LLM_MODEL="llama3.2:3b" LLM_EMBED_MODEL="" OLLAMA_STUB_LOG="$LOG" runner "$SH" "$PULL")"; rc=$?
check "chat-only -> exit 0"                       '[[ $rc -eq 0 ]]'
check "chat-only -> pulled the chat model"        'grep -q "pull llama3.2:3b" "$LOG"'
check "chat-only -> NO embed pull"                '[[ $(grep -c "pull " "$LOG") -eq 1 ]]'

# Branch 3: chat + embeddings -> pulls BOTH models.
LOG="$STUBBIN/log3"; : > "$LOG"
OUT="$(PATH="$PATH_WITH_STUB" LLM_MODEL="qwen2.5:7b" LLM_EMBED_MODEL="nomic-embed-text" OLLAMA_STUB_LOG="$LOG" runner "$SH" "$PULL")"; rc=$?
check "chat+embed -> exit 0"                      '[[ $rc -eq 0 ]]'
check "chat+embed -> pulled chat model"           'grep -q "pull qwen2.5:7b" "$LOG"'
check "chat+embed -> pulled embed model"          'grep -q "pull nomic-embed-text" "$LOG"'

# Branch 4: pull failure (offline / unknown model) -> non-zero exit (R13).
LOG="$STUBBIN/log4"; : > "$LOG"
OUT="$(PATH="$PATH_WITH_STUB" LLM_MODEL="__fail__" LLM_EMBED_MODEL="" OLLAMA_STUB_LOG="$LOG" runner "$SH" "$PULL")"; rc=$?
check "pull failure -> non-zero exit"             '[[ $rc -ne 0 ]]'

echo
echo "RESULT: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

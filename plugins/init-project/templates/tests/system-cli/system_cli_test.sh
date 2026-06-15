#!/usr/bin/env bash
# Description: Shell tests for this project's system.sh dispatcher + src/system-cli subcommands.
#
# Shipped into the generated project. Run from anywhere:
#   bash tests/system-cli/system_cli_test.sh
# CI runs this under kcov for line coverage; branch completeness is enforced here
# by an EXPLICIT test per branch (kcov's bash branch metric is not portable). See
# docs/tdd.md.
#
# Surfaces:
#   1) Dispatcher contract: routing, exit 64 (usage/underscore) + pinned error,
#      exit 127 (unknown), help listing + underscore-hiding.
#   2) build-config validators + distribution: per-component .env, SPA public
#      config stamp, realm-import stamp + clean-prior-on-rename, and a test per
#      reject branch (alphabet, port, host, missing field, raw deploy template).

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"        # repo root
SYS="$ROOT/system.sh"
BUILD_CONFIG="$ROOT/src/system-cli/build-config.sh"
PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad()   { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# Isolate generated artifacts: copy config.json into a scratch root so the suite
# never clobbers the developer's working .env files. We run build-config against
# a COPY of the project (system.sh/src/system-cli + config.json) inside a tmp dir.
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src"
cp "$SYS" "$WORK/system.sh"
cp -R "$ROOT/src/system-cli" "$WORK/src/system-cli"
cp "$ROOT/config.json" "$WORK/config.json"
chmod +x "$WORK/system.sh" "$WORK"/src/system-cli/*.sh
WSYS="$WORK/system.sh"
WCLI="$WORK/src/system-cli"             # subcommand dir (build-config, up, down, ...)
WBC="$WCLI/build-config.sh"

# Coverage mode (opt-in): when SYSTEM_CLI_KCOV_DIR is set, each script invocation
# runs as a DIRECT kcov child (kcov instruments only its immediate target reliably —
# the scripts under test run via bash, not deeply nested), with per-call collect dirs
# that CI merges afterward. kcov scopes to the executed copies (system.sh +
# src/system-cli) via --include-pattern so it measures the real scripts, never the
# harness or scaffold.sh. When unset, invocations run plainly. Either way we strip
# kcov's LD_PRELOAD-warning line from captured output so it never corrupts the exact
# stderr-prefix assertions below.
# runner <script> [args...]: run the script in $WORK, echo combined stdout+stderr,
# and RETURN THE SCRIPT'S EXIT CODE (not the LD_PRELOAD-filter's). The filter strip
# of kcov's preload-warning line must not mask the script's rc, so we capture rc in
# the same subshell that runs the script and re-exit with it after filtering.
#
# Each runner call is itself wrapped in $(...) by the caller (a subshell), so a shell
# variable counter would not persist — we derive a UNIQUE per-call collect dir from a
# monotonically-incremented counter FILE under $SYSTEM_CLI_KCOV_DIR. CI merges all
# run-* dirs afterward (kcov --merge) into one summary the coverage gate parses.
runner() {
  local script="$1"; shift
  if [[ -n "${SYSTEM_CLI_KCOV_DIR:-}" ]]; then
    local n cf="$SYSTEM_CLI_KCOV_DIR/.counter"
    n=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$cf"
    ( cd "$WORK"
      raw="$(kcov --collect-only \
              --include-pattern=/system.sh,/src/system-cli/ \
              "$SYSTEM_CLI_KCOV_DIR/run-$n" \
              bash "$script" "$@" 2>&1)"; rc=$?
      printf '%s' "$raw" | grep -vE "object '.*libkcov.*' from LD_PRELOAD cannot be preloaded"
      exit "$rc" )
  else
    ( cd "$WORK" && bash "$script" "$@" 2>&1 )
  fi
}

echo "== dispatcher contract =="
OUT="$(runner "$WSYS" help)"; rc=$?
check "valid subcommand dispatches (help exit 0)" '[[ $rc -eq 0 ]]'
check "help lists subcommands + descriptions"     'grep -q "Available commands:" <<<"$OUT" && grep -q "build-config" <<<"$OUT"'

OUT="$(runner "$WSYS")"; rc=$?
check "no subcommand -> exit 64"                  '[[ $rc -eq 64 ]]'
check "no subcommand -> usage on stderr"          'grep -q "usage:" <<<"$OUT"'

OUT="$(runner "$WSYS" _private)"; rc=$?
check "underscore subcommand -> exit 64"          '[[ $rc -eq 64 ]]'
check "underscore error pinned ERROR: '\''<sub>'\''" '[[ "$OUT" == "ERROR: '\''_private'\'' is a private helper"* ]]'

OUT="$(runner "$WSYS" nope)"; rc=$?
check "unknown subcommand -> exit 127"            '[[ $rc -eq 127 ]]'

# Underscore helpers are hidden from help.
cat > "$WORK/src/system-cli/_hidden.sh" <<'HID'
#!/usr/bin/env bash
# Description: never shown.
echo x
HID
chmod +x "$WORK/src/system-cli/_hidden.sh"
OUT="$(runner "$WSYS" help)"
check "help hides underscore helpers"             '! grep -q "_hidden" <<<"$OUT"'
rm -f "$WORK/src/system-cli/_hidden.sh"

# No-description fallback.
cat > "$WORK/src/system-cli/nodesc.sh" <<'ND'
#!/usr/bin/env bash
echo x
ND
chmod +x "$WORK/src/system-cli/nodesc.sh"
OUT="$(runner "$WSYS" help)"
check "help falls back to (no description)"       'grep -qE "nodesc[[:space:]]+\(no description\)" <<<"$OUT"'
rm -f "$WORK/src/system-cli/nodesc.sh"

echo "== build-config: validators (explicit per-branch reject tests) =="
# shellcheck disable=SC1090
source "$WBC"
set +e +u

check "v_urlsafe rejects out-of-alphabet" '( v_urlsafe "bad=x" l ) 2>/dev/null; [[ $? -eq 64 ]]'
check "v_host rejects underscore"         '( v_host "a_b" l ) 2>/dev/null; [[ $? -eq 64 ]]'
check "v_container rejects leading dash"  '( v_container "-x" l ) 2>/dev/null; [[ $? -eq 64 ]]'
check "v_clientid rejects space"          '( v_clientid "a b" l ) 2>/dev/null; [[ $? -eq 64 ]]'
check "v_url rejects non-url"             '( v_url "nope" l ) 2>/dev/null; [[ $? -eq 64 ]]'
check "v_port rejects 0"                  '( v_port 0 l ) 2>/dev/null; [[ $? -eq 64 ]]'
check "v_port rejects 70000"             '( v_port 70000 l ) 2>/dev/null; [[ $? -eq 64 ]]'
check "v_port accepts valid"             '( v_port 5432 l ); [[ $? -eq 0 ]]'

# --- v_base_url (service base-URL grammar + separate port range-check, R6) ---
check "v_base_url accepts loopback+port"  '( v_base_url "http://127.0.0.1:4000" l ); [[ $? -eq 0 ]]'
check "v_base_url accepts https+path"     '( v_base_url "https://api.openai.com/v1" l ); [[ $? -eq 0 ]]'
check "v_base_url accepts no-port host"   '( v_base_url "https://api.anthropic.com" l ); [[ $? -eq 0 ]]'
check "v_base_url rejects wrong scheme"   '( v_base_url "ftp://host" l ) 2>/dev/null; [[ $? -eq 64 ]]'
check "v_base_url rejects bad host char"  '( v_base_url "http://h@st/x" l ) 2>/dev/null; [[ $? -eq 64 ]]'
check "v_base_url rejects space in host"  '( v_base_url "http://ho st" l ) 2>/dev/null; [[ $? -eq 64 ]]'
check "v_base_url rejects non-num port"   '( v_base_url "http://host:abc" l ) 2>/dev/null; [[ $? -eq 64 ]]'
check "v_base_url rejects port 99999"     '( v_base_url "http://host:99999" l ) 2>/dev/null; [[ $? -eq 64 ]]'
check "v_base_url accepts port boundary"  '( v_base_url "http://host:65535" l ); [[ $? -eq 0 ]]'

# --- v_modelname (Ollama model-name grammar, R6/R12) ------------------------
check "v_modelname accepts simple"        '( v_modelname "llama3.2" l ); [[ $? -eq 0 ]]'
check "v_modelname accepts namespaced+tag" '( v_modelname "huihui_ai/llama3.2-abliterate:q4" l ); [[ $? -eq 0 ]]'
check "v_modelname accepts colon tag"     '( v_modelname "llama3.2:3b" l ); [[ $? -eq 0 ]]'
check "v_modelname rejects shell metachar" '( v_modelname "bad; rm -rf /" l ) 2>/dev/null; [[ $? -eq 64 ]]'
check "v_modelname rejects space"         '( v_modelname "a b" l ) 2>/dev/null; [[ $? -eq 64 ]]'

# --- v_env_value (transport-safety for the docker-compose env_file consumer) -
check "v_env_value accepts space/#/quotes" '( v_env_value "a b#c\"d'"'"'e" l ); [[ $? -eq 0 ]]'
check "v_env_value rejects LF"            '( v_env_value "$(printf "a\nb")" l ) 2>/dev/null; [[ $? -eq 64 ]]'
check "v_env_value rejects CR"            '( v_env_value "$(printf "a\rb")" l ) 2>/dev/null; [[ $? -eq 64 ]]'
check "v_env_value rejects TAB (control)" '( v_env_value "$(printf "a\tb")" l ) 2>/dev/null; [[ $? -eq 64 ]]'
check "v_env_value rejects \$ (interpolation)" '( v_env_value "a\$b" l ) 2>/dev/null; [[ $? -eq 64 ]]'

echo "== build-config: distribution =="
OUT="$(runner "$WBC")"; rc=$?
check "build-config succeeds"            '[[ $rc -eq 0 ]]'
check "writes src/postgres/.env"         '[[ -f "$WORK/src/postgres/.env" ]]'
check "DataAccess migrator conn string"  'grep -q "MIGRATOR_CONNECTION_STRING=.*Username=migrator" "$WORK/src/DataAccess/.env"'
check "Api api-role conn + keycloak"     'grep -q "API_CONNECTION_STRING=.*Username=api" "$WORK/src/Api/.env" && grep -q "KEYCLOAK_API_CLIENT_SECRET=" "$WORK/src/Api/.env"'
# LLM endpoint vars (R6): all four emitted into Api/.env with SDK-standard names +
# the non-opt-in real-provider defaults, RAW (no wrapping quotes — compose env_file).
check "Api ANTHROPIC_BASE_URL default"   'grep -qx "ANTHROPIC_BASE_URL=https://api.anthropic.com" "$WORK/src/Api/.env"'
check "Api ANTHROPIC_API_KEY default"    'grep -qx "ANTHROPIC_API_KEY=REPLACE_ME" "$WORK/src/Api/.env"'
check "Api OPENAI_BASE_URL default"      'grep -qx "OPENAI_BASE_URL=https://api.openai.com/v1" "$WORK/src/Api/.env"'
check "Api OPENAI_API_KEY default"       'grep -qx "OPENAI_API_KEY=REPLACE_ME" "$WORK/src/Api/.env"'
# Non-opt-in (no localLlm): no embedding model var, and no generated litellm config.
check "no OPENAI_EMBEDDING_MODEL w/o embed" '! grep -q "OPENAI_EMBEDDING_MODEL" "$WORK/src/Api/.env"'
check "no litellm config.yaml w/o localLlm" '[[ ! -f "$WORK/etc/local-llm/litellm/config.yaml" ]]'
check "stamps SPA public config (non-secret)" 'jq -e "(keys|sort)==[\"clientId\",\"realmUrl\"]" "$WORK/src/WebApp/public/config.json" >/dev/null'

OUT="$(runner "$WBC" --config "$WORK/config.json")"; rc=$?
check "--config <path> accepted"         '[[ $rc -eq 0 ]]'

OUT="$(runner "$WBC" --config /nonexistent.json)"; rc=$?
check "missing --config file -> exit 64" '[[ $rc -eq 64 ]]'

OUT="$(runner "$WBC" --bogus)"; rc=$?
check "unknown flag -> exit 64"          '[[ $rc -eq 64 ]]'

# Reject: out-of-alphabet secret.
BAD="$WORK/bad.json"
jq '(.systems[] | select(.name=="postgres") | .owner_password)="bad=secret"' "$WORK/config.json" > "$BAD"
OUT="$(runner "$WBC" --config "$BAD")"; rc=$?
check "out-of-alphabet secret -> exit 64" '[[ $rc -eq 64 ]]'

# Reject: bad port.
BADP="$WORK/badport.json"
jq '(.systems[] | select(.name=="Api") | .port)=99999' "$WORK/config.json" > "$BADP"
OUT="$(runner "$WBC" --config "$BADP")"; rc=$?
check "out-of-range port -> exit 64"      '[[ $rc -eq 64 ]]'

# Reject: raw deploy template ({{VAR}}).
if [[ -f "$ROOT/config.deploy.json" ]]; then
  OUT="$(runner "$WBC" --config "$ROOT/config.deploy.json")"; rc=$?
  check "raw deploy template -> exit 64"  '[[ $rc -eq 64 ]]'
fi

# External service credential exempt (opaque api_key with /+= passes) — both entries.
OPAQUE="$WORK/opaque.json"
jq '.services."claude-api".api_key="sk-a/b+c=d" | .services."openai-api".api_key="sk-x/y+z=w"' "$WORK/config.json" > "$OPAQUE"
OUT="$(runner "$WBC" --config "$OPAQUE")"; rc=$?
check "external service cred exempt"      '[[ $rc -eq 0 ]]'
check "opaque openai-api key emitted raw" '[[ $rc -eq 0 ]] && grep -qx "OPENAI_API_KEY=sk-x/y+z=w" "$WORK/src/Api/.env"'

# The generated runtime litellm config MUST be gitignored (R6 acceptance) so a
# build-config run with localLlm.model never leaves a committable artifact. The
# committed template (config.yaml.template) is NOT matched by this rule.
if [[ -f "$ROOT/.gitignore" ]]; then
  check ".gitignore ignores generated litellm config.yaml" 'grep -qE "^[[:space:]]*etc/local-llm/litellm/config\.yaml[[:space:]]*$" "$ROOT/.gitignore"'
fi

echo "== build-config: services{} LLM endpoints (R6) =="
# base_url grammar: reject malformed host / non-numeric & out-of-range ports.
BADURL="$WORK/badurl.json"
jq '.services."claude-api".base_url="http://h@st/x"' "$WORK/config.json" > "$BADURL"
OUT="$(runner "$WBC" --config "$BADURL")"; rc=$?
check "claude-api base_url bad host -> 64" '[[ $rc -eq 64 ]]'
jq '.services."openai-api".base_url="http://host:99999"' "$WORK/config.json" > "$BADURL"
OUT="$(runner "$WBC" --config "$BADURL")"; rc=$?
check "openai-api base_url port 99999 -> 64" '[[ $rc -eq 64 ]]'
jq '.services."openai-api".base_url="http://host:abc"' "$WORK/config.json" > "$BADURL"
OUT="$(runner "$WBC" --config "$BADURL")"; rc=$?
check "openai-api base_url non-num port -> 64" '[[ $rc -eq 64 ]]'

# Split test matrix — API KEY punctuation: space/#/"/' round-trip raw (compose
# env_file consumer); $ and CR/LF/control are rejected.
KEYT="$WORK/keyt.json"
for pair in "space:sk a" "hash:sk#a" "dquote:sk\"a" "squote:sk'a"; do
  label="${pair%%:*}"; val="${pair#*:}"
  jq --arg k "$val" '.services."claude-api".api_key=$k' "$WORK/config.json" > "$KEYT"
  OUT="$(runner "$WBC" --config "$KEYT")"; rc=$?
  check "api_key with $label round-trips"  '[[ $rc -eq 0 ]] && grep -qx "ANTHROPIC_API_KEY=$val" "$WORK/src/Api/.env"'
done
jq --arg k 'sk-a$b' '.services."claude-api".api_key=$k' "$WORK/config.json" > "$KEYT"
OUT="$(runner "$WBC" --config "$KEYT")"; rc=$?
check "api_key with \$ rejected -> 64"     '[[ $rc -eq 64 ]]'
# whitespace+# is a compose env_file inline-comment sequence that TRUNCATES the value
# (KEY=sk #x -> sk), so it must be rejected even though space and # are each fine alone.
jq --arg k 'sk-a #suffix' '.services."claude-api".api_key=$k' "$WORK/config.json" > "$KEYT"
OUT="$(runner "$WBC" --config "$KEYT")"; rc=$?
check "api_key with space+# rejected -> 64" '[[ $rc -eq 64 ]]'
# A # NOT preceded by whitespace round-trips (no inline comment).
jq --arg k 'sk-a#suffix' '.services."claude-api".api_key=$k' "$WORK/config.json" > "$KEYT"
OUT="$(runner "$WBC" --config "$KEYT")"; rc=$?
check "api_key with #-no-space round-trips" '[[ $rc -eq 0 ]] && grep -qx "ANTHROPIC_API_KEY=sk-a#suffix" "$WORK/src/Api/.env"'
jq --arg k "$(printf 'sk-a\nb')" '.services."claude-api".api_key=$k' "$WORK/config.json" > "$KEYT"
OUT="$(runner "$WBC" --config "$KEYT")"; rc=$?
check "api_key with LF rejected -> 64"     '[[ $rc -eq 64 ]]'
jq --arg k "$(printf 'sk-a\rb')" '.services."claude-api".api_key=$k' "$WORK/config.json" > "$KEYT"
OUT="$(runner "$WBC" --config "$KEYT")"; rc=$?
check "api_key with CR rejected -> 64"     '[[ $rc -eq 64 ]]'
jq --arg k "$(printf 'sk-a\tb')" '.services."claude-api".api_key=$k' "$WORK/config.json" > "$KEYT"
OUT="$(runner "$WBC" --config "$KEYT")"; rc=$?
check "api_key with TAB rejected -> 64"    '[[ $rc -eq 64 ]]'

# Base URL legal path punctuation: # round-trips (grammar-valid path); $ rejected.
jq --arg u 'http://host/p#frag' '.services."claude-api".base_url=$u' "$WORK/config.json" > "$BADURL"
OUT="$(runner "$WBC" --config "$BADURL")"; rc=$?
check "base_url path # round-trips"        '[[ $rc -eq 0 ]] && grep -qx "ANTHROPIC_BASE_URL=http://host/p#frag" "$WORK/src/Api/.env"'
jq --arg u 'http://host/p$x' '.services."claude-api".base_url=$u' "$WORK/config.json" > "$BADURL"
OUT="$(runner "$WBC" --config "$BADURL")"; rc=$?
check "base_url path \$ rejected -> 64"    '[[ $rc -eq 64 ]]'

echo "== build-config: rendered deploy config distributes LLM vars (R6) =="
# Raw config.deploy.json still fails the unrendered-placeholder guard (above);
# a RENDERED deploy config distributes the four LLM vars + embedding model var.
if [[ -f "$ROOT/config.deploy.json" ]]; then
  RENDERED="$WORK/rendered.json"
  sed -e 's/{{POSTGRES_HOST}}/postgres/g' \
      -e 's/{{POSTGRES_OWNER_PASSWORD}}/ownerpw/g' \
      -e 's/{{POSTGRES_MIGRATOR_PASSWORD}}/migpw/g' \
      -e 's/{{POSTGRES_API_PASSWORD}}/apipw/g' \
      -e 's/{{KEYCLOAK_HOST}}/keycloak/g' \
      -e 's/{{KEYCLOAK_REALM}}/myrealm/g' \
      -e 's#{{KEYCLOAK_PUBLIC_URL}}#http://127.0.0.1:8080#g' \
      -e 's/{{KEYCLOAK_ADMIN_PASSWORD}}/adminpw/g' \
      -e 's/{{KEYCLOAK_API_CLIENT_SECRET}}/apisecret/g' \
      -e 's/{{API_HOST}}/127.0.0.1/g' \
      -e 's#{{CLAUDE_API_BASE_URL}}#https://api.anthropic.com#g' \
      -e 's/{{CLAUDE_API_KEY}}/sk-claude/g' \
      -e 's#{{OPENAI_API_BASE_URL}}#https://api.openai.com/v1#g' \
      -e 's/{{OPENAI_API_KEY}}/sk-openai/g' \
      "$ROOT/config.deploy.json" > "$RENDERED"
  OUT="$(runner "$WBC" --config "$RENDERED")"; rc=$?
  check "rendered deploy distributes claude key" '[[ $rc -eq 0 ]] && grep -qx "ANTHROPIC_API_KEY=sk-claude" "$WORK/src/Api/.env"'
  check "rendered deploy distributes openai key" 'grep -qx "OPENAI_API_KEY=sk-openai" "$WORK/src/Api/.env"'
fi

echo "== build-config: localLlm config.yaml stamping (R6/R12) =="
# Provide the litellm template at the path build-config reads (etc/local-llm/litellm/).
LLDIR="$WORK/etc/local-llm/litellm"
mkdir -p "$LLDIR"
LLTPL_SRC=""
for cand in "$ROOT/_optional/local-llm/litellm/config.yaml.template" \
            "$ROOT/etc/local-llm/litellm/config.yaml.template"; do
  [[ -f "$cand" ]] && LLTPL_SRC="$cand" && break
done
if [[ -n "$LLTPL_SRC" ]]; then
  cp "$LLTPL_SRC" "$LLDIR/config.yaml.template"

  # Chat-only: model present, no embeddingModel -> embeddings block deleted.
  LLC="$WORK/ll-chat.json"
  jq '.localLlm={model:"llama3.2:3b"}' "$WORK/config.json" > "$LLC"
  rm -f "$LLDIR/config.yaml"
  OUT="$(runner "$WBC" --config "$LLC")"; rc=$?
  check "chat-only stamps config.yaml"        '[[ $rc -eq 0 ]] && [[ -f "$LLDIR/config.yaml" ]]'
  check "chat-only model raw (no re-prefix)"  'grep -q "ollama_chat/llama3.2:3b" "$LLDIR/config.yaml" && ! grep -q "ollama_chat/ollama_chat" "$LLDIR/config.yaml"'
  check "chat-only no local-embed entry"      '! grep -q "model_name: local-embed" "$LLDIR/config.yaml"'
  check "chat-only no leftover @@token"       '! grep -Eq "@@[A-Za-z_]+@@" "$LLDIR/config.yaml"'
  check "chat-only markers stripped"          '! grep -Eq "^[[:space:]]*# (>>>|<<<) embeddings[[:space:]]*$" "$LLDIR/config.yaml"'
  check "chat-only writes NO litellm .env"    '[[ ! -f "$LLDIR/.env" ]] && ! grep -q "OPENAI_EMBEDDING_MODEL" "$WORK/src/Api/.env"'

  # Chat + embeddings: block kept, token substituted, embedding var emitted.
  LLE="$WORK/ll-embed.json"
  jq '.localLlm={model:"llama3.2:3b",embeddingModel:"nomic-embed-text"}' "$WORK/config.json" > "$LLE"
  rm -f "$LLDIR/config.yaml"
  OUT="$(runner "$WBC" --config "$LLE")"; rc=$?
  check "embed kept: local-embed entry"       '[[ $rc -eq 0 ]] && grep -q "model_name: local-embed" "$LLDIR/config.yaml"'
  check "embed kept: embed token substituted" 'grep -q "ollama/nomic-embed-text" "$LLDIR/config.yaml" && ! grep -Eq "@@[A-Za-z_]+@@" "$LLDIR/config.yaml"'
  check "embed kept: OPENAI_EMBEDDING_MODEL"   'grep -qx "OPENAI_EMBEDDING_MODEL=local-embed" "$WORK/src/Api/.env"'

  # Reject: hostile model name.
  LLBAD="$WORK/ll-bad.json"
  jq '.localLlm={model:"bad; rm -rf /"}' "$WORK/config.json" > "$LLBAD"
  OUT="$(runner "$WBC" --config "$LLBAD")"; rc=$?
  check "hostile localLlm.model -> 64"        '[[ $rc -eq 64 ]]'

  # Reject: embeddingModel without model.
  jq '.localLlm={embeddingModel:"nomic-embed-text"}' "$WORK/config.json" > "$LLBAD"
  OUT="$(runner "$WBC" --config "$LLBAD")"; rc=$?
  check "embeddingModel without model -> 64"  '[[ $rc -eq 64 ]]'

  # Reject: .localLlm present but not an object.
  jq '.localLlm="oops"' "$WORK/config.json" > "$LLBAD"
  OUT="$(runner "$WBC" --config "$LLBAD")"; rc=$?
  check "localLlm not an object -> 64"        '[[ $rc -eq 64 ]]'

  # Reject: model present but template missing -> opt-in invariant.
  # ALSO assert ATOMICITY: the template preflight runs in the validation phase BEFORE
  # any artifact is written, so a stale Api/.env must NOT be overwritten on this
  # failure (no partial update). Seed a sentinel Api/.env and confirm it survives.
  mv "$LLDIR/config.yaml.template" "$LLDIR/config.yaml.template.bak"
  printf 'SENTINEL=untouched\n' > "$WORK/src/Api/.env"
  OUT="$(runner "$WBC" --config "$LLC")"; rc=$?
  check "model present + template missing -> err" '[[ $rc -ne 0 ]] && grep -q "is missing" <<<"$OUT"'
  check "missing template fails BEFORE writing Api/.env" 'grep -qx "SENTINEL=untouched" "$WORK/src/Api/.env"'
  mv "$LLDIR/config.yaml.template.bak" "$LLDIR/config.yaml.template"

  # Reject: malformed template — @@LLM_MODEL@@ token absent entirely.
  printf 'model_list:\n  - model_name: local\n# >>> embeddings\n# <<< embeddings\n' > "$LLDIR/config.yaml.template"
  OUT="$(runner "$WBC" --config "$LLC")"; rc=$?
  check "template missing @@LLM_MODEL@@ -> err" '[[ $rc -ne 0 ]] && grep -q "@@LLM_MODEL@@" <<<"$OUT"'

  # Reject: malformed template — embeddings markers unbalanced/duplicated.
  printf 'model: ollama_chat/@@LLM_MODEL@@\n# >>> embeddings\n# >>> embeddings\n# <<< embeddings\n' > "$LLDIR/config.yaml.template"
  OUT="$(runner "$WBC" --config "$LLC")"; rc=$?
  check "template duplicated markers -> err"  '[[ $rc -ne 0 ]] && grep -q "exactly once" <<<"$OUT"'

  # Reject: markers present but in the WRONG order (close before open).
  printf 'model: ollama_chat/@@LLM_MODEL@@\n# <<< embeddings\nx: @@LLM_EMBED_MODEL@@\n# >>> embeddings\n' > "$LLDIR/config.yaml.template"
  OUT="$(runner "$WBC" --config "$LLE")"; rc=$?
  check "template reversed markers -> err"    '[[ $rc -ne 0 ]] && grep -q "must precede" <<<"$OUT"'

  # Reject: embed kept but @@LLM_EMBED_MODEL@@ token absent from the block.
  printf 'model: ollama_chat/@@LLM_MODEL@@\n# >>> embeddings\n  - model_name: local-embed\n# <<< embeddings\n' > "$LLDIR/config.yaml.template"
  OUT="$(runner "$WBC" --config "$LLE")"; rc=$?
  check "embed kept w/o embed token -> err"   '[[ $rc -ne 0 ]] && grep -q "@@LLM_EMBED_MODEL@@" <<<"$OUT"'

  # Reject: embed token present but OUTSIDE the sentinel block (the block itself is
  # tokenless). The within-block check must catch this even though the token exists
  # somewhere in the template.
  printf 'model: ollama_chat/@@LLM_MODEL@@\nstray: @@LLM_EMBED_MODEL@@\n# >>> embeddings\n  - model_name: local-embed\n# <<< embeddings\n' > "$LLDIR/config.yaml.template"
  OUT="$(runner "$WBC" --config "$LLE")"; rc=$?
  check "embed token outside block -> err"    '[[ $rc -ne 0 ]] && grep -q "inside the embeddings block" <<<"$OUT"'

  # Reject: post-stamp scan catches a stray @@token@@ with a DIGIT/DASH name (the
  # narrow [A-Za-z_] pattern would have missed @@LLM2@@; the scan must reject any token).
  printf 'model: ollama_chat/@@LLM_MODEL@@\nstray: @@LLM2@@\n# >>> embeddings\nx: @@LLM_EMBED_MODEL@@\n# <<< embeddings\n' > "$LLDIR/config.yaml.template"
  OUT="$(runner "$WBC" --config "$LLC")"; rc=$?
  check "post-stamp stray digit token -> err" '[[ $rc -ne 0 ]] && grep -q "unreplaced" <<<"$OUT"'

  # Restore the real template for any later sections.
  cp "$LLTPL_SRC" "$LLDIR/config.yaml.template"
fi

echo "== build-config: realm-stamp mechanism =="
if [[ -f "$ROOT/src/keycloak/realm.template.json" ]]; then
  # Copy the realm template INTO the work keycloak dir. An earlier build-config run
  # already wrote src/keycloak/.env, so the dir exists — `cp -R src dest` would nest
  # as dest/keycloak/. Copy the template file (and compose) explicitly to land it at
  # the path build-config reads (src/keycloak/realm.template.json).
  mkdir -p "$WORK/src/keycloak/import"
  cp "$ROOT/src/keycloak/realm.template.json" "$WORK/src/keycloak/realm.template.json"
  [[ -f "$ROOT/src/keycloak/docker-compose.yml" ]] \
    && cp "$ROOT/src/keycloak/docker-compose.yml" "$WORK/src/keycloak/docker-compose.yml"
  touch "$WORK/src/keycloak/import/stale-realm.json"
  OUT="$(runner "$WBC")"; rc=$?
  REALM="$(jq -r '(.systems[] | select(.name=="keycloak") | .realm)' "$WORK/config.json")"
  check "realm import stamped"            '[[ $rc -eq 0 ]] && [[ -f "$WORK/src/keycloak/import/$REALM-realm.json" ]]'
  check "stale prior realm import removed" '[[ ! -f "$WORK/src/keycloak/import/stale-realm.json" ]]'
else
  # No realm template yet (owned by the keycloak task) — stamping must skip cleanly.
  OUT="$(runner "$WBC")"; rc=$?
  check "no realm template -> stamp skipped" '[[ $rc -eq 0 ]] && grep -q "skipping realm stamp" <<<"$OUT"'
fi

echo "== service subcommands (up/down/status) — external commands STUBBED =="
# The compose subcommands shell out to `docker` and `dotnet`; we never want a real
# daemon in tests/CI. Put a stub `docker`/`dotnet` first on PATH that records its
# args and always succeeds, so the suite exercises COMMAND CONSTRUCTION + every
# branch of these scripts (both the "ran N stacks" and "nothing present" paths)
# without any real service. This is what gives kcov 100% LINE coverage over the
# generated src/system-cli/*.sh subcommands.
STUBBIN="$WORK/stubbin"; mkdir -p "$STUBBIN"
cat > "$STUBBIN/docker" <<'STUB'
#!/usr/bin/env bash
echo "STUB docker $*" >> "${STUB_LOG:-/dev/null}"
exit 0
STUB
cat > "$STUBBIN/dotnet" <<'STUB'
#!/usr/bin/env bash
echo "STUB dotnet $*" >> "${STUB_LOG:-/dev/null}"
exit 0
STUB
chmod +x "$STUBBIN/docker" "$STUBBIN/dotnet"
export PATH="$STUBBIN:$PATH"
export STUB_LOG="$WORK/stub.log"

# Branch A: NO compose stacks present yet -> each script takes its "nothing" path
# (and the observability network-ensure/remove block takes its absent branch).
# Remove any compose files an earlier section (realm-stamp) may have left behind so
# this branch genuinely has zero stacks.
rm -f "$WORK/src/postgres/docker-compose.yml" "$WORK/src/keycloak/docker-compose.yml" \
      "$WORK/src/otel-collector/docker-compose.yml" "$WORK/src/prometheus/docker-compose.yml" \
      "$WORK/src/grafana/docker-compose.yml"
: > "$STUB_LOG"
for sub in up down status; do
  OUT="$(runner "$WCLI/$sub.sh")"; rc=$?
  check "$sub: no stacks present -> exit 0 + notice" '[[ $rc -eq 0 ]] && grep -qE "no compose stacks present|no compose stacks" <<<"$OUT"'
done

# Branch B: compose stacks PRESENT -> each script iterates + invokes (stubbed) docker.
# The observability components (otel-collector/prometheus/grafana) are separate
# compose projects sharing the `observability` network, so up/down also create/remove
# that network.
mkdir -p "$WORK/src/postgres" "$WORK/src/keycloak" \
         "$WORK/src/otel-collector" "$WORK/src/prometheus" "$WORK/src/grafana"
printf 'services: {}\n' > "$WORK/src/postgres/docker-compose.yml"
printf 'services: {}\n' > "$WORK/src/keycloak/docker-compose.yml"
printf 'services: {}\n' > "$WORK/src/otel-collector/docker-compose.yml"
printf 'services: {}\n' > "$WORK/src/prometheus/docker-compose.yml"
printf 'services: {}\n' > "$WORK/src/grafana/docker-compose.yml"
: > "$STUB_LOG"
OUT="$(runner "$WCLI/up.sh")"; rc=$?
check "up: stacks present -> exit 0 + docker compose up invoked" '[[ $rc -eq 0 ]] && grep -q "up -d" "$STUB_LOG"'
check "up: ensures shared observability network" 'grep -q "network create observability" "$STUB_LOG"'
: > "$STUB_LOG"
OUT="$(runner "$WCLI/down.sh")"; rc=$?
check "down: stacks present -> exit 0 + docker compose down invoked" '[[ $rc -eq 0 ]] && grep -q " down" "$STUB_LOG"'
check "down: removes shared observability network" 'grep -q "network rm observability" "$STUB_LOG"'
: > "$STUB_LOG"
OUT="$(runner "$WCLI/status.sh")"; rc=$?
check "status: stacks present -> exit 0 + docker compose ps invoked" '[[ $rc -eq 0 ]] && grep -q " ps" "$STUB_LOG"'

echo "== up/down: opt-in local-llm profile orchestration (docker STUBBED) =="
# The local-llm stack lives at etc/local-llm/docker-compose.yml (config at
# etc/local-llm/litellm/config.yaml, model from config.json -> localLlm.model). All
# docker calls are stubbed; we assert command CONSTRUCTION + every branch.
#
# Core src/* compose stacks are still present from Branch B above (postgres/keycloak/
# observability) — so we can assert that a FAILED `--profile ai` preflight leaves
# ZERO docker invocations (no core stack started either: preflight runs first).

LLDIR_RT="$WORK/etc/local-llm"
LLCFG_RT="$LLDIR_RT/litellm"
mkdir -p "$LLCFG_RT"
# A docker stub that records argv (incl. the cleared COMPOSE_PROFILES) into STUB_LOG.
# Overwrites the generic stub for this section so we can also assert env handling.
cat > "$STUBBIN/docker" <<'STUB'
#!/usr/bin/env bash
echo "STUB docker $* [COMPOSE_PROFILES=${COMPOSE_PROFILES-<unset>}]" >> "${STUB_LOG:-/dev/null}"
exit 0
STUB
chmod +x "$STUBBIN/docker"

# Helper: write a generated litellm config.yaml with the given chat + (optional)
# embed models, matching build-config's stamped shape (two ollama_chat routes + an
# optional ollama/ embed route).
write_llcfg() {  # write_llcfg <chat-model> [embed-model]
  {
    printf 'model_list:\n'
    printf '  - model_name: "*"\n    litellm_params:\n      model: ollama_chat/%s\n      api_base: http://ollama:11434\n' "$1"
    printf '  - model_name: local\n    litellm_params:\n      model: ollama_chat/%s\n      api_base: http://ollama:11434\n' "$1"
    if [[ -n "${2:-}" ]]; then
      printf '  - model_name: local-embed\n    litellm_params:\n      model: ollama/%s\n      api_base: http://ollama:11434\n' "$2"
    fi
  } > "$LLCFG_RT/config.yaml"
}
set_llmodel() {  # set_llmodel <jq-localLlm-expr-or-empty>  (writes $WORK/config.json)
  if [[ -z "${1:-}" ]]; then
    jq 'del(.localLlm)' "$WORK/config.json" > "$WORK/config.json.tmp"
  else
    jq ".localLlm=$1" "$WORK/config.json" > "$WORK/config.json.tmp"
  fi
  mv "$WORK/config.json.tmp" "$WORK/config.json"
}

# --- profile grammar (parse layer, shared by up + down) ----------------------------
: > "$STUB_LOG"
OUT="$(runner "$WCLI/up.sh" --profile bogus)"; rc=$?
check "up: unknown profile -> exit 64"            '[[ $rc -eq 64 ]] && grep -q "usage:" <<<"$OUT"'
OUT="$(runner "$WCLI/up.sh" --frobnicate)"; rc=$?
check "up: unknown flag -> exit 64"               '[[ $rc -eq 64 ]]'
OUT="$(runner "$WCLI/up.sh" --profile)"; rc=$?
check "up: --profile missing value -> exit 64"    '[[ $rc -eq 64 ]]'
OUT="$(runner "$WCLI/up.sh" --profile ai --profile ai-mock)"; rc=$?
check "up: both ai + ai-mock -> exit 64 (port)"   '[[ $rc -eq 64 ]] && grep -q ":4000" <<<"$OUT"'
OUT="$(runner "$WCLI/down.sh" --profile=bogus)"; rc=$?
check "down: unknown profile (= form) -> exit 64" '[[ $rc -eq 64 ]]'
OUT="$(runner "$WCLI/down.sh" stray-arg)"; rc=$?
check "down: non-profile arg -> exit 64"          '[[ $rc -eq 64 ]]'

# --- not-installed stack (etc/local-llm/docker-compose.yml ABSENT) -----------------
rm -f "$LLDIR_RT/docker-compose.yml"
: > "$STUB_LOG"
OUT="$(runner "$WCLI/up.sh" --profile ai)"; rc=$?
check "up --profile ai, not installed -> exit 64"   '[[ $rc -eq 64 ]] && grep -q "not installed" <<<"$OUT"'
check "up --profile ai, not installed -> 0 docker"  '! grep -q "STUB docker" "$STUB_LOG"'
: > "$STUB_LOG"
OUT="$(runner "$WCLI/up.sh" --profile ai-mock)"; rc=$?
check "up --profile ai-mock, not installed -> 64"   '[[ $rc -eq 64 ]] && grep -q "not installed" <<<"$OUT"'
: > "$STUB_LOG"
OUT="$(runner "$WCLI/down.sh" --profile ai)"; rc=$?
check "down --profile ai, not installed -> no-op 0" '[[ $rc -eq 0 ]] && ! grep -q "local-llm" "$STUB_LOG"'

# Install the stack compose file for the remaining cases.
printf 'services: {}\n' > "$LLDIR_RT/docker-compose.yml"

# --- default up (no profile) never invokes the local compose, even with ambient
#     COMPOSE_PROFILES=ai set --------------------------------------------------------
: > "$STUB_LOG"
OUT="$(COMPOSE_PROFILES=ai runner "$WCLI/up.sh")"; rc=$?
check "default up: exit 0"                          '[[ $rc -eq 0 ]]'
check "default up: NO local-llm compose invoked"    '! grep -q "etc/local-llm" "$STUB_LOG"'
check "default up: ambient COMPOSE_PROFILES ignored — no ai containers" '! grep -q "etc/local-llm" "$STUB_LOG"'

# --- up --profile ai-mock: installed, no model needed (static config) --------------
set_llmodel ""            # no localLlm at all — ai-mock must not require it
: > "$STUB_LOG"
OUT="$(COMPOSE_PROFILES=ai runner "$WCLI/up.sh" --profile ai-mock)"; rc=$?
check "up --profile ai-mock: exit 0 (no model needed)" '[[ $rc -eq 0 ]]'
check "up --profile ai-mock: invokes local compose w/ --profile ai-mock" \
      'grep -q "etc/local-llm/docker-compose.yml --profile ai-mock up -d" "$STUB_LOG"'
check "up --profile ai-mock: COMPOSE_PROFILES cleared on the call" \
      'grep -q "etc/local-llm.*COMPOSE_PROFILES=\]" "$STUB_LOG"'

# --- up --profile ai preflight: config.yaml absent ---------------------------------
set_llmodel '{model:"llama3.2:3b"}'
rm -f "$LLCFG_RT/config.yaml"
: > "$STUB_LOG"
OUT="$(runner "$WCLI/up.sh" --profile ai)"; rc=$?
check "up --profile ai: config.yaml absent -> err"  '[[ $rc -ne 0 ]] && grep -q "build-config" <<<"$OUT"'
check "up --profile ai: preflight fail -> 0 docker"  '! grep -q "STUB docker" "$STUB_LOG"'

# --- up --profile ai preflight: localLlm.model empty -------------------------------
set_llmodel '{embeddingModel:"nomic-embed-text"}'   # model absent
write_llcfg "llama3.2:3b"
: > "$STUB_LOG"
OUT="$(runner "$WCLI/up.sh" --profile ai)"; rc=$?
check "up --profile ai: empty model -> err"         '[[ $rc -ne 0 ]] && grep -q "localLlm.model" <<<"$OUT"'

# --- up --profile ai preflight: malformed localLlm (wrong type) tolerated by export,
#     but empty model -> err (no jq crash) -----------------------------------------
set_llmodel '"oops-a-string"'
: > "$STUB_LOG"
OUT="$(runner "$WCLI/up.sh" --profile ai)"; rc=$?
check "up --profile ai: wrong-typed localLlm -> err (no jq crash)" \
      '[[ $rc -ne 0 ]] && ! grep -qi "jq:" <<<"$OUT"'

# --- up --profile ai preflight: stale chat model (model names with ./:/) -----------
set_llmodel '{model:"huihui_ai/llama3.2:q4"}'
write_llcfg "llama3.2:3b"     # YAML stamped with a DIFFERENT model
: > "$STUB_LOG"
OUT="$(runner "$WCLI/up.sh" --profile ai)"; rc=$?
check "up --profile ai: stale chat model -> err"    '[[ $rc -ne 0 ]] && grep -q "stale" <<<"$OUT"'
check "up --profile ai: stale -> 0 docker"          '! grep -q "STUB docker" "$STUB_LOG"'

# --- up --profile ai preflight: config has embed, YAML has none --------------------
set_llmodel '{model:"llama3.2:3b",embeddingModel:"nomic-embed-text"}'
write_llcfg "llama3.2:3b"     # no embed route
: > "$STUB_LOG"
OUT="$(runner "$WCLI/up.sh" --profile ai)"; rc=$?
check "up --profile ai: embed in config, none in YAML -> err" '[[ $rc -ne 0 ]] && grep -q "stale" <<<"$OUT"'

# --- up --profile ai preflight: YAML has embed, config has none --------------------
set_llmodel '{model:"llama3.2:3b"}'
write_llcfg "llama3.2:3b" "nomic-embed-text"   # embed route present
: > "$STUB_LOG"
OUT="$(runner "$WCLI/up.sh" --profile ai)"; rc=$?
check "up --profile ai: embed in YAML, none in config -> err" '[[ $rc -ne 0 ]] && grep -q "stale" <<<"$OUT"'

# --- up --profile ai preflight: stale embed VALUE ----------------------------------
set_llmodel '{model:"llama3.2:3b",embeddingModel:"mxbai-embed-large"}'
write_llcfg "llama3.2:3b" "nomic-embed-text"   # embed route has the OLD value
: > "$STUB_LOG"
OUT="$(runner "$WCLI/up.sh" --profile ai)"; rc=$?
check "up --profile ai: stale embed value -> err"   '[[ $rc -ne 0 ]] && grep -q "stale" <<<"$OUT"'

# --- up --profile ai preflight: no ollama_chat route at all ------------------------
set_llmodel '{model:"llama3.2:3b"}'
printf 'model_list:\n  - model_name: local\n    litellm_params:\n      model: openai/gpt\n' > "$LLCFG_RT/config.yaml"
: > "$STUB_LOG"
OUT="$(runner "$WCLI/up.sh" --profile ai)"; rc=$?
check "up --profile ai: no ollama_chat route -> err" '[[ $rc -ne 0 ]] && grep -q "no ollama_chat route" <<<"$OUT"'

# --- up --profile ai: all preflights pass (chat-only) -> brings up the real stack --
set_llmodel '{model:"llama3.2:3b"}'
write_llcfg "llama3.2:3b"
: > "$STUB_LOG"
OUT="$(COMPOSE_PROFILES=ai runner "$WCLI/up.sh" --profile ai)"; rc=$?
check "up --profile ai (chat-only): exit 0"          '[[ $rc -eq 0 ]]'
check "up --profile ai: invokes local compose --profile ai up" \
      'grep -q "etc/local-llm/docker-compose.yml --profile ai up -d" "$STUB_LOG"'
check "up --profile ai: COMPOSE_PROFILES cleared on the call" \
      'grep -q "etc/local-llm.*COMPOSE_PROFILES=\]" "$STUB_LOG"'

# --- dispatcher forwarding: the REAL user path is `./system.sh up --profile ...`, so
#     prove system.sh forwards "$@" verbatim (a dispatcher dropping args would pass
#     every direct-script test above yet break the actual command). Drive through
#     $WSYS for both a forwarded SUCCESS (ai-mock, stack installed) and a forwarded
#     usage error (invalid profile reaching up's grammar). (R7 arg-forwarding, R10) --
set_llmodel ""
: > "$STUB_LOG"
OUT="$(COMPOSE_PROFILES=ai runner "$WSYS" up --profile ai-mock)"; rc=$?
check "dispatcher: system.sh forwards --profile ai-mock to up" \
      '[[ $rc -eq 0 ]] && grep -q "etc/local-llm/docker-compose.yml --profile ai-mock up -d" "$STUB_LOG"'
OUT="$(runner "$WSYS" up --profile bogus)"; rc=$?
check "dispatcher: forwarded invalid profile -> up usage exit 64" \
      '[[ $rc -eq 64 ]] && grep -q "usage:" <<<"$OUT"'
OUT="$(runner "$WSYS" down --profile ai)"; rc=$?
check "dispatcher: system.sh forwards down --profile ai (tears down both)" \
      '[[ $rc -eq 0 ]]'

# --- up --profile ai: all preflights pass (chat + embeddings) ----------------------
set_llmodel '{model:"llama3.2:3b",embeddingModel:"nomic-embed-text"}'
write_llcfg "llama3.2:3b" "nomic-embed-text"
: > "$STUB_LOG"
OUT="$(runner "$WCLI/up.sh" --profile ai)"; rc=$?
check "up --profile ai (chat+embed): exit 0 + compose up" \
      '[[ $rc -eq 0 ]] && grep -q "etc/local-llm/docker-compose.yml --profile ai up -d" "$STUB_LOG"'

# --- up --profile ai: a compose failure propagates as non-zero (R13) ---------------
set_llmodel '{model:"llama3.2:3b"}'
write_llcfg "llama3.2:3b"
cat > "$STUBBIN/docker" <<'STUB'
#!/usr/bin/env bash
echo "STUB docker $*" >> "${STUB_LOG:-/dev/null}"
# Fail only the local-llm compose up (simulate a model-pull / bring-up failure).
case "$*" in
  *etc/local-llm*up*) exit 7 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$STUBBIN/docker"
: > "$STUB_LOG"
OUT="$(runner "$WCLI/up.sh" --profile ai)"; rc=$?
check "up --profile ai: compose/model-pull failure -> non-zero (R13)" '[[ $rc -ne 0 ]]'
# Restore the recording (always-succeed) stub.
cat > "$STUBBIN/docker" <<'STUB'
#!/usr/bin/env bash
echo "STUB docker $* [COMPOSE_PROFILES=${COMPOSE_PROFILES-<unset>}]" >> "${STUB_LOG:-/dev/null}"
exit 0
STUB
chmod +x "$STUBBIN/docker"

# --- down: NOT profile-gated — always tears down the stack (both profiles) ---------
# Config.yaml ABSENT must still succeed (down needs no generated config).
set_llmodel '{model:"llama3.2:3b"}'
rm -f "$LLCFG_RT/config.yaml"
: > "$STUB_LOG"
OUT="$(runner "$WCLI/down.sh")"; rc=$?
check "down (default): tears down local-llm under both profiles" \
      '[[ $rc -eq 0 ]] && grep -q "etc/local-llm/docker-compose.yml --profile ai --profile ai-mock down" "$STUB_LOG"'
check "down: succeeds with generated config.yaml absent" '[[ $rc -eq 0 ]]'
check "down: COMPOSE_PROFILES cleared on the teardown call" \
      'grep -q "etc/local-llm.*COMPOSE_PROFILES=\]" "$STUB_LOG"'

# down mirrors up's grammar as no-ops: a profile arg (and duplicates / both) is
# accepted but does not change the teardown (always both).
: > "$STUB_LOG"
OUT="$(runner "$WCLI/down.sh" --profile ai --profile ai --profile ai-mock)"; rc=$?
check "down --profile (dups + both) -> still tears down both, exit 0" \
      '[[ $rc -eq 0 ]] && grep -q "etc/local-llm/docker-compose.yml --profile ai --profile ai-mock down" "$STUB_LOG"'

# down tolerates a malformed (wrong-typed) localLlm via the type-safe export.
set_llmodel '["not","an","object"]'
: > "$STUB_LOG"
OUT="$(runner "$WCLI/down.sh")"; rc=$?
check "down: wrong-typed localLlm tolerated (no jq crash)" \
      '[[ $rc -eq 0 ]] && ! grep -qi "jq:" <<<"$OUT"'

# down with config.json ABSENT (export yields empty, no jq error) still tears down.
mv "$WORK/config.json" "$WORK/config.json.bak"
: > "$STUB_LOG"
OUT="$(runner "$WCLI/down.sh")"; rc=$?
check "down: config.json absent -> empty export, still tears down" \
      '[[ $rc -eq 0 ]] && grep -q "etc/local-llm/docker-compose.yml --profile ai --profile ai-mock down" "$STUB_LOG"'
mv "$WORK/config.json.bak" "$WORK/config.json"

# Restore a clean config.json + remove the local-llm stack so later sections are
# unaffected (migrate/psql don't touch it, but keep the work tree tidy).
set_llmodel ""
rm -rf "$LLDIR_RT"

echo "== migrate subcommand — dotnet STUBBED, env-gated branches =="
# migrate.sh: (1) missing src/DataAccess/.env -> exit 64; (2) .env present but no
# MIGRATOR_CONNECTION_STRING -> exit 64; (3) full env -> runs (stubbed) dotnet.
rm -f "$WORK/src/DataAccess/.env"
OUT="$(runner "$WCLI/migrate.sh")"; rc=$?
check "migrate: missing .env -> exit 64" '[[ $rc -eq 64 ]] && grep -q "run .*build-config" <<<"$OUT"'
mkdir -p "$WORK/src/DataAccess"; printf 'OTHER=x\n' > "$WORK/src/DataAccess/.env"
OUT="$(runner "$WCLI/migrate.sh")"; rc=$?
check "migrate: .env without MIGRATOR_CONNECTION_STRING -> exit 64" '[[ $rc -eq 64 ]]'
printf 'MIGRATOR_CONNECTION_STRING=Host=localhost;Username=migrator\n' > "$WORK/src/DataAccess/.env"
: > "$STUB_LOG"
OUT="$(runner "$WCLI/migrate.sh")"; rc=$?
check "migrate: full env -> exit 0 + dotnet ef invoked" '[[ $rc -eq 0 ]] && grep -q "ef database update" "$STUB_LOG"'

echo "== psql subcommand — psql STUBBED, config-driven connection =="
# psql.sh execs `psql`; stub it to record argv + PGPASSWORD and exit 0 so we assert
# the constructed connection (host/port/role/db from config.json) and that the
# password travels via the environment, never on the argv. jq stays real (config
# reads). The scaffold config.json's role passwords are the __SCAFFOLD_GEN_URLSAFE__
# placeholder — URL-safe, so it reads back unchanged here.
cat > "$STUBBIN/psql" <<'STUB'
#!/usr/bin/env bash
echo "STUB psql $*" >> "${STUB_LOG:-/dev/null}"
echo "PGPASSWORD=${PGPASSWORD:-}" >> "${STUB_LOG:-/dev/null}"
exit 0
STUB
chmod +x "$STUBBIN/psql"

# Branch: missing database arg -> usage, exit 64.
OUT="$(runner "$WCLI/psql.sh")"; rc=$?
check "psql: missing database -> exit 64"          '[[ $rc -eq 64 ]] && grep -q "usage:" <<<"$OUT"'

# Branch: valid db -> exec psql as migrator against configured host/port/db.
: > "$STUB_LOG"
OUT="$(runner "$WCLI/psql.sh" platform)"; rc=$?
check "psql: connects as migrator to the named db" '[[ $rc -eq 0 ]] && grep -q "U migrator" "$STUB_LOG" && grep -q "d platform" "$STUB_LOG"'
check "psql: targets configured host/port"         'grep -q "h 127.0.0.1" "$STUB_LOG" && grep -q "p 5432" "$STUB_LOG"'
check "psql: password passed via PGPASSWORD env"   'grep -q "PGPASSWORD=__SCAFFOLD_GEN_URLSAFE__" "$STUB_LOG"'

# Branch: --role api -> connects as the api role (api_password).
: > "$STUB_LOG"
OUT="$(runner "$WCLI/psql.sh" --role api platform)"; rc=$?
check "psql: --role api connects as api"           '[[ $rc -eq 0 ]] && grep -q "U api" "$STUB_LOG"'

# Branch: passthrough args after the db name reach psql verbatim.
: > "$STUB_LOG"
OUT="$(runner "$WCLI/psql.sh" platform -c "SELECT 1")"; rc=$?
check "psql: forwards passthrough args to psql"    '[[ $rc -eq 0 ]] && grep -q "c SELECT 1" "$STUB_LOG"'

# Branch: owner is NOLOGIN -> exit 64.
OUT="$(runner "$WCLI/psql.sh" --role owner platform)"; rc=$?
check "psql: --role owner rejected -> exit 64"     '[[ $rc -eq 64 ]] && grep -q "NOLOGIN" <<<"$OUT"'

# Branch: invalid role -> exit 64.
OUT="$(runner "$WCLI/psql.sh" --role bogus platform)"; rc=$?
check "psql: invalid --role -> exit 64"            '[[ $rc -eq 64 ]]'

# Branch: unknown flag -> exit 64.
OUT="$(runner "$WCLI/psql.sh" --bogus platform)"; rc=$?
check "psql: unknown flag -> exit 64"              '[[ $rc -eq 64 ]]'

# Branch: invalid database name -> exit 64.
OUT="$(runner "$WCLI/psql.sh" "bad;name")"; rc=$?
check "psql: invalid db name -> exit 64"           '[[ $rc -eq 64 ]]'

# Branch: missing --config file -> exit 64.
OUT="$(runner "$WCLI/psql.sh" --config /nonexistent.json platform)"; rc=$?
check "psql: missing --config file -> exit 64"     '[[ $rc -eq 64 ]]'

rm -f "$STUBBIN/psql"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

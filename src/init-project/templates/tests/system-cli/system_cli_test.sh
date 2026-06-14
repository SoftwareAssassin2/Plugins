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
WBC="$WORK/src/system-cli/build-config.sh"

echo "== dispatcher contract =="
OUT="$( cd "$WORK" && bash "$WSYS" help 2>&1 )"; rc=$?
check "valid subcommand dispatches (help exit 0)" '[[ $rc -eq 0 ]]'
check "help lists subcommands + descriptions"     'grep -q "Available commands:" <<<"$OUT" && grep -q "build-config" <<<"$OUT"'

OUT="$( cd "$WORK" && bash "$WSYS" 2>&1 )"; rc=$?
check "no subcommand -> exit 64"                  '[[ $rc -eq 64 ]]'
check "no subcommand -> usage on stderr"          'grep -q "usage:" <<<"$OUT"'

OUT="$( cd "$WORK" && bash "$WSYS" _private 2>&1 )"; rc=$?
check "underscore subcommand -> exit 64"          '[[ $rc -eq 64 ]]'
check "underscore error pinned ERROR: '\''<sub>'\''" '[[ "$OUT" == "ERROR: '\''_private'\'' is a private helper"* ]]'

OUT="$( cd "$WORK" && bash "$WSYS" nope 2>&1 )"; rc=$?
check "unknown subcommand -> exit 127"            '[[ $rc -eq 127 ]]'

# Underscore helpers are hidden from help.
cat > "$WORK/src/system-cli/_hidden.sh" <<'HID'
#!/usr/bin/env bash
# Description: never shown.
echo x
HID
chmod +x "$WORK/src/system-cli/_hidden.sh"
OUT="$( cd "$WORK" && bash "$WSYS" help 2>&1 )"
check "help hides underscore helpers"             '! grep -q "_hidden" <<<"$OUT"'
rm -f "$WORK/src/system-cli/_hidden.sh"

# No-description fallback.
cat > "$WORK/src/system-cli/nodesc.sh" <<'ND'
#!/usr/bin/env bash
echo x
ND
chmod +x "$WORK/src/system-cli/nodesc.sh"
OUT="$( cd "$WORK" && bash "$WSYS" help 2>&1 )"
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

echo "== build-config: distribution =="
OUT="$( cd "$WORK" && bash "$WBC" 2>&1 )"; rc=$?
check "build-config succeeds"            '[[ $rc -eq 0 ]]'
check "writes src/postgres/.env"         '[[ -f "$WORK/src/postgres/.env" ]]'
check "DataAccess migrator conn string"  'grep -q "MIGRATOR_CONNECTION_STRING=.*Username=migrator" "$WORK/src/DataAccess/.env"'
check "Api api-role conn + keycloak"     'grep -q "API_CONNECTION_STRING=.*Username=api" "$WORK/src/Api/.env" && grep -q "KEYCLOAK_API_CLIENT_SECRET=" "$WORK/src/Api/.env"'
check "stamps SPA public config (non-secret)" 'jq -e "(keys|sort)==[\"clientId\",\"realmUrl\"]" "$WORK/src/WebApp/public/config.json" >/dev/null'

OUT="$( cd "$WORK" && bash "$WBC" --config "$WORK/config.json" 2>&1 )"; rc=$?
check "--config <path> accepted"         '[[ $rc -eq 0 ]]'

OUT="$( cd "$WORK" && bash "$WBC" --config /nonexistent.json 2>&1 )"; rc=$?
check "missing --config file -> exit 64" '[[ $rc -eq 64 ]]'

OUT="$( cd "$WORK" && bash "$WBC" --bogus 2>&1 )"; rc=$?
check "unknown flag -> exit 64"          '[[ $rc -eq 64 ]]'

# Reject: out-of-alphabet secret.
BAD="$WORK/bad.json"
jq '(.systems[] | select(.name=="postgres") | .owner_password)="bad=secret"' "$WORK/config.json" > "$BAD"
OUT="$( cd "$WORK" && bash "$WBC" --config "$BAD" 2>&1 )"; rc=$?
check "out-of-alphabet secret -> exit 64" '[[ $rc -eq 64 ]]'

# Reject: bad port.
BADP="$WORK/badport.json"
jq '(.systems[] | select(.name=="Api") | .port)=99999' "$WORK/config.json" > "$BADP"
OUT="$( cd "$WORK" && bash "$WBC" --config "$BADP" 2>&1 )"; rc=$?
check "out-of-range port -> exit 64"      '[[ $rc -eq 64 ]]'

# Reject: raw deploy template ({{VAR}}).
if [[ -f "$ROOT/config.deploy.json" ]]; then
  OUT="$( cd "$WORK" && bash "$WBC" --config "$ROOT/config.deploy.json" 2>&1 )"; rc=$?
  check "raw deploy template -> exit 64"  '[[ $rc -eq 64 ]]'
fi

# External service credential exempt (opaque api_key with /+= passes).
OPAQUE="$WORK/opaque.json"
jq '.services."claude-api".api_key="sk-a/b+c=d"' "$WORK/config.json" > "$OPAQUE"
OUT="$( cd "$WORK" && bash "$WBC" --config "$OPAQUE" 2>&1 )"; rc=$?
check "external service cred exempt"      '[[ $rc -eq 0 ]]'

echo "== build-config: realm-stamp mechanism =="
if [[ -f "$ROOT/src/keycloak/realm.template.json" ]]; then
  cp -R "$ROOT/src/keycloak" "$WORK/src/keycloak" 2>/dev/null || true
  mkdir -p "$WORK/src/keycloak/import"
  touch "$WORK/src/keycloak/import/stale-realm.json"
  OUT="$( cd "$WORK" && bash "$WBC" 2>&1 )"; rc=$?
  REALM="$(jq -r '(.systems[] | select(.name=="keycloak") | .realm)' "$WORK/config.json")"
  check "realm import stamped"            '[[ $rc -eq 0 ]] && [[ -f "$WORK/src/keycloak/import/$REALM-realm.json" ]]'
  check "stale prior realm import removed" '[[ ! -f "$WORK/src/keycloak/import/stale-realm.json" ]]'
else
  # No realm template yet (owned by the keycloak task) — stamping must skip cleanly.
  OUT="$( cd "$WORK" && bash "$WBC" 2>&1 )"; rc=$?
  check "no realm template -> stamp skipped" '[[ $rc -eq 0 ]] && grep -q "skipping realm stamp" <<<"$OUT"'
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

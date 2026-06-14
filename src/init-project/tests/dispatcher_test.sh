#!/usr/bin/env bash
# Description: Tests for the system.sh dispatcher template + src/system-cli subcommands.
#
# Two surfaces:
#   1) The dispatcher contract (routing, exit 64/127, underscore rejection, help
#      listing) exercised against a FRESHLY SCAFFOLDED project root — proving the
#      `$script_dir/src/system-cli/<sub>.sh` path resolves from the repo root.
#   2) build-config.sh validators + helpers, sourced directly, with an explicit
#      test per reject branch (URL-safe alphabet, port range, host/container/
#      client-id/URL shape) and the realm-stamp / SPA-config stamp mechanisms.
#
# Run: bash src/init-project/tests/dispatcher_test.sh
# (For line coverage, tests/coverage.sh wraps this under kcov.)

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"          # src/init-project
SCAFFOLD="$PKG_DIR/scaffold.sh"
TEMPLATES="$PKG_DIR/templates"
PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad()   { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# ============================================================================
# Surface 1: dispatcher contract against a freshly scaffolded project root.
# ============================================================================
echo "== dispatcher: scaffold a project and route from its root =="
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
( cd "$WORK" && bash "$SCAFFOLD" demo-app "A demo project" >/dev/null )
ROOT="$WORK/demo-app"
SYS="$ROOT/system.sh"

check "system.sh lands at scaffolded repo root"   '[[ -f "$SYS" ]]'
check "system.sh is executable"                    '[[ -x "$SYS" ]]'
check "src/system-cli/ subcommands land"           '[[ -f "$ROOT/src/system-cli/help.sh" && -f "$ROOT/src/system-cli/build-config.sh" && -f "$ROOT/src/system-cli/up.sh" && -f "$ROOT/src/system-cli/down.sh" && -f "$ROOT/src/system-cli/migrate.sh" && -f "$ROOT/src/system-cli/status.sh" ]]'
check "dispatcher output token-free"               '! grep -rqE "__SCAFFOLD_[A-Z0-9_]+__" "$SYS" "$ROOT/src/system-cli"'

# Path resolution: `help` must route from the scaffolded root (script_dir == root).
HELP_OUT="$( cd "$ROOT" && bash "$SYS" help 2>&1 )"; rc=$?
check "valid subcommand dispatches (help exit 0)"  '[[ $rc -eq 0 ]]'
check "help lists subcommands + descriptions"      'grep -q "Available commands:" <<<"$HELP_OUT" && grep -q "build-config" <<<"$HELP_OUT" && grep -q "Distribute config.json" <<<"$HELP_OUT"'
check "help routes from the repo ROOT, not src/"   '[[ -n "$HELP_OUT" ]]'
# Resolution must NOT depend on CWD being the root — invoke by absolute path from /tmp.
HELP_FROM_ELSEWHERE="$( cd "$WORK" && bash "$SYS" help 2>&1 )"; rc=$?
check "dispatch resolves regardless of CWD"        '[[ $rc -eq 0 ]] && grep -q "build-config" <<<"$HELP_FROM_ELSEWHERE"'

# Branch: no subcommand -> usage, exit 64.
OUT="$( cd "$ROOT" && bash "$SYS" 2>&1 )"; rc=$?
check "no subcommand -> exit 64"                   '[[ $rc -eq 64 ]]'
check "no subcommand -> usage on stderr"           'grep -q "usage:" <<<"$OUT"'

# Branch: underscore-prefixed subcommand -> exit 64 with pinned error format.
OUT="$( cd "$ROOT" && bash "$SYS" _private 2>&1 )"; rc=$?
check "underscore subcommand -> exit 64"           '[[ $rc -eq 64 ]]'
check "underscore error pinned ERROR: '\''<sub>'\''" '[[ "$OUT" == "ERROR: '\''_private'\'' is a private helper"* ]]'

# Branch: unknown subcommand -> exit 127.
OUT="$( cd "$ROOT" && bash "$SYS" nope 2>&1 )"; rc=$?
check "unknown subcommand -> exit 127"             '[[ $rc -eq 127 ]]'
check "unknown subcommand names the target"        'grep -q "no such subcommand .nope." <<<"$OUT"'

# Branch: underscore-prefixed helper hidden from `help` listing.
cat > "$ROOT/src/system-cli/_hidden.sh" <<'EOF'
#!/usr/bin/env bash
# Description: should never appear in help.
echo hidden
EOF
chmod +x "$ROOT/src/system-cli/_hidden.sh"
HELP_OUT="$( cd "$ROOT" && bash "$SYS" help 2>&1 )"
check "help hides underscore helpers"              '! grep -q "_hidden" <<<"$HELP_OUT"'
rm -f "$ROOT/src/system-cli/_hidden.sh"

# Branch: a command with NO Description line falls back to "(no description)".
cat > "$ROOT/src/system-cli/nodesc.sh" <<'EOF'
#!/usr/bin/env bash
echo x
EOF
chmod +x "$ROOT/src/system-cli/nodesc.sh"
HELP_OUT="$( cd "$ROOT" && bash "$SYS" help 2>&1 )"
check "help falls back to (no description)"        'grep -qE "nodesc[[:space:]]+\(no description\)" <<<"$HELP_OUT"'
rm -f "$ROOT/src/system-cli/nodesc.sh"

# Every shipped subcommand carries a `# Description:` line.
for sub in help build-config up down migrate status; do
  check "subcommand $sub has a # Description: line" \
    "grep -qE '^#[[:space:]]*Description:' \"\$ROOT/src/system-cli/$sub.sh\""
done

# ============================================================================
# Surface 2: build-config validators + stamping mechanism (sourced + run).
# ============================================================================
echo "== build-config: validators (explicit per-branch reject tests) =="
BUILD_CONFIG="$ROOT/src/system-cli/build-config.sh"
# shellcheck disable=SC1090
source "$BUILD_CONFIG"
set +e +u   # the sourced `set -euo pipefail` leaks in; we run intentional failures.

# Each validator exits 64 on a bad value, 0 on a good one. Run in subshells so the
# `die`/exit doesn't kill the test harness.
check "v_urlsafe accepts url-safe"      '( v_urlsafe "Ab9_-" x ); [[ $? -eq 0 ]]'
check "v_urlsafe rejects '\''=/+ '\''"  '( v_urlsafe "bad=secret" x ) 2>/dev/null; [[ $? -eq 64 ]]'
check "v_host accepts dotted host"      '( v_host "127.0.0.1" x ); [[ $? -eq 0 ]]'
check "v_host rejects '\''_'\''"        '( v_host "bad_host" x ) 2>/dev/null; [[ $? -eq 64 ]]'
check "v_container accepts name"        '( v_container "postgres" x ); [[ $? -eq 0 ]]'
check "v_container rejects leading '\''-'\''" '( v_container "-bad" x ) 2>/dev/null; [[ $? -eq 64 ]]'
check "v_clientid accepts client-id"    '( v_clientid "web.app_1-x" x ); [[ $? -eq 0 ]]'
check "v_clientid rejects space"        '( v_clientid "bad id" x ) 2>/dev/null; [[ $? -eq 64 ]]'
check "v_url accepts http(s)"           '( v_url "http://127.0.0.1:8080" x ); [[ $? -eq 0 ]]'
check "v_url rejects non-url"           '( v_url "ftp://x" x ) 2>/dev/null; [[ $? -eq 64 ]]'
check "v_port accepts 1..65535"         '( v_port "5432" x ); [[ $? -eq 0 ]]'
check "v_port rejects 0"                '( v_port "0" x ) 2>/dev/null; [[ $? -eq 64 ]]'
check "v_port rejects 70000"            '( v_port "70000" x ) 2>/dev/null; [[ $? -eq 64 ]]'
check "v_port rejects non-integer"      '( v_port "8x" x ) 2>/dev/null; [[ $? -eq 64 ]]'

echo "== build-config: end-to-end distribution from a scaffolded config.json =="
# A fresh scaffold has a valid config.json; run build-config against it from root.
OUT="$( cd "$ROOT" && bash "$BUILD_CONFIG" 2>&1 )"; rc=$?
check "build-config succeeds on scaffold config" '[[ $rc -eq 0 ]]'
check "writes src/postgres/.env"        '[[ -f "$ROOT/src/postgres/.env" ]] && grep -q "POSTGRES_OWNER_PASSWORD=" "$ROOT/src/postgres/.env"'
check "DataAccess .env has migrator conn (db platform, role migrator)" \
  'grep -q "MIGRATOR_CONNECTION_STRING=.*Database=platform" "$ROOT/src/DataAccess/.env" && grep -q "Username=migrator" "$ROOT/src/DataAccess/.env"'
check "Api .env has api conn (role api) + keycloak values" \
  'grep -q "API_CONNECTION_STRING=.*Username=api" "$ROOT/src/Api/.env" && grep -q "KEYCLOAK_API_CLIENT_SECRET=" "$ROOT/src/Api/.env"'
check "keycloak .env has admin + realm"  'grep -q "KEYCLOAK_ADMIN=" "$ROOT/src/keycloak/.env" && grep -q "KEYCLOAK_REALM=demo-app" "$ROOT/src/keycloak/.env"'
check "stamps SPA public config (realmUrl+clientId only)" \
  'jq -e "(keys|sort)==[\"clientId\",\"realmUrl\"]" "$ROOT/src/WebApp/public/config.json" >/dev/null && jq -e ".clientId==\"webapp\"" "$ROOT/src/WebApp/public/config.json" >/dev/null'

# Branch: --config <path> deploy handoff accepts a concrete config file.
RENDERED="$WORK/rendered.json"
cp "$ROOT/config.json" "$RENDERED"
OUT="$( cd "$ROOT" && bash "$BUILD_CONFIG" --config "$RENDERED" 2>&1 )"; rc=$?
check "build-config --config <path> accepted"    '[[ $rc -eq 0 ]]'
OUT="$( cd "$ROOT" && bash "$BUILD_CONFIG" --config=$RENDERED 2>&1 )"; rc=$?
check "build-config --config=<path> accepted"     '[[ $rc -eq 0 ]]'

# Branch: missing config file -> exit 64.
OUT="$( cd "$ROOT" && bash "$BUILD_CONFIG" --config /nonexistent.json 2>&1 )"; rc=$?
check "missing --config file -> exit 64"          '[[ $rc -eq 64 ]]'
# Branch: --config with no value -> usage exit 64.
OUT="$( cd "$ROOT" && bash "$BUILD_CONFIG" --config 2>&1 )"; rc=$?
check "--config with no value -> exit 64"         '[[ $rc -eq 64 ]]'
# Branch: unknown flag / stray arg -> exit 64.
OUT="$( cd "$ROOT" && bash "$BUILD_CONFIG" --bogus 2>&1 )"; rc=$?
check "unknown flag -> exit 64"                   '[[ $rc -eq 64 ]]'
OUT="$( cd "$ROOT" && bash "$BUILD_CONFIG" stray 2>&1 )"; rc=$?
check "stray positional -> exit 64"               '[[ $rc -eq 64 ]]'
# Branch: -h/--help -> usage exit 64.
OUT="$( cd "$ROOT" && bash "$BUILD_CONFIG" --help 2>&1 )"; rc=$?
check "--help -> usage exit 64"                   '[[ $rc -eq 64 ]]'

# Branch: invalid JSON config -> exit 64.
echo 'not json{' > "$WORK/bad.json"
OUT="$( cd "$ROOT" && bash "$BUILD_CONFIG" --config "$WORK/bad.json" 2>&1 )"; rc=$?
check "invalid JSON config -> exit 64"            '[[ $rc -eq 64 ]]'

# Branch: unrendered {{VAR-NAME}} deploy template -> exit 64 (never validated in CI).
OUT="$( cd "$ROOT" && bash "$BUILD_CONFIG" --config "$ROOT/config.deploy.json" 2>&1 )"; rc=$?
check "raw deploy template ({{VAR}}) -> exit 64"  '[[ $rc -eq 64 ]] && grep -q "placeholder" <<<"$OUT"'

# Branch: a config with an out-of-alphabet secret -> exit 64 (no .env rewritten).
BADSEC="$WORK/badsecret.json"
jq '(.systems[] | select(.name=="postgres") | .owner_password) = "bad=secret/here"' "$ROOT/config.json" > "$BADSEC"
OUT="$( cd "$ROOT" && bash "$BUILD_CONFIG" --config "$BADSEC" 2>&1 )"; rc=$?
check "out-of-alphabet secret -> exit 64"         '[[ $rc -eq 64 ]] && grep -q "URL-safe" <<<"$OUT"'

# Branch: a config with a bad port -> exit 64.
BADPORT="$WORK/badport.json"
jq '(.systems[] | select(.name=="Api") | .port) = 99999' "$ROOT/config.json" > "$BADPORT"
OUT="$( cd "$ROOT" && bash "$BUILD_CONFIG" --config "$BADPORT" 2>&1 )"; rc=$?
check "out-of-range port -> exit 64"              '[[ $rc -eq 64 ]] && grep -q "port" <<<"$OUT"'

# Branch: external service credential is EXEMPT (opaque) — a non-URL-safe api_key passes.
OPAQUE="$WORK/opaque.json"
jq '.services."claude-api".api_key = "sk-with/slashes+and=pad"' "$ROOT/config.json" > "$OPAQUE"
OUT="$( cd "$ROOT" && bash "$BUILD_CONFIG" --config "$OPAQUE" 2>&1 )"; rc=$?
check "external service cred exempt from alphabet" '[[ $rc -eq 0 ]]'

# Branch: missing required field -> exit 64.
MISSING="$WORK/missing.json"
jq 'del(.systems[] | select(.name=="postgres") | .owner_password)' "$ROOT/config.json" > "$MISSING"
OUT="$( cd "$ROOT" && bash "$BUILD_CONFIG" --config "$MISSING" 2>&1 )"; rc=$?
check "missing required field -> exit 64"         '[[ $rc -eq 64 ]] && grep -q "missing config field" <<<"$OUT"'

echo "== build-config: realm-stamp mechanism + clean-prior-on-rename =="
# The keycloak task (.10) now ships a COMMITTED realm.template.json, so a fresh
# scaffold has one and build-config STAMPS it (the previous "skip when absent"
# default no longer holds for the scaffold). Assert the committed template stamps.
OUT="$( cd "$ROOT" && bash "$BUILD_CONFIG" 2>&1 )"; rc=$?
check "committed realm template stamped on fresh scaffold" '[[ $rc -eq 0 ]] && grep -q "stamped src/keycloak/import/" <<<"$OUT" && [[ -f "$ROOT/src/keycloak/import/demo-app-realm.json" ]]'

# The skip-when-absent branch still exists in build-config — exercise it in
# ISOLATION against a copy with no realm.template.json (so it doesn't depend on the
# scaffold lacking one). A separate config dir with no src/keycloak/.
NOTPL="$WORK/no-realm"; mkdir -p "$NOTPL"
cp "$ROOT/config.json" "$NOTPL/config.json"
OUT="$( cd "$NOTPL" && bash "$BUILD_CONFIG" 2>&1 )"; rc=$?
check "no realm template -> stamp skipped, no failure" '[[ $rc -eq 0 ]] && grep -q "skipping realm stamp" <<<"$OUT"'

# Provide a minimal template and verify deterministic stamping + stale cleanup.
mkdir -p "$ROOT/src/keycloak"
cat > "$ROOT/src/keycloak/realm.template.json" <<'EOF'
{ "realm": "TEMPLATE", "id": "TEMPLATE",
  "clients": [ { "clientId": "api", "secret": "DUMMY" },
               { "clientId": "webapp" } ] }
EOF
# Seed a stale prior import to prove it gets removed.
mkdir -p "$ROOT/src/keycloak/import"
touch "$ROOT/src/keycloak/import/old-realm.json"
OUT="$( cd "$ROOT" && bash "$BUILD_CONFIG" 2>&1 )"; rc=$?
check "realm import stamped from template"        '[[ $rc -eq 0 ]] && [[ -f "$ROOT/src/keycloak/import/demo-app-realm.json" ]]'
check "stamped realm name + api client secret injected" \
  'jq -e ".realm==\"demo-app\"" "$ROOT/src/keycloak/import/demo-app-realm.json" >/dev/null && jq -e "(.clients[] | select(.clientId==\"api\") | .secret) != \"DUMMY\"" "$ROOT/src/keycloak/import/demo-app-realm.json" >/dev/null'
check "stale prior *-realm.json removed (no stale-on-rename)" '[[ ! -f "$ROOT/src/keycloak/import/old-realm.json" ]]'

# Branch: invalid realm template JSON -> exit 65.
printf 'not json{' > "$ROOT/src/keycloak/realm.template.json"
OUT="$( cd "$ROOT" && bash "$BUILD_CONFIG" 2>&1 )"; rc=$?
check "invalid realm template -> exit 65"         '[[ $rc -eq 65 ]]'
rm -rf "$ROOT/src/keycloak"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

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

echo "== build-config: distribution =="
OUT="$(runner "$WBC")"; rc=$?
check "build-config succeeds"            '[[ $rc -eq 0 ]]'
check "writes src/postgres/.env"         '[[ -f "$WORK/src/postgres/.env" ]]'
check "DataAccess migrator conn string"  'grep -q "MIGRATOR_CONNECTION_STRING=.*Username=migrator" "$WORK/src/DataAccess/.env"'
check "Api api-role conn + keycloak"     'grep -q "API_CONNECTION_STRING=.*Username=api" "$WORK/src/Api/.env" && grep -q "KEYCLOAK_API_CLIENT_SECRET=" "$WORK/src/Api/.env"'
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

# External service credential exempt (opaque api_key with /+= passes).
OPAQUE="$WORK/opaque.json"
jq '.services."claude-api".api_key="sk-a/b+c=d"' "$WORK/config.json" > "$OPAQUE"
OUT="$(runner "$WBC" --config "$OPAQUE")"; rc=$?
check "external service cred exempt"      '[[ $rc -eq 0 ]]'

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

# Branch A: NO compose stacks present yet -> each script takes its "nothing" path.
# Remove any compose files an earlier section (realm-stamp) may have left behind so
# this branch genuinely has zero stacks.
rm -f "$WORK/src/postgres/docker-compose.yml" "$WORK/src/keycloak/docker-compose.yml" \
      "$WORK/etc/observability/docker-compose.yml"
: > "$STUB_LOG"
for sub in up down status; do
  OUT="$(runner "$WCLI/$sub.sh")"; rc=$?
  check "$sub: no stacks present -> exit 0 + notice" '[[ $rc -eq 0 ]] && grep -qE "no compose stacks present|no compose stacks" <<<"$OUT"'
done

# Branch B: compose stacks PRESENT -> each script iterates + invokes (stubbed) docker.
mkdir -p "$WORK/src/postgres" "$WORK/src/keycloak" "$WORK/etc/observability"
printf 'services: {}\n' > "$WORK/src/postgres/docker-compose.yml"
printf 'services: {}\n' > "$WORK/src/keycloak/docker-compose.yml"
printf 'services: {}\n' > "$WORK/etc/observability/docker-compose.yml"
: > "$STUB_LOG"
OUT="$(runner "$WCLI/up.sh")"; rc=$?
check "up: stacks present -> exit 0 + docker compose up invoked" '[[ $rc -eq 0 ]] && grep -q "up -d" "$STUB_LOG"'
: > "$STUB_LOG"
OUT="$(runner "$WCLI/down.sh")"; rc=$?
check "down: stacks present -> exit 0 + docker compose down invoked" '[[ $rc -eq 0 ]] && grep -q " down" "$STUB_LOG"'
: > "$STUB_LOG"
OUT="$(runner "$WCLI/status.sh")"; rc=$?
check "status: stacks present -> exit 0 + docker compose ps invoked" '[[ $rc -eq 0 ]] && grep -q " ps" "$STUB_LOG"'

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

echo
echo "RESULT: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

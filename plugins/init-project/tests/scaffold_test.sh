#!/usr/bin/env bash
# Description: Integration tests for the init-project scaffold engine (scaffold.sh).
#
# Exercises the accepted matrix: scaffold + token/secret substitution, _CLAUDE.md
# mapping, leftover-token gate, manifest ownership, refuse-non-empty, --force
# collision, --update manifest-gating + config.json merge, --replace-config,
# --dry-run, invalid name, and distinct/URL-safe generated secrets.
#
# Run: bash plugins/init-project/tests/scaffold_test.sh
# (For coverage, fn-2 task .6 wraps this under kcov; this file is the harness.)

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCAFFOLD="$SCRIPT_DIR/../scaffold.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# Source for unit-level checks (source-guard prevents main from running).
# shellcheck disable=SC1090
source "$SCAFFOLD"
set +e +u   # scaffold.sh's `set -euo pipefail` leaks into us via source; the test
            # harness intentionally runs commands that exit non-zero, so disable here.

echo "== unit: gen_urlsafe / target_rel =="
s1="$(gen_urlsafe)"; s2="$(gen_urlsafe)"
check "gen_urlsafe url-safe"      '[[ "$s1" =~ ^[A-Za-z0-9_-]+$ ]]'
check "gen_urlsafe distinct"      '[[ "$s1" != "$s2" ]]'
check "target_rel maps _CLAUDE.md" '[[ "$(target_rel _CLAUDE.md)" == "CLAUDE.md" ]]'
check "target_rel passthrough"     '[[ "$(target_rel docs/x.md)" == "docs/x.md" ]]'

run() { ( cd "$WORK" && bash "$SCAFFOLD" "$@" ); }

echo "== integration =="
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# scaffold
run demo-app "A demo project" >/dev/null
check "creates CLAUDE.md (mapped)"        '[[ -f "$WORK/demo-app/CLAUDE.md" && ! -f "$WORK/demo-app/_CLAUDE.md" ]]'
check "name substituted"                  'grep -q "# demo-app" "$WORK/demo-app/CLAUDE.md"'
check "description substituted"           'grep -q "A demo project" "$WORK/demo-app/CLAUDE.md"'
check "no leftover tokens"                '! grep -rqE "__SCAFFOLD_[A-Z0-9_]+__" "$WORK/demo-app"'
check "trailing newline preserved"        '[[ "$(tail -c1 "$WORK/demo-app/config.json")" == "" ]]'
check "manifest valid json"               'jq -e . "$WORK/demo-app/.init-project-manifest.json" >/dev/null'
check "manifest paths relative"           '! jq -r ".files[].path" "$WORK/demo-app/.init-project-manifest.json" | grep -qE "^/|\.\."'
check "claude-api stays REPLACE_ME"       'jq -e ".services.\"claude-api\".api_key==\"REPLACE_ME\"" "$WORK/demo-app/config.json" >/dev/null'

# config.json prepopulated with a systems[] entry for EVERY starter component
STARTER='["Framework","DataAccess","BusinessLogic","Api","MarketingSite","WebApp","postgres","keycloak","SampleApp"]'
check "all starter components in systems[]" 'jq -e --argjson want "$STARTER" "([.systems[].name]) as \$have | (\$want - \$have)==[]" "$WORK/demo-app/config.json" >/dev/null'
check "keycloak public SPA client ids"     'jq -e ".systems[1] | .webapp_client_id==\"webapp\" and .marketingsite_client_id==\"marketingsite\"" "$WORK/demo-app/config.json" >/dev/null'
check "keycloak Api confidential client"   'jq -e ".systems[1] | .api_client_id==\"api\" and (.api_client_secret|test(\"^[A-Za-z0-9_-]+\$\"))" "$WORK/demo-app/config.json" >/dev/null'
check "keycloak realm stamped (name)"      'jq -e ".systems[1].realm==\"demo-app\"" "$WORK/demo-app/config.json" >/dev/null'

# config.deploy.json: shape mirror, {{VAR-NAME}} secrets, identical key-set
check "config.deploy.json valid json"      'jq -e . "$WORK/demo-app/config.deploy.json" >/dev/null'
check "deploy secrets are placeholders"    'jq -e "(.systems[0].owner_password|test(\"^\\\\{\\\\{.*\\\\}\\\\}\$\")) and (.systems[1].api_client_secret|test(\"^\\\\{\\\\{.*\\\\}\\\\}\$\")) and (.services.\"claude-api\".api_key|test(\"^\\\\{\\\\{.*\\\\}\\\\}\$\"))" "$WORK/demo-app/config.deploy.json" >/dev/null'
check "deploy has no scaffold tokens"      '! grep -qE "__SCAFFOLD_[A-Z0-9_]+__" "$WORK/demo-app/config.deploy.json"'
# Key-set parity: recursive sorted leaf-paths must match between the two files.
LP='[paths(scalars==scalars) | map(tostring) | join(".")] | sort'
check "config/deploy key-set parity"       'diff <(jq -S "$LP" "$WORK/demo-app/config.json") <(jq -S "$LP" "$WORK/demo-app/config.deploy.json") >/dev/null'

# config-management standard doc shipped, generalized (no H&G framing)
check "config-management.md present"       '[[ -f "$WORK/demo-app/docs/config-management.md" ]]'
check "config-mgmt: systems/services model" 'grep -q "systems\[\]" "$WORK/demo-app/docs/config-management.md" && grep -q "services{}" "$WORK/demo-app/docs/config-management.md"'
check "config-mgmt: owner/migrator/api"    'grep -q "owner" "$WORK/demo-app/docs/config-management.md" && grep -q "migrator" "$WORK/demo-app/docs/config-management.md"'
check "config-mgmt: url-safe alphabet"     'grep -qF "[A-Za-z0-9_-]+" "$WORK/demo-app/docs/config-management.md"'
check "config-mgmt: no H&G framing"        '! grep -qiE "platform-db|platform-api|flyway|play\.sh|games\[\]|google_oauth|play games|[^a-z]pgs[^a-z]" "$WORK/demo-app/docs/config-management.md"'

# Generalized standards + business-doc stubs + .gitignore (fn-2 task .8). The
# _CLAUDE.md Standards index links these docs; assert the ones .8 authors all land
# in scaffold output (front-end.md is task .12's deliverable, asserted there).
for d in architecture tdd ubiquitous-language keycloak dev-container; do
  check "standard doc docs/$d.md present" "[[ -f \"\$WORK/demo-app/docs/$d.md\" ]]"
done
for d in business strategy customers priorities decisions; do
  check "business stub docs/$d.md present" "[[ -f \"\$WORK/demo-app/docs/$d.md\" ]]"
  check "business stub docs/$d.md is a TODO home" "grep -q '## TODO' \"\$WORK/demo-app/docs/$d.md\""
done
check "no docs/roadmap.md (priorities replaces it)" '[[ ! -f "$WORK/demo-app/docs/roadmap.md" ]]'
check ".gitignore present in scaffold output"       '[[ -f "$WORK/demo-app/.gitignore" ]]'
check ".gitignore ignores .worktrees/ + generated realm" 'grep -q "^\.worktrees/" "$WORK/demo-app/.gitignore" && grep -q "src/keycloak/import/\*-realm.json" "$WORK/demo-app/.gitignore"'
# config.json and .flow/bin/ must stay tracked — assert no ACTIVE ignore rule
# (non-comment, non-blank line) matches them. (Comments mentioning them are fine.)
check ".gitignore keeps config.json + .flow/bin/ tracked" 'RULES=$(grep -vE "^[[:space:]]*(#|$)" "$WORK/demo-app/.gitignore"); ! grep -qE "^config\.json$" <<<"$RULES" && ! grep -qE "\.flow/bin" <<<"$RULES"'

# Root etc/ catch-all folder must ship in a fresh scaffold. Empty dirs are not
# tracked/copyable, so a committed etc/.gitkeep keeps it present (same pattern as
# src/keycloak/import/.gitkeep) — otherwise the etc/ row in the _CLAUDE.md root
# layout would name a directory that never lands.
check "etc/ folder lands via .gitkeep"     '[[ -f "$WORK/demo-app/etc/.gitkeep" ]]'

# .NET starter solution (fn-2 task .9): single src/system.sln + 5 src/<component>/
# projects + a pinned dotnet-ef manifest + per-component tests/ projects, all landing
# in scaffold output token-free. (The actual `dotnet build`/`dotnet ef` smoke is run
# by the worker against a freshly scaffolded copy — it needs the SDK; these are
# structural assertions that don't require dotnet.)
check "src/system.sln present"             '[[ -f "$WORK/demo-app/src/system.sln" ]]'
check "system.sln references all 5 src projects" 'for p in Framework DataAccess BusinessLogic Api SampleApp; do grep -q "$p\\\\$p.csproj" "$WORK/demo-app/src/system.sln" || exit 1; done'
check "system.sln references 4 test projects" 'for p in Framework DataAccess BusinessLogic Api; do grep -q "$p.Tests\\\\$p.Tests.csproj" "$WORK/demo-app/src/system.sln" || exit 1; done'
for p in Framework DataAccess BusinessLogic Api SampleApp; do
  check ".NET project src/$p/$p.csproj present" "[[ -f \"\$WORK/demo-app/src/$p/$p.csproj\" ]]"
done
for p in Framework DataAccess BusinessLogic Api; do
  check "test project tests/$p.Tests present" "[[ -f \"\$WORK/demo-app/tests/$p.Tests/$p.Tests.csproj\" ]]"
  check "tests/$p.Tests wires coverlet.msbuild" "grep -q 'coverlet.msbuild' \"\$WORK/demo-app/tests/$p.Tests/$p.Tests.csproj\""
done
# Layering: project references point one way down the stack (only spot-check the
# load-bearing edges, not every file — don't over-fit to exact contents).
check "Api references BusinessLogic"        'grep -q "BusinessLogic\\\\BusinessLogic.csproj" "$WORK/demo-app/src/Api/Api.csproj"'
check "BusinessLogic references DataAccess" 'grep -q "DataAccess\\\\DataAccess.csproj" "$WORK/demo-app/src/BusinessLogic/BusinessLogic.csproj"'
check "DataAccess references Framework"     'grep -q "Framework\\\\Framework.csproj" "$WORK/demo-app/src/DataAccess/DataAccess.csproj"'
check "DataAccess uses Npgsql EF provider"  'grep -q "Npgsql.EntityFrameworkCore.PostgreSQL" "$WORK/demo-app/src/DataAccess/DataAccess.csproj"'
check "DataAccess references EF Core Design" 'grep -q "Microsoft.EntityFrameworkCore.Design" "$WORK/demo-app/src/DataAccess/DataAccess.csproj"'
check "DataAccess ships a DbContext (UseNpgsql)" 'grep -rq "UseNpgsql" "$WORK/demo-app/src/DataAccess/"'
check "DataAccess ships IDesignTimeDbContextFactory" 'grep -rq "IDesignTimeDbContextFactory" "$WORK/demo-app/src/DataAccess/"'
check "design-time factory reads MIGRATOR_CONNECTION_STRING" 'grep -rq "MIGRATOR_CONNECTION_STRING" "$WORK/demo-app/src/DataAccess/"'
check ".config/dotnet-tools.json pins dotnet-ef" 'jq -e ".tools.\"dotnet-ef\".version" "$WORK/demo-app/.config/dotnet-tools.json" >/dev/null'
check "SampleApp marked removable"          'grep -qi "REMOVABLE" "$WORK/demo-app/src/SampleApp/SampleApp.csproj"'
check ".NET output token-free"              '! grep -rqE "__SCAFFOLD_[A-Z0-9_]+__" "$WORK/demo-app/src" "$WORK/demo-app/tests" "$WORK/demo-app/.config"'

# EF migrations + RLS baseline + Keycloak-gated DB auth (fn-2 task .11). The initial
# EF migration (code-first) ships in DataAccess with the owner-wrapped RLS baseline;
# the per-table RLS policy template + session-context unit-of-work live in DataAccess;
# the JWT/Keycloak auth + UoW middleware live in Api. Structural assertions only here
# (the real `dotnet ef` smoke + the LIVE RLS isolation proof against the .10 postgres
# container are run by the worker — they need the SDK + Docker). The decision-bearing
# UoW/RLS/claim-extraction LOGIC is covered to 100% by the .NET suites; here we assert
# the FIXTURES land in scaffold output token-free.
DA="$WORK/demo-app/src/DataAccess"
APIDIR="$WORK/demo-app/src/Api"
check "DataAccess ships an initial EF migration" 'compgen -G "$DA/Migrations/*_*.cs" >/dev/null'
check "DataAccess ships the EF model snapshot"   '[[ -f "$DA/Migrations/PlatformDbContextModelSnapshot.cs" ]]'
check "initial migration excluded from coverage gate" 'grep -rq "ExcludeFromCodeCoverage" "$DA/Migrations/"'
check "RLS baseline: ALTER DEFAULT PRIVILEGES for owner -> api" 'grep -rq "ALTER DEFAULT PRIVILEGES FOR ROLE owner" "$DA/Rls/"'
check "RLS baseline installs a named session-context helper function" 'grep -q "CREATE OR REPLACE FUNCTION public." "$DA/Rls/RlsBaseline.cs" && grep -q "app_current_user_id" "$DA/Rls/RlsBaseline.cs"'
check "Api flattens Keycloak realm_access.roles into role claims" 'grep -q "realm_access" "$APIDIR/Auth/KeycloakRoleClaims.cs"'
check "session UoW exposes a rollback for the failure path" 'grep -q "RollbackAsync" "$DA/Rls/ISessionUnitOfWork.cs"'
check "RLS baseline does NOT enable RLS on any table" '! grep -rq "ENABLE ROW LEVEL SECURITY" "$DA/Rls/RlsBaseline.cs"'
check "per-table RLS template: ENABLE+FORCE keyed off app.user_id" 'grep -q "FORCE ROW LEVEL SECURITY" "$DA/Rls/RlsPolicy.cs" && grep -q "current_setting(.app.user_id., true)" "$DA/Rls/RlsPolicy.cs"'
check "owner-DDL convention wraps DDL in SET ROLE owner" 'grep -q "SET ROLE" "$DA/Rls/OwnerDdl.cs" && grep -q "RESET ROLE" "$DA/Rls/OwnerDdl.cs"'
check "MigrationBuilder helper makes owner-wrapped RLS the default path" '[[ -f "$DA/Rls/MigrationBuilderRlsExtensions.cs" ]] && grep -q "EnableRlsForTableAsOwner" "$DA/Rls/MigrationBuilderRlsExtensions.cs"'
check "session-context applied via parameterised set_config (not SET LOCAL string)" 'grep -q "ApplySessionSql" "$DA/Rls/SessionContextSql.cs" && grep -q "set_config" "$DA/Rls/SessionContextSql.cs" && grep -q "@user_id" "$DA/Rls/SessionContextSql.cs"'
check "per-request unit-of-work present (opens txn then session context)" '[[ -f "$DA/Rls/SessionUnitOfWork.cs" ]] && grep -q "ISessionUnitOfWork" "$DA/Rls/ISessionUnitOfWork.cs"'
check "Api wires Keycloak JWT bearer auth"  'grep -q "AddJwtBearer" "$APIDIR/Program.cs"'
check "Api wires the session unit-of-work middleware" 'grep -q "SessionUnitOfWorkMiddleware" "$APIDIR/Program.cs"'
check "Api maps Keycloak sub claim -> session user id" 'grep -rq "SubjectClaimType" "$APIDIR/Auth/"'
check "Api connects as least-privilege api role (API_CONNECTION_STRING)" 'grep -q "API_CONNECTION_STRING" "$APIDIR/Program.cs"'
check ".11 tests land: DataAccess RLS + Api auth suites" 'compgen -G "$WORK/demo-app/tests/DataAccess.Tests/Rls/*.cs" >/dev/null && compgen -G "$WORK/demo-app/tests/Api.Tests/Auth/*.cs" >/dev/null'
check "coverage gate scoped per-component (Include filter)" 'grep -q "<Include>\[DataAccess\]" "$WORK/demo-app/tests/DataAccess.Tests/DataAccess.Tests.csproj"'
check ".11 output token-free"               '! grep -rqE "__SCAFFOLD_[A-Z0-9_]+__" "$DA" "$APIDIR" "$WORK/demo-app/tests/DataAccess.Tests" "$WORK/demo-app/tests/Api.Tests"'

# Dispatcher CLI (fn-2 task .6): the system.sh dispatcher lands at the REPO ROOT
# (script_dir == root, so $script_dir/src/system-cli/<sub>.sh resolves), with the
# subcommand scripts under src/system-cli/ and the generated-project shell
# test-harness under tests/system-cli/. Deep behavior (routing, exit codes, the
# build-config validators) is covered by dispatcher_test.sh; here we only assert
# the files land in scaffold output, executable + token-free. (src/system-cli/ is
# the documented invariant exception — repo tooling, not a systems[] component.)
check "dispatcher system.sh at scaffolded ROOT" '[[ -f "$WORK/demo-app/system.sh" ]]'
check "system.sh resolves subcommands from repo root (not src/)" 'grep -q "src/system-cli/\$subcommand.sh" "$WORK/demo-app/system.sh"'
for sub in help build-config up down migrate status psql; do
  check "subcommand src/system-cli/$sub.sh present" "[[ -f \"\$WORK/demo-app/src/system-cli/$sub.sh\" ]]"
  check "subcommand $sub has a # Description: line" "grep -qE '^#[[:space:]]*Description:' \"\$WORK/demo-app/src/system-cli/$sub.sh\""
done
check "dispatcher + subcommands executable" 'for s in "$WORK/demo-app/system.sh" "$WORK"/demo-app/src/system-cli/*.sh; do [[ -x "$s" ]] || exit 1; done'
check "dispatcher CLI output token-free"    '! grep -rqE "__SCAFFOLD_[A-Z0-9_]+__" "$WORK/demo-app/system.sh" "$WORK/demo-app/src/system-cli"'
check "generated-project shell test-harness ships (tests/system-cli/)" '[[ -d "$WORK/demo-app/tests/system-cli" ]] && compgen -G "$WORK/demo-app/tests/system-cli/*.sh" >/dev/null'
# A fresh scaffold's system.sh actually dispatches a valid subcommand from its root.
# (Capture the output first — piping `system.sh help` straight into `grep -q` would
# SIGPIPE the exec'd help.sh and trip pipefail.)
check "scaffolded system.sh dispatches help (exit 0)" 'HELP_OUT="$( cd "$WORK/demo-app" && bash ./system.sh help )" && grep -q "build-config" <<<"$HELP_OUT"'
check "scaffolded system.sh no-arg -> usage exit 64"  '( cd "$WORK/demo-app" && bash ./system.sh >/dev/null 2>&1 ); [[ $? -eq 64 ]]'
check "scaffolded system.sh unknown -> exit 127"      '( cd "$WORK/demo-app" && bash ./system.sh nope >/dev/null 2>&1 ); [[ $? -eq 127 ]]'

# Observability stack (fn-2 task .5): Grafana + Prometheus + OTel Collector, each a
# first-class src/<component>/ compose stack (NOT a systems[] component and NOT an
# external services{} dep — local dev tooling, no config.json entry). Being separate
# compose projects, they resolve one another by service name over a SHARED external
# Docker network `observability` that `system.sh up` creates. Build-time-complete:
# each compose file + its config land in scaffold output, token-free, with valid
# YAML/JSON, PINNED image tags (no :latest), loopback-bound ports, and the shared
# network declared. A real `docker compose up` needs Docker and is deferred to the
# dev container / CI; here we assert presence + validity + structure.
OTEL="$WORK/demo-app/src/otel-collector"
PROM="$WORK/demo-app/src/prometheus"
GRAF="$WORK/demo-app/src/grafana"
OBS_COMPOSES=("$OTEL/docker-compose.yml" "$PROM/docker-compose.yml" "$GRAF/docker-compose.yml")

check "src/otel-collector/ compose + config present" '[[ -f "$OTEL/docker-compose.yml" && -f "$OTEL/otel-collector-config.yaml" ]]'
check "src/prometheus/ compose + scrape config present" '[[ -f "$PROM/docker-compose.yml" && -f "$PROM/prometheus.yml" ]]'
check "src/grafana/ compose + provisioning present" '[[ -f "$GRAF/docker-compose.yml" && -f "$GRAF/provisioning/datasources/datasources.yaml" && -f "$GRAF/provisioning/dashboards/dashboards.yaml" ]]'
check "observability components live OUTSIDE .devcontainer/" '[[ ! -e "$WORK/demo-app/.devcontainer/grafana" && ! -e "$WORK/demo-app/.devcontainer/prometheus" && ! -e "$WORK/demo-app/.devcontainer/otel-collector" ]]'
# Pure dev tooling: NONE of the three is a config.json systems[] entry (documented exception).
for svc in otel-collector prometheus grafana; do
  check "observability '$svc' is NOT a systems[] entry" "! jq -e '[.systems[].name] | index(\"$svc\")' \"\$WORK/demo-app/config.json\" >/dev/null"
done
# Each compose defines exactly its one service, with the expected name.
check "otel-collector compose defines otel-collector service" 'python3 -c "import yaml,sys; s=yaml.safe_load(open(\"$OTEL/docker-compose.yml\"))[\"services\"]; sys.exit(0 if list(s)==[\"otel-collector\"] else 1)"'
check "prometheus compose defines prometheus service" 'python3 -c "import yaml,sys; s=yaml.safe_load(open(\"$PROM/docker-compose.yml\"))[\"services\"]; sys.exit(0 if list(s)==[\"prometheus\"] else 1)"'
check "grafana compose defines grafana service" 'python3 -c "import yaml,sys; s=yaml.safe_load(open(\"$GRAF/docker-compose.yml\"))[\"services\"]; sys.exit(0 if list(s)==[\"grafana\"] else 1)"'
# Images PINNED per component (no floating :latest).
check "collector image is otel contrib pinned" 'grep -qE "otel/opentelemetry-collector-contrib:[0-9]" "$OTEL/docker-compose.yml"'
check "prometheus image is prom/prometheus pinned" 'grep -qE "prom/prometheus:v?[0-9]" "$PROM/docker-compose.yml"'
check "grafana image is grafana/grafana pinned" 'grep -qE "grafana/grafana:[0-9]" "$GRAF/docker-compose.yml"'
# Structural invariants applied to ALL THREE compose files: PINNED images, loopback
# ports, the shared external `observability` network (service attached + declared
# external), and no hardcoded container_name (would collide across scaffolded projects).
for f in "${OBS_COMPOSES[@]}"; do
  base="$(basename "$(dirname "$f")")"
  check "$base: image pinned (no :latest)" "python3 -c \"import yaml,sys; s=yaml.safe_load(open('$f'))['services']; imgs=[v['image'] for v in s.values()]; sys.exit(0 if all((':' in i and not i.endswith(':latest')) for i in imgs) else 1)\""
  check "$base: published ports bound to 127.0.0.1" "python3 -c \"import yaml,sys; s=yaml.safe_load(open('$f'))['services']; ports=[p for v in s.values() for p in v.get('ports',[])]; sys.exit(0 if ports and all(str(p).startswith('127.0.0.1:') for p in ports) else 1)\""
  check "$base: joins shared external 'observability' network" "python3 -c \"import yaml,sys; c=yaml.safe_load(open('$f')); n=c.get('networks',{}).get('observability',{}); s=list(c['services'].values())[0]; sys.exit(0 if n.get('external') is True and 'observability' in (s.get('networks') or []) else 1)\""
  check "$base: does NOT hardcode container_name" "! grep -qE '^[[:space:]]*container_name:' \"$f\""
done
# Cross-component wiring: prometheus scrapes the collector exporter; grafana queries prometheus.
check "prometheus scrapes otel-collector:8889" 'grep -q "otel-collector:8889" "$PROM/prometheus.yml"'
check "grafana datasource points at prometheus" 'grep -q "http://prometheus:9090" "$GRAF/provisioning/datasources/datasources.yaml"'
check "prometheus scrape config valid YAML" 'python3 -c "import yaml,sys; c=yaml.safe_load(open(\"$PROM/prometheus.yml\")); sys.exit(0 if \"scrape_configs\" in c else 1)"'
# OTel collector config is valid YAML with the standard receivers/service shape.
check "otel config valid YAML + OTLP receiver" 'python3 -c "import yaml,sys; c=yaml.safe_load(open(\"$OTEL/otel-collector-config.yaml\")); sys.exit(0 if \"otlp\" in c[\"receivers\"] and \"pipelines\" in c[\"service\"] else 1)"'
# Grafana provisioning is valid YAML; the starter dashboard is valid JSON.
check "grafana datasources valid YAML" 'python3 -c "import yaml; yaml.safe_load(open(\"$GRAF/provisioning/datasources/datasources.yaml\"))"'
check "grafana dashboard JSON valid" 'jq -e . "$GRAF/provisioning/dashboards/otel-collector.json" >/dev/null'
check "observability output token-free" '! grep -rqE "__SCAFFOLD_[A-Z0-9_]+__" "$OTEL" "$PROM" "$GRAF"'

# Postgres + Keycloak service components (fn-2 task .10): each its own src/<component>/
# with a PINNED-image compose stack launched by `system.sh up`. postgres ships a
# role-bootstrap init script (owner/migrator/api created BEFORE EF migrations);
# keycloak ships a committed realm TEMPLATE (dummy secrets) that build-config stamps
# into a gitignored runtime import. Structural assertions only here — the real
# `docker compose config` + live bring-up + build-config realm-stamp proof are run by
# the worker (need Docker). The build-config UNIT contract (stamp_realm_import jq
# fields, validators) is covered by dispatcher_test.sh; here we assert the FIXTURES.
PG="$WORK/demo-app/src/postgres"
KC="$WORK/demo-app/src/keycloak"
check "src/postgres/docker-compose.yml present" '[[ -f "$PG/docker-compose.yml" ]]'
check "src/postgres role-bootstrap init script present + executable" '[[ -x "$PG/init/10-roles.sh" ]]'
check "postgres image pinned (no :latest)" 'grep -qE "image:[[:space:]]*postgres:[0-9]" "$PG/docker-compose.yml" && ! grep -qE "postgres:latest" "$PG/docker-compose.yml"'
check "postgres compose sets POSTGRES_DB platform" 'grep -qE "POSTGRES_DB:[[:space:]]*platform" "$PG/docker-compose.yml"'
check "postgres compose mounts initdb.d (init runs at first volume init)" 'grep -q "/docker-entrypoint-initdb.d" "$PG/docker-compose.yml"'
check "postgres compose env_file the generated .env" 'grep -qE "^[[:space:]]*-[[:space:]]*\.env" "$PG/docker-compose.yml"'
check "postgres port bound to 127.0.0.1 (loopback)" 'grep -qE "127\.0\.0\.1:.*:5432" "$PG/docker-compose.yml"'
check "postgres compose no hardcoded container_name" '! grep -qE "^[[:space:]]*container_name:" "$PG/docker-compose.yml"'
check "postgres init bootstraps owner/migrator/api roles" 'grep -q "CREATE ROLE owner" "$PG/init/10-roles.sh" && grep -q "CREATE ROLE migrator" "$PG/init/10-roles.sh" && grep -q "CREATE ROLE api" "$PG/init/10-roles.sh"'
check "postgres init: owner NOLOGIN, migrator/api LOGIN" 'grep -q "CREATE ROLE owner NOLOGIN" "$PG/init/10-roles.sh" && grep -q "CREATE ROLE migrator LOGIN" "$PG/init/10-roles.sh" && grep -q "CREATE ROLE api LOGIN" "$PG/init/10-roles.sh"'
check "postgres init: migrator is member of owner (SET ROLE path)" 'grep -q "GRANT owner TO migrator" "$PG/init/10-roles.sh"'
check "postgres init: api least-privilege (no create on public)" 'grep -q "REVOKE CREATE ON SCHEMA public FROM PUBLIC" "$PG/init/10-roles.sh"'
check "postgres init reads role passwords from env (not config.json)" 'grep -q "POSTGRES_OWNER_PASSWORD" "$PG/init/10-roles.sh" && grep -q "POSTGRES_MIGRATOR_PASSWORD" "$PG/init/10-roles.sh" && grep -q "POSTGRES_API_PASSWORD" "$PG/init/10-roles.sh"'
check "postgres init script syntactically valid" 'bash -n "$PG/init/10-roles.sh"'
# keycloak service: compose + committed realm TEMPLATE.
check "src/keycloak/docker-compose.yml present" '[[ -f "$KC/docker-compose.yml" ]]'
check "src/keycloak/realm.template.json present + valid JSON" '[[ -f "$KC/realm.template.json" ]] && jq -e . "$KC/realm.template.json" >/dev/null'
check "keycloak image pinned (no :latest)" 'grep -qE "image:[[:space:]]*quay.io/keycloak/keycloak:[0-9]" "$KC/docker-compose.yml" && ! grep -qE "keycloak:latest" "$KC/docker-compose.yml"'
check "keycloak starts with --import-realm" 'grep -q -- "--import-realm" "$KC/docker-compose.yml"'
check "keycloak mounts the import dir (runtime stamped realm)" 'grep -q "/opt/keycloak/data/import" "$KC/docker-compose.yml"'
check "keycloak import dir exists (mount target, .gitkeep)" '[[ -f "$KC/import/.gitkeep" ]]'
check "keycloak port bound to 127.0.0.1 (loopback)" 'grep -qE "127\.0\.0\.1:.*:8080" "$KC/docker-compose.yml"'
check "keycloak compose no hardcoded container_name" '! grep -qE "^[[:space:]]*container_name:" "$KC/docker-compose.yml"'
# Realm template content (R27): public SPA clients + confidential Api + service account.
check "realm template clientIds match stamp contract (webapp/marketingsite/api)" 'jq -e "([.clients[].clientId] | sort) == [\"api\",\"marketingsite\",\"webapp\"]" "$KC/realm.template.json" >/dev/null'
check "realm: WebApp + MarketingSite are PUBLIC SPA clients (no svc account)" 'jq -e "[.clients[] | select(.clientId==\"webapp\" or .clientId==\"marketingsite\") | (.publicClient==true and .serviceAccountsEnabled==false)] | all and (length==2)" "$KC/realm.template.json" >/dev/null'
check "realm: Api is confidential + serviceAccountsEnabled true" 'jq -e ".clients[] | select(.clientId==\"api\") | (.publicClient==false and .serviceAccountsEnabled==true)" "$KC/realm.template.json" >/dev/null'
check "realm: Api carries a (dummy) secret to be stamped" 'jq -e ".clients[] | select(.clientId==\"api\") | (.secret|type==\"string\" and length>0)" "$KC/realm.template.json" >/dev/null'
check "realm template carries DEV-DUMMY Api secret (never a real/generated secret)" 'S=$(jq -r ".clients[]|select(.clientId==\"api\").secret" "$KC/realm.template.json"); [[ "$S" == *dummy* ]]'
check "realm defines a baseline role set" 'jq -e "(.roles.realm|length)>0" "$KC/realm.template.json" >/dev/null'
# The generated runtime import is gitignored; the committed template + dirs are NOT.
check ".gitignore ignores generated realm import (already asserted above too)" 'grep -q "src/keycloak/import/\*-realm.json" "$WORK/demo-app/.gitignore"'
check "service component output token-free" '! grep -rqE "__SCAFFOLD_[A-Z0-9_]+__" "$PG" "$KC"'

# Angular SPA templates (fn-2 task .12): two SPAs (MarketingSite + WebApp) each its
# own src/<component>/ folder, a single root Angular-version source, and the
# docs/front-end.md standard — all landing in scaffold output token-free. Light
# STRUCTURAL assertions only (the real `npm install` + `ng build` static + `jest`
# 100% smoke is run by the worker against a freshly scaffolded copy — it needs Node;
# don't over-fit to file contents here).
for SPA in MarketingSite WebApp; do
  check "SPA src/$SPA app component present" "[[ -f \"\$WORK/demo-app/src/$SPA/src/app/app.ts\" ]]"
  check "SPA src/$SPA jest.config.js present" "[[ -f \"\$WORK/demo-app/src/$SPA/jest.config.js\" ]]"
  check "SPA src/$SPA jest coverage gate 100" "grep -q 'branches: 100' \"\$WORK/demo-app/src/$SPA/jest.config.js\""
  # The committed sample public/config.json MUST land in scaffold output so a fresh
  # scaffold builds/serves before build-config runs. (It is force-tracked in the
  # template tree: templates/.gitignore ignores src/*/public/config.json, which
  # would otherwise silently drop the committed sample from the plugin repo.) It must
  # carry ONLY non-secret public fields (realmUrl + clientId) — never a secret.
  check "SPA src/$SPA public/config.json present" "[[ -f \"\$WORK/demo-app/src/$SPA/public/config.json\" ]]"
  check "SPA src/$SPA public config is non-secret (realmUrl+clientId only)" \
    "jq -e '(keys|sort)==[\"clientId\",\"realmUrl\"]' \"\$WORK/demo-app/src/$SPA/public/config.json\" >/dev/null"
done
# Single Angular-version source: the ROOT package.json holds @angular/* — and there
# is NO per-SPA package.json pinning a divergent Angular version (one source of truth).
check "root package.json pins @angular/core"  'jq -e ".dependencies.\"@angular/core\"" "$WORK/demo-app/package.json" >/dev/null'
check "root package.json pins @angular/build"  'jq -e ".devDependencies.\"@angular/build\"" "$WORK/demo-app/package.json" >/dev/null'
# R11: the Angular major + builder are PINNED EXACTLY (no ^/~ ranges) so a fresh
# local install and CI cannot drift to a different patch/minor over time.
check "Angular deps pinned exactly (no ^/~)" 'jq -e "[ (.dependencies + .devDependencies) | to_entries[] | select(.key|startswith(\"@angular/\")) | .value ] | all(test(\"^[0-9]\"))" "$WORK/demo-app/package.json" >/dev/null'
# ...and ALL @angular/* (runtime + CLI + builder + compiler) share ONE canonical
# exact version (single source of truth — no patch drift between framework and CLI).
check "all @angular/* share one exact version" 'jq -e "([ (.dependencies + .devDependencies) | to_entries[] | select(.key|startswith(\"@angular/\")) | .value ] | unique | length)==1" "$WORK/demo-app/package.json" >/dev/null'
check "no per-SPA package.json (single Angular source)" '! [[ -f "$WORK/demo-app/src/MarketingSite/package.json" || -f "$WORK/demo-app/src/WebApp/package.json" ]]'
# Root Angular workspace: one angular.json defining BOTH SPA projects, static output.
check "root angular.json defines both SPAs"   'jq -e ".projects.MarketingSite and .projects.WebApp" "$WORK/demo-app/angular.json" >/dev/null'
check "both SPAs build outputMode static"     'jq -e "(.projects.MarketingSite.architect.build.options.outputMode==\"static\") and (.projects.WebApp.architect.build.options.outputMode==\"static\")" "$WORK/demo-app/angular.json" >/dev/null'
# front-end.md standard shipped + linked from _CLAUDE.md Standards index (the link is
# authored by task .2/.8; this asserts the doc itself lands here in .12).
check "docs/front-end.md present"             '[[ -f "$WORK/demo-app/docs/front-end.md" ]]'
check "front-end.md: static/S3 + no-SSR"      'grep -qi "outputMode" "$WORK/demo-app/docs/front-end.md" && grep -qi "S3" "$WORK/demo-app/docs/front-end.md"'
check "front-end.md: S3 error-document fallback + CloudFront caveat" 'grep -qi "error document" "$WORK/demo-app/docs/front-end.md" && grep -qi "cloudfront" "$WORK/demo-app/docs/front-end.md"'
check "front-end.md: single Angular version rule" 'grep -qiE "single (angular version|source)|one source of truth|root .package.json." "$WORK/demo-app/docs/front-end.md"'
check "SPA output token-free"                 '! grep -rqE "__SCAFFOLD_[A-Z0-9_]+__" "$WORK/demo-app/src/MarketingSite" "$WORK/demo-app/src/WebApp" "$WORK/demo-app/angular.json" "$WORK/demo-app/package.json"'

# CI templates (fn-2 task .13, R30): .github/workflows/{ci,deploy}.yml + the helper
# gate scripts must land in the scaffold output as build-time-complete, valid YAML,
# token-free, and REFERENCE REAL targets that exist in the generated project. GitHub
# Actions does not run here; these are structural/validity + real-target assertions
# (actual execution happens on push). A python3 YAML parse is the validity check;
# `actionlint`, when present, is run by the worker directly.
GHA="$WORK/demo-app/.github"
check ".github/workflows/ci.yml present"       "[[ -f \"$GHA/workflows/ci.yml\" ]]"
check ".github/workflows/deploy.yml present"   "[[ -f \"$GHA/workflows/deploy.yml\" ]]"
check ".github/scripts/kcov-gate.sh present+exec"    "[[ -x \"$GHA/scripts/kcov-gate.sh\" ]]"
check ".github/scripts/config-drift.sh present+exec" "[[ -x \"$GHA/scripts/config-drift.sh\" ]]"
check "tests/coverage.sh present+exec"               "[[ -x \"$WORK/demo-app/tests/coverage.sh\" ]]"
check "ci.yml valid YAML"                      "python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' \"$GHA/workflows/ci.yml\""
check "deploy.yml valid YAML"                  "python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' \"$GHA/workflows/deploy.yml\""
check ".github output token-free"              "! grep -rqE \"__SCAFFOLD_[A-Z0-9_]+__\" \"$GHA\""
# CI gates the three real toolchains: .NET solution build, the Angular npm scripts,
# and the generated shell suite under kcov — each must name a target that EXISTS.
check "ci.yml builds the real .sln"            "grep -q 'src/system.sln' \"$GHA/workflows/ci.yml\" && [[ -f \"$WORK/demo-app/src/system.sln\" ]]"
check "ci.yml runs the coverlet 100 line+branch gate" "grep -q 'ThresholdType=line,branch' \"$GHA/workflows/ci.yml\" && grep -q '/p:Threshold=100' \"$GHA/workflows/ci.yml\""
check "ci.yml pins .NET SDK 9 (net9.0 native, no SDK-10 rollforward)" "grep -qE 'dotnet-version: *\"?9' \"$GHA/workflows/ci.yml\""
check "ci.yml runs real npm scripts (build/lint/format/coverage)" "grep -q 'npm run build' \"$GHA/workflows/ci.yml\" && grep -q 'npm run lint' \"$GHA/workflows/ci.yml\" && grep -q 'npm run format:check' \"$GHA/workflows/ci.yml\" && grep -q 'npm run test:coverage' \"$GHA/workflows/ci.yml\""
check "ci.yml verifies static SSG dist/<app>/browser/index.html" "grep -q 'dist/\$app/browser/index.html' \"$GHA/workflows/ci.yml\""
check "ci.yml runs the generated shell suite via tests/coverage.sh --require-kcov" "grep -q 'tests/coverage.sh --require-kcov' \"$GHA/workflows/ci.yml\" && [[ -x \"$WORK/demo-app/tests/coverage.sh\" ]]"
check "coverage.sh runs the real shell suite + the kcov-gate" "grep -q 'system_cli_test.sh' \"$WORK/demo-app/tests/coverage.sh\" && grep -q 'kcov-gate.sh' \"$WORK/demo-app/tests/coverage.sh\" && [[ -f \"$WORK/demo-app/tests/system-cli/system_cli_test.sh\" ]]"
check "coverage.sh kcov scopes system.sh+src/system-cli (via the suite, NOT scaffold.sh)" "grep -q 'include-pattern=/system.sh,/src/system-cli/' \"$WORK/demo-app/tests/system-cli/system_cli_test.sh\" && ! grep -qE 'include-pattern=[^ ]*scaffold' \"$WORK/demo-app/tests/system-cli/system_cli_test.sh\""
check "ci.yml has a config-drift job (needs no secret store)" "grep -q 'config-drift.sh config.json config.deploy.json' \"$GHA/workflows/ci.yml\""
check "ci.yml validates config.json via build-config (no secret store)" "grep -q 'build-config --config config.json' \"$GHA/workflows/ci.yml\""
# The build/test CI must carry NO secret context: no \${{ secrets.* }} reference
# (which is how raw {{VAR-NAME}} secrets would reach validation) anywhere in ci.yml.
check "ci.yml uses NO secrets context (build/test needs no secret store)" "! grep -qE '[$][{][{][[:space:]]*secrets\\.' \"$GHA/workflows/ci.yml\""
check "ci.yml least-privilege permissions (contents: read)" "grep -qE 'permissions:' \"$GHA/workflows/ci.yml\" && grep -qE 'contents: read' \"$GHA/workflows/ci.yml\""
check "ci.yml pins action versions (no floating @vN-only refs)" "! grep -qE 'uses: .*@v[0-9]+\$' \"$GHA/workflows/ci.yml\""
# deploy.yml is the SECRET-bearing half: it renders config.deploy.json from the
# secret store, then runs the real build-config subcommand.
check "deploy.yml renders config.deploy.json from secrets" "grep -q 'secrets\\.' \"$GHA/workflows/deploy.yml\" && grep -q 'config.deploy.json' \"$GHA/workflows/deploy.yml\""
check "deploy.yml runs build-config --config <rendered>" "grep -q 'build-config --config rendered-config.json' \"$GHA/workflows/deploy.yml\" && [[ -f \"$WORK/demo-app/src/system-cli/build-config.sh\" ]]"
check "deploy.yml guards against leftover {{VAR-NAME}}" "grep -q 'unrendered' \"$GHA/workflows/deploy.yml\""
# The drift gate actually PASSES on the freshly scaffolded config pair (proves the
# two files share a structural path set on real output, not just in templates).
check "config-drift gate passes on scaffolded config pair" "( cd \"$WORK/demo-app\" && bash .github/scripts/config-drift.sh config.json config.deploy.json >/dev/null )"
# Drift gate catches an EXTRA empty container (no scalar leaves) — a node that a
# scalar-only path set would miss.
DTMP="$(mktemp -d)"; jq '.systems[0].extra={}' "$WORK/demo-app/config.deploy.json" > "$DTMP/d.json"
check "config-drift catches an extra empty {} node" "! ( cd \"$WORK/demo-app\" && bash .github/scripts/config-drift.sh config.json \"$DTMP/d.json\" >/dev/null 2>&1 )"
rm -rf "$DTMP"

# CI-based AI code review (fn-2 task .14, R31): BOTH host files ship with no
# scaffold-time platform detection — GitHub Actions ai-review.yml (Codex/GPT PR
# review) + a .gitlab-ci.yml ai-review job (GitLab Duo MR review). Both advisory /
# non-fatal, secrets referenced via the host's store (never committed), and scoped
# to PRs/MRs only. GitHub Actions / GitLab CI do not run here — these are
# structural/validity assertions on the scaffolded output.
AIR="$GHA/workflows/ai-review.yml"
GLC="$WORK/demo-app/.gitlab-ci.yml"
check "ai-review.yml present"                  "[[ -f \"$AIR\" ]]"
check ".gitlab-ci.yml present"                 "[[ -f \"$GLC\" ]]"
check "ai-review.yml valid YAML"               "python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' \"$AIR\""
check ".gitlab-ci.yml valid YAML"              "python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' \"$GLC\""
check "ai-review output token-free"            "! grep -rqE \"__SCAFFOLD_[A-Z0-9_]+__\" \"$AIR\" \"$GLC\""
# GitHub: triggers on pull_request (PR-only, not push), runs a Codex/GPT review,
# references a secret, posts feedback, and is non-fatal when the secret is absent.
check "ai-review.yml triggers on pull_request only (no push:)" "grep -qE '^[[:space:]]*pull_request:' \"$AIR\" && ! grep -qE '^[[:space:]]*push:' \"$AIR\""
check "ai-review.yml runs Codex/GPT reviewer"  "grep -q 'codex exec' \"$AIR\" && grep -q '@openai/codex@' \"$AIR\""
check "ai-review.yml references OPENAI_API_KEY secret" "grep -qE 'secrets\\.OPENAI_API_KEY' \"$AIR\""
check "ai-review.yml posts PR feedback"        "grep -q 'gh pr comment' \"$AIR\""
check "ai-review.yml non-fatal on missing secret (warn + exit 0)" "grep -q 'is not configured' \"$AIR\" && grep -q 'have_secret' \"$AIR\""
check "ai-review.yml pins action versions (no floating @vN-only refs)" "! grep -qE 'uses: .*@v[0-9]+\$' \"$AIR\""
check "ai-review.yml least-privilege permissions" "grep -qE 'permissions:' \"$AIR\" && grep -qE 'contents: read' \"$AIR\""
# GitLab: scoped to merge-request pipelines, runs GitLab Duo, non-fatal (allow_failure
# + warn/exit-0), auth via CI variables (no committed secret).
check ".gitlab-ci.yml scoped to merge-request pipelines" "grep -q 'CI_PIPELINE_SOURCE == \"merge_request_event\"' \"$GLC\""
check ".gitlab-ci.yml runs GitLab Duo review"  "grep -q 'glab duo review' \"$GLC\""
check ".gitlab-ci.yml non-fatal (allow_failure + warn/exit 0)" "grep -q 'allow_failure: true' \"$GLC\" && grep -q 'non-fatal' \"$GLC\""
check ".gitlab-ci.yml pins image (no floating :latest)" "grep -qE 'image: .+:[^[:space:]]+' \"$GLC\" && ! grep -qE 'image: .+:latest' \"$GLC\""
# Neither AI-review file may commit a raw secret value — auth is referenced only.
check "ai-review files commit NO raw secret values" "! grep -rqE '(OPENAI_API_KEY|TOKEN|SECRET)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9_-]{16,}' \"$AIR\" \"$GLC\""

# The kcov-gate parses a kcov summary and fails below 100% line (schema-shaped test).
GTMP="$(mktemp -d)"; mkdir -p "$GTMP/kcov-merged"
printf '{"percent_covered":"100","covered_lines":10,"total_lines":10}' > "$GTMP/kcov-merged/coverage.json"
check "kcov-gate PASSES at 100% line" "bash \"$GHA/scripts/kcov-gate.sh\" \"$GTMP\" >/dev/null"
printf '{"percent_covered":"90","covered_lines":9,"total_lines":10}' > "$GTMP/kcov-merged/coverage.json"
check "kcov-gate FAILS below 100% line" "! bash \"$GHA/scripts/kcov-gate.sh\" \"$GTMP\" >/dev/null 2>&1"
# 0 total lines = kcov instrumented nothing -> the gate FAILS (never a silent pass).
printf '{"percent_covered":"0.00","covered_lines":0,"total_lines":0}' > "$GTMP/kcov-merged/coverage.json"
check "kcov-gate FAILS when 0 lines measured (broken instrumentation)" "! bash \"$GHA/scripts/kcov-gate.sh\" \"$GTMP\" >/dev/null 2>&1"
rm -rf "$GTMP"
# deploy.yml's renderer must map a hyphenated {{VAR-NAME}} to its underscore env var
# (a shell var name can't contain '-'). Exercise the exact substitution shape.
HREND="$(mktemp -d)"; printf '{"a":"{{FOO-BAR}}"}' > "$HREND/in.json"
check "deploy renderer maps {{VAR-NAME}} hyphen to env underscore" "( cd \"$HREND\" && FOO_BAR=ok bash -c 'set -euo pipefail; v=FOO-BAR; env_name=\${v//-/_}; val=\${!env_name-}; [[ -n \"\$val\" ]] && jq --arg ph \"{{\$v}}\" --arg val \"\$val\" \"walk(if type==\\\"string\\\" then split(\\\$ph)|join(\\\$val) else . end)\" in.json | jq -e \".a==\\\"ok\\\"\" >/dev/null' )"
rm -rf "$HREND"

# Dev container template (fn-2 task .4): .devcontainer/{devcontainer.json,setup.sh}
# + a build-time-complete .mcp.json, all landing in scaffold output token-free with
# valid JSON. A real `devcontainer build` needs the dev container CLI + Docker and is
# deferred to CI; these are STRUCTURAL/validity assertions only. (devcontainer.json is
# JSONC — strip // line comments before piping to jq; none of our string values
# contain //.) The setup.sh shellcheck/bash -n lint is run by the worker directly.
DCJ="$WORK/demo-app/.devcontainer/devcontainer.json"
check ".devcontainer/devcontainer.json present" "[[ -f \"$DCJ\" ]]"
check ".devcontainer/setup.sh present + executable" "[[ -x \"$WORK/demo-app/.devcontainer/setup.sh\" ]]"
check ".mcp.json present" '[[ -f "$WORK/demo-app/.mcp.json" ]]'
check "devcontainer.json valid JSONC (parses after comment strip)" "sed -E 's@//.*\$@@' \"$DCJ\" | jq -e . >/dev/null"
check "devcontainer base image is dotnet:1-9.0" "sed -E 's@//.*\$@@' \"$DCJ\" | jq -e '.image==\"mcr.microsoft.com/devcontainers/dotnet:1-9.0\"' >/dev/null"
# Pinned features: node + the official cloud CLIs + community gcloud (:1.0.1) + jq + docker-in-docker.
check "devcontainer pins node:2 feature"   "sed -E 's@//.*\$@@' \"$DCJ\" | jq -e '.features | has(\"ghcr.io/devcontainers/features/node:2\")' >/dev/null"
check "devcontainer pins aws/azure/github CLI features" "sed -E 's@//.*\$@@' \"$DCJ\" | jq -e '.features | has(\"ghcr.io/devcontainers/features/aws-cli:1\") and has(\"ghcr.io/devcontainers/features/azure-cli:1\") and has(\"ghcr.io/devcontainers/features/github-cli:1\")' >/dev/null"
check "devcontainer pins community gcloud :1.0.1" "sed -E 's@//.*\$@@' \"$DCJ\" | jq -e '.features | has(\"ghcr.io/dhoeric/features/google-cloud-cli:1.0.1\")' >/dev/null"
check "devcontainer adds docker-in-docker"  "sed -E 's@//.*\$@@' \"$DCJ\" | jq -e '.features | has(\"ghcr.io/devcontainers/features/docker-in-docker:2\")' >/dev/null"
check "devcontainer installs jq via feature" "sed -E 's@//.*\$@@' \"$DCJ\" | grep -q 'jq'"
check "devcontainer installs postgresql-client (psql) via feature" "sed -E 's@//.*\$@@' \"$DCJ\" | jq -e '.features.\"ghcr.io/devcontainers-extra/features/apt-get-packages:1\".packages | test(\"postgresql-client\")' >/dev/null"
check "devcontainer wires onCreate setup.sh" "sed -E 's@//.*\$@@' \"$DCJ\" | jq -e '.onCreateCommand | test(\"setup.sh\")' >/dev/null"
check "devcontainer name token-substituted" "sed -E 's@//.*\$@@' \"$DCJ\" | jq -e '.name==\"demo-app\"' >/dev/null"
check "devcontainer declares vscode extensions" "sed -E 's@//.*\$@@' \"$DCJ\" | jq -e '(.customizations.vscode.extensions|length)>0' >/dev/null"
# setup.sh installs the script-only tools (Angular CLI, DuckDB, acli, glab, Claude Code, Codex CLI)
# and best-effort enables the marketplace by its REMOTE git URL (never local ./src).
SUP="$WORK/demo-app/.devcontainer/setup.sh"
check "setup.sh installs Angular CLI"      "grep -q '@angular/cli' \"$SUP\""
check "setup.sh pins Angular CLI from package.json (no hard-coded version)" "grep -q 'angular_version' \"$SUP\" && ! grep -qE '@angular/cli@[0-9]' \"$SUP\""
check "setup.sh restores dotnet-ef via tool manifest" "grep -q 'dotnet tool restore' \"$SUP\""
check "setup.sh installs DuckDB"           "grep -qi 'duckdb' \"$SUP\""
check "setup.sh pins DuckDB version"       "grep -q 'DUCKDB_VERSION=' \"$SUP\" && grep -q 'DUCKDB_INSTALL_VERSION' \"$SUP\""
check "setup.sh installs Atlassian acli"   "grep -q 'acli' \"$SUP\""
check "setup.sh installs GitLab CLI (glab)" "grep -q 'install_glab' \"$SUP\" && grep -q 'gitlab-org/cli' \"$SUP\""
check "setup.sh pins glab version"         "grep -q 'GLAB_VERSION=' \"$SUP\""
check "setup.sh installs Claude Code (install.sh)" "grep -q 'claude.ai/install.sh' \"$SUP\""
check "setup.sh installs Codex CLI"        "grep -qi 'codex' \"$SUP\""
check "setup.sh pins Codex CLI version"    "grep -q 'CODEX_VERSION=' \"$SUP\" && grep -q '@openai/codex@' \"$SUP\""
check "setup.sh does NOT add ankitpokhrel jira-cli" "! grep -qi 'ankitpokhrel' \"$SUP\""
check "setup.sh adds marketplace by REMOTE git url (not ./src)" "grep -q 'SoftwareAssassin2/Plugins' \"$SUP\" && ! grep -q 'claude plugin marketplace add ./' \"$SUP\""
check "setup.sh best-effort enables 7 marketplace plugins" "for p in dick grill-me handoff tdd ubiquitous-language preferred-browser-automation-plugin preferred-ralph-loops-plugin; do grep -q \"\$p\" \"$SUP\" || exit 1; done"
check "setup.sh uses set -euo pipefail"    "grep -q 'set -euo pipefail' \"$SUP\""
check "setup.sh isolates best-effort steps (warn-not-fail)" "grep -q 'best-effort' \"$SUP\""
# .mcp.json is the build-time-complete source for the two MCP servers (NOT claude plugin install).
check ".mcp.json valid JSON"               'jq -e . "$WORK/demo-app/.mcp.json" >/dev/null'
check ".mcp.json declares context7 + github-mcp-server" 'jq -e ".mcpServers | has(\"context7\") and has(\"github-mcp-server\")" "$WORK/demo-app/.mcp.json" >/dev/null'
check "setup.sh does NOT install MCP servers as plugins" "! grep -qE 'claude plugin install +(context7|github-mcp-server)' \"$SUP\""
# .claude/settings.json declares the marketplace remote (coexists with .mcp.json).
check "settings.json declares marketplace remote (SoftwareAssassin2/Plugins)" 'jq -e ".extraKnownMarketplaces.plugins.source.repo==\"SoftwareAssassin2/Plugins\"" "$WORK/demo-app/.claude/settings.json" >/dev/null'
check "dev container output token-free"    '! grep -rqE "__SCAFFOLD_[A-Z0-9_]+__" "$WORK/demo-app/.devcontainer" "$WORK/demo-app/.mcp.json"'

# distinct + url-safe generated secrets (portable read loop — mapfile is bash 4+)
# 5 sentinels: postgres owner/migrator/api passwords + keycloak admin password +
# keycloak Api confidential-client secret — each independently generated.
SECS=()
while IFS= read -r line; do SECS+=("$line"); done < <(jq -r '.systems[0].owner_password,.systems[0].migrator_password,.systems[0].api_password,.systems[1].admin_password,.systems[1].api_client_secret' "$WORK/demo-app/config.json")
check "5 generated secrets"               '[[ ${#SECS[@]} -eq 5 ]]'
check "secrets distinct"                  '[[ $(printf "%s\n" "${SECS[@]}" | sort -u | wc -l) -eq 5 ]]'
check "secrets url-safe"                  '! printf "%s\n" "${SECS[@]}" | grep -qE "[^A-Za-z0-9_-]"'

# refuse non-empty / invalid name / dry-run
run demo-app "x" >/dev/null 2>&1; rc=$?; check "refuse non-empty (exit 65)" '[[ $rc -eq 65 ]]'
run "Bad_Name" "x" >/dev/null 2>&1; rc=$?; check "invalid name (exit 64)"   '[[ $rc -eq 64 ]]'
DRY="$(mktemp -d)"; ( cd "$DRY" && bash "$SCAFFOLD" d "x" --dry-run >/dev/null ); check "dry-run writes nothing" '[[ -z "$(ls -A "$DRY")" ]]'; rm -rf "$DRY"

# --update: config.json preserved (secrets retained), manifest-owned overwrite
BEFORE="$(jq -r '.systems[0].owner_password' "$WORK/demo-app/config.json")"
echo '<!-- operator edit -->' >> "$WORK/demo-app/CLAUDE.md"
run demo-app "A demo project" --update >/dev/null
AFTER="$(jq -r '.systems[0].owner_password' "$WORK/demo-app/config.json")"
check "--update preserves config secret"  '[[ "$BEFORE" == "$AFTER" ]]'
check "--update overwrites managed CLAUDE.md" '! grep -q "operator edit" "$WORK/demo-app/CLAUDE.md"'

# --update refuses unmanaged collision (simulate by dropping config.json from the manifest)
MFT_BAK="$WORK/mft.bak"
cp "$WORK/demo-app/.init-project-manifest.json" "$MFT_BAK"
jq '.files |= map(select(.path != "config.json"))' "$MFT_BAK" > "$WORK/demo-app/.init-project-manifest.json"
run demo-app "A demo project" --update >/dev/null 2>&1; rc=$?; check "--update refuses unmanaged config.json (exit 65)" '[[ $rc -eq 65 ]]'
cp "$MFT_BAK" "$WORK/demo-app/.init-project-manifest.json"; rm -f "$MFT_BAK"

# --force on a PRIOR scaffold (has a manifest) refuses -> must use --update
run demo-app "A demo project" --force >/dev/null 2>&1; rc=$?; check "--force on prior scaffold refused (exit 65)" '[[ $rc -eq 65 ]]'

# description containing a reserved token is rejected before any write
DT="$(mktemp -d)"; ( cd "$DT" && bash "$SCAFFOLD" t 'has __SCAFFOLD_GEN_URLSAFE__ token' >/dev/null 2>&1 ); rc=$?
check "token in description rejected (exit 64)" '[[ $rc -eq 64 ]]'
check "rejected token-desc wrote nothing"       '[[ -z "$(ls -A "$DT" 2>/dev/null)" ]]'; rm -rf "$DT"

# --replace-config rotates config.json
run demo-app "A demo project" --update --replace-config >/dev/null
ROTATED="$(jq -r '.systems[0].owner_password' "$WORK/demo-app/config.json")"
check "--replace-config rotates secret"   '[[ "$ROTATED" != "$AFTER" ]]'

# --update with no prior manifest refuses (even into an empty/missing target)
NM="$(mktemp -d)"; ( cd "$NM" && bash "$SCAFFOLD" fresh "x" --update >/dev/null 2>&1 ); rc=$?
check "--update w/o prior manifest (exit 65)" '[[ $rc -eq 65 ]]'; rm -rf "$NM"

# config merge by name: re-adds template field, preserves existing secret + operator key + operator system
W2="$(mktemp -d)"
( cd "$W2" && bash "$SCAFFOLD" m "x" >/dev/null )
OWN="$(jq -r '.systems[0].owner_password' "$W2/m/config.json")"
jq '(.systems[0] |= del(.migrator_password)) | (.systems[0].operator_note="keep") | (.systems += [{"name":"extra","host":"h"}])' \
   "$W2/m/config.json" > "$W2/m/cfg.x" && mv "$W2/m/cfg.x" "$W2/m/config.json"
( cd "$W2" && bash "$SCAFFOLD" m "x" --update >/dev/null )
check "merge re-adds template field"        'jq -e ".systems[0].migrator_password" "$W2/m/config.json" >/dev/null'
check "merge preserves existing secret"      '[[ "$(jq -r ".systems[0].owner_password" "$W2/m/config.json")" == "$OWN" ]]'
check "merge keeps operator field"           'jq -e ".systems[0].operator_note==\"keep\"" "$W2/m/config.json" >/dev/null'
check "merge keeps operator-added system"    'jq -e "([.systems[].name]|index(\"extra\"))!=null" "$W2/m/config.json" >/dev/null'
rm -rf "$W2"

# config merge failure (invalid existing config.json) aborts with non-zero, no false success
W3="$(mktemp -d)"
( cd "$W3" && bash "$SCAFFOLD" b "x" >/dev/null )
printf 'not json{' > "$W3/b/config.json"
( cd "$W3" && bash "$SCAFFOLD" b "x" --update >/dev/null 2>&1 ); rc=$?
check "invalid existing config aborts --update (exit 65)" '[[ $rc -eq 65 ]]'
rm -rf "$W3"

# ---------------------------------------------------------------------------
# Local-LLM mock-stack opt-in (fn-3 task .4): --local-llm / --local-llm-model /
# --local-llm-embed-model. The `_optional/local-llm/` subtree is pruned from the
# default copy and laid down at etc/local-llm/ ONLY on opt-in; config.json is
# jq-mutated (base URLs + keys + localLlm.model[/embeddingModel]) on opt-in only.
# Every engine branch is exercised here (the per-branch + missing-jq coverage R10).
# ---------------------------------------------------------------------------
echo "== local-llm opt-in =="

# target_rel unit: the _optional/local-llm/ subtree remaps under etc/local-llm/.
check "target_rel maps _optional/local-llm subtree" '[[ "$(target_rel _optional/local-llm/litellm/config.yaml.template)" == "etc/local-llm/litellm/config.yaml.template" ]]'

# (a) NON-opt-in: zero etc/local-llm, no localLlm block, real-provider base URLs +
# REPLACE_ME keys, and NO leaked _optional/ subtree.
LN="$(mktemp -d)"; ( cd "$LN" && bash "$SCAFFOLD" demo "x" >/dev/null )
check "non-opt-in: no etc/local-llm/ files"        '[[ -z "$(find "$LN/demo/etc/local-llm" -type f 2>/dev/null)" ]]'
check "non-opt-in: no _optional/ leaked"           '[[ ! -e "$LN/demo/_optional" ]]'
check "non-opt-in: no localLlm block"              '! jq -e ".localLlm" "$LN/demo/config.json" >/dev/null 2>&1'
check "non-opt-in: claude-api real-provider URL"   'jq -e ".services.\"claude-api\".base_url==\"https://api.anthropic.com\"" "$LN/demo/config.json" >/dev/null'
check "non-opt-in: openai-api real-provider URL"   'jq -e ".services.\"openai-api\".base_url==\"https://api.openai.com/v1\"" "$LN/demo/config.json" >/dev/null'
check "non-opt-in: both keys stay REPLACE_ME"      'jq -e "(.services.\"claude-api\".api_key==\"REPLACE_ME\") and (.services.\"openai-api\".api_key==\"REPLACE_ME\")" "$LN/demo/config.json" >/dev/null'
check "non-opt-in: manifest has no etc/local-llm"  '! jq -r ".files[].path" "$LN/demo/.init-project-manifest.json" | grep -q "etc/local-llm"'
rm -rf "$LN"

# (b) opt-in (chat only): subtree laid down, URLs/keys repointed, localLlm.model set,
# NO embeddingModel, manifest carries the 4 copied files, no leftover __SCAFFOLD__
# tokens, and the @@LLM_MODEL@@ build-config token survives (NOT a scaffold token).
LC="$(mktemp -d)"; ( cd "$LC" && bash "$SCAFFOLD" demo "x" --local-llm --local-llm-model "qwen2.5:7b" >/dev/null ); rc=$?
check "opt-in chat: exit 0"                         '[[ $rc -eq 0 ]]'
check "opt-in chat: etc/local-llm/docker-compose.yml landed" '[[ -f "$LC/demo/etc/local-llm/docker-compose.yml" ]]'
check "opt-in chat: etc/local-llm/litellm config template landed" '[[ -f "$LC/demo/etc/local-llm/litellm/config.yaml.template" && -f "$LC/demo/etc/local-llm/litellm/config.mock.yaml" ]]'
check "opt-in chat: _pull-model.sh landed"          '[[ -f "$LC/demo/etc/local-llm/_pull-model.sh" ]]'
check "opt-in chat: no _optional/ leaked"           '[[ ! -e "$LC/demo/_optional" ]]'
check "opt-in chat: claude-api repointed to gateway" 'jq -e ".services.\"claude-api\".base_url==\"http://127.0.0.1:4000\"" "$LC/demo/config.json" >/dev/null'
check "opt-in chat: openai-api repointed to gateway/v1" 'jq -e ".services.\"openai-api\".base_url==\"http://127.0.0.1:4000/v1\"" "$LC/demo/config.json" >/dev/null'
check "opt-in chat: both keys are sk-local-mock"    'jq -e "(.services.\"claude-api\".api_key==\"sk-local-mock\") and (.services.\"openai-api\".api_key==\"sk-local-mock\")" "$LC/demo/config.json" >/dev/null'
check "opt-in chat: localLlm.model set"             'jq -e ".localLlm.model==\"qwen2.5:7b\"" "$LC/demo/config.json" >/dev/null'
check "opt-in chat: NO localLlm.embeddingModel"     '! jq -e ".localLlm | has(\"embeddingModel\")" "$LC/demo/config.json" >/dev/null'
check "opt-in chat: manifest lists 4 etc/local-llm files" '[[ "$(jq -r ".files[].path" "$LC/demo/.init-project-manifest.json" | grep -c "^etc/local-llm/")" -eq 4 ]]'
check "opt-in chat: no leftover __SCAFFOLD__ tokens" '! grep -rqE "__SCAFFOLD_[A-Z0-9_]+__" "$LC/demo/etc/local-llm"'
check "opt-in chat: @@LLM_MODEL@@ build-config token preserved" 'grep -q "@@LLM_MODEL@@" "$LC/demo/etc/local-llm/litellm/config.yaml.template"'
rm -rf "$LC"

# (c) opt-in (chat + embed): embeddingModel set; also exercises the `--flag=value` form.
LE="$(mktemp -d)"; ( cd "$LE" && bash "$SCAFFOLD" demo "x" --local-llm --local-llm-model="llama3.2:3b" --local-llm-embed-model="nomic-embed-text" >/dev/null ); rc=$?
check "opt-in embed: exit 0 (=value form)"          '[[ $rc -eq 0 ]]'
check "opt-in embed: localLlm.model set"            'jq -e ".localLlm.model==\"llama3.2:3b\"" "$LE/demo/config.json" >/dev/null'
check "opt-in embed: localLlm.embeddingModel set"   'jq -e ".localLlm.embeddingModel==\"nomic-embed-text\"" "$LE/demo/config.json" >/dev/null'
rm -rf "$LE"

# (d) opt-in accepts a model with valid `/` and `:` punctuation (abliterated path).
LA="$(mktemp -d)"; ( cd "$LA" && bash "$SCAFFOLD" demo "x" --local-llm --local-llm-model "huihui_ai/llama3.2-abliterate:7b-instruct" >/dev/null ); rc=$?
check "opt-in: valid slash+colon model accepted"    '[[ $rc -eq 0 ]] && jq -e ".localLlm.model==\"huihui_ai/llama3.2-abliterate:7b-instruct\"" "$LA/demo/config.json" >/dev/null'
rm -rf "$LA"

# (e) opt-in mutation applies on --update too (re-scaffold over a prior output).
LU="$(mktemp -d)"
( cd "$LU" && bash "$SCAFFOLD" demo "x" >/dev/null )                                   # plain first scaffold
( cd "$LU" && bash "$SCAFFOLD" demo "x" --update --local-llm --local-llm-model "qwen2.5:7b" >/dev/null ); rc=$?
check "opt-in on --update: exit 0"                  '[[ $rc -eq 0 ]]'
check "opt-in on --update: config.json repointed"   'jq -e ".services.\"claude-api\".base_url==\"http://127.0.0.1:4000\" and .localLlm.model==\"qwen2.5:7b\"" "$LU/demo/config.json" >/dev/null'
check "opt-in on --update: etc/local-llm laid down" '[[ -f "$LU/demo/etc/local-llm/docker-compose.yml" ]]'
rm -rf "$LU"

# (e2) NON-opt-in --update RESETS a prior opt-in (opt-in is NOT sticky — fn-3 R5):
# localLlm dropped, base URLs/keys restored to real-provider defaults, the prior
# etc/local-llm/ files removed (no orphans), and the manifest no longer lists them.
LR="$(mktemp -d)"
( cd "$LR" && bash "$SCAFFOLD" demo "x" --local-llm --local-llm-model "qwen2.5:7b" --local-llm-embed-model "nomic-embed-text" >/dev/null )
check "reset precondition: opt-in laid down 4 files" '[[ "$(find "$LR/demo/etc/local-llm" -type f | wc -l | tr -d " ")" -eq 4 ]]'
( cd "$LR" && bash "$SCAFFOLD" demo "x" --update >/dev/null ); rc=$?
check "non-opt-in --update: exit 0"                  '[[ $rc -eq 0 ]]'
check "non-opt-in --update: localLlm dropped"        '! jq -e ".localLlm" "$LR/demo/config.json" >/dev/null 2>&1'
check "non-opt-in --update: claude-api restored"     'jq -e ".services.\"claude-api\".base_url==\"https://api.anthropic.com\" and .services.\"claude-api\".api_key==\"REPLACE_ME\"" "$LR/demo/config.json" >/dev/null'
check "non-opt-in --update: openai-api restored"     'jq -e ".services.\"openai-api\".base_url==\"https://api.openai.com/v1\" and .services.\"openai-api\".api_key==\"REPLACE_ME\"" "$LR/demo/config.json" >/dev/null'
check "non-opt-in --update: etc/local-llm files removed" '[[ -z "$(find "$LR/demo/etc/local-llm" -type f 2>/dev/null)" ]]'
check "non-opt-in --update: manifest drops etc/local-llm" '! jq -r ".files[].path" "$LR/demo/.init-project-manifest.json" | grep -q "etc/local-llm"'
rm -rf "$LR"

# (e2b) a NEVER-opted-in project with operator-customized provider creds/URLs is
# NOT reset by a plain --update: the reset is gated on prior-opt-in evidence (a prior
# manifest etc/local-llm/ entry), so a real-provider config keeps its operator edits
# per the existing "existing wins" contract.
LK="$(mktemp -d)"
( cd "$LK" && bash "$SCAFFOLD" demo "x" >/dev/null )                                   # plain (never opt-in)
# Operator customizes the provider creds/URLs by hand.
jq '.services."claude-api".api_key="sk-ant-REAL" | .services."claude-api".base_url="https://proxy.example.com" | .services."openai-api".api_key="sk-oai-REAL"' \
   "$LK/demo/config.json" > "$LK/demo/config.json.tmp" && mv "$LK/demo/config.json.tmp" "$LK/demo/config.json"
( cd "$LK" && bash "$SCAFFOLD" demo "x" --update >/dev/null ); rc=$?
check "non-opt-in --update on a never-opted project: exit 0" '[[ $rc -eq 0 ]]'
check "never-opted --update PRESERVES operator claude-api key" 'jq -e ".services.\"claude-api\".api_key==\"sk-ant-REAL\"" "$LK/demo/config.json" >/dev/null'
check "never-opted --update PRESERVES operator claude-api URL" 'jq -e ".services.\"claude-api\".base_url==\"https://proxy.example.com\"" "$LK/demo/config.json" >/dev/null'
check "never-opted --update PRESERVES operator openai-api key" 'jq -e ".services.\"openai-api\".api_key==\"sk-oai-REAL\"" "$LK/demo/config.json" >/dev/null'
check "never-opted --update: still no localLlm block"          '! jq -e ".localLlm" "$LK/demo/config.json" >/dev/null 2>&1'
rm -rf "$LK"

# (e3) empty --flag=value (the `=` form with no value) is a usage error (exit 64) —
# an empty embed model must NOT be silently accepted/omitted.
lerr2() { local d; d="$(mktemp -d)"; ( cd "$d" && bash "$SCAFFOLD" "$@" >/dev/null 2>&1 ); local r=$?; rm -rf "$d"; return $r; }
lerr2 demo x --local-llm --local-llm-model= ;                                  rc=$?; check "empty --local-llm-model= -> 64"        '[[ $rc -eq 64 ]]'
lerr2 demo x --local-llm --local-llm-model ok --local-llm-embed-model= ;       rc=$?; check "empty --local-llm-embed-model= -> 64"  '[[ $rc -eq 64 ]]'
lerr2 demo x --local-llm --local-llm-model "" ;                                rc=$?; check "empty --local-llm-model (space form) -> 64" '[[ $rc -eq 64 ]]'

# (f) usage errors (exit 64) — every guard branch. (Capture rc into a var first —
# the harness's check evaluates its predicate against an explicit $rc, never a bare $?.)
lerr() { local d; d="$(mktemp -d)"; ( cd "$d" && bash "$SCAFFOLD" "$@" >/dev/null 2>&1 ); local r=$?; rm -rf "$d"; return $r; }
lerr demo x --local-llm;                                                  rc=$?; check "--local-llm w/o model -> 64"            '[[ $rc -eq 64 ]]'
lerr demo x --local-llm-model qwen2.5:7b;                                 rc=$?; check "--local-llm-model w/o --local-llm -> 64" '[[ $rc -eq 64 ]]'
lerr demo x --local-llm-embed-model nomic-embed-text;                     rc=$?; check "--local-llm-embed-model w/o --local-llm -> 64" '[[ $rc -eq 64 ]]'
lerr demo x --local-llm --local-llm-model 'bad model';                    rc=$?; check "invalid model (space) -> 64"            '[[ $rc -eq 64 ]]'
lerr demo x --local-llm --local-llm-model 'evil;rm -rf';                  rc=$?; check "invalid model (metachar) -> 64"         '[[ $rc -eq 64 ]]'
lerr demo x --local-llm --local-llm-model ok --local-llm-embed-model 'bad embed'; rc=$?; check "invalid embed model -> 64"     '[[ $rc -eq 64 ]]'
lerr demo x --local-llm --local-llm-model;                                rc=$?; check "--local-llm-model missing value -> 64"  '[[ $rc -eq 64 ]]'
lerr demo x --local-llm --local-llm-model ok --local-llm-embed-model;     rc=$?; check "--local-llm-embed-model missing value -> 64" '[[ $rc -eq 64 ]]'

# (g) the --local-llm jq preflight: opt-in REQUIRES jq on the host (exit 64 with a
# clear message); the NON-opt-in scaffold stays jq-free. Simulate a jq-less host by
# running scaffold.sh under a PATH that contains only a curated bin WITHOUT jq.
# (Symlink the few non-jq tools scaffold.sh needs; deliberately omit jq.)
JQLESS="$(mktemp -d)"; mkdir -p "$JQLESS/bin"
for t in bash sh env cat cp mkdir find shasum cut dirname openssl tr grep ls mv rm sed sort; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$JQLESS/bin/$t"
done
JD="$(mktemp -d)"
( cd "$JD" && PATH="$JQLESS/bin" bash "$SCAFFOLD" demo "x" --local-llm --local-llm-model qwen2.5:7b >/tmp/jqless.out 2>&1 ); rc=$?
check "--local-llm without jq on host -> exit 64"   '[[ $rc -eq 64 ]]'
check "--local-llm-without-jq error names jq"       'grep -qi "jq" /tmp/jqless.out'
rm -rf "$JD"
# NON-opt-in scaffold must succeed even when jq is absent from PATH (no jq dependency).
JD2="$(mktemp -d)"
( cd "$JD2" && PATH="$JQLESS/bin" bash "$SCAFFOLD" demo "x" >/dev/null 2>&1 ); rc=$?
check "non-opt-in scaffold succeeds without jq (exit 0)" '[[ $rc -eq 0 && -f "$JD2/demo/config.json" ]]'
rm -rf "$JD2" "$JQLESS"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

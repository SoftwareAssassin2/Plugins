#!/usr/bin/env bash
# Description: Integration tests for the init-project scaffold engine (scaffold.sh).
#
# Exercises the accepted matrix: scaffold + token/secret substitution, _CLAUDE.md
# mapping, leftover-token gate, manifest ownership, refuse-non-empty, --force
# collision, --update manifest-gating + config.json merge, --replace-config,
# --dry-run, invalid name, and distinct/URL-safe generated secrets.
#
# Run: bash src/init-project/tests/scaffold_test.sh
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

# Dispatcher CLI (fn-2 task .6): the system.sh dispatcher lands at the REPO ROOT
# (script_dir == root, so $script_dir/src/system-cli/<sub>.sh resolves), with the
# subcommand scripts under src/system-cli/ and the generated-project shell
# test-harness under tests/system-cli/. Deep behavior (routing, exit codes, the
# build-config validators) is covered by dispatcher_test.sh; here we only assert
# the files land in scaffold output, executable + token-free. (src/system-cli/ is
# the documented invariant exception — repo tooling, not a systems[] component.)
check "dispatcher system.sh at scaffolded ROOT" '[[ -f "$WORK/demo-app/system.sh" ]]'
check "system.sh resolves subcommands from repo root (not src/)" 'grep -q "src/system-cli/\$subcommand.sh" "$WORK/demo-app/system.sh"'
for sub in help build-config up down migrate status; do
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

# Observability dev-tooling stack (fn-2 task .5): Grafana + OTel Collector compose
# stack under etc/observability/ — INTERNAL dev tooling, NOT a systems[] component
# and NOT an external services{} dep (no config.json entry; up/down hardcode the
# path). Build-time-complete: compose file + collector config + Grafana provisioning
# all land in scaffold output, token-free, with valid YAML/JSON and PINNED image tags
# (no :latest). A real `docker compose up` needs Docker and is deferred to the dev
# container / CI; here we assert presence + validity + that it lives OUTSIDE the
# systems[] invariant and OUTSIDE .devcontainer/. (`docker compose config` validity
# is run by the worker directly — it needs the docker CLI.)
OBS="$WORK/demo-app/etc/observability"
check "etc/observability/docker-compose.yml present" '[[ -f "$OBS/docker-compose.yml" ]]'
check "etc/observability/otel-collector-config.yaml present" '[[ -f "$OBS/otel-collector-config.yaml" ]]'
check "grafana datasources provisioning present" '[[ -f "$OBS/grafana/provisioning/datasources/datasources.yaml" ]]'
check "grafana dashboards provider present" '[[ -f "$OBS/grafana/provisioning/dashboards/dashboards.yaml" ]]'
check "observability lives OUTSIDE .devcontainer/" '[[ ! -e "$WORK/demo-app/.devcontainer/observability" ]]'
# Pure dev tooling: NO config.json systems[] entry (the documented invariant exception).
check "observability is NOT a config.json systems[] entry" '! jq -e "[.systems[].name] | index(\"observability\")" "$WORK/demo-app/config.json" >/dev/null'
# Compose defines the named services with PINNED image tags (no floating :latest).
# Grafana queries via a Prometheus service that scrapes the collector exporter
# (Grafana cannot query the collector's exposition endpoint directly).
check "compose defines grafana + otel-collector services" 'python3 -c "import yaml,sys; s=yaml.safe_load(open(\"$OBS/docker-compose.yml\"))[\"services\"]; sys.exit(0 if (\"grafana\" in s and \"otel-collector\" in s) else 1)"'
check "compose defines prometheus query backend" 'python3 -c "import yaml,sys; s=yaml.safe_load(open(\"$OBS/docker-compose.yml\"))[\"services\"]; sys.exit(0 if \"prometheus\" in s else 1)"'
check "compose images pinned (no :latest)" 'python3 -c "import yaml,sys; s=yaml.safe_load(open(\"$OBS/docker-compose.yml\"))[\"services\"]; imgs=[v[\"image\"] for v in s.values()]; sys.exit(0 if all((\":\" in i and not i.endswith(\":latest\")) for i in imgs) else 1)"'
check "grafana image is grafana/grafana pinned" 'grep -qE "grafana/grafana:[0-9]" "$OBS/docker-compose.yml"'
check "collector image is otel contrib pinned" 'grep -qE "otel/opentelemetry-collector-contrib:[0-9]" "$OBS/docker-compose.yml"'
check "prometheus image is prom/prometheus pinned" 'grep -qE "prom/prometheus:v?[0-9]" "$OBS/docker-compose.yml"'
# Dev tooling must bind to loopback only (anonymous-admin Grafana must not be LAN-reachable).
check "compose published ports bound to 127.0.0.1" 'python3 -c "import yaml,sys; s=yaml.safe_load(open(\"$OBS/docker-compose.yml\"))[\"services\"]; ports=[p for v in s.values() for p in v.get(\"ports\",[])]; sys.exit(0 if ports and all(str(p).startswith(\"127.0.0.1:\") for p in ports) else 1)"'
# No hardcoded container_name (would collide across two scaffolded projects).
check "compose does NOT hardcode container_name" '! grep -qE "^[[:space:]]*container_name:" "$OBS/docker-compose.yml"'
# Prometheus scrapes the collector exporter; datasource points at prometheus (not the collector).
check "prometheus scrapes otel-collector:8889" 'grep -q "otel-collector:8889" "$OBS/prometheus/prometheus.yml"'
check "grafana datasource points at prometheus" 'grep -q "http://prometheus:9090" "$OBS/grafana/provisioning/datasources/datasources.yaml"'
check "prometheus scrape config valid YAML" 'python3 -c "import yaml,sys; c=yaml.safe_load(open(\"$OBS/prometheus/prometheus.yml\")); sys.exit(0 if \"scrape_configs\" in c else 1)"'
# OTel collector config is valid YAML with the standard receivers/exporters/service shape.
check "otel config valid YAML + OTLP receiver" 'python3 -c "import yaml,sys; c=yaml.safe_load(open(\"$OBS/otel-collector-config.yaml\")); sys.exit(0 if \"otlp\" in c[\"receivers\"] and \"pipelines\" in c[\"service\"] else 1)"'
# Grafana provisioning is valid YAML; the starter dashboard is valid JSON.
check "grafana datasources valid YAML" 'python3 -c "import yaml; yaml.safe_load(open(\"$OBS/grafana/provisioning/datasources/datasources.yaml\"))"'
check "grafana dashboard JSON valid" 'jq -e . "$OBS/grafana/provisioning/dashboards/otel-collector.json" >/dev/null'
check "observability output token-free" '! grep -rqE "__SCAFFOLD_[A-Z0-9_]+__" "$OBS"'

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
check "devcontainer wires onCreate setup.sh" "sed -E 's@//.*\$@@' \"$DCJ\" | jq -e '.onCreateCommand | test(\"setup.sh\")' >/dev/null"
check "devcontainer name token-substituted" "sed -E 's@//.*\$@@' \"$DCJ\" | jq -e '.name==\"demo-app\"' >/dev/null"
check "devcontainer declares vscode extensions" "sed -E 's@//.*\$@@' \"$DCJ\" | jq -e '(.customizations.vscode.extensions|length)>0' >/dev/null"
# setup.sh installs the script-only tools (Angular CLI, DuckDB, acli, Claude Code, Codex CLI)
# and best-effort enables the marketplace by its REMOTE git URL (never local ./src).
SUP="$WORK/demo-app/.devcontainer/setup.sh"
check "setup.sh installs Angular CLI"      "grep -q '@angular/cli' \"$SUP\""
check "setup.sh pins Angular CLI from package.json (no hard-coded version)" "grep -q 'angular_version' \"$SUP\" && ! grep -qE '@angular/cli@[0-9]' \"$SUP\""
check "setup.sh restores dotnet-ef via tool manifest" "grep -q 'dotnet tool restore' \"$SUP\""
check "setup.sh installs DuckDB"           "grep -qi 'duckdb' \"$SUP\""
check "setup.sh pins DuckDB version"       "grep -q 'DUCKDB_VERSION=' \"$SUP\" && grep -q 'DUCKDB_INSTALL_VERSION' \"$SUP\""
check "setup.sh installs Atlassian acli"   "grep -q 'acli' \"$SUP\""
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

echo
echo "RESULT: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

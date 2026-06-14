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

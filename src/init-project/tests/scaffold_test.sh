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

# distinct + url-safe generated secrets (portable read loop — mapfile is bash 4+)
SECS=()
while IFS= read -r line; do SECS+=("$line"); done < <(jq -r '.systems[0].owner_password,.systems[0].migrator_password,.systems[0].api_password,.systems[1].admin_password' "$WORK/demo-app/config.json")
check "4 generated secrets"               '[[ ${#SECS[@]} -eq 4 ]]'
check "secrets distinct"                  '[[ $(printf "%s\n" "${SECS[@]}" | sort -u | wc -l) -eq 4 ]]'
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

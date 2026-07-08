#!/usr/bin/env bash
# Description: Unit tests for the speak Stop hook (fn-5.6, R26/R28): toggle
# gating, jq-less hook order + the static missing-jq JSON, the shared
# debounced systemMessage emitter (jq --arg encoding of hostile values such as
# a SPEAK_PORT containing quotes/newlines), reason-specific notices
# (invalid-config / invalid-port / missing-<tool> / listener-unreachable),
# 7-day stale-marker pruning, extraction-gated silence, and the detached
# local-mode dispatch (via a PATH-shimmed `say` — no audio, ever).
#
# Every hook run uses a RESTRICTED symlink-farm PATH so "jq missing" and
# "say missing" are constructible on any test host.
#
# Run: bash plugins/speak/tests/hook_test.sh
# (For line coverage, tests/coverage.sh wraps this under kcov.)

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)" # plugins/speak
SPEAK="$PKG_DIR/bin/speak"
HOOK="$PKG_DIR/hooks/stop-speak.sh"
HOOKS_JSON="$PKG_DIR/hooks/hooks.json"
FIXTURES="$SCRIPT_DIR/fixtures"
PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad()   { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# shellcheck disable=SC1090
source "$SPEAK"
set +e +u # repo convention: the harness intentionally runs failing commands

unset SPEAK_MODE SPEAK_PORT SPEAK_MAX_CHARS SPEAK_SESSION SPEAK_DATA_DIR CLAUDE_PLUGIN_DATA

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
JQ_BIN="$(command -v jq)" # the real jq, for validating emitted JSON

check "jq present on the test host (hook tests validate real JSON)" '[ -n "$JQ_BIN" ]'
check "hook script is executable" '[ -x "$HOOK" ]'

# make_path_farm <dir> [excluded-tool ...] — a restricted PATH of symlinks to
# the real tools the hook + sourced bin/speak need, minus the excluded ones.
make_path_farm() {
  local dest="$1" t p; shift
  local excl=" $* "
  mkdir -p "$dest"
  for t in bash sh cat dirname basename find rm rmdir grep mkdir tr sed awk \
    head tail mktemp mv cp chmod date hostname uname printf echo env nohup \
    sleep ps kill wc od stat touch ls seq true false jq base64 nc say lsof iconv; do
    case "$excl" in *" $t "*) continue ;; esac
    p="$(type -P "$t" 2>/dev/null)" || continue
    [ -n "$p" ] && ln -s "$p" "$dest/$t" 2>/dev/null
  done
}

FARM_FULL="$WORK/farm-full";  make_path_farm "$FARM_FULL"
FARM_NOJQ="$WORK/farm-nojq";  make_path_farm "$FARM_NOJQ" jq
FARM_NOSAY="$WORK/farm-nosay"; make_path_farm "$FARM_NOSAY" say uname
# forced-local on a shimmed non-Darwin host, with say hidden:
printf '#!/usr/bin/env bash\nprintf "Linux\\n"\n' >"$FARM_NOSAY/uname"
chmod +x "$FARM_NOSAY/uname"
# FARM_FULL gets a Darwin uname + capture-say so dispatch is deterministic and
# silent on any test host; nc answers flag probes fast and refuses connects.
rm -f "$FARM_FULL/uname" "$FARM_FULL/say" "$FARM_FULL/nc"
SAY_OUT="$WORK/say.out"
printf '#!/usr/bin/env bash\nprintf "Darwin\\n"\n' >"$FARM_FULL/uname"
printf '#!/usr/bin/env bash\ncat > "%s"\n' "$SAY_OUT" >"$FARM_FULL/say"
cat >"$FARM_FULL/nc" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "-G1" | "-w1" | "-N" | "-q 0" | "-z") echo "usage: nc [-46...] destination port" >&2; exit 1 ;;
  *) exit 1 ;; # any real connect: refused (listener "unreachable")
esac
EOF
chmod +x "$FARM_FULL/uname" "$FARM_FULL/say" "$FARM_FULL/nc"

STATE="$WORK/plugdata"
DEBOUNCE="$STATE/debounce"
toggle_on()  { mkdir -p "$STATE"; printf 'on\n' >"$STATE/auto-speak"; }
toggle_off() { rm -f "$STATE/auto-speak"; }
reset_state() { rm -rf "$STATE"; toggle_on; }

hook_input() { # $1 transcript path -> the Stop-hook stdin JSON
  printf '{"session_id":"sess-1","transcript_path":"%s","stop_hook_active":false,"hook_event_name":"Stop"}' "$1"
}

# run_hook <farm> <transcript> [env...] -> stdout in $HOOK_OUT, rc in $HOOK_RC
run_hook() {
  local farm="$1" transcript="$2"; shift 2
  HOOK_OUT="$(hook_input "$transcript" \
    | env "$@" PATH="$farm" SPEAK_DATA_DIR="$STATE" bash "$HOOK" 2>"$WORK/hook.err")"
  HOOK_RC=$?
}

echo "== hooks.json wiring (R3/C9) =="
check "Stop hook wired with timeout 10 (C9)" \
  '[ "$("$JQ_BIN" -r ".hooks.Stop[0].hooks[0].timeout" "$HOOKS_JSON")" = "10" ]'
check "hook command runs stop-speak.sh via CLAUDE_PLUGIN_ROOT" \
  '"$JQ_BIN" -r ".hooks.Stop[0].hooks[0].command" "$HOOKS_JSON" | grep -q "stop-speak.sh"'

echo "== step 1: toggle gates everything (R4) =="
toggle_off; mkdir -p "$STATE"
run_hook "$FARM_FULL" "$FIXTURES/cluster_trailer.jsonl"
check "toggle missing -> exit 0, silent" '[ $HOOK_RC -eq 0 ] && [ -z "$HOOK_OUT" ]'
printf 'banana\n' >"$STATE/auto-speak"
run_hook "$FARM_FULL" "$FIXTURES/cluster_trailer.jsonl"
check "corrupt toggle content reads OFF -> silent" '[ $HOOK_RC -eq 0 ] && [ -z "$HOOK_OUT" ]'
check "OFF path never wrote debounce markers" '[ ! -d "$DEBOUNCE" ] || [ -z "$(ls -A "$DEBOUNCE")" ]'

echo "== jq-less hook order (step 2) + static missing-jq JSON (R28) =="
reset_state
out="$(printf '{"stop_hook_active":true}' | env PATH="$FARM_NOJQ" SPEAK_DATA_DIR="$STATE" bash "$HOOK")"
check "no jq: stop_hook_active=true guard still works (grep) -> silent" '[ -z "$out" ]'
run_hook "$FARM_NOJQ" "$FIXTURES/cluster_trailer.jsonl"
check "no jq: exactly one static notice, exit 0" '[ $HOOK_RC -eq 0 ] && [ -n "$HOOK_OUT" ]'
check "static notice is valid JSON with a systemMessage" \
  'printf "%s" "$HOOK_OUT" | "$JQ_BIN" -e ".systemMessage" >/dev/null'
check "static notice names jq + the /speak:off escape hatch" \
  'printf "%s" "$HOOK_OUT" | grep -q "jq" && printf "%s" "$HOOK_OUT" | grep -q "/speak:off"'
check "missing-jq marker uses the fixed GLOBAL key (C8)" '[ -f "$DEBOUNCE/global.missing-jq" ]'
run_hook "$FARM_NOJQ" "$FIXTURES/cluster_trailer.jsonl"
check "second run debounced -> silent" '[ $HOOK_RC -eq 0 ] && [ -z "$HOOK_OUT" ]'

echo "== C8: stale debounce markers pruned at 7 days on entry =="
reset_state; mkdir -p "$DEBOUNCE"
touch -t 202001010000 "$DEBOUNCE/ancient.listener-unreachable"
touch "$DEBOUNCE/fresh.listener-unreachable"
run_hook "$FARM_FULL" "$FIXTURES/user_final.jsonl" # exits silently at step 4
check "marker older than 7 days pruned"  '[ ! -f "$DEBOUNCE/ancient.listener-unreachable" ]'
check "fresh marker survives the prune"  '[ -f "$DEBOUNCE/fresh.listener-unreachable" ]'

echo "== step 4: extraction gates dispatch (nothing to speak -> silence) =="
reset_state; rm -f "$SAY_OUT"
run_hook "$FARM_FULL" "$FIXTURES/user_final.jsonl"
check "user-final transcript -> silent exit 0" '[ $HOOK_RC -eq 0 ] && [ -z "$HOOK_OUT" ]'
run_hook "$FARM_FULL" "$FIXTURES/tool_use_final.jsonl"
check "tool_use-final transcript -> silent"    '[ $HOOK_RC -eq 0 ] && [ -z "$HOOK_OUT" ]'
run_hook "$FARM_FULL" "$WORK/missing.jsonl"
check "missing transcript -> silent"           '[ $HOOK_RC -eq 0 ] && [ -z "$HOOK_OUT" ]'
sleep 1 # let any (wrongly) dispatched child land before asserting silence
check "no playback was dispatched from the nothing-to-speak paths" '[ ! -e "$SAY_OUT" ]'

echo "== step 3: stop_hook_active loop guard (jq path) =="
reset_state
out="$(printf '{"stop_hook_active":true,"transcript_path":"%s"}' "$FIXTURES/cluster_trailer.jsonl" \
  | env PATH="$FARM_FULL" SPEAK_DATA_DIR="$STATE" bash "$HOOK")"
check "stop_hook_active=true -> silent exit"   '[ -z "$out" ]'

echo "== step 5: invalid SPEAK_MODE -> debounced invalid-config notice (C1) =="
reset_state
run_hook "$FARM_FULL" "$FIXTURES/cluster_trailer.jsonl" SPEAK_MODE=bogus
check "one JSON notice, exit 0" '[ $HOOK_RC -eq 0 ] && printf "%s" "$HOOK_OUT" | "$JQ_BIN" -e ".systemMessage" >/dev/null'
check "notice names the invalid SPEAK_MODE" \
  'printf "%s" "$HOOK_OUT" | "$JQ_BIN" -r ".systemMessage" | grep -q "invalid SPEAK_MODE=.bogus."'
check "marker <sid>.invalid-config written (C8-sanitized sid)" '[ -f "$DEBOUNCE/sess-1.invalid-config" ]'
run_hook "$FARM_FULL" "$FIXTURES/cluster_trailer.jsonl" SPEAK_MODE=bogus
check "debounced on the second run" '[ -z "$HOOK_OUT" ]'
check "invalid config never dispatched playback" '[ ! -e "$SAY_OUT" ]'

echo "== step 5: unsupported host -> invalid-config notice (C1 rc 4) =="
reset_state
# FARM_NOSAY pins uname=Linux; with SPEAK_MODE unset and no container marker
# visible, mode detection returns rc 4.
run_hook "$FARM_NOSAY" "$FIXTURES/cluster_trailer.jsonl"
check "unsupported-host notice emitted once" \
  'printf "%s" "$HOOK_OUT" | "$JQ_BIN" -r ".systemMessage" | grep -q "unsupported host"'
check "marker sess-1.invalid-config written" '[ -f "$DEBOUNCE/sess-1.invalid-config" ]'

echo "== step 5: missing required-in-mode dep -> missing-<tool> notice =="
reset_state
run_hook "$FARM_NOSAY" "$FIXTURES/cluster_trailer.jsonl" SPEAK_MODE=local
check "forced-local without say: missing-say notice" \
  'printf "%s" "$HOOK_OUT" | "$JQ_BIN" -r ".systemMessage" | grep -q "needs .say. in local mode"'
check "guidance flags local mode unsupported off-macOS" \
  'printf "%s" "$HOOK_OUT" | "$JQ_BIN" -r ".systemMessage" | grep -q "non-macOS hosts local mode is unsupported"'
check "marker sess-1.missing-say written" '[ -f "$DEBOUNCE/sess-1.missing-say" ]'
run_hook "$FARM_NOSAY" "$FIXTURES/cluster_trailer.jsonl" SPEAK_MODE=local
check "missing-dep notice debounced" '[ -z "$HOOK_OUT" ]'

echo "== step 5: invalid SPEAK_PORT -> invalid-port notice; hostile value stays JSON-safe (R28) =="
reset_state
hostile_port='87"65
x'
run_hook "$FARM_FULL" "$FIXTURES/cluster_trailer.jsonl" SPEAK_MODE=forward SPEAK_PORT="$hostile_port"
check "invalid-port notice emitted, exit 0" '[ $HOOK_RC -eq 0 ] && [ -n "$HOOK_OUT" ]'
check "output is ONE valid JSON object despite quotes+newline in SPEAK_PORT (jq --arg)" \
  'printf "%s" "$HOOK_OUT" | "$JQ_BIN" -e ".systemMessage" >/dev/null'
check "notice names SPEAK_PORT + the valid range" \
  'printf "%s" "$HOOK_OUT" | "$JQ_BIN" -r ".systemMessage" | grep -q "SPEAK_PORT" && printf "%s" "$HOOK_OUT" | "$JQ_BIN" -r ".systemMessage" | grep -q "1..65535"'
check "the hostile value survives INSIDE the JSON string (round-trips via jq)" \
  '[ "$(printf "%s" "$HOOK_OUT" | "$JQ_BIN" -r ".systemMessage" | grep -c "87\"65")" -ge 1 ]'
check "marker sess-1.invalid-port written" '[ -f "$DEBOUNCE/sess-1.invalid-port" ]'
run_hook "$FARM_FULL" "$FIXTURES/cluster_trailer.jsonl" SPEAK_MODE=forward SPEAK_PORT="$hostile_port"
check "invalid-port debounced on the second run" '[ -z "$HOOK_OUT" ]'
check "invalid port never dispatched playback" '[ ! -e "$SAY_OUT" ]'

echo "== step 5/6: forward listener-unreachable -> advisory notice, send still dispatched (C4/R8/R9) =="
reset_state
run_hook "$FARM_FULL" "$FIXTURES/cluster_trailer.jsonl" SPEAK_MODE=forward SPEAK_PORT=8893
check "unreachable notice emitted (advisory probe)" \
  'printf "%s" "$HOOK_OUT" | "$JQ_BIN" -e ".systemMessage" >/dev/null'
check "notice carries the workspace-relative serve command (R8)" \
  'printf "%s" "$HOOK_OUT" | "$JQ_BIN" -r ".systemMessage" | grep -q "\./plugins/speak/bin/speak --serve"'
check "notice says the response was still sent (probe never gates the send)" \
  'printf "%s" "$HOOK_OUT" | "$JQ_BIN" -r ".systemMessage" | grep -qi "still sent"'
check "marker sess-1.listener-unreachable written" '[ -f "$DEBOUNCE/sess-1.listener-unreachable" ]'
run_hook "$FARM_FULL" "$FIXTURES/cluster_trailer.jsonl" SPEAK_MODE=forward SPEAK_PORT=8893
check "unreachable notice debounced once per session (R9)" '[ -z "$HOOK_OUT" ]'

echo "== step 6: local-mode dispatch is detached, captured, and speaks the extracted text (R3/R28) =="
reset_state; rm -f "$SAY_OUT"
run_hook "$FARM_FULL" "$FIXTURES/cluster_trailer.jsonl"
check "healthy local dispatch: hook stdout EMPTY (R28)" '[ $HOOK_RC -eq 0 ] && [ -z "$HOOK_OUT" ]'
i=0; while [ ! -s "$SAY_OUT" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
check "detached child spoke the joined cluster text via say" \
  '[ "$(cat "$SAY_OUT" 2>/dev/null)" = "First part. Second part." ]'
check "no notice marker written on the happy path" \
  '[ -z "$(ls -A "$DEBOUNCE" 2>/dev/null)" ]'

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Description: Unit tests for the speak CLI's pure-logic units (fn-5.6, R26):
# cleaning (R19), SPEAK_MAX_CHARS bounds (R20), mode detection (C1), port
# validation (C9), session-id sanitization (C8), base64 round-trip +
# decode-flag detection, frame build/validation + UTF-8-boundary over-cap
# truncation (C2/R20), nc capability detection (C6, never a -l probe),
# transcript extraction against the VERIFIED real schema fixtures (fn-5.4),
# and CLI dispatch precedence / exit codes (R29/R30) via a PATH-shimmed `say`.
#
# Run: bash plugins/speak/tests/cli_test.sh
# (For line coverage, tests/coverage.sh wraps this under kcov.)

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)" # plugins/speak
SPEAK="$PKG_DIR/bin/speak"
FIXTURES="$SCRIPT_DIR/fixtures"
PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad()   { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# Source the script-under-test via its source-guard (defines helpers, runs
# nothing, leaks no strict mode).
# shellcheck disable=SC1090
source "$SPEAK"
set +e +u # repo convention: the harness intentionally runs failing commands

# A clean env: none of the SPEAK_* knobs may leak in from the caller.
unset SPEAK_MODE SPEAK_PORT SPEAK_MAX_CHARS SPEAK_SESSION SPEAK_DATA_DIR CLAUDE_PLUGIN_DATA

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# --- PATH shims -------------------------------------------------------------
# uname shims make C1's OS branches deterministic on any test host; the say
# shim captures spoken text to a file so NOTHING in this suite makes noise.
SHIM_DARWIN="$WORK/shim-darwin"; mkdir -p "$SHIM_DARWIN"
printf '#!/usr/bin/env bash\nprintf "Darwin\\n"\n' >"$SHIM_DARWIN/uname"
SHIM_LINUX="$WORK/shim-linux"; mkdir -p "$SHIM_LINUX"
printf '#!/usr/bin/env bash\nprintf "Linux\\n"\n' >"$SHIM_LINUX/uname"
SAY_OUT="$WORK/say.out"
SHIM_SAY="$WORK/shim-say"; mkdir -p "$SHIM_SAY"
printf '#!/usr/bin/env bash\ncat > "%s"\n' "$SAY_OUT" >"$SHIM_SAY/say"
cp "$SHIM_DARWIN/uname" "$SHIM_SAY/uname" # dispatch tests: mode=local on any host
chmod +x "$SHIM_DARWIN/uname" "$SHIM_LINUX/uname" "$SHIM_SAY/say" "$SHIM_SAY/uname"

echo "== clean_text (R19) =="
out="$(printf '# Title\nBody text\n' | clean_text)"
check "headers stripped"            '[ "$out" = "Title Body text" ]'
out="$(printf 'keep\n```\ncode line\n```\nafter\n' | clean_text)"
check "fenced code blocks dropped"  '[ "$out" = "keep after" ]'
out="$(printf -- '- one\n* two\n+ three\n12. four\n' | clean_text)"
check "bullet + numbered lists stripped" '[ "$out" = "one two three four" ]'
out="$(printf 'see [the docs](https://example.com/x) here\n' | clean_text)"
check "[text](url) keeps the text"  '[ "$out" = "see the docs here" ]'
out="$(printf 'go to https://example.com/path now\n' | clean_text)"
check "bare URLs dropped"           '[ "$out" = "go to now" ]'
out="$(printf '**bold** and _emphasis_ and `code`\n' | clean_text)"
check "emphasis + inline-code markers stripped" '[ "$out" = "bold and emphasis and code" ]'
out="$(printf '  a\t\tb\n\n\nc   \n' | clean_text)"
check "whitespace collapsed + trimmed" '[ "$out" = "a b c" ]'
out="$(printf '```\nonly code\n```\n' | clean_text)"
check "pure code block -> empty"    '[ -z "$out" ]'

echo "== apply_max_chars (R20/C9 bounds) =="
out="$( unset SPEAK_MAX_CHARS; printf 'hello world' | apply_max_chars 2>"$WORK/e" )"
check "unset -> no cap"             '[ "$out" = "hello world" ] && [ ! -s "$WORK/e" ]'
out="$( export SPEAK_MAX_CHARS=5; printf 'hello world' | apply_max_chars 2>"$WORK/e" )"
check "positive cap truncates"      '[ "$out" = "hello" ]'
check "truncation notice on stderr only" 'grep -q "truncated" "$WORK/e"'
out="$( export SPEAK_MAX_CHARS=11; printf 'hello world' | apply_max_chars 2>"$WORK/e" )"
check "exact length -> no truncation, no notice" '[ "$out" = "hello world" ] && [ ! -s "$WORK/e" ]'
out="$( export SPEAK_MAX_CHARS=0; printf 'hello world' | apply_max_chars 2>"$WORK/e" )"
check "zero -> treated unset + stderr diagnostic" '[ "$out" = "hello world" ] && grep -q "invalid SPEAK_MAX_CHARS" "$WORK/e"'
out="$( export SPEAK_MAX_CHARS=-3; printf 'hello world' | apply_max_chars 2>"$WORK/e" )"
check "negative -> treated unset + diagnostic" '[ "$out" = "hello world" ] && grep -q "invalid SPEAK_MAX_CHARS" "$WORK/e"'
out="$( export SPEAK_MAX_CHARS=abc; printf 'hello world' | apply_max_chars 2>"$WORK/e" )"
check "non-numeric -> treated unset + diagnostic" '[ "$out" = "hello world" ] && grep -q "invalid SPEAK_MAX_CHARS" "$WORK/e"'

echo "== speak_mode (C1 precedence) =="
out="$( PATH="$SHIM_DARWIN:$PATH"; hash -r; speak_mode )"; rc=$?
check "Darwin auto-detects local"   '[ $rc -eq 0 ] && [ "$out" = "local" ]'
( PATH="$SHIM_LINUX:$PATH"; hash -r; speak_mode >/dev/null ); rc=$?
# no container marker reachable from a test -> bare non-Darwin = rc 4
check "bare non-Darwin -> rc 4 (unsupported host OS)" '[ $rc -eq 4 ]'
out="$( export SPEAK_MODE=forward; PATH="$SHIM_DARWIN:$PATH"; hash -r; speak_mode )"; rc=$?
check "explicit SPEAK_MODE=forward wins even on Darwin" '[ $rc -eq 0 ] && [ "$out" = "forward" ]'
out="$( export SPEAK_MODE=local; PATH="$SHIM_LINUX:$PATH"; hash -r; speak_mode )"; rc=$?
check "explicit SPEAK_MODE=local honored on non-Darwin" '[ $rc -eq 0 ] && [ "$out" = "local" ]'
( export SPEAK_MODE=bogus; speak_mode >/dev/null ); rc=$?
check "invalid SPEAK_MODE -> rc 2"  '[ $rc -eq 2 ]'
( export SPEAK_MODE=Forward; speak_mode >/dev/null ); rc=$?
check "SPEAK_MODE is exact-match (Forward != forward) -> rc 2" '[ $rc -eq 2 ]'

echo "== play_local seam (C1: forced local on non-Darwin) =="
( PATH="$SHIM_LINUX:$PATH"; hash -r; play_local "hi" 2>"$WORK/e" ); rc=$?
check "non-Darwin play_local -> rc 1" '[ $rc -eq 1 ]'
check "names 'unsupported local TTS backend' (not generic missing-say)" \
  'grep -q "unsupported local TTS backend" "$WORK/e"'

echo "== speak_port (C9: 1..65535) =="
out="$( unset SPEAK_PORT; speak_port )"; rc=$?
check "unset -> default 8765"       '[ $rc -eq 0 ] && [ "$out" = "8765" ]'
out="$( export SPEAK_PORT=1; speak_port )"; rc=$?
check "1 valid"                     '[ $rc -eq 0 ] && [ "$out" = "1" ]'
out="$( export SPEAK_PORT=65535; speak_port )"; rc=$?
check "65535 valid"                 '[ $rc -eq 0 ] && [ "$out" = "65535" ]'
( export SPEAK_PORT=0; speak_port >/dev/null ); rc=$?
check "0 -> rc 6"                   '[ $rc -eq 6 ]'
( export SPEAK_PORT=65536; speak_port >/dev/null ); rc=$?
check "65536 -> rc 6"               '[ $rc -eq 6 ]'
( export SPEAK_PORT=-1; speak_port >/dev/null ); rc=$?
check "negative -> rc 6"            '[ $rc -eq 6 ]'
( export SPEAK_PORT=abc; speak_port >/dev/null ); rc=$?
check "non-numeric -> rc 6"         '[ $rc -eq 6 ]'
out="$( export SPEAK_PORT=08765; speak_port )"; rc=$?
check "leading zeros normalized"    '[ $rc -eq 0 ] && [ "$out" = "8765" ]'

echo "== sanitize_session_id (C8) =="
out="$(sanitize_session_id 'abc-DEF_1.2')"
check "safe charset passes through" '[ "$out" = "abc-DEF_1.2" ]'
out="$(sanitize_session_id 'a b/c$d;e')"
check "unsafe chars removed"        '[ "$out" = "abcde" ]'
out="$(sanitize_session_id '../../etc/passwd')"
check "path separators cannot survive" '[ "$out" = "....etcpasswd" ]'
out="$(sanitize_session_id '!!!')"
check "empty-after-sanitize -> safe non-empty fallback" '[ "$out" = "unknown" ]'
out="$(sanitize_session_id '')"
check "empty input -> fallback"     '[ "$out" = "unknown" ]'
long="$(printf 'a%.0s' $(seq 1 100))"
out="$(sanitize_session_id "$long")"
check "capped at 64 chars"          '[ "${#out}" -eq 64 ]'
out="$( export SPEAK_SESSION='we/ird id!'; speak_session_id )"
check "speak_session_id sanitizes SPEAK_SESSION" '[ "$out" = "weirdid" ]'
out="$( unset SPEAK_SESSION; speak_session_id )"
check "no SPEAK_SESSION -> hostname-based, non-empty" '[ -n "$out" ]'

echo "== base64 round-trip (C2, payload >76 chars) =="
flag="$(b64_decode_flag)"; rc=$?
check "decode flag detected (-d or -D)" '[ $rc -eq 0 ] && { [ "$flag" = "-d" ] || [ "$flag" = "-D" ]; }'
long_payload="$(printf 'payload-%03d ' $(seq 1 20))" # ~240 bytes -> >76-char base64
enc="$(printf '%s' "$long_payload" | b64_encode_line)"
check "encoded payload >76 chars (would wrap on GNU)" '[ "${#enc}" -gt 76 ]'
case "$enc" in
  *$'\n'*) bad "interior newlines stripped from base64" ;;
  *) ok "interior newlines stripped from base64" ;;
esac
dec="$(printf '%s' "$enc" | b64_decode_line)"
check "round-trip restores the text" '[ "$dec" = "$long_payload" ]'
( printf 'not@base64!!' | b64_decode_line >/dev/null 2>&1 ); rc=$?
check "undecodable input -> non-zero" '[ $rc -ne 0 ]'

echo "== validate_frame (C2/R18) =="
b64hello="$(printf 'hello' | b64_encode_line)"
validate_frame "sess1	$b64hello"; rc=$?
check "valid frame -> rc 0"         '[ $rc -eq 0 ]'
check "SID/B64 globals populated"   '[ "$SPEAK_FRAME_SID" = "sess1" ] && [ "$SPEAK_FRAME_B64" = "$b64hello" ]'
validate_frame "no-tab-here"; rc=$?
check "zero tabs -> rc 10"          '[ $rc -eq 10 ]'
validate_frame "a	b	c"; rc=$?
check ">1 tab -> rc 10"             '[ $rc -eq 10 ]'
validate_frame "	$b64hello"; rc=$?
check "empty session id -> rc 11"   '[ $rc -eq 11 ]'
validate_frame "sess1	"; rc=$?
check "empty payload -> rc 12"      '[ $rc -eq 12 ]'

echo "== truncate_utf8_bytes (C2/R20 boundary) =="
e_acute="$(printf '\303\251')"        # é (2 bytes)
euro="$(printf '\342\202\254')"       # € (3 bytes)
grin="$(printf '\360\237\230\200')"   # 😀 (4 bytes)
out="$(printf 'hello' | truncate_utf8_bytes 3)"
check "ASCII cut is a plain byte cut" '[ "$out" = "hel" ]'
out="$(printf '%s%s%s' "$e_acute" "$e_acute" "$e_acute" | truncate_utf8_bytes 5)" # cut mid-3rd
check "2-byte char: dangling lead dropped" '[ "$out" = "$e_acute$e_acute" ]'
out="$(printf '%s%s' "$euro" "$euro" | truncate_utf8_bytes 4)" # cut mid-2nd
check "3-byte char: partial sequence dropped" '[ "$out" = "$euro" ]'
out="$(printf '%s%s' "$grin" "$grin" | truncate_utf8_bytes 6)" # cut mid-2nd
check "4-byte char: partial sequence dropped" '[ "$out" = "$grin" ]'
out="$(printf '%s' "$e_acute" | truncate_utf8_bytes 2)"
check "cut exactly on a boundary keeps the char" '[ "$out" = "$e_acute" ]'

echo "== build_frame (C2: shape, cap, UTF-8-boundary truncation) =="
export SPEAK_SESSION="testsess"
frame="$(build_frame "hello" 2>"$WORK/e")"
check "small frame: no truncation notice" '[ ! -s "$WORK/e" ]'
check "frame is sid<TAB>b64"        '[ "$frame" = "testsess	$b64hello" ]'
frame="$( export SPEAK_SESSION='!!!'; build_frame "hello" )"
check "empty-after-sanitize sid -> 'unknown' frame (never empty-id)" \
  '[ "$frame" = "unknown	$b64hello" ]'
# Over-cap multibyte text: 7100 x 11-byte chunk ("abcdéfghij") = 78,100 bytes.
big="$(awk 'BEGIN{ for(i=0;i<7100;i++) printf "abcd\303\251fghij" }')"
frame="$(build_frame "$big" 2>"$WORK/e")"
check "over-cap emits stderr truncation notice" 'grep -q "truncated" "$WORK/e"'
check "frame fits the 65536-byte encoded cap (incl. newline)" \
  '[ $(( $(printf "%s" "$frame" | wc -c) + 1 )) -le 65536 ]'
stripped="${frame//	/}"
check "truncated frame still exactly one tab" '[ $(( ${#frame} - ${#stripped} )) -eq 1 ]'
dec="$(printf '%s' "${frame#*	}" | b64_decode_line)"
check "payload still decodes"       '[ -n "$dec" ]'
case "$big" in
  "$dec"*) ok "decoded text is a prefix of the original" ;;
  *) bad "decoded text is a prefix of the original" ;;
esac
check "no mid-character cut (valid UTF-8 after truncation)" \
  'printf "%s" "$dec" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1'

echo "== nc capability detection (C6 — usage-error probing, never -l) =="
NC_LOG="$WORK/nc-calls.log"
make_nc_shim() { # $1 dir; $2..: patterns of SUPPORTED probe invocations
  local dir="$1"; shift
  mkdir -p "$dir"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo "$*" >> "%s"\n' "$NC_LOG"
    printf 'case "$*" in\n'
    local p
    for p in "$@"; do printf '  "%s") echo "usage: nc [-46...] destination port" >&2; exit 1;;\n' "$p"; done
    printf '  "-N") echo "nc: option requires an argument -- N" >&2; exit 1;;\n'
    printf '  *) echo "nc: invalid option" >&2; exit 1;;\n'
    printf 'esac\n'
  } >"$dir/nc"
  chmod +x "$dir/nc"
}
SHIM_NCBSD="$WORK/shim-ncbsd"
# BSD-flavored: -G/-N/-z usable ("-N" hits the SUPPORTED arm first; the
# generated requires-an-argument arm below it is unreachable for this shim)
make_nc_shim "$SHIM_NCBSD" "-G1" "-N" "-z"
SHIM_NCGNU="$WORK/shim-ncgnu"
make_nc_shim "$SHIM_NCGNU" "-w1" "-q 0" "-z" # GNU/OpenBSD-flavored: -w/-q 0/-z
SHIM_NCAPPLE="$WORK/shim-ncapple"
make_nc_shim "$SHIM_NCAPPLE" "-G1" "-z" # Apple-ish: -N takes an ARG -> not the boolean EOF flag
SHIM_NCBAD="$WORK/shim-ncbad"
make_nc_shim "$SHIM_NCBAD" # supports nothing

out="$( PATH="$SHIM_NCBSD:$PATH"; hash -r; SPEAK_NC_DETECTED=""; SPEAK_NC_TIMEOUT_FLAG=""; SPEAK_NC_EOF_FLAGS=""; SPEAK_NC_Z_OK=""
  printf '%s|%s|' "$(nc_connect_timeout_flag)" "$(nc_eof_flags)"; nc_probe_supported && printf 'z-ok' )"
check "BSD flavor: -G / -N / -z"    '[ "$out" = "-G|-N|z-ok" ]'
out="$( PATH="$SHIM_NCGNU:$PATH"; hash -r; SPEAK_NC_DETECTED=""; SPEAK_NC_TIMEOUT_FLAG=""; SPEAK_NC_EOF_FLAGS=""; SPEAK_NC_Z_OK=""
  printf '%s|%s|' "$(nc_connect_timeout_flag)" "$(nc_eof_flags)"; nc_probe_supported && printf 'z-ok' )"
check "GNU/OpenBSD flavor: -w / -q 0 / -z" '[ "$out" = "-w|-q 0|z-ok" ]'
( PATH="$SHIM_NCAPPLE:$PATH"; hash -r; SPEAK_NC_DETECTED=""; SPEAK_NC_TIMEOUT_FLAG=""; SPEAK_NC_EOF_FLAGS=""; SPEAK_NC_Z_OK=""
  nc_eof_flags >/dev/null ); rc=$?
check "'-N requires an argument' is NOT the boolean EOF flag -> rc 5" '[ $rc -eq 5 ]'
( PATH="$SHIM_NCBAD:$PATH"; hash -r; SPEAK_NC_DETECTED=""; SPEAK_NC_TIMEOUT_FLAG=""; SPEAK_NC_EOF_FLAGS=""; SPEAK_NC_Z_OK=""
  nc_connect_timeout_flag >/dev/null ); rc=$?
check "no usable timeout flag -> rc 5" '[ $rc -eq 5 ]'
( PATH="$WORK/empty-path"; SPEAK_NC_DETECTED=""; nc_detect ); rc=$?
check "nc missing entirely -> rc 3" '[ $rc -eq 3 ]'
check "detection probed nc at least once" '[ -s "$NC_LOG" ]'
check "detection NEVER probes -l (listen proven only by --serve)" \
  '! grep -qE "(^| )-l( |$)" "$NC_LOG"'
SHIM_NCNOZ="$WORK/nc-noz"; make_nc_shim "$SHIM_NCNOZ" "-G1" "-N"  # timeout+EOF ok, no -z
out="$(PATH="$SHIM_NCNOZ:$PATH" bash -c '. "'"$SPEAK"'"; nc_detect_reset 2>/dev/null || true; deps_missing forward' 2>/dev/null)"; rc=$?
check "deps_missing forward: nc without -z reported as missing capability (C6/R23)" \
  '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "zero-I/O probe"'

echo "== extract_last (verified real schema fixtures, fn-5.4) =="
check "jq present (required for extraction tests)" 'command -v jq >/dev/null 2>&1'
out="$(extract_last "$FIXTURES/cluster_trailer.jsonl")"
check "trailer skipped; message.id cluster text-parts joined" \
  '[ "$out" = "First part. Second part." ]'
out="$(extract_last "$FIXTURES/two_clusters.jsonl")"
check "only the FINAL cluster is spoken" '[ "$out" = "New response." ]'
out="$(extract_last "$FIXTURES/user_final.jsonl")"
check "user-final -> nothing (never scan backward past a user record)" '[ -z "$out" ]'
out="$(extract_last "$FIXTURES/tool_use_final.jsonl")"
check "tool_use-only cluster -> nothing" '[ -z "$out" ]'
out="$(extract_last "$FIXTURES/thinking_only.jsonl")"
check "thinking-only cluster -> nothing" '[ -z "$out" ]'
out="$(extract_last "$FIXTURES/sidechain_tail.jsonl")"
check "sidechain records ignored; main chain ends on user -> nothing" '[ -z "$out" ]'
out="$(extract_last "$FIXTURES/string_content.jsonl")"
check "plain-string message.content taken as-is" '[ "$out" = "A plain string response." ]'
out="$(extract_last "$FIXTURES/no_id_final.jsonl")"
check "assistant final without message.id -> that record only" '[ "$out" = "Only this record." ]'
out="$(extract_last "$FIXTURES/torn_tail.jsonl")"
check "torn trailing JSONL line tolerated" '[ "$out" = "Answer before the torn write." ]'
: >"$WORK/empty.jsonl"
out="$(extract_last "$WORK/empty.jsonl")"
check "empty transcript -> nothing"  '[ -z "$out" ]'
out="$(extract_last "$WORK/no-such-file.jsonl")"; rc=$?
check "missing transcript -> nothing, rc 0" '[ -z "$out" ] && [ $rc -eq 0 ]'

echo "== read_input + CLI dispatch precedence / exit codes (R29/R30) =="
out="$(printf 'stdin text' | read_input argv text)"
check "argv wins over piped stdin"  '[ "$out" = "argv text" ]'
out="$(printf 'from stdin' | read_input)"
check "no argv -> stdin is read"    '[ "$out" = "from stdin" ]'

run_speak() { # PATH-shimmed executable run: $@ passed through, stdin from caller
  rm -f "$SAY_OUT"
  PATH="$SHIM_SAY:$PATH" "$SPEAK" "$@"
}
run_speak "hello **world**" </dev/null; rc=$?
check "speak <text> -> rc 0"        '[ $rc -eq 0 ]'
check "spoken text is the CLEANED text" '[ "$(cat "$SAY_OUT")" = "hello world" ]'
printf 'stdin body' | run_speak "argv wins"; rc=$?
check "argv beats stdin end-to-end" '[ $rc -eq 0 ] && [ "$(cat "$SAY_OUT")" = "argv wins" ]'
printf 'piped *text*' | run_speak; rc=$?
check "stdin path speaks cleaned stdin" '[ $rc -eq 0 ] && [ "$(cat "$SAY_OUT")" = "piped text" ]'
run_speak -- doctor </dev/null; rc=$?
check "speak -- doctor SPEAKS the literal word" '[ $rc -eq 0 ] && [ "$(cat "$SAY_OUT")" = "doctor" ]'
printf 'doctor' | run_speak; rc=$?
check "echo doctor | speak SPEAKS it" '[ $rc -eq 0 ] && [ "$(cat "$SAY_OUT")" = "doctor" ]'
printf '```\ncode only\n```' | run_speak; rc=$?
check "empty-after-cleaning -> rc 0, nothing spoken" '[ $rc -eq 0 ] && [ ! -e "$SAY_OUT" ]'
( export SPEAK_MODE=bogus; printf 'hi' | run_speak 2>"$WORK/e" ); rc=$?
check "invalid SPEAK_MODE -> rc 1 + clear CLI failure" \
  '[ $rc -eq 1 ] && grep -q "invalid SPEAK_MODE" "$WORK/e"'

echo "== reserved-word dispatch: on/off toggle (R4/R21/C3) =="
TOGGLE_DIR="$WORK/toggle"
SPEAK_DATA_DIR="$TOGGLE_DIR" run_speak on </dev/null; rc=$?
check "speak on -> rc 0, dispatched (not spoken)" '[ $rc -eq 0 ] && [ ! -e "$SAY_OUT" ]'
check "flag file written with 'on'"  '[ "$(cat "$TOGGLE_DIR/auto-speak")" = "on" ]'
SPEAK_DATA_DIR="$TOGGLE_DIR" run_speak off </dev/null; rc=$?
check "speak off -> rc 0"            '[ $rc -eq 0 ] && [ "$(cat "$TOGGLE_DIR/auto-speak")" = "off" ]'
env -u SPEAK_DATA_DIR -u CLAUDE_PLUGIN_DATA PATH="$SHIM_SAY:$PATH" "$SPEAK" on </dev/null 2>"$WORK/e"; rc=$?
check "outside Claude, no data dir -> 'toggle unavailable', rc 1" \
  '[ $rc -eq 1 ] && grep -q "toggle unavailable" "$WORK/e"'

echo "== auto_speak_enabled (toggle read: missing/corrupt -> OFF) =="
( export SPEAK_DATA_DIR="$WORK/toggle2"; auto_speak_enabled ); rc=$?
check "missing flag -> OFF"          '[ $rc -eq 1 ]'
mkdir -p "$WORK/toggle2"; printf 'banana\n' >"$WORK/toggle2/auto-speak"
( export SPEAK_DATA_DIR="$WORK/toggle2"; auto_speak_enabled ); rc=$?
check "corrupt flag content -> OFF"  '[ $rc -eq 1 ]'
printf 'on\n' >"$WORK/toggle2/auto-speak"
( export SPEAK_DATA_DIR="$WORK/toggle2"; auto_speak_enabled ); rc=$?
check "'on' -> ON"                   '[ $rc -eq 0 ]'
printf 'off\n' >"$WORK/toggle2/auto-speak"
( export SPEAK_DATA_DIR="$WORK/toggle2"; auto_speak_enabled ); rc=$?
check "'off' -> OFF"                 '[ $rc -eq 1 ]'
( unset SPEAK_DATA_DIR CLAUDE_PLUGIN_DATA; auto_speak_enabled ); rc=$?
check "unresolvable state dir -> OFF" '[ $rc -eq 1 ]'
printf 'on' >"$WORK/toggle2/auto-speak"
( export SPEAK_DATA_DIR="$WORK/toggle2"; auto_speak_enabled ); rc=$?
check "'on' without newline (2 bytes) -> OFF (C3 exact on\\n)" '[ $rc -eq 1 ]'
printf 'on\n\n' >"$WORK/toggle2/auto-speak"
( export SPEAK_DATA_DIR="$WORK/toggle2"; auto_speak_enabled ); rc=$?
check "'on\\n\\n' (4 bytes) -> OFF (C3 exact on\\n)" '[ $rc -eq 1 ]'

echo "== doctor rows (C1/C5 fatal-config classifications) =="
( export SPEAK_MODE=bogus; PATH="$SHIM_SAY:$PATH" "$SPEAK" doctor >"$WORK/o" 2>&1 ); rc=$?
check "doctor: invalid SPEAK_MODE -> rc 1" '[ $rc -eq 1 ]'
check "doctor names the invalid value" 'grep -q "INVALID — SPEAK_MODE=.bogus." "$WORK/o"'
( PATH="$SHIM_LINUX:$PATH" "$SPEAK" doctor >"$WORK/o" 2>&1 ); rc=$?
check "doctor: bare non-Darwin -> rc 1 'UNSUPPORTED host OS'" \
  '[ $rc -eq 1 ] && grep -q "UNSUPPORTED host OS" "$WORK/o"'
( export SPEAK_MODE=local; PATH="$SHIM_LINUX:$PATH" "$SPEAK" doctor >"$WORK/o" 2>&1 ); rc=$?
check "doctor: forced-local on non-Darwin -> 'unsupported local TTS backend'" \
  '[ $rc -eq 1 ] && grep -q "unsupported local TTS backend" "$WORK/o"'
( PATH="$SHIM_SAY:$PATH" "$SPEAK" doctor --bogus 2>"$WORK/e" ); rc=$?
check "unknown doctor option -> rc 1" '[ $rc -eq 1 ] && grep -q "unknown doctor option" "$WORK/e"'
( PATH="$SHIM_SAY:$PATH" "$SPEAK" doctor --hook --listener 2>"$WORK/e" ); rc=$?
check "doctor --hook --listener together -> rc 1" '[ $rc -eq 1 ]'
( export SPEAK_PORT=1 SPEAK_DATA_DIR="$WORK/docstate"
  PATH="$SHIM_SAY:$PATH" "$SPEAK" doctor >"$WORK/o" 2>&1 ); rc=$?
check "healthy local doctor -> rc 0 (say shimmed, listener not needed)" '[ $rc -eq 0 ]'
check "doctor reports 'result: healthy (local mode)'" 'grep -q "result: healthy (local mode)" "$WORK/o"'
check "listen -l reported not-checked (proven by --serve)" 'grep -q "proven by --serve" "$WORK/o"'
( export SPEAK_PORT=1 SPEAK_DATA_DIR="$WORK/docstate"
  PATH="$SHIM_SAY:$PATH" "$SPEAK" status >"$WORK/o2" 2>&1 ); rc=$?
check "speak status aliases doctor"  '[ $rc -eq 0 ] && grep -q "speak doctor — full diagnostic" "$WORK/o2"'
( export SPEAK_PORT=1 SPEAK_DATA_DIR="$WORK/docstate"
  PATH="$SHIM_SAY:$PATH" "$SPEAK" doctor --hook >"$WORK/o" 2>&1 ); rc=$?
check "doctor --hook local: READY (jq + say)" '[ $rc -eq 0 ] && grep -q "result: READY" "$WORK/o"'

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

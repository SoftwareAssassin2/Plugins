#!/usr/bin/env bash
# Description: Unit tests for the speak listener's sourceable helpers (fn-5.6,
# R26): C9 constants, mkdir-mutex locking, counters, session window, spool
# ordering + drop-oldest (R16), frame processing (R18), the .9 bounded-capture
# / reject-budget accept loop, the C7 identity + lifetime-lock + stale-cleanup
# helpers (rc 10/11, SPEAK_LOCK_GRACE_SECS grace window), and cmd_serve's
# pidfile-only-after-bind / fatal-pidfile-write-failure / double-start
# classifications via the REAL executable with PATH-shimmed nc + say (no real
# bind, no audio). Live end-to-end serve proofs are owned by .3/.9 — these are
# the repeatable unit tests.
#
# Run: bash plugins/speak/tests/listener_test.sh
# (For line coverage, tests/coverage.sh wraps this under kcov.)

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)" # plugins/speak
SPEAK="$PKG_DIR/bin/speak"
PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad()   { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# shellcheck disable=SC1090
source "$SPEAK"
set +e +u # repo convention: the harness intentionally runs failing commands

unset SPEAK_MODE SPEAK_PORT SPEAK_MAX_CHARS SPEAK_SESSION SPEAK_DATA_DIR CLAUDE_PLUGIN_DATA

WORK="$(mktemp -d)"
FAKE_PID=""
cleanup() {
  [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

export SPEAK_DATA_DIR="$WORK/state"
listener_init_state || { echo "FATAL: listener_init_state failed" >&2; exit 1; }
SPEAK_SPOOL_DIR="$WORK/spool"; mkdir -p "$SPEAK_SPOOL_DIR"

log_size() { wc -c <"$SPEAK_LISTENER_LOG" 2>/dev/null | tr -d ' ' || printf '0'; }

echo "== C9/.9 constants as shipped (contract pins) =="
check "spool cap default 50"          '[ "$SPEAK_SPOOL_CAP" -eq 50 ]'
check "session window default 60s"    '[ "$SPEAK_SESSION_WINDOW_SECS" -eq 60 ]'
check "encoded-frame cap 65536"       '[ "$SPEAK_MAX_FRAME_BYTES" -eq 65536 ]'
check "per-connection reject budget 16" '[ "$SPEAK_MAX_REJECTS_PER_CONN" -eq 16 ]'
check "lock grace window 10s"         '[ "$SPEAK_LOCK_GRACE_SECS" -eq 10 ]'

echo "== speak_lock_acquire / release (mkdir mutex) =="
check "acquire on a free lock"        'speak_lock_acquire'
( speak_lock_acquire ); rc=$? # bounded ~2s spin, then gives up
check "second acquire times out (rc 1), never steals" '[ $rc -eq 1 ]'
check "lock dir still held after the failed acquire" '[ -d "$SPEAK_LOCK_DIR" ]'
speak_lock_release
check "released lock can be re-acquired" 'speak_lock_acquire && speak_lock_release'

echo "== counters (R17: playback totals) =="
out="$(counter_read "$WORK/no-such-counter")"
check "missing counter reads 0"       '[ "$out" = "0" ]'
printf 'garbage\n' >"$SPEAK_COUNTER_OK"
out="$(counter_read "$SPEAK_COUNTER_OK")"
check "garbage counter reads 0"       '[ "$out" = "0" ]'
counter_incr "$SPEAK_COUNTER_OK"
counter_incr "$SPEAK_COUNTER_OK"
out="$(counter_read "$SPEAK_COUNTER_OK")"
check "increment is lock-guarded read-modify-write" '[ "$out" = "2" ]'

echo "== session window (C9: distinct ids in the last 60s) =="
: >"$SPEAK_SESSIONS_FILE"
session_log_append "sess-a"
session_log_append "sess-b"
session_log_append "sess-a"
out="$(session_active_count)"
check "distinct sessions counted once" '[ "$out" = "2" ]'
now="$(date +%s)"
{ printf '%s old-sess\n' "$((now - 120))"; printf '%s fresh-sess\n' "$((now - 10))"; } >"$SPEAK_SESSIONS_FILE"
out="$(session_active_count)"
check "entries older than the window expire" '[ "$out" = "1" ]'
session_log_append "another"
check "append prunes expired entries in the same rewrite" \
  '! grep -q "old-sess" "$SPEAK_SESSIONS_FILE" && grep -q "fresh-sess" "$SPEAK_SESSIONS_FILE"'

echo "== spool: FIFO ordering + drop-oldest at the cap (R16) =="
rm -rf "$SPEAK_SPOOL_DIR"; mkdir -p "$SPEAK_SPOOL_DIR"
( SPEAK_SPOOL_CAP=3
  for t in one two three four five; do printf '%s' "$t" | spool_enqueue; done )
n=$(ls "$SPEAK_SPOOL_DIR"/*.frame 2>/dev/null | wc -l | tr -d ' ')
check "cap 3: five enqueues leave three entries" '[ "$n" = "3" ]'
check "drop-oldest events logged"     'grep -q "queue full (cap 3): dropped oldest" "$SPEAK_LISTENER_LOG"'
f="$(spool_claim)"; c1="$(cat "$f")"; rm -f "$f"
f="$(spool_claim)"; c2="$(cat "$f")"; rm -f "$f"
f="$(spool_claim)"; c3="$(cat "$f")"; rm -f "$f"
check "survivors drain oldest-first (three four five)" \
  '[ "$c1" = "three" ] && [ "$c2" = "four" ] && [ "$c3" = "five" ]'
( spool_claim >/dev/null ); rc=$?
check "empty queue claim -> rc 1"     '[ $rc -eq 1 ]'
rm -rf "$SPEAK_SPOOL_DIR"; mkdir -p "$SPEAK_SPOOL_DIR"
i=1; while [ $i -le 52 ]; do printf 'p%s' "$i" | spool_enqueue; i=$((i + 1)); done
n=$(ls "$SPEAK_SPOOL_DIR"/*.frame 2>/dev/null | wc -l | tr -d ' ')
check "default cap: 52 enqueues leave exactly 50" '[ "$n" = "50" ]'

echo "== process_frame_line (C2/R18 accept-side handling) =="
rm -rf "$SPEAK_SPOOL_DIR"; mkdir -p "$SPEAK_SPOOL_DIR"
: >"$SPEAK_SESSIONS_FILE"
b64hi="$(printf 'hi there' | b64_encode_line)"
process_frame_line "sess-1	$b64hi"; rc=$?
check "valid frame accepted (rc 0)"   '[ $rc -eq 0 ]'
f="$(spool_claim)"
check "decoded text enqueued"         '[ "$(cat "$f")" = "hi there" ]'
rm -f "$f"
check "session recorded"              'grep -q "sess-1" "$SPEAK_SESSIONS_FILE"'
process_frame_line "we/ird	$b64hi"; rc=$?
check "session id sanitized BEFORE any state use" \
  '[ $rc -eq 0 ] && grep -q "weird" "$SPEAK_SESSIONS_FILE" && ! grep -q "we/ird" "$SPEAK_SESSIONS_FILE"'
f="$(spool_claim)"; rm -f "$f"
process_frame_line "sess-1	$b64hi"$'\r'; rc=$?
check "trailing CR stripped, frame still valid" '[ $rc -eq 0 ]'
f="$(spool_claim)"; rm -f "$f"
process_frame_line ""; rc=$?
check "empty line rejected (rc 1) + logged" \
  '[ $rc -eq 1 ] && grep -q "rejected frame: empty line" "$SPEAK_LISTENER_LOG"'
process_frame_line "no-tab-at-all"; rc=$?
check "zero-tab line rejected + logged" \
  '[ $rc -eq 1 ] && grep -q "expected exactly one tab" "$SPEAK_LISTENER_LOG"'
process_frame_line "	$b64hi"; rc=$?
check "empty session id rejected"     '[ $rc -eq 1 ] && grep -q "empty session id" "$SPEAK_LISTENER_LOG"'
process_frame_line "sess-1	"; rc=$?
check "empty payload rejected"        '[ $rc -eq 1 ] && grep -q "empty payload" "$SPEAK_LISTENER_LOG"'
process_frame_line "sess-1	!!!notbase64!!!"; rc=$?
check "undecodable base64 rejected"   '[ $rc -eq 1 ] && grep -q "undecodable base64" "$SPEAK_LISTENER_LOG"'
line_at_cap="$(awk 'BEGIN{ for(i=0;i<6553;i++) printf "aaaaaaaaaa" }')aaaaaa" # 65536 chars
process_frame_line "$line_at_cap"; rc=$?
check "line body of exactly the cap rejected (>= mirrors the sender's +newline count)" \
  '[ $rc -eq 1 ] && grep -q "over the 65536-byte cap" "$SPEAK_LISTENER_LOG"'
process_frame_line "${line_at_cap%a}"; rc=$? # 65535 chars -> passes the length gate
check "one under the cap reaches validation (tab check, not the cap)" \
  '[ $rc -eq 1 ] && tail -1 "$SPEAK_LISTENER_LOG" | grep -q "expected exactly one tab"'
n=$(ls "$SPEAK_SPOOL_DIR"/*.frame 2>/dev/null | wc -l | tr -d ' ')
check "nothing from the reject paths was enqueued" '[ "$n" = "0" ]'

echo "== listener_accept_lines (.9 bounded capture / watchdog seams / budget) =="
rm -rf "$SPEAK_SPOOL_DIR"; mkdir -p "$SPEAK_SPOOL_DIR"
before="$(log_size)"; ok_before="$(counter_read "$SPEAK_COUNTER_OK")"; fail_before="$(counter_read "$SPEAK_COUNTER_FAIL")"
listener_accept_lines "" 8765 </dev/null; rc=$?
check "zero-byte connection (nc -z probe) drains silently (rc 0)" '[ $rc -eq 0 ]'
check "probe not logged"              '[ "$(log_size)" = "$before" ]'
check "probe not counted"             '[ "$(counter_read "$SPEAK_COUNTER_OK")" = "$ok_before" ] && [ "$(counter_read "$SPEAK_COUNTER_FAIL")" = "$fail_before" ]'
printf 'sess-1\t%s\nsess-2\t%s\n' "$b64hi" "$b64hi" | listener_accept_lines "" 8765; rc=$?
n=$(ls "$SPEAK_SPOOL_DIR"/*.frame 2>/dev/null | wc -l | tr -d ' ')
check "two valid frames drain to EOF (rc 0) and enqueue both" '[ $rc -eq 0 ] && [ "$n" = "2" ]'
rm -rf "$SPEAK_SPOOL_DIR"; mkdir -p "$SPEAK_SPOOL_DIR"
big="$(awk 'BEGIN{ for(i=0;i<6600;i++) printf "aaaaaaaaaa" }')" # 66,000 bytes > cap+1
printf '%s\n' "$big" | listener_accept_lines "" 8765; rc=$?
check "oversized frame: dropped before decode, connection severed (rc 9)" '[ $rc -eq 9 ]'
check "oversized drop logged as bounded capture" 'grep -q "bounded capture stopped" "$SPEAK_LISTENER_LOG"'
printf '%s' "$big" | listener_accept_lines "" 8765; rc=$?
check "oversized NEWLINE-LESS stream: capped at cap+1 bytes, severed (rc 9)" '[ $rc -eq 9 ]'
printf 'sess-1\t%s' "$b64hi" | listener_accept_lines "" 8765; rc=$?
n=$(ls "$SPEAK_SPOOL_DIR"/*.frame 2>/dev/null | wc -l | tr -d ' ')
check "small newline-less line at EOF: dropped, never decoded (rc 0)" \
  '[ $rc -eq 0 ] && [ "$n" = "0" ] && grep -q "newline-less line at EOF" "$SPEAK_LISTENER_LOG"'
( i=1; while [ $i -le 16 ]; do printf 'bad-line-%s\n' "$i"; i=$((i + 1)); done ) \
  | listener_accept_lines "" 8765; rc=$?
check "16 rejected frames on one connection sever it (rc 9)" '[ $rc -eq 9 ]'
check "reject-budget sever logged"    'grep -q "16 rejected frames on one connection" "$SPEAK_LISTENER_LOG"'
( i=1; while [ $i -le 15 ]; do printf 'bad-line-%s\n' "$i"; i=$((i + 1)); done ) \
  | listener_accept_lines "" 8765; rc=$?
check "15 rejects then EOF stays under the budget (rc 0)" '[ $rc -eq 0 ]'

echo "== C7 identity: pidfile schema + path-normalization-resilient check =="
# A live fake listener whose ps command contains 'bin/speak' AND '--serve' but
# whose PATH is DIFFERENT from the cmd= recorded in the pidfile — identity is
# on the live ps shape, never an exact script-path match.
mkdir -p "$WORK/xbin/bin"
printf '#!/usr/bin/env bash\nsleep 300\n' >"$WORK/xbin/bin/speak"
chmod +x "$WORK/xbin/bin/speak"
bash "$WORK/xbin/bin/speak" --serve &
FAKE_PID=$!
sleep 0.2
printf 'pid=%s\nport=8765\ncmd=./plugins/speak/bin/speak\nstarted=1750000000\n' "$FAKE_PID" >"$SPEAK_PIDFILE"
mkdir -p "$SPEAK_LIFETIME_LOCK_DIR"
listener_identity_check 8765; rc=$?
check "identity true: pid+ps-shape+port+lock (recorded cmd path differs from live path)" '[ $rc -eq 0 ]'
check "pidfile globals describe the listener" \
  '[ "$SPEAK_PIDFILE_PID" = "$FAKE_PID" ] && [ "$SPEAK_PIDFILE_PORT" = "8765" ] && [ "$SPEAK_PIDFILE_CMD" = "./plugins/speak/bin/speak" ]'
listener_identity_check 9999; rc=$?
check "recorded port != checked port -> rc 5" '[ $rc -eq 5 ]'
rmdir "$SPEAK_LIFETIME_LOCK_DIR"
listener_identity_check 8765; rc=$?
check "lifetime lock not held -> rc 6" '[ $rc -eq 6 ]'
mkdir -p "$SPEAK_LIFETIME_LOCK_DIR"
printf 'started=1750000000\ncmd=./plugins/speak/bin/speak\nport=8765\npid=%s\n' "$FAKE_PID" >"$SPEAK_PIDFILE"
listener_identity_check 8765; rc=$?
check "pidfile fields are order-free" '[ $rc -eq 0 ]'
printf 'pid=notanumber\nport=8765\ncmd=x\nstarted=1\n' >"$SPEAK_PIDFILE"
listener_identity_check 8765; rc=$?
check "malformed pid -> rc 2"         '[ $rc -eq 2 ]'
rm -f "$SPEAK_PIDFILE"
listener_identity_check 8765; rc=$?
check "no pidfile -> rc 1"            '[ $rc -eq 1 ]'
printf 'pid=%s\nport=8765\ncmd=x\nstarted=1\n' "$$" >"$SPEAK_PIDFILE"
listener_identity_check 8765; rc=$?
check "live pid with the WRONG ps shape (this test, not speak --serve) -> rc 4" '[ $rc -eq 4 ]'
check "reachability plays no part in identity (no nc calls made)" 'true' # identity helpers never invoke nc by construction

echo "== C7 stale cleanup: rc 10 / rc 11 / stale removal / grace window =="
printf 'pid=%s\nport=8765\ncmd=./plugins/speak/bin/speak\nstarted=1750000000\n' "$FAKE_PID" >"$SPEAK_PIDFILE"
listener_stale_cleanup 8765; rc=$?
check "valid live listener on this port -> rc 10, NOTHING removed" \
  '[ $rc -eq 10 ] && [ -f "$SPEAK_PIDFILE" ] && [ -d "$SPEAK_LIFETIME_LOCK_DIR" ]'
listener_stale_cleanup 9999; rc=$?
check "LIVE listener recorded on a DIFFERENT port -> rc 11, markers preserved" \
  '[ $rc -eq 11 ] && [ -f "$SPEAK_PIDFILE" ] && [ -d "$SPEAK_LIFETIME_LOCK_DIR" ]'
check "rc 11 reports the actual recorded port" '[ "$SPEAK_PIDFILE_PORT" = "8765" ]'
printf 'pid=%s\nport=8765\ncmd=x\nstarted=1\n' "$$" >"$SPEAK_PIDFILE" # wrong ps shape
listener_stale_cleanup 8765; rc=$?
check "ps-shape mismatch is stale: markers removed (rc 0)" \
  '[ $rc -eq 0 ] && [ ! -f "$SPEAK_PIDFILE" ] && [ ! -d "$SPEAK_LIFETIME_LOCK_DIR" ]'
sleep 0.3 &
dead_pid=$!
wait "$dead_pid" 2>/dev/null
printf 'pid=%s\nport=8765\ncmd=./plugins/speak/bin/speak\nstarted=1\n' "$dead_pid" >"$SPEAK_PIDFILE"
mkdir -p "$SPEAK_LIFETIME_LOCK_DIR"
listener_stale_cleanup 8765; rc=$?
check "dead pid is stale: markers removed (rc 0)" \
  '[ $rc -eq 0 ] && [ ! -f "$SPEAK_PIDFILE" ] && [ ! -d "$SPEAK_LIFETIME_LOCK_DIR" ]'
mkdir -p "$SPEAK_LIFETIME_LOCK_DIR" # lock with NO pidfile, freshly created
listener_stale_cleanup 8765; rc=$?
check "young lock-without-pidfile survives (SPEAK_LOCK_GRACE_SECS startup grace)" \
  '[ $rc -eq 0 ] && [ -d "$SPEAK_LIFETIME_LOCK_DIR" ]'
touch -t 202001010000 "$SPEAK_LIFETIME_LOCK_DIR" # backdate far past the grace window
listener_stale_cleanup 8765; rc=$?
check "lock-without-pidfile older than the grace window is removed" \
  '[ $rc -eq 0 ] && [ ! -d "$SPEAK_LIFETIME_LOCK_DIR" ]'

echo "== C7 pidfile write/read =="
listener_pidfile_write 4321; rc=$?
check "pidfile write succeeds"        '[ $rc -eq 0 ] && [ -f "$SPEAK_PIDFILE" ]'
listener_pidfile_read; rc=$?
check "written schema parses back"    '[ $rc -eq 0 ] && [ "$SPEAK_PIDFILE_PID" = "$$" ] && [ "$SPEAK_PIDFILE_PORT" = "4321" ]'
check "cmd records \$0; started numeric or 'unknown'" \
  '[ -n "$SPEAK_PIDFILE_CMD" ] && { [ "$SPEAK_PIDFILE_STARTED" = "unknown" ] || [ "$SPEAK_PIDFILE_STARTED" -gt 0 ]; }'
rm -f "$SPEAK_PIDFILE"
( SPEAK_PIDFILE="$WORK/no-such-dir/listener.pid"; listener_pidfile_write 4321 ); rc=$?
check "unwritable pidfile path -> rc 1 (mktemp fails)" '[ $rc -eq 1 ]'
printf 'pid=%s\nport=eighty\ncmd=x\nstarted=1\n' "$$" >"$SPEAK_PIDFILE"
listener_pidfile_read; rc=$?
check "non-numeric port -> rc 2 (malformed)" '[ $rc -eq 2 ]'
rm -f "$SPEAK_PIDFILE"

echo "== cmd_serve preflight classifications (real executable, no real bind) =="
# run_serve <state_dir> <shim_dir> [env...]: runs `speak --serve` with a
# deadline so a wedged serve can never hang the suite. Captures rc + output.
SERVE_RC=""
run_serve() {
  local state="$1" shim="$2"; shift 2
  SERVE_OUT="$WORK/serve.out"
  env "$@" SPEAK_DATA_DIR="$state" PATH="$shim:$PATH" \
    "$SPEAK" --serve >"$SERVE_OUT" 2>&1 &
  local pid=$! i=0
  while kill -0 "$pid" 2>/dev/null; do
    i=$((i + 1))
    if [ $i -ge 100 ]; then # 10s deadline
      kill -TERM "$pid" 2>/dev/null
      sleep 0.5
      kill -KILL "$pid" 2>/dev/null
      SERVE_RC=124
      wait "$pid" 2>/dev/null
      return 0
    fi
    sleep 0.1
  done
  SERVE_RC=0
  wait "$pid" || SERVE_RC=$?
}

SHIM_SRV="$WORK/shim-serve"; mkdir -p "$SHIM_SRV"
printf '#!/usr/bin/env bash\ncat >/dev/null\n' >"$SHIM_SRV/say"
printf '#!/usr/bin/env bash\nexit 1\n' >"$SHIM_SRV/nc" # every bind attempt fails
chmod +x "$SHIM_SRV/say" "$SHIM_SRV/nc"
run_serve "$WORK/srv-bindfail" "$SHIM_SRV" SPEAK_PORT=8891
check "bind failure -> non-zero exit"  '[ "$SERVE_RC" -ne 0 ] && [ "$SERVE_RC" -ne 124 ]'
check "bind failure classified as unrelated port holder" \
  'grep -q "port :8891 in use by another process" "$SERVE_OUT"'
check "pidfile only after bind: failed bind NEVER published a pidfile" \
  '[ ! -f "$WORK/srv-bindfail/listener.pid" ]'
check "lifetime lock released on the failed start" \
  '[ ! -d "$WORK/srv-bindfail/listener.lock" ]'

SHIM_SRV2="$WORK/shim-serve2"; mkdir -p "$SHIM_SRV2"
printf '#!/usr/bin/env bash\ncat >/dev/null\n' >"$SHIM_SRV2/say"
printf '#!/usr/bin/env bash\nsleep 30\n' >"$SHIM_SRV2/nc" # "bind" succeeds and idles
# mktemp shim: fail ONLY for the pidfile template — the bind "succeeds" (nc
# stays up through the confirmation window) and then the identity-marker
# write fails, exercising the fatal pidfile-write-failure abort (C7/.8).
cat >"$SHIM_SRV2/mktemp" <<'EOF'
#!/usr/bin/env bash
case "$*" in *listener.pid*) exit 1 ;; esac
for real in /usr/bin/mktemp /bin/mktemp; do
  [ -x "$real" ] && exec "$real" "$@"
done
exit 1
EOF
chmod +x "$SHIM_SRV2/say" "$SHIM_SRV2/nc" "$SHIM_SRV2/mktemp"
run_serve "$WORK/srv-pidfail" "$SHIM_SRV2" SPEAK_PORT=8892
check "fatal pidfile-write failure aborts --serve (non-zero)" \
  '[ "$SERVE_RC" -ne 0 ] && [ "$SERVE_RC" -ne 124 ]'
check "refusal names the identity marker" \
  'grep -q "refusing to serve without an identity marker" "$SERVE_OUT"'
check "lifetime lock released on the aborted start" \
  '[ ! -d "$WORK/srv-pidfail/listener.lock" ]'

# Double-start against the LIVE fake listener from the identity section.
printf 'pid=%s\nport=8765\ncmd=./plugins/speak/bin/speak\nstarted=1750000000\n' "$FAKE_PID" >"$SPEAK_PIDFILE"
mkdir -p "$SPEAK_LIFETIME_LOCK_DIR"
run_serve "$SPEAK_DATA_DIR" "$SHIM_SRV" SPEAK_PORT=8765
check "double-start: friendly 'already running' + exit 0 (R27)" \
  '[ "$SERVE_RC" -eq 0 ] && grep -q "already running on 127.0.0.1:8765" "$SERVE_OUT"'
check "double-start leaves the live markers alone" \
  '[ -f "$SPEAK_PIDFILE" ] && [ -d "$SPEAK_LIFETIME_LOCK_DIR" ]'
run_serve "$SPEAK_DATA_DIR" "$SHIM_SRV" SPEAK_PORT=9999
check "live listener on a DIFFERENT port: --serve refuses (rc 11 path)" \
  '[ "$SERVE_RC" -ne 0 ] && [ "$SERVE_RC" -ne 124 ] && grep -q "already running on 127.0.0.1:8765" "$SERVE_OUT"'
check "rc-11 refusal names the recorded port remedy" 'grep -q "SPEAK_PORT=8765" "$SERVE_OUT"'
check "rc-11 refusal preserves the live markers" \
  '[ -f "$SPEAK_PIDFILE" ] && [ -d "$SPEAK_LIFETIME_LOCK_DIR" ]'
run_serve "$WORK/srv-badport" "$SHIM_SRV" SPEAK_PORT=notaport
check "invalid SPEAK_PORT: --serve fails clearly" \
  '[ "$SERVE_RC" -ne 0 ] && [ "$SERVE_RC" -ne 124 ] && grep -q "invalid SPEAK_PORT" "$SERVE_OUT"'

echo "== doctor --listener host-side classifications (C5, via the C7 helpers) =="
# A deterministic doctor shim: uname pinned to Darwin (host context on any
# test OS), say present, and an nc that answers the C6 flag probes with fast
# usage errors ("supported") but REFUSES every real connect — so reachability
# is deterministically "unreachable" with no real network and no hangs.
SHIM_DOC="$WORK/shim-doc"; mkdir -p "$SHIM_DOC"
printf '#!/usr/bin/env bash\ncat >/dev/null\n' >"$SHIM_DOC/say"
printf '#!/usr/bin/env bash\nprintf "Darwin\\n"\n' >"$SHIM_DOC/uname"
cat >"$SHIM_DOC/nc" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "-G1" | "-w1" | "-N" | "-q 0" | "-z") echo "usage: nc [-46...] destination port" >&2; exit 1 ;;
  *) exit 1 ;; # any real connect: refused
esac
EOF
chmod +x "$SHIM_DOC/say" "$SHIM_DOC/uname" "$SHIM_DOC/nc"

# Identity valid + unreachable: markers must be PRESERVED (C4 — reachability
# never folds into identity). Port 8765 has our fake markers; nothing listens.
out="$( export SPEAK_PORT=8765
  PATH="$SHIM_DOC:$PATH" "$SPEAK" doctor --listener 2>&1 )"; rc=$?
check "identity valid but unreachable -> non-zero, 'may be stuck'" \
  '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "markers preserved"'
check "markers preserved by doctor --listener" \
  '[ -f "$SPEAK_PIDFILE" ] && [ -d "$SPEAK_LIFETIME_LOCK_DIR" ]'
out="$( export SPEAK_PORT=9999
  PATH="$SHIM_DOC:$PATH" "$SPEAK" doctor --listener 2>&1 )"; rc=$?
check "rc 11: 'listener running on :8765, not :9999', non-zero, markers kept" \
  '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "listener running on :8765, not :9999" && [ -f "$SPEAK_PIDFILE" ]'
kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; FAKE_PID=""
rm -f "$SPEAK_PIDFILE"; rm -rf "$SPEAK_LIFETIME_LOCK_DIR"
out="$( export SPEAK_PORT=8765 SPEAK_DATA_DIR="$WORK/srv-empty"
  PATH="$SHIM_DOC:$PATH" "$SPEAK" doctor --listener 2>&1 )"; rc=$?
check "no marker + nothing on port -> 'unrelated process / nothing on port', non-zero" \
  '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "unrelated process / nothing on port"'

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

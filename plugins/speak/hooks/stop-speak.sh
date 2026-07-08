#!/usr/bin/env bash
# Description: Non-blocking Stop hook for the speak plugin (fn-5.4) — when the
# global auto-speak toggle is ON, speak the just-finished assistant response
# aloud by dispatching `bin/speak` DETACHED (playback never blocks the hook or
# counts against its 10s hooks.json timeout). When playback genuinely cannot
# proceed (missing dependency, invalid config) or the forward listener looks
# unreachable, it emits AT MOST ONE debounced `systemMessage` JSON object on
# stdout — once per session+reason (C8 markers) — and nothing otherwise.
#
# Wired via hooks/hooks.json -> hooks.Stop (no matcher, exec form, timeout 10
# per C9). Claude Code passes the hook JSON on stdin; `stop_hook_active` is the
# loop guard (this hook never asks Claude to continue, but guard anyway on both
# the jq and no-jq paths).
#
# Contract: ALWAYS exit 0 — a Stop hook must never block the session from
# stopping. No `set -e`: bin/speak is sourced for its helpers (its strict mode
# is source-guarded and does NOT leak here) and every helper return code is
# handled explicitly. stdout is empty or exactly ONE JSON object (R28); the
# detached child's output goes to <plugin_state_dir>/stop-hook.log, never here.
#
# Ordered algorithm (task fn-5.4 — steps 1..6):
#   1. toggle first (plain file read, no jq; anything but "on" -> exit 0)
#   2. read stdin once; no jq -> grep loop-guard, then <=1 static missing-jq
#      notice (jq-free emitter, hard-coded JSON-safe strings), exit 0
#   3. jq present -> parse; stop_hook_active true -> exit 0
#   4. extract_last on transcript_path (real-schema extraction in bin/speak);
#      nothing to speak -> exit 0 silently
#   5. preflight: mode -> deps -> port -> (forward only) advisory probe.
#      Missing dep / invalid config / invalid port -> one debounced notice,
#      exit 0 WITHOUT dispatching. A failed forward probe only PREPARES the
#      listener-unreachable notice and falls through — send-with-retry still
#      dispatches (C4: the probe is advisory, never a send gate).
#   6. dispatch playback asynchronously: text handed off via a temp file the
#      CHILD unlinks after opening (the parent never race-deletes it), child
#      detached with nohup + its output redirected to the log; then emit the
#      prepared notice, if any, and exit 0.

# --- locate + source the sourceable helpers from bin/speak -------------------
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
plugin_root="${CLAUDE_PLUGIN_ROOT:-$(cd -- "$script_dir/.." && pwd)}"
speak_bin="$plugin_root/bin/speak"
if [ ! -r "$speak_bin" ]; then
  exit 0 # nothing we can do, and a Stop hook never blocks
fi
# shellcheck source=../bin/speak
# shellcheck disable=SC1091  # path is runtime-resolved from CLAUDE_PLUGIN_ROOT
. "$speak_bin" # source-guarded: defines helpers only, no strict mode, runs nothing

# --- step 1: toggle first (no jq involved) -----------------------------------
if ! auto_speak_enabled; then
  exit 0
fi
# auto_speak_enabled == 0 implies plugin_state_dir resolved.
state_dir="$(plugin_state_dir)" || exit 0
debounce_dir="$state_dir/debounce"

# C8: prune stale debounce markers (>7 days) on hook entry.
find "$debounce_dir" -type f -mtime +7 -exec rm -f -- {} + 2>/dev/null

# The ONLY message the no-jq emitter can produce — hard-coded JSON-safe static
# string (R28: no untrusted interpolation can corrupt hook stdout).
MISSING_JQ_JSON='{"systemMessage":"speak plugin: auto-speak is ON but jq is not installed, so the Stop hook cannot read its input. Install jq (macOS: brew install jq; Debian/Ubuntu: apt-get install jq), or turn auto-speak off with /speak:off."}'

# emit_notice_once — the shared debounced systemMessage emitter.
#   $1 = marker filename "<key>.<reason>" ($1's key part is already sanitized:
#        sanitize_session_id output, or the fixed "global" for missing-jq)
#   $2 = human message (IGNORED on the no-jq path, which only ever emits the
#        static MISSING_JQ_JSON above)
# Emits nothing when the marker already exists. If the marker cannot be
# recorded, stays SILENT — debounce integrity ("at most once per session")
# beats notice delivery. With jq present the message is encoded via
# `jq -n --arg` so ANY value (quotes, newlines, a hostile SPEAK_PORT) is
# JSON-safe — never string interpolation (R28).
emit_notice_once() {
  local marker
  marker="$debounce_dir/$1"
  if [ -e "$marker" ]; then
    return 0
  fi
  mkdir -p "$debounce_dir" 2>/dev/null || return 0
  : >"$marker" 2>/dev/null || return 0
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg m "$2" '{systemMessage: $m}'
  else
    printf '%s\n' "$MISSING_JQ_JSON"
  fi
}

# --- step 2: read stdin ONCE; handle the no-jq world --------------------------
hook_input="$(cat 2>/dev/null)" || hook_input=""

if ! command -v jq >/dev/null 2>&1; then
  # jq-free, whitespace-tolerant loop guard (handles minified JSON).
  if printf '%s' "$hook_input" | grep -Eq '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
    exit 0
  fi
  # Fixed GLOBAL debounce key — session_id is unavailable without jq (C8).
  emit_notice_once "global.missing-jq" ""
  exit 0
fi

# --- step 3: parse (jq present) -----------------------------------------------
if [ "$(printf '%s' "$hook_input" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
  exit 0
fi
session_id_raw="$(printf '%s' "$hook_input" | jq -r '.session_id // ""' 2>/dev/null)" || session_id_raw=""
transcript_path="$(printf '%s' "$hook_input" | jq -r '.transcript_path // ""' 2>/dev/null)" || transcript_path=""
sid="$(sanitize_session_id "$session_id_raw")" # C8: never a raw id in a filename

# --- step 4: transcript extraction (final assistant response only) ------------
text="$(extract_last "$transcript_path")"
if [ -z "$text" ]; then
  exit 0 # stop didn't end on an assistant response (or nothing readable) — silent
fi

# --- step 5: synchronous preflight ---------------------------------------------
mode_rc=0
mode="$(speak_mode)" || mode_rc=$?
case "$mode_rc" in
  0) ;;
  2)
    emit_notice_once "$sid.invalid-config" \
      "speak plugin: invalid SPEAK_MODE='${SPEAK_MODE:-}' — expected exactly 'local' or 'forward'. Auto-speak is paused until this is fixed (or turn it off with /speak:off)."
    exit 0
    ;;
  *)
    emit_notice_once "$sid.invalid-config" \
      "speak plugin: unsupported host for auto-speak — only macOS (local mode) or a Linux container (forward mode) is supported. Turn auto-speak off with /speak:off to silence this notice."
    exit 0
    ;;
esac

# Missing required-in-mode dependency -> one debounced reason-specific notice,
# no dispatch (playback genuinely cannot proceed). Local mode preflights ONLY
# `say` (+ jq, already proven above) and NEVER probes or mentions the listener
# (R10/R22); base64 is not a local dep (R23).
dep_report="$(deps_missing "$mode")"
if [ -n "$dep_report" ]; then
  dep_line="$(printf '%s\n' "$dep_report" | head -n 1)"
  dep_tool="${dep_line%%$'\t'*}"
  dep_hint="${dep_line#*$'\t'}"
  emit_notice_once "$sid.missing-$dep_tool" \
    "speak plugin: auto-speak needs '$dep_tool' in $mode mode but it is missing or unusable — $dep_hint. Turn auto-speak off with /speak:off to silence this notice."
  exit 0
fi

notice_reason=""
notice_msg=""
if [ "$mode" = "forward" ]; then
  if ! port="$(speak_port)"; then
    # Reason-specific: names the bad value + the valid range, NOT a serve hint.
    # jq --arg encoding above keeps even a hostile value JSON-safe.
    emit_notice_once "$sid.invalid-port" \
      "speak plugin: invalid SPEAK_PORT='${SPEAK_PORT:-}' — expected an integer 1..65535. Auto-speak is paused until this is fixed."
    exit 0
  fi
  # Advisory probe (C4): decides ONLY whether to ALSO emit the debounced
  # unreachable notice. Deps + port are valid here, so the async
  # send-with-retry below ALWAYS dispatches — a transient false-negative
  # probe must never drop auto-speech.
  if ! listener_reachable; then
    notice_reason="$sid.listener-unreachable"
    notice_msg="speak plugin: the host listener on host.docker.internal:$port looks unreachable. Recommended (one-time, on your Mac): from the Plugins repo run ./plugins/speak/bin/speak agent install — it installs a LaunchAgent so the listener starts immediately, at every login, and restarts if it dies. One-off alternative: ./plugins/speak/bin/speak --serve in a Mac terminal (details: plugins/speak/README.md). The response was still sent in case this is a transient blip."
  fi
fi

# --- step 6: dispatch playback asynchronously, detached ------------------------
log_file="$state_dir/stop-hook.log"
tmp_text="$(mktemp "${TMPDIR:-/tmp}/speak-stop.XXXXXX" 2>/dev/null)" || exit 0
if ! printf '%s' "$text" >"$tmp_text" 2>/dev/null; then
  rm -f -- "$tmp_text"
  exit 0
fi
# The CHILD opens the temp file as its stdin, unlinks it (safe once open —
# the fd keeps the data), then execs bin/speak reading that fd. The parent
# never deletes it, so there is no read/delete race; the unlink survives even
# a crashed exec because it happens first. Explicit stdin handoff — the child
# never inherits the hook's (already-consumed) stdin. Detached via nohup + &;
# the hook exits immediately and playback duration never counts against the
# hook timeout. Child stdout/stderr -> log, never hook stdout (R28).
# shellcheck disable=SC2016  # single quotes deliberate: $1/$2 are the CHILD's argv
nohup env SPEAK_SESSION="$session_id_raw" bash -c '
  exec <"$1" || exit 1
  rm -f -- "$1"
  exec "$2"
' stop-speak-child "$tmp_text" "$plugin_root/bin/speak" >>"$log_file" 2>&1 &

# Emit the prepared advisory notice (if any) AFTER dispatch — at most one JSON
# object on stdout per run, debounced per session+reason.
if [ -n "$notice_reason" ]; then
  emit_notice_once "$notice_reason" "$notice_msg"
fi

exit 0

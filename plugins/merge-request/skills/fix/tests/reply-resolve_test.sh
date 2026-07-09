#!/usr/bin/env bash
#
# reply-resolve_test.sh — tests for reply-resolve.sh (the acknowledge+resolve
# half of /merge-request:fix, fn-10.2).
#
# Run: bash plugins/merge-request/skills/fix/tests/reply-resolve_test.sh
#
# Isolation: gh and glab are MOCKED (tiny scripts on a PATH prepended ahead of
# the real ones) and record every invocation to a log file so we can assert the
# exact reply + resolve calls were made. jq is the REAL tool. No real forge, no
# network. MOCK_FAIL_RESOLVE makes the resolve step fail to exercise RESOLVED=0.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RR="$SCRIPT_DIR/../scripts/reply-resolve.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1  (got: ${2:-})"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

ROOT_TMP="$(mktemp -d)"
trap 'rm -rf "$ROOT_TMP"' EXIT
BIN="$ROOT_TMP/bin"; mkdir -p "$BIN"
LOG="$ROOT_TMP/calls.log"

# --- gh mock ---------------------------------------------------------------
# Logs every call. A graphql mutation carrying `resolveReviewThread` is the
# resolve step; anything with `addPullRequestReviewThreadReply` is the reply.
# MOCK_FAIL_RESOLVE=1 makes the resolve mutation exit non-zero.
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"
echo "gh $args" >> "$MOCK_LOG"
if [[ "$args" == *"resolveReviewThread"* ]]; then
  [ -n "${MOCK_FAIL_RESOLVE:-}" ] && { echo "resolve boom" >&2; exit 1; }
  echo '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}'; exit 0
fi
if [[ "$args" == *"addPullRequestReviewThreadReply"* ]]; then
  echo '{"data":{"addPullRequestReviewThreadReply":{"comment":{"id":"C_1"}}}}'; exit 0
fi
if [[ "$args" == *"pr comment"* ]]; then exit 0; fi
exit 0
EOF
chmod +x "$BIN/gh"

# --- glab mock -------------------------------------------------------------
# A PUT with resolved=true is the resolve step; a POST to .../notes is the reply.
cat > "$BIN/glab" <<'EOF'
#!/usr/bin/env bash
args="$*"
echo "glab $args" >> "$MOCK_LOG"
if [[ "$args" == *"--method PUT"* && "$args" == *"resolved=true"* ]]; then
  [ -n "${MOCK_FAIL_RESOLVE:-}" ] && { echo "resolve boom" >&2; exit 1; }
  echo '{"resolved":true}'; exit 0
fi
if [[ "$args" == *"/notes"* && "$args" == *"--method POST"* ]]; then
  echo '{"id":123}'; exit 0
fi
exit 0
EOF
chmod +x "$BIN/glab"

run() {
  : > "$LOG"
  OUT="$( PATH="$BIN:$PATH" MOCK_LOG="$LOG" bash "$RR" "$@" 2>"$ROOT_TMP/err" )"; RC=$?
  ERR="$(cat "$ROOT_TMP/err")"
}
runf() { # run with MOCK_FAIL_RESOLVE set
  : > "$LOG"
  OUT="$( PATH="$BIN:$PATH" MOCK_LOG="$LOG" MOCK_FAIL_RESOLVE=1 bash "$RR" "$@" 2>"$ROOT_TMP/err" )"; RC=$?
  ERR="$(cat "$ROOT_TMP/err")"
}
trailer() { printf '%s\n' "$OUT" | grep -m1 "^$1=" | cut -d= -f2-; }

echo "== merge-request:fix — reply-resolve.sh =="

# --- argument / usage guards ----------------------------------------------
run; check "no args: exit 2" "[ \"$RC\" = 2 ]" "$RC"
run --forge github --id 5 --kind thread; check "missing --source-id: exit 2" "[ \"$RC\" = 2 ]" "$RC"
run --forge github --id 5 --source-id x --kind thread ; # ok baseline handled below
run --forge bitbucket --id 5 --kind thread --source-id x; check "bad forge: exit 2" "[ \"$RC\" = 2 ]" "$RC"
run --forge github --id 5 --kind bogus --source-id x; check "bad kind: exit 2" "[ \"$RC\" = 2 ]" "$RC"
run --forge github --id 5 --kind ci-job --source-id x; check "ci-job kind rejected: exit 2" "[ \"$RC\" = 2 ]" "$RC"
run --forge github --id 'abc' --kind thread --source-id x; check "non-numeric id: exit 2" "[ \"$RC\" = 2 ]" "$RC"
check "non-numeric id: message mentions numeric" "printf '%s' \"$ERR\" | grep -qi numeric"

# --- github thread: reply exactly 'Fixed' then resolve ---------------------
run --forge github --id 42 --kind thread --source-id RT_9
check "gh thread: exit 0" "[ \"$RC\" = 0 ]" "$RC ($ERR)"
check "gh thread: REPLY_POSTED=1" "[ \"$(trailer REPLY_POSTED)\" = 1 ]" "$(trailer REPLY_POSTED)"
check "gh thread: RESOLVED=1" "[ \"$(trailer RESOLVED)\" = 1 ]" "$(trailer RESOLVED)"
check "gh thread: reply mutation was called" "grep -q 'addPullRequestReviewThreadReply' '$LOG'"
check "gh thread: reply body is exactly Fixed" "grep -q 'body=Fixed' '$LOG'"
check "gh thread: resolve mutation was called with the node id" "grep -q 'resolveReviewThread' '$LOG' && grep -q 'tid=RT_9' '$LOG'"

# --- github thread: resolve failure -> RESOLVED=0, exit 1 ------------------
runf --forge github --id 42 --kind thread --source-id RT_9
check "gh thread resolve-fail: exit 1" "[ \"$RC\" = 1 ]" "$RC"
check "gh thread resolve-fail: REPLY_POSTED=1 (reply still went out)" "[ \"$(trailer REPLY_POSTED)\" = 1 ]" "$(trailer REPLY_POSTED)"
check "gh thread resolve-fail: RESOLVED=0" "[ \"$(trailer RESOLVED)\" = 0 ]" "$(trailer RESOLVED)"

# --- github comment: non-resolvable fallback -> post note, skip resolve ----
run --forge github --id 42 --kind comment --source-id IC_3
check "gh comment: exit 0" "[ \"$RC\" = 0 ]" "$RC ($ERR)"
check "gh comment: REPLY_POSTED=1" "[ \"$(trailer REPLY_POSTED)\" = 1 ]" "$(trailer REPLY_POSTED)"
check "gh comment: RESOLVED=skipped" "[ \"$(trailer RESOLVED)\" = skipped ]" "$(trailer RESOLVED)"
check "gh comment: posted a general PR comment" "grep -q 'pr comment 42' '$LOG'"
check "gh comment: NO resolve mutation" "! grep -q 'resolveReviewThread' '$LOG'"

# --- gitlab thread: reply note then PUT resolved=true ----------------------
run --forge gitlab --id 55 --kind thread --source-id disc7
check "glab thread: exit 0" "[ \"$RC\" = 0 ]" "$RC ($ERR)"
check "glab thread: REPLY_POSTED=1" "[ \"$(trailer REPLY_POSTED)\" = 1 ]" "$(trailer REPLY_POSTED)"
check "glab thread: RESOLVED=1" "[ \"$(trailer RESOLVED)\" = 1 ]" "$(trailer RESOLVED)"
check "glab thread: posted reply note to the discussion" "grep -q 'discussions/disc7/notes' '$LOG' && grep -q 'method POST' '$LOG'"
check "glab thread: reply body is exactly Fixed" "grep -q 'body=Fixed' '$LOG'"
check "glab thread: PUT resolved=true on the discussion" "grep -q 'method PUT' '$LOG' && grep -q 'resolved=true' '$LOG'"

# --- gitlab thread: resolve failure -> RESOLVED=0, exit 1 ------------------
runf --forge gitlab --id 55 --kind thread --source-id disc7
check "glab thread resolve-fail: exit 1" "[ \"$RC\" = 1 ]" "$RC"
check "glab thread resolve-fail: RESOLVED=0" "[ \"$(trailer RESOLVED)\" = 0 ]" "$(trailer RESOLVED)"

# --- gitlab comment: non-resolvable fallback -------------------------------
run --forge gitlab --id 55 --kind comment --source-id note9
check "glab comment: exit 0" "[ \"$RC\" = 0 ]" "$RC ($ERR)"
check "glab comment: RESOLVED=skipped" "[ \"$(trailer RESOLVED)\" = skipped ]" "$(trailer RESOLVED)"
check "glab comment: posted a general MR note (not a discussion)" "grep -q 'merge_requests/55/notes' '$LOG'"
check "glab comment: NO PUT resolve" "! grep -q 'method PUT' '$LOG'"

echo
echo "== reply-resolve_test: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]

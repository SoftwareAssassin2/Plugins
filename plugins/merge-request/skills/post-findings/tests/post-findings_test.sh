#!/usr/bin/env bash
#
# post-findings_test.sh — tests for the two deterministic scripts of
# /merge-request:post-findings: post-inline-comment.sh and approve-and-lgtm.sh.
#
# Run: bash plugins/merge-request/skills/post-findings/tests/post-findings_test.sh
#
# Isolation: gh and glab are fully MOCKED. Each mock appends its full invocation
# (one arg per line) to $MOCK_LOG so a test can assert exactly what would have
# been sent to the forge — no real posts, no real approvals. The mock bin dir is
# PREPENDED to PATH so the mocks shadow real gh/glab while real coreutils (awk,
# grep, sha1sum, jq) still resolve. jq is required by the gitlab inline path; if
# it's absent those two checks are skipped (noted), never failed.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
POST="$SCRIPT_DIR/../scripts/post-inline-comment.sh"
APPROVE="$SCRIPT_DIR/../scripts/approve-and-lgtm.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1  (got: ${2:-})"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

ROOT_TMP="$(mktemp -d)"
trap 'rm -rf "$ROOT_TMP"' EXIT

BIN="$ROOT_TMP/bin"
mkdir -p "$BIN"

# --- gh mock ---------------------------------------------------------------
# Logs every arg. Behavior: `gh api .../comments` (inline) and `gh pr comment`
# (general) succeed unless MOCK_POST_FAIL is set; `gh pr review --approve`
# succeeds unless MOCK_APPROVE_FAIL is set.
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
{ echo "CMD gh"; for a in "$@"; do printf 'ARG %s\n' "$a"; done; echo "END"; } >> "${MOCK_LOG:-/dev/null}"
if [ "${1:-}" = api ]; then
  [ -n "${MOCK_POST_FAIL:-}" ] && { echo "422 line not part of diff" >&2; exit 1; }
  echo '{"id":123,"html_url":"https://github.com/o/r/pull/1#c123"}'; exit 0
fi
if [ "${1:-}" = pr ] && [ "${2:-}" = comment ]; then
  [ -n "${MOCK_POST_FAIL:-}" ] && { echo "comment failed" >&2; exit 1; }
  echo "https://github.com/o/r/pull/1#issuecomment-9"; exit 0
fi
if [ "${1:-}" = pr ] && [ "${2:-}" = review ]; then
  [ -n "${MOCK_APPROVE_FAIL:-}" ] && { echo "cannot approve your own PR" >&2; exit 1; }
  exit 0
fi
exit 0
EOF
chmod +x "$BIN/gh"

# --- glab mock -------------------------------------------------------------
cat > "$BIN/glab" <<'EOF'
#!/usr/bin/env bash
{ echo "CMD glab"; for a in "$@"; do printf 'ARG %s\n' "$a"; done; echo "END"; } >> "${MOCK_LOG:-/dev/null}"
if [ "${1:-}" = api ]; then
  [ -n "${MOCK_POST_FAIL:-}" ] && { echo "400 position invalid" >&2; exit 1; }
  echo '{"id":"disc1","notes":[{"id":55}]}'; exit 0
fi
if [ "${1:-}" = mr ] && [ "${2:-}" = approve ]; then
  [ -n "${MOCK_APPROVE_FAIL:-}" ] && { echo "cannot approve" >&2; exit 1; }
  exit 0
fi
exit 0
EOF
chmod +x "$BIN/glab"

PATH="$BIN:$PATH"; export PATH

# Exact finding text (Conventional Comments prefix + body) — reused as the
# approval preview and the posted body; the two must be byte-identical.
BODY='issue: On create error this reopens a blank dialog; keep the form open.'

# run <log> -- <script> args...   → RC set, MOCK_LOG points at <log>
run() {
  local log="$1"; shift; [ "$1" = "--" ] && shift
  : > "$log"
  # MOCK_LOG must be an ENV var of the invoked command (the mocks are external
  # scripts), so set it as a command prefix inside the substitution.
  OUT="$( MOCK_LOG="$log" "$@" 2>"$ROOT_TMP/err" )"; RC=$?
  ERR="$(cat "$ROOT_TMP/err")"
}

# ===========================================================================
# post-inline-comment.sh
# ===========================================================================
echo "== post-inline-comment.sh =="

# 1. GitHub inline, single line — posts to the review-comments endpoint with the
#    exact body, commit_id, path, side, and line.
LOG="$ROOT_TMP/log1"
run "$LOG" -- bash "$POST" --forge github --id 77 \
  --file src/app.ts --line 42 --side RIGHT --head-sha abc123 --body "$BODY"
check "gh inline: exit 0"              "[ \"$RC\" = 0 ]" "$RC"
check "gh inline: hit comments endpoint" "grep -q 'ARG repos/{owner}/{repo}/pulls/77/comments' '$LOG'"
check "gh inline: body verbatim"      "grep -qF 'ARG body=$BODY' '$LOG'"
check "gh inline: commit_id = head"   "grep -qF 'ARG commit_id=abc123' '$LOG'"
check "gh inline: path"               "grep -qF 'ARG path=src/app.ts' '$LOG'"
check "gh inline: side RIGHT"         "grep -qF 'ARG side=RIGHT' '$LOG'"
check "gh inline: line 42"            "grep -qF 'ARG line=42' '$LOG'"
check "gh inline: POSTED=inline"      "printf '%s' \"$OUT\" | grep -q '^POSTED=inline$'"
check "gh inline: no general comment" "! grep -q 'ARG comment' '$LOG'"

# 2. GitHub inline, multi-line range — start_line + line, both sides.
LOG="$ROOT_TMP/log2"
run "$LOG" -- bash "$POST" --forge github --id 77 \
  --file src/app.ts --line-range 40-42 --side RIGHT --head-sha abc123 --body "$BODY"
check "gh range: exit 0"        "[ \"$RC\" = 0 ]" "$RC"
check "gh range: start_line=40" "grep -qF 'ARG start_line=40' '$LOG'"
check "gh range: line=42"       "grep -qF 'ARG line=42' '$LOG'"
check "gh range: start_side"    "grep -qF 'ARG start_side=RIGHT' '$LOG'"

# 3. Missing location (no side) → general fallback with EXACTLY the body, no wrapper.
LOG="$ROOT_TMP/log3"
run "$LOG" -- bash "$POST" --forge github --id 77 \
  --file src/app.ts --line 42 --head-sha abc123 --body "$BODY"
check "gh fallback: exit 0"            "[ \"$RC\" = 0 ]" "$RC"
check "gh fallback: POSTED=general"    "printf '%s' \"$OUT\" | grep -q '^POSTED=general$'"
check "gh fallback: general endpoint"  "grep -q 'ARG comment' '$LOG'"
check "gh fallback: body verbatim, no wrapper" "grep -qxF 'ARG $BODY' '$LOG'"
check "gh fallback: not inline"        "! grep -q 'comments' '$LOG'"

# 4. --general forces a general comment even with a full valid location.
LOG="$ROOT_TMP/log4"
run "$LOG" -- bash "$POST" --forge github --id 77 --general \
  --file src/app.ts --line 42 --side RIGHT --head-sha abc123 --body "$BODY"
check "gh --general: POSTED=general" "printf '%s' \"$OUT\" | grep -q '^POSTED=general$'"
check "gh --general: general endpoint" "grep -q 'ARG comment' '$LOG'"

# 5. Inline post failure → exit 1, nothing else claimed; failure surfaced.
LOG="$ROOT_TMP/log5"
MOCK_POST_FAIL=1 run "$LOG" -- bash "$POST" --forge github --id 77 \
  --file src/app.ts --line 42 --side RIGHT --head-sha abc123 --body "$BODY"
unset MOCK_POST_FAIL
check "gh post fail: exit 1"          "[ \"$RC\" = 1 ]" "$RC"
check "gh post fail: no RESTAGED line" "! printf '%s' \"$OUT\" | grep -q 'RESTAGED'"

# 6. GitLab inline — discussion with the base/start/head SHA position triple.
LOG="$ROOT_TMP/log6"
if command -v jq >/dev/null 2>&1 && command -v sha1sum >/dev/null 2>&1; then
  run "$LOG" -- bash "$POST" --forge gitlab --id 88 \
    --file src/app.ts --line 42 --head-sha hhh --base-sha bbb --body "$BODY"
  check "glab inline: exit 0"            "[ \"$RC\" = 0 ]" "$RC"
  check "glab inline: discussions"       "grep -q 'ARG projects/:id/merge_requests/88/discussions' '$LOG'"
  check "glab inline: base_sha"          "grep -qF 'ARG position[base_sha]=bbb' '$LOG'"
  check "glab inline: start defaults to base" "grep -qF 'ARG position[start_sha]=bbb' '$LOG'"
  check "glab inline: head_sha"          "grep -qF 'ARG position[head_sha]=hhh' '$LOG'"
  check "glab inline: new_line"          "grep -qF 'ARG position[new_line]=42' '$LOG'"
  check "glab inline: body verbatim"     "grep -qF 'ARG body=$BODY' '$LOG'"
else
  echo "  skip - glab inline path (jq/sha1sum unavailable)"
fi

# 7. GitLab missing base_sha → general note fallback with exact body.
LOG="$ROOT_TMP/log7"
run "$LOG" -- bash "$POST" --forge gitlab --id 88 \
  --file src/app.ts --line 42 --head-sha hhh --body "$BODY"
check "glab fallback: POSTED=general"   "printf '%s' \"$OUT\" | grep -q '^POSTED=general$'"
check "glab fallback: notes endpoint"   "grep -q 'ARG projects/:id/merge_requests/88/notes' '$LOG'"
check "glab fallback: body verbatim"    "grep -qF 'ARG body=$BODY' '$LOG'"

# ===========================================================================
# post-inline-comment.sh — edit / restage (R8)
# ===========================================================================
echo "== restage (edit-by-stable-id) =="

# Build a fixture artifact with three findings + surrounding sections.
mk_artifact() {
  cat > "$1" <<'EOF'
# Merge review: 77

id: 77
forge: github
Reviewed at commit: abc123
<!-- merge-review-status: findings -->

## Intent

Wire the clients page to the API.

## Handled

## Declined

## Findings

```jsonl
{"id":"F-aaa","prefix":"issue:","kind":"inline","file":"a.ts","old_path":null,"line":10,"line_range":null,"side":"RIGHT","head_sha":"abc123","base_sha":"def456","body":"first"}
{"id":"F-bbb","prefix":"suggestion:","kind":"inline","file":"b.ts","old_path":null,"line":20,"line_range":null,"side":"RIGHT","head_sha":"abc123","base_sha":"def456","body":"second original"}
{"id":"F-ccc","prefix":"question:","kind":"general","file":null,"old_path":null,"line":null,"line_range":null,"side":null,"head_sha":null,"base_sha":null,"body":"third"}
```

## Build

build/test: pass
EOF
}

NEWREC='{"id":"F-bbb","prefix":"suggestion:","kind":"inline","file":"b.ts","old_path":null,"line":20,"line_range":null,"side":"RIGHT","head_sha":"abc123","base_sha":"def456","body":"second EDITED"}'

# 8. Edit F-bbb: posts the edited text AND rewrites only that record; the rest of
#    the file is byte-for-byte identical to a targeted single-line replacement.
ART="$ROOT_TMP/77.md"; EXP="$ROOT_TMP/77.expected"
mk_artifact "$ART"
mk_artifact "$EXP"
# Expected = original with ONLY the F-bbb line swapped for NEWREC.
awk -v r="$NEWREC" '/"id":"F-bbb"/{print r; next} {print}' "$ART" > "$EXP.tmp" && mv "$EXP.tmp" "$EXP"
LOG="$ROOT_TMP/log8"
run "$LOG" -- bash "$POST" --forge github --id 77 \
  --file b.ts --line 20 --side RIGHT --head-sha abc123 \
  --body 'suggestion: second EDITED' \
  --stage-file "$ART" --stage-id F-bbb --stage-record "$NEWREC"
check "edit: exit 0"                 "[ \"$RC\" = 0 ]" "$RC"
check "edit: RESTAGED=1"             "printf '%s' \"$OUT\" | grep -q '^RESTAGED=1$'"
check "edit: posted edited text"     "grep -qF 'ARG body=suggestion: second EDITED' '$LOG'"
check "edit: F-bbb rewritten"        "grep -qF 'second EDITED' '$ART'"
check "edit: old F-bbb body gone"    "! grep -qF 'second original' '$ART'"
check "edit: other findings intact"  "grep -qF '\"id\":\"F-aaa\"' '$ART' && grep -qF '\"id\":\"F-ccc\"' '$ART'"
check "edit: byte-for-byte vs targeted swap" "diff -q '$ART' '$EXP' >/dev/null"

# 9. Restage with an unknown id → dies BEFORE posting (nothing sent to forge).
ART2="$ROOT_TMP/77b.md"; mk_artifact "$ART2"
LOG="$ROOT_TMP/log9"
run "$LOG" -- bash "$POST" --forge github --id 77 --general \
  --body 'issue: x' --stage-file "$ART2" --stage-id F-zzz --stage-record "$NEWREC"
check "unknown id: exit 1"        "[ \"$RC\" = 1 ]" "$RC"
check "unknown id: nothing posted" "[ ! -s '$LOG' ]"
check "unknown id: artifact untouched" "grep -qF 'second original' '$ART2'"

# ===========================================================================
# approve-and-lgtm.sh (R2)
# ===========================================================================
echo "== approve-and-lgtm.sh =="

mk_clean() {
  cat > "$1" <<'EOF'
# Merge review: 90

id: 90
forge: github
Reviewed at commit: sha999
<!-- merge-review-status: clean -->

## Intent

A tidy change.

## Findings

(none — cleared the bar)

## Build

build/test: pass
EOF
}

# 10. Clean (marker + zero findings) → approve + EXACTLY "Looks good." (GitHub).
#     The note is the approving review's body — ONE atomic gh call, no partial state.
CLEAN="$ROOT_TMP/90.md"; mk_clean "$CLEAN"
LOG="$ROOT_TMP/log10"
run "$LOG" -- bash "$APPROVE" --forge github --id 90 --artifact "$CLEAN"
check "clean gh: exit 0"            "[ \"$RC\" = 0 ]" "$RC"
check "clean gh: approved"          "grep -q 'ARG --approve' '$LOG'"
check "clean gh: note is exactly Looks good." "grep -qxF 'ARG Looks good.' '$LOG'"
check "clean gh: note carried by the approve call" "grep -q 'ARG --body' '$LOG'"
check "clean gh: APPROVED=1"        "printf '%s' \"$OUT\" | grep -q '^APPROVED=1$'"
check "clean gh: single atomic gh call" "[ \"\$(grep -c 'CMD gh' '$LOG')\" = 1 ]"

# 11. Clean (GitLab) → note posted FIRST, then glab mr approve; note exactly "Looks good."
CLEANL="$ROOT_TMP/90l.md"; mk_clean "$CLEANL"
LOG="$ROOT_TMP/log11"
run "$LOG" -- bash "$APPROVE" --forge gitlab --id 90 --artifact "$CLEANL"
check "clean glab: exit 0"          "[ \"$RC\" = 0 ]" "$RC"
check "clean glab: mr approve"      "grep -q 'ARG approve' '$LOG'"
check "clean glab: note body"       "grep -qxF 'ARG body=Looks good.' '$LOG'"
# Failure-safety: the note must precede the approval, so a failed approve can
# never leave an MR approved without its note.
check "clean glab: note precedes approve" \
  "[ \"\$(grep -n 'merge_requests/90/notes' '$LOG' | head -1 | cut -d: -f1)\" -lt \"\$(grep -n 'CMD glab' '$LOG' | tail -1 | cut -d: -f1)\" ]"

# 11b. GitLab note fails → MR is NOT approved (note-first ordering).
CLEANL2="$ROOT_TMP/90l2.md"; mk_clean "$CLEANL2"
LOG="$ROOT_TMP/log11b"
MOCK_POST_FAIL=1 run "$LOG" -- bash "$APPROVE" --forge gitlab --id 90 --artifact "$CLEANL2"
unset MOCK_POST_FAIL
check "glab note-fail: exit 1"        "[ \"$RC\" = 1 ]" "$RC"
check "glab note-fail: not approved"  "! grep -q 'ARG approve' '$LOG'"
check "glab note-fail: says not approved" "printf '%s' \"$ERR\" | grep -qi 'NOT approved'"

# 12. Marker present but FINDINGS staged → refuse, approve nothing.
ART3="$ROOT_TMP/hasfind.md"; mk_artifact "$ART3"
# force the marker to clean while findings still present (marker/section disagree)
sed 's/merge-review-status: findings/merge-review-status: clean/' "$ART3" > "$ART3.x" && mv "$ART3.x" "$ART3"
LOG="$ROOT_TMP/log12"
run "$LOG" -- bash "$APPROVE" --forge github --id 77 --artifact "$ART3"
check "marker-but-findings: exit 1"    "[ \"$RC\" = 1 ]" "$RC"
check "marker-but-findings: no approve" "[ ! -s '$LOG' ]"
check "marker-but-findings: says not clean" "printf '%s' \"$ERR\" | grep -qi 'not clean'"

# 13. Missing marker (findings artifact as-is) → refuse.
ART4="$ROOT_TMP/nomarker.md"; mk_artifact "$ART4"  # marker = findings
LOG="$ROOT_TMP/log13"
run "$LOG" -- bash "$APPROVE" --forge github --id 77 --artifact "$ART4"
check "no clean marker: exit 1"     "[ \"$RC\" = 1 ]" "$RC"
check "no clean marker: no approve" "[ ! -s '$LOG' ]"
check "no clean marker: says marker" "printf '%s' \"$ERR\" | grep -qi 'marker'"

# 14. Malformed: clean marker but NO ## Findings heading at all → refuse.
MAL="$ROOT_TMP/malformed.md"
{ echo "# Merge review: 12"; echo; echo "<!-- merge-review-status: clean -->"; echo; echo "## Build"; echo "pass"; } > "$MAL"
LOG="$ROOT_TMP/log14"
run "$LOG" -- bash "$APPROVE" --forge github --id 12 --artifact "$MAL"
check "malformed: exit 1"        "[ \"$RC\" = 1 ]" "$RC"
check "malformed: no approve"    "[ ! -s '$LOG' ]"
check "malformed: mentions Findings/malformed" "printf '%s' \"$ERR\" | grep -qiE 'Findings|malformed'"

# 15. Missing artifact file → refuse (no proof of a clean review).
LOG="$ROOT_TMP/log15"
run "$LOG" -- bash "$APPROVE" --forge github --id 5 --artifact "$ROOT_TMP/nope.md"
check "missing artifact: exit 1"  "[ \"$RC\" = 1 ]" "$RC"
check "missing artifact: no approve" "[ ! -s '$LOG' ]"

# 16. Approve API failure → exit 1, note never attempted.
mk_clean "$ROOT_TMP/failapprove.md"
LOG="$ROOT_TMP/log16"
MOCK_APPROVE_FAIL=1 run "$LOG" -- bash "$APPROVE" --forge github --id 90 --artifact "$ROOT_TMP/failapprove.md"
unset MOCK_APPROVE_FAIL
check "approve fail: exit 1"      "[ \"$RC\" = 1 ]" "$RC"
check "approve fail: no note posted" "! grep -q 'ARG comment' '$LOG'"

# ===========================================================================
# argument validation
# ===========================================================================
echo "== argument validation =="

run "$ROOT_TMP/logv1" -- bash "$POST" --forge svn --id 1 --body x
check "post: bad forge → exit 2" "[ \"$RC\" = 2 ]" "$RC"
run "$ROOT_TMP/logv2" -- bash "$POST" --forge github --id abc --body x
check "post: non-numeric id → exit 2" "[ \"$RC\" = 2 ]" "$RC"
run "$ROOT_TMP/logv3" -- bash "$POST" --forge github --id 1
check "post: missing body → exit 2" "[ \"$RC\" = 2 ]" "$RC"
run "$ROOT_TMP/logv4" -- bash "$APPROVE" --forge github --id 1
check "approve: missing artifact arg → exit 2" "[ \"$RC\" = 2 ]" "$RC"
run "$ROOT_TMP/logv5" -- bash "$POST" --forge github --id 1 --body x --stage-file /nope --stage-id F-x
check "post: partial --stage-* → exit 2" "[ \"$RC\" = 2 ]" "$RC"

echo
echo "== post-findings_test: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]

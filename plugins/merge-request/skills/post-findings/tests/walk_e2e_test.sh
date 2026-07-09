#!/usr/bin/env bash
#
# walk_e2e_test.sh — end-to-end fixture harness for /merge-request:post-findings.
#
# Run: bash plugins/merge-request/skills/post-findings/tests/walk_e2e_test.sh
#
# The other suites exercise each deterministic script in isolation. This one
# drives them IN THE SEQUENCE THE SKILL ORCHESTRATES against a staged
# `.data/merge/<ID>.md` fixture — proving the scripts compose correctly and that
# every section the walk does not target stays byte-for-byte intact throughout.
#
# For each staged finding the skill lets the user approve / edit / skip:
#   approve → post-inline-comment.sh            (inline forge call, no restage)
#   edit    → post-inline-comment.sh --stage-*  (post edited body, restage by id)
#   skip    → merge-prefs.sh declined-append    (append-only ## Declined record)
# and, on a fully CLEAN review, approve-and-lgtm.sh signs off with exactly
# `Looks good.`. A malformed / marker-missing artifact must be refused.
#
# Isolation: git, gh and glab are fully MOCKED (mock bin PREPENDED to PATH so real
# coreutils still resolve). Each mock appends its full invocation to $MOCK_LOG so
# a test can assert exactly what would have hit the forge — no real posts, no real
# approvals, no network.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
POST="$SCRIPT_DIR/../scripts/post-inline-comment.sh"
APPROVE="$SCRIPT_DIR/../scripts/approve-and-lgtm.sh"
MP="$SCRIPT_DIR/../scripts/merge-prefs.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1  (got: ${2:-})"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

ROOT_TMP="$(mktemp -d)"
trap 'rm -rf "$ROOT_TMP"' EXIT

BIN="$ROOT_TMP/bin"
mkdir -p "$BIN"

# --- mocks: git / gh / glab ------------------------------------------------
# git is not called by these scripts, but the harness mocks it too so the walk
# can never reach a real repo. gh/glab mirror the per-script suite's mocks.
cat > "$BIN/git" <<'EOF'
#!/usr/bin/env bash
{ echo "CMD git"; for a in "$@"; do printf 'ARG %s\n' "$a"; done; echo "END"; } >> "${MOCK_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$BIN/git"

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

# run <log> -- <cmd> args...   → RC set, OUT captured, MOCK_LOG points at <log>.
run() {
  local log="$1"; shift; [ "$1" = "--" ] && shift
  : > "$log"
  # shellcheck disable=SC2034
  OUT="$( MOCK_LOG="$log" "$@" 2>"$ROOT_TMP/err" )"; RC=$?
  # shellcheck disable=SC2034
  ERR="$(cat "$ROOT_TMP/err")"
}

# section <file> <name> → the BODY lines of `## <name>` (heading excluded), used
# to assert a section is byte-for-byte unchanged across a walk step.
section() {
  awk -v n="$2" '
    /^## / { inS = ($0 == "## " n); next }
    inS { print }
  ' "$1"
}

# ===========================================================================
# The staged findings walk: approve → edit → skip, in skill order.
# ===========================================================================
echo "== walk: approve / edit / skip (github) =="

# A staged findings artifact: header + marker, Intent/Handled to prove
# preservation, an (empty) Declined the skip will append to, and three findings —
# one full-location inline (approve), one inline (edit), one missing-location
# general (skip).
mk_findings() {
  cat > "$1" <<'EOF'
# Merge review: 101

id: 101
forge: github
Reviewed at commit: abc123
<!-- merge-review-status: findings -->

## Intent

Wire the clients page to the API — keep the form open on a create error.

## Handled

- **thread#5** — already implemented in an earlier commit

## Declined

## Findings

```jsonl
{"id":"F-approve","prefix":"issue:","kind":"inline","file":"src/app.ts","old_path":null,"line":42,"line_range":null,"side":"RIGHT","head_sha":"abc123","base_sha":"def456","body":"reopens a blank dialog on create error"}
{"id":"F-edit","prefix":"suggestion:","kind":"inline","file":"src/api.ts","old_path":null,"line":20,"line_range":null,"side":"RIGHT","head_sha":"abc123","base_sha":"def456","body":"original suggestion body"}
{"id":"F-skip","prefix":"question:","kind":"general","file":null,"old_path":null,"line":null,"line_range":null,"side":null,"head_sha":null,"base_sha":null,"body":"missing location — general, nitpick"}
```

## Build

build/test: pass
EOF
}

ART="$ROOT_TMP/101.md"; mk_findings "$ART"
PRISTINE="$ROOT_TMP/101.pristine"; cp "$ART" "$PRISTINE"

# Snapshot the sections the walk must never disturb. These are consumed only
# inside the deferred `check` eval strings, which shellcheck cannot see through.
# shellcheck disable=SC2034
INTENT0="$(section "$ART" Intent)"
# shellcheck disable=SC2034
HANDLED0="$(section "$ART" Handled)"
# shellcheck disable=SC2034
BUILD0="$(section "$ART" Build)"

# --- step 1: APPROVE F-approve → inline post, artifact NOT touched ----------
LOG="$ROOT_TMP/log.approve"
run "$LOG" -- bash "$POST" --forge github --id 101 \
  --file src/app.ts --line 42 --side RIGHT --head-sha abc123 \
  --body 'issue: reopens a blank dialog on create error'
check "approve: exit 0"                 "[ \"$RC\" = 0 ]" "$RC"
check "approve: inline forge call"      "grep -q 'ARG repos/{owner}/{repo}/pulls/101/comments' '$LOG'"
check "approve: POSTED=inline"          "printf '%s' \"\$OUT\" | grep -q '^POSTED=inline$'"
check "approve: body verbatim"          "grep -qxF 'ARG body=issue: reopens a blank dialog on create error' '$LOG'"
# No --stage-* on an approve → the artifact is byte-for-byte unchanged.
check "approve: artifact untouched (whole file)" "diff -q '$ART' '$PRISTINE' >/dev/null"

# --- step 2: EDIT F-edit → post edited body AND restage by stable id --------
NEWREC='{"id":"F-edit","prefix":"suggestion:","kind":"inline","file":"src/api.ts","old_path":null,"line":20,"line_range":null,"side":"RIGHT","head_sha":"abc123","base_sha":"def456","body":"EDITED suggestion body"}'
# Expected artifact after the edit = pristine with ONLY the F-edit record swapped.
EXP_EDIT="$ROOT_TMP/101.edited.expected"
awk -v r="$NEWREC" '/"id":"F-edit"/{print r; next} {print}' "$PRISTINE" > "$EXP_EDIT"

LOG="$ROOT_TMP/log.edit"
run "$LOG" -- bash "$POST" --forge github --id 101 \
  --file src/api.ts --line 20 --side RIGHT --head-sha abc123 \
  --body 'suggestion: EDITED suggestion body' \
  --stage-file "$ART" --stage-id F-edit --stage-record "$NEWREC"
check "edit: exit 0"                    "[ \"$RC\" = 0 ]" "$RC"
check "edit: RESTAGED=1"                "printf '%s' \"\$OUT\" | grep -q '^RESTAGED=1$'"
check "edit: posted the EDITED body"    "grep -qF 'ARG body=suggestion: EDITED suggestion body' '$LOG'"
check "edit: F-edit record rewritten"   "grep -qF 'EDITED suggestion body' '$ART'"
check "edit: old F-edit body gone"      "! grep -qF 'original suggestion body' '$ART'"
check "edit: other findings intact"     "grep -qF '\"id\":\"F-approve\"' '$ART' && grep -qF '\"id\":\"F-skip\"' '$ART'"
check "edit: whole file == targeted swap only" "diff -q '$ART' '$EXP_EDIT' >/dev/null"
check "edit: Intent byte-for-byte"      "[ \"\$(section '$ART' Intent)\" = \"\$INTENT0\" ]"
check "edit: Handled byte-for-byte"     "[ \"\$(section '$ART' Handled)\" = \"\$HANDLED0\" ]"
check "edit: Build byte-for-byte"       "[ \"\$(section '$ART' Build)\" = \"\$BUILD0\" ]"

# --- step 3: SKIP F-skip → declined-append (append-only ## Declined) --------
# shellcheck disable=SC2034
FINDINGS_BEFORE_SKIP="$(section "$ART" Findings)"
LOG="$ROOT_TMP/log.skip"
run "$LOG" -- bash "$MP" declined-append --file "$ART" \
  --finding-id F-skip --summary "missing location — general, nitpick" \
  --rationale "declined at post gate"
check "skip: exit 0"                    "[ \"$RC\" = 0 ]" "$RC"
check "skip: DECLINED=F-skip"           "printf '%s' \"\$OUT\" | grep -q '^DECLINED=F-skip$'"
check "skip: ## Declined got the record" "grep -qF -- '- **F-skip** — missing location — general, nitpick — declined at post gate' '$ART'"
check "skip: record IS in ## Declined, before ## Findings" \
  "[ \"\$(grep -n 'F-skip' '$ART' | head -1 | cut -d: -f1)\" -lt \"\$(grep -n '^## Findings' '$ART' | cut -d: -f1)\" ]"
# Append-only: every other section stays byte-for-byte.
check "skip: Intent byte-for-byte"      "[ \"\$(section '$ART' Intent)\" = \"\$INTENT0\" ]"
check "skip: Handled byte-for-byte"     "[ \"\$(section '$ART' Handled)\" = \"\$HANDLED0\" ]"
check "skip: Build byte-for-byte"       "[ \"\$(section '$ART' Build)\" = \"\$BUILD0\" ]"
check "skip: Findings untouched by the skip" "[ \"\$(section '$ART' Findings)\" = \"\$FINDINGS_BEFORE_SKIP\" ]"

# Cumulative proof: the final artifact == pristine with ONLY the F-edit swap and
# the one appended ## Declined bullet — no other byte moved across the whole walk.
EXP_FINAL="$ROOT_TMP/101.final.expected"
awk -v r="$NEWREC" '
  /"id":"F-edit"/ { print r; next }
  /^## Declined[[:space:]]*$/ {
    print
    print "- **F-skip** — missing location — general, nitpick — declined at post gate"
    next
  }
  { print }
' "$PRISTINE" > "$EXP_FINAL"
check "walk: final artifact == pristine + edit swap + one declined bullet" \
  "diff -q '$ART' '$EXP_FINAL' >/dev/null"

# ===========================================================================
# Same walk step against GitLab — the inline call is forge-parametrized.
# ===========================================================================
echo "== walk: approve inline (gitlab) =="

if command -v sha1sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1; then
  LOG="$ROOT_TMP/log.gl"
  run "$LOG" -- bash "$POST" --forge gitlab --id 202 \
    --file src/app.ts --line 42 --head-sha hhh --base-sha bbb \
    --body 'issue: reopens a blank dialog on create error'
  check "gitlab approve: exit 0"           "[ \"$RC\" = 0 ]" "$RC"
  check "gitlab approve: discussions call" "grep -q 'ARG projects/:id/merge_requests/202/discussions' '$LOG'"
  check "gitlab approve: base_sha in position" "grep -qF 'ARG position[base_sha]=bbb' '$LOG'"
  check "gitlab approve: body verbatim"    "grep -qF 'ARG body=issue: reopens a blank dialog on create error' '$LOG'"
else
  echo "  skip - gitlab inline path (sha1sum/shasum unavailable)"
fi

# ===========================================================================
# Clean-gate path: a clean review is signed off with exactly `Looks good.`.
# ===========================================================================
echo "== clean gate: approve + Looks good. =="

CLEAN="$ROOT_TMP/303.md"
cat > "$CLEAN" <<'EOF'
# Merge review: 303

id: 303
forge: github
Reviewed at commit: sha999
<!-- merge-review-status: clean -->

## Intent

A tidy, self-contained change.

## Findings

```jsonl
```

## Build

build/test: pass
EOF
LOG="$ROOT_TMP/log.clean"
run "$LOG" -- bash "$APPROVE" --forge github --id 303 --artifact "$CLEAN"
check "clean: exit 0"                    "[ \"$RC\" = 0 ]" "$RC"
check "clean: approved"                  "grep -q 'ARG --approve' '$LOG'"
check "clean: note is exactly Looks good." "grep -qxF 'ARG Looks good.' '$LOG'"
check "clean: APPROVED=1"                "printf '%s' \"\$OUT\" | grep -q '^APPROVED=1$'"
check "clean: NOTE=Looks good."          "printf '%s' \"\$OUT\" | grep -qxF 'NOTE=Looks good.'"
check "clean: single atomic gh call"     "[ \"\$(grep -c 'CMD gh' '$LOG')\" = 1 ]"

# ===========================================================================
# Refusal path: a marker-missing / malformed artifact is never approved.
# ===========================================================================
echo "== refusal: marker missing / malformed =="

# The staged findings artifact carries the `findings` marker (not clean) — even
# though nothing new is being posted, the clean gate must refuse it.
LOG="$ROOT_TMP/log.refuse1"
run "$LOG" -- bash "$APPROVE" --forge github --id 101 --artifact "$PRISTINE"
check "refuse (findings marker): exit 1"  "[ \"$RC\" = 1 ]" "$RC"
check "refuse (findings marker): nothing hit the forge" "[ ! -s '$LOG' ]"
check "refuse (findings marker): says marker/clean" "printf '%s' \"\$ERR\" | grep -qiE 'marker|clean'"

# A malformed artifact: clean marker present but NO ## Findings section at all.
MAL="$ROOT_TMP/mal.md"
cat > "$MAL" <<'EOF'
# Merge review: 404

id: 404
<!-- merge-review-status: clean -->

## Build

pass
EOF
LOG="$ROOT_TMP/log.refuse2"
run "$LOG" -- bash "$APPROVE" --forge github --id 404 --artifact "$MAL"
check "refuse (malformed): exit 1"        "[ \"$RC\" = 1 ]" "$RC"
check "refuse (malformed): nothing hit the forge" "[ ! -s '$LOG' ]"
check "refuse (malformed): mentions Findings/malformed" "printf '%s' \"\$ERR\" | grep -qiE 'Findings|malformed'"

echo
echo "== walk_e2e_test: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]

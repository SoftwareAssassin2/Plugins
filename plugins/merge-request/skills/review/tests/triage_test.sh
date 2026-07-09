#!/usr/bin/env bash
#
# triage_test.sh — tests for triage.sh (scope + head-SHA skip check, fn-11.2).
#
# Run: bash plugins/merge-request/skills/review/tests/triage_test.sh
#
# Isolation: git, gh and glab are MOCKED (tiny scripts on a PATH prepended ahead
# of the real ones); jq / awk / grep are the REAL tools. No real repo, no forge,
# no network. Fixtures are driven by MOCK_* env vars. Artifacts are written into
# a real temp data dir (passed absolute so the main-worktree anchoring is a
# no-op) so the `Reviewed at commit:` skip/re-review branch is exercised for real.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TRIAGE="$SCRIPT_DIR/../scripts/triage.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1  (got: ${2:-})"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

ROOT_TMP="$(mktemp -d)"
trap 'rm -rf "$ROOT_TMP"' EXIT
BIN="$ROOT_TMP/bin"; mkdir -p "$BIN"

# --- git mock: just enough for triage (repo check + worktree root) ----------
cat > "$BIN/git" <<'EOF'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "rev-parse --is-inside-work-tree") exit 0 ;;
  "rev-parse --show-toplevel") echo "/main/root"; exit 0 ;;
  "worktree list") echo "worktree /main/root"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BIN/git"

# --- gh mock ---------------------------------------------------------------
# MOCK_LIST = space-separated open PR numbers (batch). MOCK_SHA = head oid the
# `pr view` metadata reports (empty => metadata "fails" => head unresolved).
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = pr ] && [ "$2" = list ]; then
  for n in ${MOCK_LIST:-}; do echo "$n"; done
  exit 0
fi
if [ "$1" = pr ] && [ "$2" = view ]; then
  [ -z "${MOCK_SHA:-}" ] && { echo ""; exit 0; }
  cat <<JSON
{"headRefOid":"${MOCK_SHA}","title":"A title","url":"https://gh/pr/${3}","headRefName":"feature","headRepository":{"name":"repo"},"headRepositoryOwner":{"login":"forkowner"}}
JSON
  exit 0
fi
exit 0
EOF
chmod +x "$BIN/gh"

# --- glab mock -------------------------------------------------------------
cat > "$BIN/glab" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = mr ] && [ "$2" = list ]; then
  printf '['; first=1
  for n in ${MOCK_LIST:-}; do [ $first = 1 ] || printf ','; printf '{"iid":%s}' "$n"; first=0; done
  printf ']\n'; exit 0
fi
if [ "$1" = mr ] && [ "$2" = view ]; then
  [ -z "${MOCK_SHA:-}" ] && { echo ""; exit 0; }
  echo "{\"diff_refs\":{\"head_sha\":\"${MOCK_SHA}\"},\"title\":\"A title\",\"web_url\":\"https://gl/mr/${3}\",\"source_branch\":\"feature\"}"
  exit 0
fi
exit 0
EOF
chmod +x "$BIN/glab"

DATA="$ROOT_TMP/data"; mkdir -p "$DATA"

run_triage() { # <forge> [extra args...]
  OUT="$( PATH="$BIN:$PATH" bash "$TRIAGE" --forge "$1" --data-dir "$DATA" "${@:2}" 2>"$ROOT_TMP/err" )"
  RC=$?; ERR="$(cat "$ROOT_TMP/err")"
}
# one <index> -> the JSON object at that array index
one() { printf '%s' "$OUT" | jq -c ".[$1]"; }
field() { printf '%s' "$OUT" | jq -r ".[${1}].${2}"; }
len() { printf '%s' "$OUT" | jq 'length'; }

echo "== merge-request:review — triage.sh =="

# 1. unsupported / missing forge -> exit 2.
( PATH="$BIN:$PATH" bash "$TRIAGE" --forge bitbucket ) >/dev/null 2>&1; RC=$?
check "unsupported forge: exit 2" "[ \"$RC\" = 2 ]" "$RC"
( PATH="$BIN:$PATH" bash "$TRIAGE" ) >/dev/null 2>&1; RC=$?
check "missing forge: exit 2" "[ \"$RC\" = 2 ]" "$RC"

# 2. non-numeric single id -> exit 2 (path-traversal guard).
( PATH="$BIN:$PATH" bash "$TRIAGE" --forge github --id ../../etc ) >/dev/null 2>&1; RC=$?
check "non-numeric id: exit 2" "[ \"$RC\" = 2 ]" "$RC"

# 3. single-ID, no artifact yet -> action=new, current_sha resolved.
export MOCK_SHA=aaaa111
run_triage github --id 5
check "new: exit 0"        "[ \"$RC\" = 0 ]" "$RC"
check "new: length 1"      "[ \"$(len)\" = 1 ]" "$(len)"
check "new: action=new"    "[ \"$(field 0 action)\" = new ]" "$(field 0 action)"
check "new: current_sha"   "[ \"$(field 0 current_sha)\" = aaaa111 ]" "$(field 0 current_sha)"
check "new: id numeric"    "[ \"$(field 0 id)\" = 5 ]" "$(field 0 id)"

# 4. skip: artifact records the SAME sha as head -> action=skip (no rework).
cat > "$DATA/6.md" <<MD
# Merge review: 6
Reviewed at commit: bbbb222
<!-- merge-review-status: clean -->
MD
export MOCK_SHA=bbbb222
run_triage github --id 6
check "skip: action=skip"      "[ \"$(field 0 action)\" = skip ]" "$(field 0 action)"
check "skip: recorded matches" "[ \"$(field 0 recorded_sha)\" = bbbb222 ]" "$(field 0 recorded_sha)"

# 5. re-review: artifact records an OLDER sha than head -> action=re-review.
cat > "$DATA/7.md" <<MD
# Merge review: 7
Reviewed at commit: oldsha0
MD
export MOCK_SHA=newsha9
run_triage github --id 7
check "re-review: action" "[ \"$(field 0 action)\" = re-review ]" "$(field 0 action)"

# 6. head unresolved (metadata empty) + existing artifact -> NEVER skip.
cat > "$DATA/8.md" <<MD
# Merge review: 8
Reviewed at commit: ccccc33
MD
unset MOCK_SHA
run_triage github --id 8
check "unresolved head: action=re-review" "[ \"$(field 0 action)\" = re-review ]" "$(field 0 action)"
check "unresolved head: current_sha empty" "[ -z \"$(field 0 current_sha)\" ]" "$(field 0 current_sha)"

# 7. batch mode (no --id): enumerates every open PR.
export MOCK_SHA=deadbee MOCK_LIST="11 12 13"
run_triage github
check "batch: length 3" "[ \"$(len)\" = 3 ]" "$(len)"
check "batch: ids present" "printf '%s' \"\$OUT\" | jq -e '[.[].id]==[11,12,13]' >/dev/null" "$(printf '%s' "$OUT" | jq -c '[.[].id]')"
unset MOCK_LIST

# 8. batch with nothing open -> [].
export MOCK_LIST=""
run_triage github
check "empty batch: []" "[ \"$(len)\" = 0 ]" "$OUT"
unset MOCK_LIST

# 9. gitlab single-ID skip works via the glab metadata shape.
cat > "$DATA/20.md" <<MD
# Merge review: 20
Reviewed at commit: deadbeef1234
MD
export MOCK_SHA=deadbeef1234
run_triage gitlab --id 20
check "gitlab skip: action=skip" "[ \"$(field 0 action)\" = skip ]" "$(field 0 action)"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]

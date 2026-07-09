#!/usr/bin/env bash
#
# create_test.sh — tests for create.sh (the deterministic half of
# /merge-request:create).
#
# Run: bash plugins/merge-request/skills/create/tests/create_test.sh
#
# Isolation strategy: git, gh and glab are fully MOCKED. Each mock is a tiny
# script whose behavior is driven by MOCK_* env vars (upstream present?, commits
# ahead?, does creation report an existing PR/MR?, does the JSON `view` path
# return an id or force the URL fallback?). The mock bin dir is PREPENDED to PATH
# so the mocks shadow the real git/gh/glab while real coreutils still resolve.
# No real repo, no real forge, no PR/MR ever opened.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CREATE="$SCRIPT_DIR/../scripts/create.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1  (got: ${2:-})"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

ROOT_TMP="$(mktemp -d)"
trap 'rm -rf "$ROOT_TMP"' EXIT

BIN="$ROOT_TMP/bin"
mkdir -p "$BIN"

# --- git mock --------------------------------------------------------------
# Driven by: MOCK_BRANCH, MOCK_DEFAULT, MOCK_UPSTREAM (set=has upstream),
# MOCK_AHEAD (commit count), MOCK_PUSHLOG (file to record push invocations).
cat > "$BIN/git" <<'EOF'
#!/usr/bin/env bash
cmd="${1:-}"; shift || true
case "$cmd" in
  --version) echo "git version 0.0-mock" ;;
  rev-parse)
    case "$*" in
      *--is-inside-work-tree*) exit 0 ;;
      *@\{u\}*|*symbolic-full-name*)
        if [ -n "${MOCK_UPSTREAM:-}" ]; then echo "origin/${MOCK_BRANCH:-feature}"; exit 0; fi
        exit 128 ;;
      *HEAD*) echo "${MOCK_BRANCH:-feature}"; exit 0 ;;
      *) exit 0 ;;
    esac ;;
  rev-list) echo "${MOCK_AHEAD:-0}" ;;
  config)
    case "$*" in
      *.remote) echo "${MOCK_UP_REMOTE:-origin}" ;;
      *.merge)  echo "refs/heads/${MOCK_UP_REF:-${MOCK_BRANCH:-feature}}" ;;
      *) exit 1 ;;
    esac ;;
  symbolic-ref)
    if [ -n "${MOCK_DEFAULT:-}" ]; then echo "origin/${MOCK_DEFAULT}"; exit 0; fi
    exit 1 ;;
  remote) echo origin ;;
  push) printf 'push %s\n' "$*" >> "${MOCK_PUSHLOG:-/dev/null}" ;;
  log) echo "abc1234 first commit"; echo "def5678 second commit" ;;
  diff) echo " src/thing.txt | 4 ++--"; echo " 1 file changed, 2 insertions(+), 2 deletions(-)" ;;
  *) exit 0 ;;
esac
exit 0
EOF
chmod +x "$BIN/git"

# --- gh mock ---------------------------------------------------------------
# Driven by: MOCK_EXISTS (set=create reports an existing PR), MOCK_URLID (id in
# the emitted URL), MOCK_VIEW_ID (id returned by `pr view --json number`;
# empty => view fails => URL fallback).
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = pr ] && [ "${2:-}" = create ]; then
  if [ -n "${MOCK_EXISTS:-}" ]; then
    echo "a pull request for branch \"feature\" into \"main\" already exists:" >&2
    echo "https://github.com/o/r/pull/${MOCK_URLID:-77}" >&2
    exit 1
  fi
  echo "https://github.com/o/r/pull/${MOCK_URLID:-77}"
  exit 0
fi
if [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
  if [ -n "${MOCK_VIEW_ID:-}" ]; then echo "${MOCK_VIEW_ID}"; exit 0; fi
  exit 1
fi
exit 0
EOF
chmod +x "$BIN/gh"

# --- glab mock -------------------------------------------------------------
cat > "$BIN/glab" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = mr ] && [ "${2:-}" = create ]; then
  if [ -n "${MOCK_EXISTS:-}" ]; then
    echo "a merge request already exists for this branch" >&2
    echo "https://gitlab.com/o/r/-/merge_requests/${MOCK_URLID:-88}" >&2
    exit 1
  fi
  echo "https://gitlab.com/o/r/-/merge_requests/${MOCK_URLID:-88}"
  exit 0
fi
if [ "${1:-}" = mr ] && [ "${2:-}" = view ]; then
  if [ -n "${MOCK_VIEW_ID:-}" ]; then
    echo "{\"iid\": ${MOCK_VIEW_ID}, \"title\": \"x\"}"; exit 0
  fi
  echo "{}"; exit 0
fi
exit 0
EOF
chmod +x "$BIN/glab"

# run_create <forge> [extra args...] — runs create.sh under the mock PATH in a
# throwaway CWD. Reads MOCK_* / DATA_DIR / INTENT_FILE / PUSHLOG from the env of
# the caller. Sets OUT and RC.
run_create() {
  local forge="$1"; shift
  local cwd; cwd="$(mktemp -d "$ROOT_TMP/cwd.XXXXXX")"
  local args=(--forge "$forge" --data-dir "${DATA_DIR:-$cwd/.data/merge}")
  [ -n "${INTENT_FILE:-}" ] && args+=(--intent-file "$INTENT_FILE")
  OUT="$( cd "$cwd" && PATH="$BIN:$PATH" MOCK_PUSHLOG="${PUSHLOG:-/dev/null}" bash "$CREATE" "${args[@]}" 2>"$ROOT_TMP/err" )"
  RC=$?
  ERR="$(cat "$ROOT_TMP/err")"
}
val() { printf '%s\n' "$OUT" | grep -m1 "^$1=" | cut -d= -f2-; }

echo "== merge-request:create — create.sh =="

# 1. unsupported-forge hard-stop: exits 2, no forge work.
( PATH="$BIN:$PATH" bash "$CREATE" --forge unsupported ) >/dev/null 2>"$ROOT_TMP/err"; RC=$?
check "unsupported forge: exit 2" "[ \"$RC\" = 2 ]" "$RC"
check "unsupported forge: message names it" "grep -qi 'unsupported forge' '$ROOT_TMP/err'"

# 1b. missing forge: usage error exit 2.
( PATH="$BIN:$PATH" bash "$CREATE" ) >/dev/null 2>&1; RC=$?
check "missing forge: exit 2" "[ \"$RC\" = 2 ]" "$RC"

# 2. no upstream -> git push -u.
PUSHLOG="$ROOT_TMP/push2.log"; : > "$PUSHLOG"
unset MOCK_UPSTREAM
export MOCK_BRANCH=feature MOCK_DEFAULT=main MOCK_VIEW_ID=101
run_create github
check "no upstream: push -u issued" "grep -q 'push -u origin HEAD' '$PUSHLOG'" "$(cat "$PUSHLOG")"
unset MOCK_VIEW_ID

# 3. upstream behind (ahead>0) -> push unpushed commits to the CONFIGURED
#    upstream remote/ref (origin/feature here).
PUSHLOG="$ROOT_TMP/push3.log"; : > "$PUSHLOG"
export MOCK_UPSTREAM=1 MOCK_AHEAD=3 MOCK_BRANCH=feature MOCK_DEFAULT=main MOCK_VIEW_ID=102
PUSHLOG="$PUSHLOG" run_create github
check "behind upstream: push to origin HEAD:feature" "grep -qE 'push origin HEAD:feature' '$PUSHLOG'" "$(cat "$PUSHLOG")"
check "behind upstream: not push -u" "! grep -q 'push -u' '$PUSHLOG'"
unset MOCK_AHEAD

# 3b. upstream tracks a FORK remote -> push must land on the fork, not origin
#     (regression guard: don't leave the tracked upstream stale).
PUSHLOG="$ROOT_TMP/push3b.log"; : > "$PUSHLOG"
export MOCK_UPSTREAM=1 MOCK_AHEAD=2 MOCK_BRANCH=feature MOCK_DEFAULT=main \
       MOCK_UP_REMOTE=fork MOCK_UP_REF=feature MOCK_VIEW_ID=104
PUSHLOG="$PUSHLOG" run_create github
check "fork upstream: push to fork remote" "grep -qE 'push fork HEAD:feature' '$PUSHLOG'" "$(cat "$PUSHLOG")"
check "fork upstream: not pushed to origin" "! grep -qE 'push origin' '$PUSHLOG'" "$(cat "$PUSHLOG")"
unset MOCK_AHEAD MOCK_UP_REMOTE MOCK_UP_REF

# 4. upstream up to date (ahead=0) -> no push.
PUSHLOG="$ROOT_TMP/push4.log"; : > "$PUSHLOG"
export MOCK_UPSTREAM=1 MOCK_AHEAD=0 MOCK_BRANCH=feature MOCK_DEFAULT=main MOCK_VIEW_ID=103
PUSHLOG="$PUSHLOG" run_create github
check "up to date: no push" "[ ! -s '$PUSHLOG' ]" "$(cat "$PUSHLOG")"
unset MOCK_UPSTREAM MOCK_AHEAD

# 5. github id capture via JSON view.
export MOCK_BRANCH=feature MOCK_DEFAULT=main MOCK_VIEW_ID=201 MOCK_URLID=999
run_create github
check "gh id via JSON: MR_ID=201" "[ \"$(val MR_ID)\" = 201 ]" "$(val MR_ID)"
check "gh: MR_STATE created" "[ \"$(val MR_STATE)\" = created ]" "$(val MR_STATE)"
check "gh: title target/source" "[ \"$(val MR_SOURCE)\" = feature ] && [ \"$(val MR_TARGET)\" = main ]"
unset MOCK_VIEW_ID MOCK_URLID

# 6. github id capture via URL fallback (view returns nothing).
export MOCK_BRANCH=feature MOCK_DEFAULT=main MOCK_URLID=305
unset MOCK_VIEW_ID
run_create github
check "gh id via URL fallback: MR_ID=305" "[ \"$(val MR_ID)\" = 305 ]" "$(val MR_ID)"
unset MOCK_URLID

# 7. github already-exists resume -> STATE=existing, id still resolved.
export MOCK_BRANCH=feature MOCK_DEFAULT=main MOCK_EXISTS=1 MOCK_VIEW_ID=410
run_create github
check "gh existing: MR_STATE existing" "[ \"$(val MR_STATE)\" = existing ]" "$(val MR_STATE)"
check "gh existing: MR_ID=410" "[ \"$(val MR_ID)\" = 410 ]" "$(val MR_ID)"
unset MOCK_EXISTS MOCK_VIEW_ID

# 8. gitlab id capture via JSON iid.
export MOCK_BRANCH=feature MOCK_DEFAULT=main MOCK_VIEW_ID=512 MOCK_URLID=999
run_create gitlab
check "glab id via JSON iid: MR_ID=512" "[ \"$(val MR_ID)\" = 512 ]" "$(val MR_ID)"
check "glab: MR_FORGE gitlab" "[ \"$(val MR_FORGE)\" = gitlab ]"
unset MOCK_VIEW_ID MOCK_URLID

# 9. gitlab id via URL fallback (view returns empty JSON, no iid).
export MOCK_BRANCH=feature MOCK_DEFAULT=main MOCK_URLID=613
unset MOCK_VIEW_ID
run_create gitlab
check "glab id via URL fallback: MR_ID=613" "[ \"$(val MR_ID)\" = 613 ]" "$(val MR_ID)"
unset MOCK_URLID

# 10. intent-stash fallback (no --intent-file) -> [TODO] Intent not provided.
DATA_DIR="$ROOT_TMP/data10"
export MOCK_BRANCH=feature MOCK_DEFAULT=main MOCK_VIEW_ID=700
unset INTENT_FILE
run_create github
check "intent fallback: stash file exists" "[ -f '$DATA_DIR/700.md' ]"
check "intent fallback: TODO placeholder" "grep -q '\[TODO\] Intent not provided' '$DATA_DIR/700.md'"
check "intent fallback: has ## Intent" "grep -q '^## Intent' '$DATA_DIR/700.md'"
check "intent fallback: has change scope" "grep -q '^## Change scope' '$DATA_DIR/700.md'"
check "intent fallback: scope has commits" "grep -q 'first commit' '$DATA_DIR/700.md'"
unset DATA_DIR MOCK_VIEW_ID

# 11. explicit intent -> stashed verbatim, no TODO.
DATA_DIR="$ROOT_TMP/data11"; INTENT_FILE="$ROOT_TMP/intent11.txt"
printf 'Add retry/backoff to the uploader so flaky networks stop dropping files.\n' > "$INTENT_FILE"
export MOCK_BRANCH=feature MOCK_DEFAULT=main MOCK_VIEW_ID=701
run_create github
check "explicit intent: prose stashed" "grep -q 'retry/backoff to the uploader' '$DATA_DIR/701.md'"
check "explicit intent: no TODO" "! grep -q '\[TODO\]' '$DATA_DIR/701.md'"
unset INTENT_FILE

# 12. resume preserves existing intent when no new intent supplied.
#     Reuse DATA_DIR/701.md (has real intent); re-run without --intent-file.
export MOCK_BRANCH=feature MOCK_DEFAULT=main MOCK_VIEW_ID=701
unset INTENT_FILE
run_create github
check "resume: intent preserved (not clobbered by TODO)" "grep -q 'retry/backoff to the uploader' '$DATA_DIR/701.md'"
check "resume: still no TODO" "! grep -q '\[TODO\]' '$DATA_DIR/701.md'"
unset DATA_DIR MOCK_VIEW_ID

# 13. detached HEAD -> hard error.
export MOCK_BRANCH=HEAD MOCK_DEFAULT=main
run_create github
check "detached HEAD: non-zero exit" "[ \"$RC\" != 0 ]" "$RC"
check "detached HEAD: message" "printf '%s' \"$ERR\" | grep -qi detached"
unset MOCK_BRANCH

# 14. source == default branch -> refuse.
export MOCK_BRANCH=main MOCK_DEFAULT=main
run_create github
check "on default branch: non-zero exit" "[ \"$RC\" != 0 ]" "$RC"
check "on default branch: message" "printf '%s' \"$ERR\" | grep -qi 'default branch'"
unset MOCK_BRANCH MOCK_DEFAULT

echo
echo "== create_test: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]

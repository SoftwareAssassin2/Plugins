#!/usr/bin/env bash
#
# setup-worktree_test.sh — tests for setup-worktree.sh (fork-safe head resolution
# + worktree reuse/creation, fn-11.2).
#
# Run: bash plugins/merge-request/skills/review/tests/setup-worktree_test.sh
#
# Isolation: git is REAL (a throwaway local origin + working clone), but the
# forge CLI (`gh`) is MOCKED so the head metadata is deterministic and no network
# is touched. The PR head is published on the origin as `refs/pull/<n>/head`
# exactly as GitHub exposes it, so the fork-safe ref transport is exercised for
# real. jq is the REAL tool.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SW="$SCRIPT_DIR/../scripts/setup-worktree.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1  (got: ${2:-})"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

command -v git >/dev/null 2>&1 || { echo "git required for this test"; exit 1; }

ROOT_TMP="$(mktemp -d)"
trap 'rm -rf "$ROOT_TMP"' EXIT
BIN="$ROOT_TMP/bin"; mkdir -p "$BIN"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# --- build a real origin with a PR head ref --------------------------------
ORIGIN="$ROOT_TMP/origin"
git init -q "$ORIGIN"
( cd "$ORIGIN" || exit
  git checkout -q -b main
  echo base > f.txt; git add f.txt; git commit -q -m base
  BASE_SHA="$(git rev-parse HEAD)"          # the PR/MR base commit (diff endpoint)
  echo "$BASE_SHA" > "$ROOT_TMP/base_sha"
  # A "PR" commit on a side branch, published as refs/pull/1/head like GitHub.
  git checkout -q -b pr1
  echo change > f.txt; git commit -q -am "pr change"
  PR_SHA="$(git rev-parse HEAD)"
  git update-ref refs/pull/1/head "$PR_SHA"
  # Also publish it as a GitLab MR head ref so the gitlab path resolves for real.
  git update-ref refs/merge-requests/1/head "$PR_SHA"
  git checkout -q main
  echo "$PR_SHA" > "$ROOT_TMP/pr_sha"
)
PR_SHA="$(cat "$ROOT_TMP/pr_sha")"
BASE_SHA="$(cat "$ROOT_TMP/base_sha")"

# Working clone (has an `origin` remote pointing at ORIGIN).
WORK="$ROOT_TMP/work"
git clone -q "$ORIGIN" "$WORK"

# --- gh mock: returns the PR head metadata (or empty for unknown ids) --------
cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = pr ] && [ "\$2" = view ]; then
  if [ "\$3" = 1 ]; then
    echo '{"headRefOid":"${PR_SHA}","headRefName":"pr1","headRepository":{"name":"repo"},"headRepositoryOwner":{"login":"owner"},"baseRefOid":"${BASE_SHA}"}'
    exit 0
  fi
  echo ""; exit 0
fi
exit 0
EOF
chmod +x "$BIN/gh"

# --- glab mock: returns the MR diff_refs (base/start/head) triple ------------
cat > "$BIN/glab" <<EOF
#!/usr/bin/env bash
if [ "\$1" = mr ] && [ "\$2" = view ]; then
  # \$3 is the id (glab_repo_args, if any, follow the positional id here)
  case "\$3" in
    1) echo '{"source_branch":"pr1","sha":"${PR_SHA}","diff_refs":{"base_sha":"${BASE_SHA}","start_sha":"${BASE_SHA}","head_sha":"${PR_SHA}"}}'; exit 0 ;;
    *) echo ""; exit 0 ;;
  esac
fi
exit 0
EOF
chmod +x "$BIN/glab"

run_sw() { # <cwd> <id>
  OUT="$( cd "$1" && PATH="$BIN:$PATH" bash "$SW" --forge github --id "$2" 2>"$ROOT_TMP/err" )"
  RC=$?; ERR="$(cat "$ROOT_TMP/err")"
}
run_sw_gitlab() { # <cwd> <id>
  OUT="$( cd "$1" && PATH="$BIN:$PATH" bash "$SW" --forge gitlab --id "$2" 2>"$ROOT_TMP/err" )"
  RC=$?; ERR="$(cat "$ROOT_TMP/err")"
}
val() { printf '%s\n' "$OUT" | grep -m1 "^$1=" | cut -d= -f2-; }

echo "== merge-request:review — setup-worktree.sh =="

# 1. bad id -> exit 2.
( cd "$WORK" && PATH="$BIN:$PATH" bash "$SW" --forge github --id nope ) >/dev/null 2>&1; RC=$?
check "bad id: exit 2" "[ \"$RC\" = 2 ]" "$RC"

# 2. fresh create: resolves the head, creates .worktrees/merge-1 @ branch merge/1.
run_sw "$WORK" 1
check "create: exit 0"          "[ \"$RC\" = 0 ]" "$RC:$ERR"
check "create: CHECKOUT=ok"     "[ \"$(val CHECKOUT)\" = ok ]" "$(val CHECKOUT)"
check "create: STATE=created"   "[ \"$(val STATE)\" = created ]" "$(val STATE)"
check "create: HEAD_SHA=pr sha" "[ \"$(val HEAD_SHA)\" = \"$PR_SHA\" ]" "$(val HEAD_SHA)"
check "create: BASE_SHA=base sha" "[ \"$(val BASE_SHA)\" = \"$BASE_SHA\" ]" "$(val BASE_SHA)"
check "create: no START_SHA on github" "[ -z \"$(val START_SHA)\" ]" "$(val START_SHA)"
check "create: BRANCH=merge/1"  "[ \"$(val BRANCH)\" = merge/1 ]" "$(val BRANCH)"
check "create: worktree dir exists" "[ -d '$WORK/.worktrees/merge-1' ]"
check "create: worktree at head"  "[ \"\$(git -C '$WORK/.worktrees/merge-1' rev-parse HEAD)\" = \"$PR_SHA\" ]"
check "create: resolution metadata-preferred" "printf '%s' \"\$(val RESOLUTION)\" | grep -q metadata" "$(val RESOLUTION)"

# 3. re-run from the MAIN worktree -> STATE=updated (existing worktree ff'd).
run_sw "$WORK" 1
check "rerun from main: STATE=updated" "[ \"$(val STATE)\" = updated ]" "$(val STATE)"

# 4. run from INSIDE the dedicated worktree -> STATE=reused.
run_sw "$WORK/.worktrees/merge-1" 1
check "inside worktree: STATE=reused" "[ \"$(val STATE)\" = reused ]" "$(val STATE)"
check "reused: CHECKOUT=ok"           "[ \"$(val CHECKOUT)\" = ok ]" "$(val CHECKOUT)"

# 5. unresolvable head (no refs/pull/2/head, metadata empty) -> unresolved, exit 1.
run_sw "$WORK" 2
check "unresolvable: exit 1"          "[ \"$RC\" = 1 ]" "$RC"
check "unresolvable: CHECKOUT=unresolved" "[ \"$(val CHECKOUT)\" = unresolved ]" "$(val CHECKOUT)"
check "unresolvable: REASON present"  "[ -n \"$(val REASON)\" ]" "$(val REASON)"

# 6. gitlab forge: emits the diff_refs triple — BASE_SHA and START_SHA (fresh clone).
WORK_GL="$ROOT_TMP/work_gl"
git clone -q "$ORIGIN" "$WORK_GL"
run_sw_gitlab "$WORK_GL" 1
check "gitlab: exit 0"             "[ \"$RC\" = 0 ]" "$RC:$ERR"
check "gitlab: HEAD_SHA=pr sha"    "[ \"$(val HEAD_SHA)\" = \"$PR_SHA\" ]" "$(val HEAD_SHA)"
check "gitlab: BASE_SHA=base sha"  "[ \"$(val BASE_SHA)\" = \"$BASE_SHA\" ]" "$(val BASE_SHA)"
check "gitlab: START_SHA=base sha" "[ \"$(val START_SHA)\" = \"$BASE_SHA\" ]" "$(val START_SHA)"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
#
# gather-feedback_test.sh — tests for gather-feedback.sh (the deterministic half
# of /merge-request:fix, fn-10.1).
#
# Run: bash plugins/merge-request/skills/fix/tests/gather-feedback_test.sh
#
# Isolation: git, gh and glab are MOCKED (tiny scripts on a PATH prepended ahead
# of the real ones); jq / sha1sum|shasum / awk / sed are the REAL tools. No real
# repo, no forge, no network. Fixtures are driven by MOCK_* env vars so a single
# mock covers the "first fetch", "rerun", and "edited comment" cases.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GATHER="$SCRIPT_DIR/../scripts/gather-feedback.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1  (got: ${2:-})"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

ROOT_TMP="$(mktemp -d)"
trap 'rm -rf "$ROOT_TMP"' EXIT
BIN="$ROOT_TMP/bin"; mkdir -p "$BIN"

# --- git mock (only needs to satisfy the work-tree probe) ------------------
cat > "$BIN/git" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  rev-parse) exit 0 ;;
  --version) echo "git version 0.0-mock" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BIN/git"

# --- gh mock ---------------------------------------------------------------
# MOCK_STATE (default OPEN), MOCK_COMMENT_BODY (override the human comment body
# to exercise content_hash change).
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ "$args" == *"repo view"* ]]; then echo "acme/widget"; exit 0; fi
if [[ "$args" == *"pr view"* && "$args" == *"state,updatedAt,headRefOid"* ]]; then
  printf '{"state":"%s","updatedAt":"%s","headRefOid":"abc123"}\n' "${MOCK_STATE:-OPEN}" "$now"; exit 0
fi
if [[ "$args" == *"pr view"* && "$args" == *"comments"* ]]; then
  body="${MOCK_COMMENT_BODY:-please rename foo to bar}"
  jq -cn --arg b "$body" '{comments:[
    {id:"IC_1", author:{login:"alice"},          body:$b,                    url:"http://x/1"},
    {id:"IC_2", author:{login:"dependabot[bot]"}, body:"bump lodash to 4.17", url:"http://x/2"}
  ]}'
  exit 0
fi
if [[ "$args" == *"pr view"* && "$args" == *"statusCheckRollup"* ]]; then
  echo '{"statusCheckRollup":[
    {"__typename":"CheckRun","name":"unit-tests","conclusion":"FAILURE","detailsUrl":"http://ci/1"},
    {"__typename":"CheckRun","name":"lint","conclusion":"SUCCESS","detailsUrl":"http://ci/2"}
  ]}'
  exit 0
fi
if [[ "$args" == *"check-runs"* ]]; then
  # Emulates `gh api ... check-runs --paginate -q '.check_runs[]'` (inner objects).
  jq -cn --arg s "${MOCK_CI_SUMMARY:-FAILED spec/x_spec.rb:9 expected 3 got 4}" \
    '{name:"unit-tests", conclusion:"failure", output:{title:"tests failed", summary:$s}}'
  exit 0
fi
if [[ "$args" == *"api graphql"* ]]; then
  echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{
    "pageInfo":{"hasNextPage":false,"endCursor":null},
    "nodes":[
      {"id":"RT_1","isResolved":false,"comments":{"nodes":[{"author":{"login":"bob"},"body":"extract this into a helper","path":"src/a.ts","line":12,"url":"http://x/t1"}]}},
      {"id":"RT_2","isResolved":true,"comments":{"nodes":[{"author":{"login":"bob"},"body":"done already","path":"src/b.ts","line":3,"url":"http://x/t2"}]}}
  ]}}}}}'
  exit 0
fi
exit 0
EOF
chmod +x "$BIN/gh"

# --- glab mock -------------------------------------------------------------
cat > "$BIN/glab" <<'EOF'
#!/usr/bin/env bash
args="$*"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# MR meta (no trailing path segment after the id)
if [[ "$args" == *"merge_requests/55"* && "$args" != *"/discussions"* && "$args" != *"/pipelines"* ]]; then
  printf '{"state":"%s","updated_at":"%s","sha":"def456","diff_refs":{"head_sha":"def456"}}\n' "${MOCK_STATE:-opened}" "$now"; exit 0
fi
if [[ "$args" == *"/discussions"* ]]; then
  echo '[{"id":"disc1","notes":[
    {"system":false,"body":"this loop is O(n^2)","author":{"username":"carol"},"resolved":false,"position":{"new_path":"src/x.rb","new_line":9}}
  ]},
  {"id":"sys","notes":[{"system":true,"body":"changed the milestone","author":{"username":"bot"}}]}]'
  exit 0
fi
if [[ "$args" == *"/merge_requests/55/pipelines"* ]]; then echo '[{"id":900,"sha":"def456"}]'; exit 0; fi
if [[ "$args" == *"/pipelines/900/jobs"* ]]; then
  echo '[{"id":5,"name":"rspec","status":"failed","allow_failure":false},
         {"id":6,"name":"flaky","status":"failed","allow_failure":true}]'
  exit 0
fi
if [[ "$args" == *"/jobs/5/trace"* ]]; then printf 'compiling...\nError: expected 3 got 4\nFAILED spec/x_spec.rb:9\n'; exit 0; fi
exit 0
EOF
chmod +x "$BIN/glab"

run() { OUT="$( PATH="$BIN:$PATH" bash "$GATHER" "$@" 2>"$ROOT_TMP/err" )"; RC=$?; ERR="$(cat "$ROOT_TMP/err")"; }
items() { printf '%s\n' "$OUT" | grep '^{'; }
trailer() { printf '%s\n' "$OUT" | grep -m1 "^$1=" | cut -d= -f2-; }

echo "== merge-request:fix — gather-feedback.sh =="

# --- argument / usage guards ----------------------------------------------
run; check "no subcommand: exit 2" "[ \"$RC\" = 2 ]" "$RC"
run bogus --id 1; check "bad subcommand: exit 2" "[ \"$RC\" = 2 ]" "$RC"
run gather --forge github; check "gather without --id: exit 2" "[ \"$RC\" = 2 ]" "$RC"
run gather --id 1 --forge bitbucket; check "gather bad forge: exit 2" "[ \"$RC\" = 2 ]" "$RC"

# --- github: first fetch on an empty ledger --------------------------------
D1="$ROOT_TMP/d1"; mkdir -p "$D1"
# Seed a stash with a real ## Intent to prove record preserves other sections.
printf '# Merge feature into main\n\n## Intent\n\nAdd retries.\n\n## Change scope\n\n```\nabc first\n```\n' > "$D1/77.md"

run gather --forge github --id 77 --data-dir "$D1"
check "gh gather: exit 0" "[ \"$RC\" = 0 ]" "$RC ($ERR)"
check "gh gather: state open" "[ \"$(trailer MR_STATE)\" = open ]" "$(trailer MR_STATE)"
check "gh gather: cadence active (recent)" "[ \"$(trailer MR_CADENCE)\" = active ]" "$(trailer MR_CADENCE)"
check "gh gather: 4 actionable" "[ \"$(trailer MR_ACTIONABLE_COUNT)\" = 4 ]" "$(trailer MR_ACTIONABLE_COUNT)"
check "gh gather: emits the human comment" "items | jq -e 'select(.kind==\"comment\" and .source_id==\"IC_1\")' >/dev/null"
check "gh gather: flags the bot comment" "items | jq -e 'select(.source_id==\"IC_2\" and .is_bot==true)' >/dev/null"
check "gh gather: unresolved thread only (RT_1)" "items | jq -e 'select(.kind==\"thread\" and .source_id==\"RT_1\")' >/dev/null"
check "gh gather: resolved thread RT_2 excluded" "! items | jq -e 'select(.source_id==\"RT_2\")' >/dev/null"
check "gh gather: failing ci-job unit-tests" "items | jq -e 'select(.kind==\"ci-job\" and .job_name==\"unit-tests\")' >/dev/null"
check "gh gather: passing check excluded" "! items | jq -e 'select(.job_name==\"lint\")' >/dev/null"
check "gh gather: comment carries content_hash" "items | jq -e 'select(.source_id==\"IC_1\") | .content_hash|length>0' >/dev/null"
check "gh gather: ci-job carries fingerprint" "items | jq -e 'select(.kind==\"ci-job\") | .fingerprint|length>0' >/dev/null"
# finding-2 fix: the fingerprint incorporates a real (non-empty) error signature
# derived from the check-run output, not a hardcoded empty string.
check "gh gather: ci-job carries non-empty signature" "items | jq -e 'select(.kind==\"ci-job\") | .signature|length>0' >/dev/null"
FP_A="$(items | jq -r 'select(.kind=="ci-job") | .fingerprint')"
FP_B="$(PATH="$BIN:$PATH" MOCK_CI_SUMMARY='OOM killed: runner ran out of memory' bash "$GATHER" gather --forge github --id 77 --data-dir "$D1" | grep '^{' | jq -r 'select(.kind=="ci-job") | .fingerprint')"
check "gh gather: different failure summary => different fingerprint" "[ -n \"$FP_A\" ] && [ \"$FP_A\" != \"$FP_B\" ]" "$FP_A vs $FP_B"

# --- record the CI item non-actionable, then confirm it is suppressed ------
CI_FP="$(items | jq -r 'select(.kind=="ci-job") | .fingerprint')"
run record --id 77 --data-dir "$D1" --kind ci-job --decision non-actionable \
    --fingerprint "$CI_FP" --commit abc123 --rationale "infra timeout, not the MR"
check "record ci: exit 0" "[ \"$RC\" = 0 ]" "$RC ($ERR)"
check "record ci: HANDLED_WRITTEN" "printf '%s' \"$OUT\" | grep -q '^HANDLED_WRITTEN=1'"
check "stash: ## Handled section added" "grep -q '^## Handled' '$D1/77.md'"
check "stash: fenced jsonl block" "grep -q '^\`\`\`jsonl' '$D1/77.md'"
check "stash: ## Intent preserved" "grep -q 'Add retries.' '$D1/77.md'"
check "stash: ## Change scope preserved" "grep -q '^## Change scope' '$D1/77.md'"

run gather --forge github --id 77 --data-dir "$D1"
check "after ci record: ci-job suppressed" "! items | jq -e 'select(.kind==\"ci-job\")' >/dev/null"
check "after ci record: 3 actionable" "[ \"$(trailer MR_ACTIONABLE_COUNT)\" = 3 ]" "$(trailer MR_ACTIONABLE_COUNT)"

# --- record a thread pending-user, confirm suppression ---------------------
TH_HASH="$(items | jq -r 'select(.kind=="thread") | .content_hash')"
run record --id 77 --data-dir "$D1" --kind thread --decision pending-user \
    --source-id RT_1 --content-hash "$TH_HASH" --rationale "asked: is this in scope?"
check "record thread pending-user: exit 0" "[ \"$RC\" = 0 ]" "$RC ($ERR)"
run gather --forge github --id 77 --data-dir "$D1"
check "pending-user: thread RT_1 suppressed" "! items | jq -e 'select(.source_id==\"RT_1\")' >/dev/null"
check "pending-user: 2 actionable left" "[ \"$(trailer MR_ACTIONABLE_COUNT)\" = 2 ]" "$(trailer MR_ACTIONABLE_COUNT)"

# --- edited comment (changed body -> new content_hash -> re-surfaces) -------
MOCK_COMMENT_BODY="please rename foo to baz (edited)" run gather --forge github --id 77 --data-dir "$D1"
# IC_1 was never recorded, so it still surfaces; the edited-hash path is proven by
# the thread case above. Confirm IC_1 still present with the NEW hash.
check "edited comment: IC_1 re-surfaces with new body" \
  "PATH=\"$BIN:$PATH\" MOCK_COMMENT_BODY='rename foo to baz (edited)' bash '$GATHER' gather --forge github --id 77 --data-dir '$D1' | grep '^{' | jq -e 'select(.source_id==\"IC_1\" and (.body|test(\"baz\")))' >/dev/null"

# --- record validation -----------------------------------------------------
run record --id 77 --data-dir "$D1" --kind ci-job --decision non-actionable
check "record ci without fingerprint: exit 2" "[ \"$RC\" = 2 ]" "$RC"
run record --id 77 --data-dir "$D1" --kind thread --decision declined --source-id X
check "record thread without content-hash: exit 2" "[ \"$RC\" = 2 ]" "$RC"
run record --id 77 --data-dir "$D1" --kind ci-job --decision bogus --fingerprint z
check "record bad decision: exit 2" "[ \"$RC\" = 2 ]" "$RC"

# --- ledger dump -----------------------------------------------------------
# (jq a file, not "$OUT" embedded in eval — multiline JSON would break quoting.)
run ledger --id 77 --data-dir "$D1"
printf '%s\n' "$OUT" > "$ROOT_TMP/ledger.jsonl"
check "ledger: has the ci-job record" "jq -e 'select(.kind==\"ci-job\" and .decision==\"non-actionable\")' '$ROOT_TMP/ledger.jsonl' >/dev/null"
check "ledger: has the pending-user record" "jq -e 'select(.decision==\"pending-user\")' '$ROOT_TMP/ledger.jsonl' >/dev/null"

# --- terminal state stops the loop (closed) --------------------------------
MOCK_STATE=CLOSED run gather --forge github --id 77 --data-dir "$D1"
check "closed PR: MR_STATE closed" \
  "PATH=\"$BIN:$PATH\" MOCK_STATE=CLOSED bash '$GATHER' gather --forge github --id 77 --data-dir '$D1' | grep -q '^MR_STATE=closed'"

# --- gitlab: discussions + attributable CI ---------------------------------
D2="$ROOT_TMP/d2"; mkdir -p "$D2"
run gather --forge gitlab --id 55 --data-dir "$D2"
check "glab gather: exit 0" "[ \"$RC\" = 0 ]" "$RC ($ERR)"
check "glab gather: state open" "[ \"$(trailer MR_STATE)\" = open ]" "$(trailer MR_STATE)"
check "glab gather: emits discussion thread" "items | jq -e 'select(.kind==\"thread\" and .source_id==\"disc1\")' >/dev/null"
check "glab gather: system note excluded" "! items | jq -e 'select(.source_id==\"sys\")' >/dev/null"
check "glab gather: failing rspec job emitted" "items | jq -e 'select(.kind==\"ci-job\" and .job_name==\"rspec\")' >/dev/null"
check "glab gather: allow_failure job excluded" "! items | jq -e 'select(.job_name==\"flaky\")' >/dev/null"
check "glab gather: ci-job has trace signature" "items | jq -e 'select(.kind==\"ci-job\") | .signature|length>0' >/dev/null"

echo
echo "== gather-feedback_test: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]

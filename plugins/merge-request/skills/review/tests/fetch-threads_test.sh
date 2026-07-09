#!/usr/bin/env bash
#
# fetch-threads_test.sh — tests for fetch-threads.sh (thread fetch/normalize +
# deterministic F-<hash>, fn-11.3).
#
# Run: bash plugins/merge-request/skills/review/tests/fetch-threads_test.sh
#
# Isolation: git, gh and glab are MOCKED (tiny scripts on a PATH prepended ahead
# of the real ones); jq / awk / grep / sed are the REAL tools. No real repo, no
# forge, no network. Fixtures are baked into the mocks. The `finding-id`↔Step-5
# equality is pinned here so the two serializations can never silently drift.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FT="$SCRIPT_DIR/../scripts/fetch-threads.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1  (got: ${2:-})"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

ROOT_TMP="$(mktemp -d)"
trap 'rm -rf "$ROOT_TMP"' EXIT
BIN="$ROOT_TMP/bin"; mkdir -p "$BIN"

# --- git mock: just enough (repo check) ------------------------------------
cat > "$BIN/git" <<'EOF'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "rev-parse --is-inside-work-tree") exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BIN/git"

# --- gh mock: issue comments + owner/repo + reviewThreads GraphQL ----------
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")
    # gh pr view <id> --json comments
    cat <<'JSON'
{"comments":[{"author":{"login":"alice"},"body":"nit: rename foo","url":"https://gh/c/1"}]}
JSON
    exit 0 ;;
  "repo view")
    # gh repo view --json nameWithOwner -q .nameWithOwner
    echo "acme/widget"; exit 0 ;;
  "api graphql")
    cat <<'JSON'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"isResolved":false,"comments":{"nodes":[{"author":{"login":"bob"},"body":"issue: hardcoded host","path":"src/config.ts","line":12}]}},
  {"isResolved":true,"comments":{"nodes":[{"author":{"login":"carol"},"body":"already resolved point","path":"src/x.ts","line":3}]}}
]}}}}}
JSON
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$BIN/gh"

# --- glab mock: discussions (general + inline + system-only) ---------------
cat > "$BIN/glab" <<'EOF'
#!/usr/bin/env bash
# glab api --paginate "projects/:id/merge_requests/<id>/discussions?per_page=100"
if [ "$1" = api ]; then
  cat <<'JSON'
[
 {"id":"d1","notes":[{"system":false,"author":{"username":"dave"},"body":"general note","position":null,"resolvable":false,"resolved":null}]},
 {"id":"d2","notes":[{"system":false,"author":{"username":"erin"},"body":"inline point","position":{"new_path":"src/a.rb","new_line":9},"resolvable":true,"resolved":true}]},
 {"id":"d3","notes":[{"system":true,"author":{"username":"bot"},"body":"changed the description","position":null}]}
]
JSON
  exit 0
fi
exit 0
EOF
chmod +x "$BIN/glab"

run() { PATH="$BIN:$PATH" bash "$FT" "$@"; }

echo "fetch-threads.sh"

# ============================ finding-id (determinism + Step-5 parity) =======
echo "== finding-id =="

# The EXACT engine serialization pinned in SKILL.md Step 5. If Step 5 changes,
# this literal must change with it — that is the whole point of the assertion.
step5_id() {
  printf '%s' "${1}|${2}|${3}|${4}|${5}" \
    | { command -v sha1sum >/dev/null 2>&1 && sha1sum || shasum; } \
    | cut -c1-12 | sed 's/^/F-/'
}

GEN_A="$(run finding-id --id 42 --prefix "issue:" --body "build failed: npm test exited 1")"
GEN_B="$(step5_id 42 "" "" "issue:" "build failed: npm test exited 1")"
check "general finding-id equals the Step-5 inline serialization" "[ '$GEN_A' = '$GEN_B' ]" "$GEN_A vs $GEN_B"

INL_A="$(run finding-id --id 42 --prefix "suggestion:" --body "move host to config" --file "src/config.ts" --line 12)"
INL_B="$(step5_id 42 "src/config.ts" "12" "suggestion:" "move host to config")"
check "inline finding-id equals the Step-5 inline serialization" "[ '$INL_A' = '$INL_B' ]" "$INL_A vs $INL_B"

check "finding-id is F- + 12 hex" "printf '%s' '$GEN_A' | grep -Eq '^F-[0-9a-f]{12}\$'" "$GEN_A"
check "finding-id is deterministic (same inputs -> same id)" "[ \"\$(run finding-id --id 42 --prefix 'issue:' --body 'x')\" = \"\$(run finding-id --id 42 --prefix 'issue:' --body 'x')\" ]"
check "line/range participates in the id (different line -> different id)" \
  "[ \"\$(run finding-id --id 42 --prefix 'issue:' --body 'x' --file f --line 1)\" != \"\$(run finding-id --id 42 --prefix 'issue:' --body 'x' --file f --line 2)\" ]"
check "finding-id without --prefix is a usage error" "run finding-id --id 42 --body x; [ \$? -eq 2 ]"

# ============================ threads: GitHub ===============================
echo "== threads (github) =="
GH="$(run threads --forge github --id 7)"
GH_JSONL="$(printf '%s\n' "$GH" | grep '^{' || true)"

check "github: 3 normalized threads emitted" "[ \"\$(printf '%s\n' \"\$GH_JSONL\" | grep -c '^{')\" -eq 3 ]" "$GH_JSONL"
check "github: issue comment normalized to kind=general, null file/line/resolved" \
  "printf '%s\n' \"\$GH_JSONL\" | jq -e 'select(.author==\"alice\") | .kind==\"general\" and .file==null and .line==null and .resolved==null' >/dev/null" "$GH_JSONL"
check "github: review thread normalized to kind=inline with file+line" \
  "printf '%s\n' \"\$GH_JSONL\" | jq -e 'select(.author==\"bob\") | .kind==\"inline\" and .file==\"src/config.ts\" and .line==12 and .resolved==false' >/dev/null" "$GH_JSONL"
check "github: RESOLVED thread is still emitted (resolved:true), not dropped" \
  "printf '%s\n' \"\$GH_JSONL\" | jq -e 'select(.author==\"carol\") | .kind==\"inline\" and .resolved==true' >/dev/null" "$GH_JSONL"
check "github: trailer THREADS_FETCHED=3" "printf '%s\n' \"\$GH\" | grep -qx 'THREADS_FETCHED=3'" "$GH"
check "github: trailer THREADS_INLINE=2" "printf '%s\n' \"\$GH\" | grep -qx 'THREADS_INLINE=2'" "$GH"
check "github: trailer THREADS_GENERAL=1" "printf '%s\n' \"\$GH\" | grep -qx 'THREADS_GENERAL=1'" "$GH"

# ============================ threads: GitLab ===============================
echo "== threads (gitlab) =="
GL="$(run threads --forge gitlab --id 5)"
GL_JSONL="$(printf '%s\n' "$GL" | grep '^{' || true)"

check "gitlab: 2 normalized threads (system-only discussion dropped)" "[ \"\$(printf '%s\n' \"\$GL_JSONL\" | grep -c '^{')\" -eq 2 ]" "$GL_JSONL"
check "gitlab: general note -> kind=general, null file/line, resolved=null" \
  "printf '%s\n' \"\$GL_JSONL\" | jq -e 'select(.author==\"dave\") | .kind==\"general\" and .file==null and .line==null and .resolved==null' >/dev/null" "$GL_JSONL"
check "gitlab: positioned note -> kind=inline with file/line and resolved=true" \
  "printf '%s\n' \"\$GL_JSONL\" | jq -e 'select(.author==\"erin\") | .kind==\"inline\" and .file==\"src/a.rb\" and .line==9 and .resolved==true' >/dev/null" "$GL_JSONL"
check "gitlab: system-only discussion (d3/bot) is NOT emitted" \
  "! printf '%s\n' \"\$GL_JSONL\" | jq -e 'select(.author==\"bot\")' >/dev/null" "$GL_JSONL"
check "gitlab: trailer THREADS_FETCHED=2" "printf '%s\n' \"\$GL\" | grep -qx 'THREADS_FETCHED=2'" "$GL"

# ============================ degradation / usage ===========================
echo "== degradation & usage =="
# gh missing entirely -> degrade to zero threads, still exit 0.
EMPTY_BIN="$ROOT_TMP/emptybin"; mkdir -p "$EMPTY_BIN"
cp "$BIN/git" "$EMPTY_BIN/git"
NOGH="$(PATH="$EMPTY_BIN:/usr/bin:/bin" bash "$FT" threads --forge github --id 7 2>/dev/null)"; rc=$?
check "missing gh degrades to zero threads, exit 0" "[ $rc -eq 0 ] && printf '%s\n' \"\$NOGH\" | grep -qx 'THREADS_FETCHED=0'" "$NOGH"

check "unknown subcommand is a usage error (exit 2)" "run bogus --id 1; [ \$? -eq 2 ]"
check "non-numeric --id is a usage error (exit 2)" "run threads --forge github --id ../etc; [ \$? -eq 2 ]"
check "missing --forge is a usage error (exit 2)" "run threads --id 1; [ \$? -eq 2 ]"

# ============================ summary =======================================
echo
echo "fetch-threads: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

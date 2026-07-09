#!/usr/bin/env bash
#
# build-and-test_test.sh — tests for build-and-test.sh (auto build/test, fn-11.2).
#
# Run: bash plugins/merge-request/skills/review/tests/build-and-test_test.sh
#
# Isolation: every toolchain binary (npm/pnpm/yarn/make/just/cargo/go/dotnet) is
# a single MOCKED script on a prepended PATH that logs its invocation and exits
# 0, or 1 when its command line matches MOCK_FAIL. jq / grep / find / tee are the
# REAL tools. Each case builds a throwaway "worktree" dir with the manifest files
# that drive detection. No --id is passed, so no git is needed (the log goes to a
# temp file whose path the tail reports).

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BT="$SCRIPT_DIR/../scripts/build-and-test.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1  (got: ${2:-})"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

ROOT_TMP="$(mktemp -d)"
trap 'rm -rf "$ROOT_TMP"' EXIT
BIN="$ROOT_TMP/bin"; mkdir -p "$BIN"

# --- one mock, installed under every toolchain name ------------------------
cat > "$BIN/tool" <<'EOF'
#!/usr/bin/env bash
name="$(basename "$0")"
# `just --summary` lists recipes so has_just_recipe can see them.
if [ "$name" = just ] && [ "${1:-}" = --summary ]; then
  echo "${MOCK_JUST_RECIPES:-}"; exit 0
fi
echo "$name $*" >> "${MOCK_RUNLOG:-/dev/null}"
if [ -n "${MOCK_FAIL:-}" ] && printf '%s %s' "$name" "$*" | grep -qF -- "$MOCK_FAIL"; then
  echo "simulated failure: $name $*" >&2; exit 1
fi
exit 0
EOF
chmod +x "$BIN/tool"
for t in npm pnpm yarn make just cargo go dotnet; do ln -s "$BIN/tool" "$BIN/$t"; done

# run_bt <worktree> — run build-and-test in the given dir. Sets OUT/RC + a fresh
# per-run MOCK_RUNLOG the caller can inspect.
run_bt() {
  RUNLOG="$ROOT_TMP/run.$$.$RANDOM.log"; : > "$RUNLOG"
  OUT="$( PATH="$BIN:$PATH" MOCK_RUNLOG="$RUNLOG" MOCK_FAIL="${MOCK_FAIL:-}" \
          MOCK_JUST_RECIPES="${MOCK_JUST_RECIPES:-}" bash "$BT" --worktree "$1" 2>"$ROOT_TMP/err" )"
  RC=$?; ERR="$(cat "$ROOT_TMP/err")"
}
val() { printf '%s\n' "$OUT" | grep -m1 "^$1=" | cut -d= -f2-; }
mkwt() { local d; d="$(mktemp -d "$ROOT_TMP/wt.XXXXXX")"; echo "$d"; }

echo "== merge-request:review — build-and-test.sh =="

# 0. missing --worktree -> exit 2.
( PATH="$BIN:$PATH" bash "$BT" ) >/dev/null 2>&1; RC=$?
check "missing --worktree: exit 2" "[ \"$RC\" = 2 ]" "$RC"

# 1. empty repo -> no build/test command detected -> n/a, exit 0.
WT="$(mkwt)"; run_bt "$WT"
check "empty: BUILD_TEST=n/a"    "[ \"$(val BUILD_TEST)\" = n/a ]" "$(val BUILD_TEST)"
check "empty: ecosystem=none"    "[ \"$(val BUILD_ECOSYSTEM)\" = none ]" "$(val BUILD_ECOSYSTEM)"
check "empty: exit 0"            "[ \"$RC\" = 0 ]" "$RC"
check "empty: log says so"       "grep -q 'no build/test command detected' \"\$(val BUILD_LOG)\"" "$(val BUILD_LOG)"

# 2. Makefile with build + test -> cumulative, both run, pass.
WT="$(mkwt)"; printf 'build:\n\t@true\ntest:\n\t@true\n' > "$WT/Makefile"
run_bt "$WT"
check "make build+test: pass"        "[ \"$(val BUILD_TEST)\" = pass ]" "$(val BUILD_TEST)"
check "make build+test: ecosystem"   "[ \"$(val BUILD_ECOSYSTEM)\" = make ]" "$(val BUILD_ECOSYSTEM)"
check "make: ran make build"         "grep -q 'make build' '$RUNLOG'" "$(cat "$RUNLOG")"
check "make: ran make test"          "grep -q 'make test' '$RUNLOG'" "$(cat "$RUNLOG")"
check "make: commands joined"        "printf '%s' \"\$(val BUILD_COMMANDS)\" | grep -q 'make build;make test'" "$(val BUILD_COMMANDS)"

# 3. Makefile with ci -> ci ONLY (not build/test), even if those exist.
WT="$(mkwt)"; printf 'ci:\n\t@true\nbuild:\n\t@true\ntest:\n\t@true\n' > "$WT/Makefile"
run_bt "$WT"
check "make ci: ran make ci"     "grep -q 'make ci' '$RUNLOG'" "$(cat "$RUNLOG")"
check "make ci: did NOT run build" "! grep -q 'make build' '$RUNLOG'" "$(cat "$RUNLOG")"

# 4. Makefile test fails -> BUILD_TEST=fail, exit 1.
WT="$(mkwt)"; printf 'build:\n\t@true\ntest:\n\t@false\n' > "$WT/Makefile"
MOCK_FAIL="make test" run_bt "$WT"
check "make fail: BUILD_TEST=fail" "[ \"$(val BUILD_TEST)\" = fail ]" "$(val BUILD_TEST)"
check "make fail: exit 1"          "[ \"$RC\" = 1 ]" "$RC"

# 5. package.json with ci script -> npm run ci only, package ecosystem, install ran.
WT="$(mkwt)"; printf '{"scripts":{"ci":"x","build":"y","test":"z"}}' > "$WT/package.json"
run_bt "$WT"
check "pkg ci: ecosystem=package" "[ \"$(val BUILD_ECOSYSTEM)\" = package ]" "$(val BUILD_ECOSYSTEM)"
check "pkg ci: ran npm run ci"    "grep -q 'npm run ci' '$RUNLOG'" "$(cat "$RUNLOG")"
check "pkg ci: no npm run build"  "! grep -q 'npm run build' '$RUNLOG'" "$(cat "$RUNLOG")"
check "pkg ci: install ran"       "grep -qE 'npm (ci|install)' '$RUNLOG'" "$(cat "$RUNLOG")"

# 6. package.json build + test (no ci) -> cumulative, both run.
WT="$(mkwt)"; printf '{"scripts":{"build":"y","test":"z"}}' > "$WT/package.json"
run_bt "$WT"
check "pkg build+test: ran build" "grep -q 'npm run build' '$RUNLOG'" "$(cat "$RUNLOG")"
check "pkg build+test: ran test"  "grep -q 'npm run test' '$RUNLOG'" "$(cat "$RUNLOG")"

# 7. package.json with ONLY lint -> lint-only is excluded -> falls through to n/a.
WT="$(mkwt)"; printf '{"scripts":{"lint":"eslint .","format":"prettier -w ."}}' > "$WT/package.json"
run_bt "$WT"
check "lint-only: n/a"        "[ \"$(val BUILD_TEST)\" = n/a ]" "$(val BUILD_TEST)"
check "lint-only: never ran lint" "! grep -q 'run lint' '$RUNLOG'" "$(cat "$RUNLOG")"

# 8. lint-only package.json + a Makefile build -> detection falls through to make.
WT="$(mkwt)"; printf '{"scripts":{"lint":"eslint ."}}' > "$WT/package.json"
printf 'build:\n\t@true\n' > "$WT/Makefile"
run_bt "$WT"
check "fallthrough: ecosystem=make" "[ \"$(val BUILD_ECOSYSTEM)\" = make ]" "$(val BUILD_ECOSYSTEM)"
check "fallthrough: lint never ran" "! grep -q 'run lint' '$RUNLOG'" "$(cat "$RUNLOG")"

# 9. Cargo -> cargo build + cargo test.
WT="$(mkwt)"; printf '[package]\nname="x"\n' > "$WT/Cargo.toml"
run_bt "$WT"
check "cargo: ecosystem=cargo"  "[ \"$(val BUILD_ECOSYSTEM)\" = cargo ]" "$(val BUILD_ECOSYSTEM)"
check "cargo: build+test ran"   "grep -q 'cargo build' '$RUNLOG' && grep -q 'cargo test' '$RUNLOG'" "$(cat "$RUNLOG")"

# 10. Go -> go build ./... + go test ./...
WT="$(mkwt)"; printf 'module x\n' > "$WT/go.mod"
run_bt "$WT"
check "go: ecosystem=go"      "[ \"$(val BUILD_ECOSYSTEM)\" = go ]" "$(val BUILD_ECOSYSTEM)"
check "go: build+test ran"    "grep -q 'go build ./...' '$RUNLOG' && grep -q 'go test ./...' '$RUNLOG'" "$(cat "$RUNLOG")"

# 11. .NET -> dotnet build + dotnet test.
WT="$(mkwt)"; printf '<Project></Project>\n' > "$WT/App.csproj"
run_bt "$WT"
check "dotnet: ecosystem=dotnet" "[ \"$(val BUILD_ECOSYSTEM)\" = dotnet ]" "$(val BUILD_ECOSYSTEM)"
check "dotnet: build+test ran"   "grep -q 'dotnet build' '$RUNLOG' && grep -q 'dotnet test' '$RUNLOG'" "$(cat "$RUNLOG")"

# 12. detection ORDER: package.json (build) wins over a Makefile in the same dir.
WT="$(mkwt)"; printf '{"scripts":{"build":"y"}}' > "$WT/package.json"
printf 'build:\n\t@true\n' > "$WT/Makefile"
run_bt "$WT"
check "order: package beats make" "[ \"$(val BUILD_ECOSYSTEM)\" = package ]" "$(val BUILD_ECOSYSTEM)"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]

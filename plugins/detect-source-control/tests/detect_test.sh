#!/usr/bin/env bash
#
# detect_test.sh — integration + unit tests for detect.sh.
#
# Run: bash plugins/detect-source-control/tests/detect_test.sh
#
# Isolation strategy: every scenario runs detect.sh against a REAL throwaway git
# repo (real `git init` + real `git remote add`, so remote parsing is exercised
# for real) under a fully CONTROLLED PATH. The controlled PATH contains ONLY
# symlinks to the real coreutils detect.sh needs PLUS whichever `gh`/`glab`
# stubs the scenario wants — so an absent CLI is genuinely absent (the host's
# real gh/glab can never leak in), and a stubbed CLI's `repo view` / `auth
# status` exit codes are exactly what the scenario dictates.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DETECT="$SCRIPT_DIR/../scripts/detect.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# Real tool paths captured BEFORE any PATH manipulation, so controlled bins can
# symlink to them regardless of the scenario PATH.
REAL_TOOLS="git grep sort tr sed cat cut mkdir rm ln env bash sh dirname basename mktemp head"
declare_real() { :; }
resolve_real() { command -v "$1" 2>/dev/null; }

ROOT_TMP="$(mktemp -d)"
trap 'rm -rf "$ROOT_TMP"' EXIT

# make_bin <dir>: seed a controlled bin dir with symlinks to the real coreutils
# detect.sh depends on. gh/glab are deliberately NOT included — a scenario adds
# them explicitly via stub_gh / stub_glab.
make_bin() {
  local d="$1" t p
  mkdir -p "$d"
  for t in $REAL_TOOLS; do
    p="$(resolve_real "$t")"
    [ -n "$p" ] && ln -sf "$p" "$d/$t"
  done
}

# stub_cli <bindir> <name> <repo_view_rc> <auth_status_rc>: write a fake gh/glab
# whose `repo view` and `auth status` subcommands exit with the given codes and
# whose presence makes `command -v <name>` succeed.
stub_cli() {
  local bin="$1" name="$2" rv="$3" as="$4"
  cat > "$bin/$name" <<EOF
#!/usr/bin/env bash
case "\$1" in
  repo)   [ "\$2" = view ] && exit $rv; exit 0 ;;
  auth)   [ "\$2" = status ] && exit $as; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$bin/$name"
}

# new_repo: create an empty real git repo, echo its path.
new_repo() {
  local d
  d="$(mktemp -d "$ROOT_TMP/repo.XXXXXX")"
  git init -q "$d" >/dev/null 2>&1
  printf '%s' "$d"
}

# run_detect <repo> <bin>: run detect.sh in <repo> with PATH restricted to <bin>.
# Sets globals OUT (stdout) and RC (exit code).
run_detect() {
  local repo="$1" bin="$2"
  OUT="$( cd "$repo" && PATH="$bin" bash "$DETECT" 2>/dev/null )"
  RC=$?
}

# val <key>: extract a value from the captured OUT block.
val() { printf '%s\n' "$OUT" | grep -m1 "^$1=" | cut -d= -f2-; }

# assert_block <label>: the block has exactly the 5 keys in the exact order.
assert_block() {
  local label="$1" keys
  keys="$(printf '%s\n' "$OUT" | cut -d= -f1 | tr '\n' ',')"
  check "$label: exact 5-key ordered block" \
    "[ \"$keys\" = 'forge,host,cli,cli_authenticated,supported,' ]"
}

# ── unit: pure helpers ─────────────────────────────────────────────────────
echo "== unit: normalize_host / classify_host / ordered_remotes =="
# shellcheck disable=SC1090
source "$DETECT"

check "normalize https"            '[ "$(normalize_host https://github.com/o/r.git)" = github.com ]'
check "normalize https token"      '[ "$(normalize_host https://u:tok@gitlab.com/o/r.git)" = gitlab.com ]'
check "normalize scp ssh"          '[ "$(normalize_host git@github.com:o/r.git)" = github.com ]'
check "normalize ssh url + port"   '[ "$(normalize_host ssh://git@gitlab.com:22/o/r.git)" = gitlab.com ]'
check "normalize self-hosted scp"  '[ "$(normalize_host git@gitlab.internal:g/r.git)" = gitlab.internal ]'
check "classify exact github"      '[ "$(classify_host github.com)" = github ]'
check "classify exact gitlab"      '[ "$(classify_host gitlab.com)" = gitlab ]'
check "classify substring github"  '[ "$(classify_host github.acme.com)" = github ]'
check "classify substring gitlab"  '[ "$(classify_host gitlab.internal)" = gitlab ]'
check "classify uppercase"         '[ "$(classify_host GITHUB.COM)" = github ]'
check "classify unknown empty"     '[ -z "$(classify_host bitbucket.org)" ]'

# ordered_remotes precedence (run inside a real repo).
UR="$(new_repo)"
( cd "$UR" && git remote add zeta https://example.com/z.git \
   && git remote add origin https://github.com/o/r.git \
   && git remote add upstream https://gitlab.com/o/r.git \
   && git remote add alpha https://example.com/a.git ) >/dev/null 2>&1
ORD="$( cd "$UR" && ordered_remotes | tr '\n' ',' )"
check "ordered_remotes precedence" "[ \"$ORD\" = 'origin,upstream,alpha,zeta,' ]"

# Re-enable a clean slate for integration runs (source leaked set -uo pipefail).
set +u +o pipefail

# ── integration scenarios ──────────────────────────────────────────────────
echo "== integration =="

# 1. github.com exact host
REPO="$(new_repo)"; BIN="$ROOT_TMP/bin1"; make_bin "$BIN"
( cd "$REPO" && git remote add origin git@github.com:o/r.git ) >/dev/null 2>&1
run_detect "$REPO" "$BIN"
check "github.com: forge"      '[ "$(val forge)" = github ]'
check "github.com: host"       '[ "$(val host)" = github.com ]'
check "github.com: supported"  '[ "$(val supported)" = true ]'
check "github.com: cli none (no gh)" '[ "$(val cli)" = none ]'
check "github.com: exit 0"     '[ "$RC" = 0 ]'
assert_block "github.com"

# 2. gitlab.com exact host
REPO="$(new_repo)"; BIN="$ROOT_TMP/bin2"; make_bin "$BIN"
( cd "$REPO" && git remote add origin https://gitlab.com/o/r.git ) >/dev/null 2>&1
run_detect "$REPO" "$BIN"
check "gitlab.com: forge"      '[ "$(val forge)" = gitlab ]'
check "gitlab.com: host"       '[ "$(val host)" = gitlab.com ]'
check "gitlab.com: supported"  '[ "$(val supported)" = true ]'

# 3. self-hosted host-substring (github)
REPO="$(new_repo)"; BIN="$ROOT_TMP/bin3"; make_bin "$BIN"
( cd "$REPO" && git remote add origin git@github.acme.com:o/r.git ) >/dev/null 2>&1
run_detect "$REPO" "$BIN"
check "self-hosted github: forge" '[ "$(val forge)" = github ]'
check "self-hosted github: host"  '[ "$(val host)" = github.acme.com ]'

# 4. self-hosted host-substring (gitlab)
REPO="$(new_repo)"; BIN="$ROOT_TMP/bin4"; make_bin "$BIN"
( cd "$REPO" && git remote add origin https://gitlab.internal/o/r.git ) >/dev/null 2>&1
run_detect "$REPO" "$BIN"
check "self-hosted gitlab: forge" '[ "$(val forge)" = gitlab ]'
check "self-hosted gitlab: host"  '[ "$(val host)" = gitlab.internal ]'

# 5. precedence: origin=gitlab + upstream=github -> gitlab (origin wins)
REPO="$(new_repo)"; BIN="$ROOT_TMP/bin5"; make_bin "$BIN"
( cd "$REPO" && git remote add origin https://gitlab.com/o/r.git \
   && git remote add upstream https://github.com/o/r.git ) >/dev/null 2>&1
run_detect "$REPO" "$BIN"
check "precedence origin wins: forge" '[ "$(val forge)" = gitlab ]'
check "precedence origin wins: host"  '[ "$(val host)" = gitlab.com ]'

# 5b. precedence: origin inconclusive -> upstream classifies
REPO="$(new_repo)"; BIN="$ROOT_TMP/bin5b"; make_bin "$BIN"
( cd "$REPO" && git remote add origin https://bitbucket.org/o/r.git \
   && git remote add upstream https://github.com/o/r.git ) >/dev/null 2>&1
run_detect "$REPO" "$BIN"
check "precedence fallthrough: forge" '[ "$(val forge)" = github ]'
check "precedence fallthrough: host"  '[ "$(val host)" = github.com ]'

# 6. .github/ CI fallback (no remotes)
REPO="$(new_repo)"; BIN="$ROOT_TMP/bin6"; make_bin "$BIN"
mkdir -p "$REPO/.github"
run_detect "$REPO" "$BIN"
check ".github CI: forge"  '[ "$(val forge)" = github ]'
check ".github CI: host unknown" '[ "$(val host)" = unknown ]'
check ".github CI: supported" '[ "$(val supported)" = true ]'

# 7. .gitlab-ci.yml CI fallback (no remotes)
REPO="$(new_repo)"; BIN="$ROOT_TMP/bin7"; make_bin "$BIN"
: > "$REPO/.gitlab-ci.yml"
run_detect "$REPO" "$BIN"
check ".gitlab-ci CI: forge" '[ "$(val forge)" = gitlab ]'
check ".gitlab-ci CI: host unknown" '[ "$(val host)" = unknown ]'

# 8. BOTH CI signals -> unsupported
REPO="$(new_repo)"; BIN="$ROOT_TMP/bin8"; make_bin "$BIN"
mkdir -p "$REPO/.github"; : > "$REPO/.gitlab-ci.yml"
run_detect "$REPO" "$BIN"
check "both CI: forge unsupported" '[ "$(val forge)" = unsupported ]'
check "both CI: supported false"   '[ "$(val supported)" = false ]'
check "both CI: exit 0"            '[ "$RC" = 0 ]'

# 9. mocked `gh repo view` probe (no remotes, no CI)
REPO="$(new_repo)"; BIN="$ROOT_TMP/bin9"; make_bin "$BIN"; stub_cli "$BIN" gh 0 0
run_detect "$REPO" "$BIN"
check "gh probe: forge github" '[ "$(val forge)" = github ]'
check "gh probe: cli gh"       '[ "$(val cli)" = gh ]'
check "gh probe: authenticated" '[ "$(val cli_authenticated)" = true ]'
check "gh probe: host unknown" '[ "$(val host)" = unknown ]'

# 10. mocked `glab repo view` probe
REPO="$(new_repo)"; BIN="$ROOT_TMP/bin10"; make_bin "$BIN"; stub_cli "$BIN" glab 0 0
run_detect "$REPO" "$BIN"
check "glab probe: forge gitlab" '[ "$(val forge)" = gitlab ]'
check "glab probe: cli glab"     '[ "$(val cli)" = glab ]'

# 11. BOTH CLI probes succeed -> unsupported
REPO="$(new_repo)"; BIN="$ROOT_TMP/bin11"; make_bin "$BIN"
stub_cli "$BIN" gh 0 0; stub_cli "$BIN" glab 0 0
run_detect "$REPO" "$BIN"
check "both CLI probe: unsupported" '[ "$(val forge)" = unsupported ]'
check "both CLI probe: cli none"    '[ "$(val cli)" = none ]'

# 12. unauthenticated CLI (forge resolved by remote; gh present, auth fails)
REPO="$(new_repo)"; BIN="$ROOT_TMP/bin12"; make_bin "$BIN"; stub_cli "$BIN" gh 0 1
( cd "$REPO" && git remote add origin https://github.com/o/r.git ) >/dev/null 2>&1
run_detect "$REPO" "$BIN"
check "unauth cli: forge github" '[ "$(val forge)" = github ]'
check "unauth cli: cli gh"       '[ "$(val cli)" = gh ]'
check "unauth cli: not authed"   '[ "$(val cli_authenticated)" = false ]'

# 13. auth exists but repo probe fails -> must NOT classify on auth alone
REPO="$(new_repo)"; BIN="$ROOT_TMP/bin13"; make_bin "$BIN"; stub_cli "$BIN" gh 1 0
run_detect "$REPO" "$BIN"
check "auth-only no classify: unsupported" '[ "$(val forge)" = unsupported ]'
check "auth-only no classify: cli none"    '[ "$(val cli)" = none ]'

# 14. resolved-forge CLI absent but OTHER CLI present -> cli=none
REPO="$(new_repo)"; BIN="$ROOT_TMP/bin14"; make_bin "$BIN"; stub_cli "$BIN" glab 0 0
( cd "$REPO" && git remote add origin https://github.com/o/r.git ) >/dev/null 2>&1
run_detect "$REPO" "$BIN"
check "irrelevant cli: forge github" '[ "$(val forge)" = github ]'
check "irrelevant cli: cli none"     '[ "$(val cli)" = none ]'
check "irrelevant cli: not authed"   '[ "$(val cli_authenticated)" = false ]'

# 15. no remote at all -> Phase B / unsupported, exit 0
REPO="$(new_repo)"; BIN="$ROOT_TMP/bin15"; make_bin "$BIN"
run_detect "$REPO" "$BIN"
check "no remote: forge unsupported" '[ "$(val forge)" = unsupported ]'
check "no remote: host unknown"      '[ "$(val host)" = unknown ]'
check "no remote: cli none"          '[ "$(val cli)" = none ]'
check "no remote: supported false"   '[ "$(val supported)" = false ]'
check "no remote: exit 0"            '[ "$RC" = 0 ]'
assert_block "no remote"

# 16. bitbucket remote -> unsupported (host substring never matches)
REPO="$(new_repo)"; BIN="$ROOT_TMP/bin16"; make_bin "$BIN"
( cd "$REPO" && git remote add origin git@bitbucket.org:o/r.git ) >/dev/null 2>&1
run_detect "$REPO" "$BIN"
check "bitbucket: forge unsupported" '[ "$(val forge)" = unsupported ]'

# 17. operational error: not a git repo -> non-zero, no block
NOGIT="$(mktemp -d "$ROOT_TMP/nogit.XXXXXX")"; BIN="$ROOT_TMP/bin17"; make_bin "$BIN"
run_detect "$NOGIT" "$BIN"
check "not a repo: non-zero exit" '[ "$RC" != 0 ]'
check "not a repo: no forge line" '! printf "%s" "$OUT" | grep -q "^forge="'

echo
echo "== detect_test: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]

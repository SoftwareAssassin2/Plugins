#!/usr/bin/env bash
#
# build-and-test.sh — auto-detect and run a repo's build/test in a PR/MR worktree,
# capturing a log the review folds into `## Build`. A failing build/test is the
# top blocking finding, so this gives the review hard signal the diff can't.
#
# Detection order (ecosystem — first one that yields a runnable command wins):
#   1. package-manager scripts (package.json: pnpm/yarn/npm)
#   2. Makefile / justfile targets
#   3. Cargo (Cargo.toml)
#   4. Go (go.mod)
#   5. .NET (*.sln / *.csproj)
#
# Within package scripts the selection is CUMULATIVE, not first-match:
#   * run `ci` if present;
#   * otherwise run `build` (if present) AND then `test` or `check` (if present)
#     — a repo with both `build` and `test` runs both.
# Makefile/justfile mirror this: `ci` if present, else `build` + `test`/`check`.
# Lint/format-only commands are NEVER selected on their own (this skill emits no
# style findings) — they run only when the repo folds them into its own ci/build.
#
# When no ecosystem yields a command, that is "no build/test command detected" —
# recorded as BUILD_TEST=n/a (NOT a failure; the repo may not expect one).
#
# Usage:
#   build-and-test.sh --worktree <path> [--id <ID>] [--data-dir <dir>]
#     (run setup-worktree.sh first to produce the worktree)
#
# Machine-readable stdout tail the caller parses:
#   BUILD_TEST=pass|fail|n/a
#   BUILD_ECOSYSTEM=package|make|just|cargo|go|dotnet|none
#   BUILD_COMMANDS=<';'-joined command line(s) that ran>
#   BUILD_LOG=<path to the full captured log>
#
# Exit codes:
#   0  every selected phase passed, OR nothing was detected (n/a). "Nothing to
#      build" is a success, like detect's `forge=unsupported`.
#   1  at least one selected phase FAILED (BUILD_TEST=fail).
#   2  usage / worktree missing (nothing was run).
#
# NOTE: strictly `set -uo pipefail` (no `-e`) — every phase runs so the log is
# complete, then the aggregate pass/fail is reported.

set -uo pipefail

PROG="merge-request:review/build-and-test"

die()  { printf '%s: %s\n' "$PROG" "$*" >&2; exit "${2:-1}"; }
warn() { printf '%s: %s\n' "$PROG" "$*" >&2; }

# --- argument parsing ------------------------------------------------------

worktree=""
id=""
data_dir=".data/merge"

while [ $# -gt 0 ]; do
  case "$1" in
    --worktree) worktree="${2:-}"; shift 2 || die "usage: --worktree needs a value" 2 ;;
    --id)       id="${2:-}"; shift 2 || die "usage: --id needs a value" 2 ;;
    --data-dir) data_dir="${2:-}"; shift 2 || die "usage: --data-dir needs a value" 2 ;;
    -h|--help)  grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done

[ -n "$worktree" ] || die "--worktree is required" 2
[ -d "$worktree" ] || die "worktree '$worktree' not found — run setup-worktree.sh first" 2
if [ -n "$id" ]; then
  case "$id" in ''|*[!0-9]*) die "--id must be a numeric PR/MR id (got '$id')" 2 ;; esac
fi

# Log destination. When --id is given, park it next to the artifact in the main
# worktree's data dir; otherwise a temp file. The assistant folds it into
# `## Build`; the standalone file is a debugging convenience.
if [ -n "$id" ]; then
  main_root="$(git -C "$worktree" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
  [ -z "$main_root" ] && main_root="$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null)"
  [ -z "$main_root" ] && main_root="$worktree"
  case "$data_dir" in /*) : ;; *) data_dir="$main_root/$data_dir" ;; esac
  mkdir -p "$data_dir" 2>/dev/null || true
  log="$data_dir/${id}-build.log"
else
  log="$(mktemp "${TMPDIR:-/tmp}/mr-build.XXXXXX")" || die "mktemp failed"
fi
: > "$log"

cd "$worktree" || die "could not cd into worktree '$worktree'"

# --- detection helpers -----------------------------------------------------

# has_npm_script <name> — true if package.json defines scripts.<name>.
has_npm_script() {
  [ -f package.json ] || return 1
  if command -v jq >/dev/null 2>&1; then
    [ -n "$(jq -r --arg n "$1" '.scripts[$n] // empty' package.json 2>/dev/null)" ]
  else
    # jq-less fallback: match a "name": key inside the scripts block, tolerant of spacing.
    grep -qE "\"$1\"[[:space:]]*:" package.json
  fi
}

# has_make_target <name> — true if a Makefile declares target <name>.
has_make_target() {
  [ -f Makefile ] || [ -f makefile ] || return 1
  grep -hqE "^$1[[:space:]]*:" Makefile makefile 2>/dev/null
}

# has_just_recipe <name> — true if a justfile declares recipe <name>.
has_just_recipe() {
  { [ -f justfile ] || [ -f Justfile ] || [ -f .justfile ]; } || return 1
  command -v just >/dev/null 2>&1 || return 1
  just --summary 2>/dev/null | tr ' ' '\n' | grep -qx "$1"
}

rc=0
COMMANDS=()

# phase <label> <cmd...> — run a phase, append its output to the log, track rc.
# The whole block is redirected to the log (NOT piped) so `rc=1` lands in THIS
# shell — a pipe would run the block in a subshell and lose the failure.
phase() {
  local label="$1"; shift
  COMMANDS+=("$*")
  {
    echo "=== $label: $* ==="
    if "$@" 2>&1; then
      echo "  [ok] $label passed"
    else
      echo "  [FAIL] $label failed"
      rc=1
    fi
    echo
  } >>"$log"
}

ECOSYSTEM="none"

# --- 1. package-manager scripts --------------------------------------------

detect_package() {
  [ -f package.json ] || return 1
  local pm=""
  if   [ -f pnpm-lock.yaml ] && command -v pnpm >/dev/null 2>&1; then pm=pnpm
  elif [ -f yarn.lock ]      && command -v yarn >/dev/null 2>&1; then pm=yarn
  elif command -v npm >/dev/null 2>&1;                               then pm=npm
  else warn "package.json present but no package manager (pnpm/yarn/npm) on PATH"; return 1
  fi

  # Which scripts will we actually run? If none, this ecosystem contributes
  # nothing and detection falls through to the next one.
  if has_npm_script ci; then :
  elif has_npm_script build || has_npm_script test || has_npm_script check; then :
  else return 1
  fi

  ECOSYSTEM="package"

  # Install deps when missing (best-effort — a failed install still lets the
  # build phase report the real error rather than a bare "module not found").
  if [ ! -e node_modules ]; then
    case "$pm" in
      pnpm) phase install pnpm install --frozen-lockfile ;;
      yarn) phase install yarn install --frozen-lockfile ;;
      npm)  if [ -f package-lock.json ]; then phase install npm ci; else phase install npm install; fi ;;
    esac
  fi

  if has_npm_script ci; then
    phase ci "$pm" run ci
  else
    has_npm_script build && phase build "$pm" run build
    if   has_npm_script test;  then phase test  "$pm" run test
    elif has_npm_script check; then phase check "$pm" run check
    fi
  fi
  return 0
}

# --- 2. Makefile / justfile -------------------------------------------------

detect_make() {
  { [ -f Makefile ] || [ -f makefile ]; } || return 1
  if has_make_target ci; then :
  elif has_make_target build || has_make_target test || has_make_target check; then :
  else return 1
  fi
  command -v make >/dev/null 2>&1 || { warn "Makefile present but make not on PATH"; return 1; }
  ECOSYSTEM="make"
  if has_make_target ci; then
    phase ci make ci
  else
    has_make_target build && phase build make build
    if   has_make_target test;  then phase test  make test
    elif has_make_target check; then phase check make check
    fi
  fi
  return 0
}

detect_just() {
  { [ -f justfile ] || [ -f Justfile ] || [ -f .justfile ]; } || return 1
  command -v just >/dev/null 2>&1 || return 1
  if has_just_recipe ci; then :
  elif has_just_recipe build || has_just_recipe test || has_just_recipe check; then :
  else return 1
  fi
  ECOSYSTEM="just"
  if has_just_recipe ci; then
    phase ci just ci
  else
    has_just_recipe build && phase build just build
    if   has_just_recipe test;  then phase test  just test
    elif has_just_recipe check; then phase check just check
    fi
  fi
  return 0
}

# --- 3/4/5. Cargo / Go / .NET ----------------------------------------------

detect_cargo() {
  [ -f Cargo.toml ] || return 1
  command -v cargo >/dev/null 2>&1 || { warn "Cargo.toml present but cargo not on PATH"; return 1; }
  ECOSYSTEM="cargo"
  phase build cargo build
  phase test  cargo test
  return 0
}

detect_go() {
  [ -f go.mod ] || return 1
  command -v go >/dev/null 2>&1 || { warn "go.mod present but go not on PATH"; return 1; }
  ECOSYSTEM="go"
  phase build go build ./...
  phase test  go test ./...
  return 0
}

detect_dotnet() {
  local hit=""
  hit="$(find . -maxdepth 2 \( -name '*.sln' -o -name '*.csproj' \) -print -quit 2>/dev/null)"
  [ -n "$hit" ] || return 1
  command -v dotnet >/dev/null 2>&1 || { warn ".NET project present but dotnet not on PATH"; return 1; }
  ECOSYSTEM="dotnet"
  phase build dotnet build
  phase test  dotnet test
  return 0
}

# --- run the first ecosystem that yields a command -------------------------

detect_package \
  || detect_make || detect_just \
  || detect_cargo \
  || detect_go \
  || detect_dotnet \
  || true

# --- report ----------------------------------------------------------------

joined="$(IFS=';'; echo "${COMMANDS[*]:-}")"

if [ "$ECOSYSTEM" = "none" ]; then
  echo "no build/test command detected" >> "$log"
  printf 'BUILD_TEST=n/a\n'
  printf 'BUILD_ECOSYSTEM=none\n'
  printf 'BUILD_COMMANDS=\n'
  printf 'BUILD_LOG=%s\n' "$log"
  exit 0
fi

if [ "$rc" -eq 0 ]; then
  printf 'BUILD_TEST=pass\n'
else
  printf 'BUILD_TEST=fail\n'
fi
printf 'BUILD_ECOSYSTEM=%s\n' "$ECOSYSTEM"
printf 'BUILD_COMMANDS=%s\n'  "$joined"
printf 'BUILD_LOG=%s\n'       "$log"
exit "$rc"

#!/usr/bin/env bash
#
# create.sh — deterministic half of the /merge-request:create skill.
#
# The assistant runs /detect-source-control first, hard-stops when the forge is
# unsupported, then invokes this script with the RESOLVED forge. This script
# owns the mechanical, non-negotiable steps so they behave identically every
# run: ensure HEAD is on the remote, open a ready PR/MR with the templated
# title, capture the canonical id robustly, and (re)write the `## Intent` stash.
# The /merge-request:fix handoff itself is an assistant continuation (a script
# cannot invoke a slash command), so this script only emits the machine-readable
# id the assistant hands on.
#
# Usage:
#   create.sh --forge <github|gitlab> [--intent-file <path>] [--data-dir <dir>]
#
#   --forge       REQUIRED. github or gitlab (from /detect-source-control).
#                 Any other value (e.g. "unsupported") is a hard-stop: the
#                 script exits non-zero without touching git or the forge.
#   --intent-file Optional. A file holding the session's stated pre-MR intent.
#                 When omitted/empty, the intent falls back to
#                 "[TODO] Intent not provided" on a first run, or preserves the
#                 existing stash's `## Intent` prose on a resume.
#   --data-dir    Optional. Where the intent stash lives. Default: .data/merge
#
# Machine-readable stdout (the assistant parses these):
#   MR_ID=<number>
#   MR_FORGE=<github|gitlab>
#   MR_SOURCE=<source-branch>
#   MR_TARGET=<target-branch>
#   MR_STATE=<created|existing>
#   MR_STASH=<path to .data/merge/<ID>.md>
#
# Exit codes:
#   0  PR/MR created (or an existing open one resolved) and stash written.
#   2  usage / unsupported-forge hard-stop (nothing was changed).
#   1  operational failure (no remote, push failed, id unresolvable, ...).
#
# NOTE: strictly `set -uo pipefail` (no `-e`) — failures are handled explicitly
# via `die` so a probe that is *allowed* to fail (e.g. the `@{u}` lookup) never
# aborts the whole run.

set -uo pipefail

PROG="merge-request:create"

die()  { printf '%s: %s\n' "$PROG" "$*" >&2; exit "${2:-1}"; }
warn() { printf '%s: %s\n' "$PROG" "$*" >&2; }

# --- argument parsing ------------------------------------------------------

forge=""
intent_file=""
data_dir=".data/merge"

while [ $# -gt 0 ]; do
  case "$1" in
    --forge)       forge="${2:-}"; shift 2 || die "usage: --forge needs a value" 2 ;;
    --intent-file) intent_file="${2:-}"; shift 2 || die "usage: --intent-file needs a value" 2 ;;
    --data-dir)    data_dir="${2:-}"; shift 2 || die "usage: --data-dir needs a value" 2 ;;
    -h|--help)
      grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'
      exit 0 ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done

# Unsupported-forge hard-stop. The assistant should already have stopped on
# supported=false; this is the belt-and-suspenders guard so the script can never
# drive gh/glab for a forge it doesn't understand.
case "$forge" in
  github|gitlab) : ;;
  "") die "--forge is required (github|gitlab)" 2 ;;
  *)  die "unsupported forge '$forge' — only github and gitlab are supported; nothing was changed" 2 ;;
esac

command -v git >/dev/null 2>&1 || die "git is not installed"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"

# --- helpers ---------------------------------------------------------------

# remote_name -> the remote to push/create against: origin if present, else the
# first configured remote.
remote_name() {
  if git remote 2>/dev/null | grep -qx origin; then
    printf 'origin'
  else
    git remote 2>/dev/null | head -n1
  fi
}

# default_branch -> the repo's default/target branch. Forge-agnostic first
# (origin/HEAD symref, no network), then the forge CLI, then a "main" fallback.
default_branch() {
  local d
  d="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
  d="${d#origin/}"
  if [ -z "$d" ]; then
    case "$forge" in
      github) d="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)" ;;
      gitlab) d="$(glab repo view 2>/dev/null | sed -n 's/.*[Dd]efault branch:[[:space:]]*//p' | head -n1)" ;;
    esac
  fi
  [ -z "$d" ] && d="main"
  printf '%s' "$d"
}

# extract_json_int <json> <key> -> the first integer value of "key" in a JSON
# blob. Dependency-free (no jq) so it works on any host; tolerant of spacing.
extract_json_int() {
  printf '%s' "$1" \
    | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*[0-9]+" \
    | head -n1 \
    | grep -oE '[0-9]+' \
    | head -n1
}

# existing_intent <stash-file> -> the current `## Intent` prose (between the
# `## Intent` heading and the next level-2 heading), trimmed of surrounding
# blank lines. Empty when the file/section is absent.
existing_intent() {
  [ -f "$1" ] || return 0
  awk '
    /^## Intent[[:space:]]*$/ { grab=1; next }
    /^## /                    { grab=0 }
    grab                      { print }
  ' "$1" | sed -e '/./,$!d' | awk 'BEGIN{n=0} {a[n++]=$0} END{last=n-1; while(last>=0 && a[last]=="") last--; for(i=0;i<=last;i++) print a[i]}'
}

# --- resolve branches ------------------------------------------------------

source_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
[ -n "$source_branch" ] || die "could not resolve current branch"
[ "$source_branch" = "HEAD" ] && die "HEAD is detached — check out a branch before creating a PR/MR"

remote="$(remote_name)"
[ -n "$remote" ] || die "no git remote configured"

target_branch="$(default_branch)"
[ "$source_branch" = "$target_branch" ] && \
  die "current branch '$source_branch' is the default branch — nothing to open a PR/MR from"

# --- ensure HEAD is on the remote -----------------------------------------
# No upstream            -> push -u (publish the branch).
# Upstream, local ahead  -> push the unpushed commits (avoid a stale remote).
# Upstream, up to date   -> nothing to push.

if upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"; then
  ahead="$(git rev-list --count '@{u}..HEAD' 2>/dev/null || printf '0')"
  if [ "${ahead:-0}" -gt 0 ] 2>/dev/null; then
    warn "pushing ${ahead} unpushed commit(s) to '${upstream}'"
    git push "$remote" HEAD || die "git push failed"
  fi
else
  warn "no upstream for '${source_branch}' — publishing with 'git push -u ${remote}'"
  git push -u "$remote" HEAD || die "git push -u failed"
fi

# --- create the PR/MR ------------------------------------------------------

title="Merge ${source_branch} into ${target_branch}"
body="Opened by \`/merge-request:create\` for \`${source_branch}\` → \`${target_branch}\`."

CREATE_OUT=""
STATE="created"
ID=""

create_github() {
  local rc
  CREATE_OUT="$(gh pr create --base "$target_branch" --head "$source_branch" \
    --title "$title" --body "$body" 2>&1)"; rc=$?
  if [ $rc -eq 0 ]; then STATE="created"; return 0; fi
  if printf '%s' "$CREATE_OUT" | grep -qiE 'already exists|already a pull request'; then
    STATE="existing"; return 0
  fi
  die "gh pr create failed: ${CREATE_OUT}"
}

capture_id_github() {
  # Authoritative: resolve the canonical number for THIS branch's PR.
  ID="$(gh pr view --json number -q .number 2>/dev/null || true)"
  if [ -z "$ID" ]; then
    # Fallback ONLY when the JSON view path failed: trailing number of the
    # /pull/<n> URL emitted on the create stdout/stderr.
    ID="$(printf '%s' "$CREATE_OUT" \
      | grep -oE 'https?://[^[:space:]]+/pull/[0-9]+' | grep -oE '[0-9]+$' | head -n1)"
  fi
  [ -n "$ID" ] || die "could not resolve PR id"
}

create_gitlab() {
  local rc
  CREATE_OUT="$(glab mr create --source-branch "$source_branch" \
    --target-branch "$target_branch" --title "$title" \
    --description "$body" --yes 2>&1)"; rc=$?
  if [ $rc -eq 0 ]; then STATE="created"; return 0; fi
  if printf '%s' "$CREATE_OUT" | grep -qiE 'already exists|open merge request'; then
    STATE="existing"; return 0
  fi
  die "glab mr create failed: ${CREATE_OUT}"
}

capture_id_gitlab() {
  local json
  json="$(glab mr view --output json 2>/dev/null || true)"
  ID="$(extract_json_int "$json" iid)"
  if [ -z "$ID" ]; then
    ID="$(printf '%s' "$CREATE_OUT" \
      | grep -oE 'https?://[^[:space:]]+/merge_requests/[0-9]+' | grep -oE '[0-9]+$' | head -n1)"
  fi
  [ -n "$ID" ] || die "could not resolve MR id"
}

case "$forge" in
  github) create_github; capture_id_github ;;
  gitlab) create_gitlab; capture_id_gitlab ;;
esac

# --- write / refresh the `## Intent` stash --------------------------------

stash_path="${data_dir}/${ID}.md"
mkdir -p "$data_dir" || die "could not create data dir '${data_dir}'"

# Intent prose precedence:
#   1. explicit --intent-file (non-empty)         -> use it.
#   2. existing stash's `## Intent` prose (resume) -> preserve it (don't clobber
#      a real intent with the TODO placeholder on a re-run).
#   3. otherwise                                   -> the TODO placeholder.
intent_text=""
if [ -n "$intent_file" ] && [ -s "$intent_file" ]; then
  intent_text="$(cat "$intent_file")"
else
  intent_text="$(existing_intent "$stash_path")"
fi
# Trim leading/trailing whitespace-only content.
intent_text="$(printf '%s' "$intent_text" | sed -e 's/[[:space:]]*$//')"
[ -z "$(printf '%s' "$intent_text" | tr -d '[:space:]')" ] && intent_text="[TODO] Intent not provided"

# Change scope (exactly the ranges the spec names): commit list on `..`,
# file stat on the `...` merge-base range.
log_out="$(git log "${target_branch}..HEAD" --oneline 2>/dev/null)"
stat_out="$(git diff --stat "${target_branch}...HEAD" 2>/dev/null)"
[ -z "$log_out" ]  && log_out="(no commits ahead of ${target_branch})"
[ -z "$stat_out" ] && stat_out="(no file changes vs ${target_branch})"

# Backticks below are literal markdown in single-quoted printf formats (not
# command substitution); SC2016 is a deliberate no-op here.
# shellcheck disable=SC2016
{
  printf '# %s\n\n' "$title"
  printf '<!-- Written by /merge-request:create. `## Intent` is consumed by /merge-request:fix. -->\n\n'
  printf '## Intent\n\n'
  printf '%s\n\n' "$intent_text"
  printf '## Change scope\n\n'
  printf '**Commits** (`%s..HEAD`):\n\n' "$target_branch"
  printf '```\n%s\n```\n\n' "$log_out"
  printf '**Files** (`git diff --stat %s...HEAD`):\n\n' "$target_branch"
  printf '```\n%s\n```\n' "$stat_out"
} > "$stash_path" || die "could not write stash '${stash_path}'"

# --- machine-readable result for the assistant handoff --------------------

printf 'MR_ID=%s\n'     "$ID"
printf 'MR_FORGE=%s\n'  "$forge"
printf 'MR_SOURCE=%s\n' "$source_branch"
printf 'MR_TARGET=%s\n' "$target_branch"
printf 'MR_STATE=%s\n'  "$STATE"
printf 'MR_STASH=%s\n'  "$stash_path"

#!/usr/bin/env bash
#
# triage.sh — decide which open PRs/MRs a review run should touch, forge-agnostic.
#
# This script owns the ONE decision the whole review engine hinges on: for each
# candidate PR/MR, does its recorded review still match the current head commit?
# Keeping that comparison in a single place (the `action` branch below) means the
# rest of the skill never re-derives it and can't drift. Crucially the head SHA
# is fetched and the skip check applied HERE, BEFORE any worktree setup or build,
# so an already-current review is skipped early — no wasted checkout/build.
#
# Scope:
#   * with `--id <ID>`   -> triage exactly that one PR/MR (single-ID mode).
#   * without `--id`     -> triage every OPEN PR/MR on the forge (batch mode).
#
# Usage:
#   triage.sh --forge <github|gitlab> [--id <ID>] [--data-dir <dir>]
#
#   --forge     REQUIRED. github or gitlab (from /detect-source-control).
#   --id        Optional. A single PR/MR id; omit to batch every open one.
#   --data-dir  Optional. Where the per-PR/MR `.data/merge/<ID>.md` artifacts
#               live. Default: .data/merge (anchored to the MAIN worktree root
#               so reviews never scatter across linked worktrees).
#
# Output: a JSON array on stdout, one object per candidate PR/MR:
#   { "id": 42,
#     "title": "...",
#     "web_url": "https://.../42",
#     "current_sha": "<head sha, or "" if metadata could not resolve it>",
#     "recorded_sha": "<sha parsed from the artifact, or "">",
#     "action": "new" | "re-review" | "skip",
#     "head_ref": "<source branch>", "head_owner": "<fork owner|"">",
#     "head_repo": "<fork repo|"">",
#     "stash_file": "<.data/merge/<ID>.md>" }
#
# Consumers review every entry whose action is "new" or "re-review" (running
# setup-worktree.sh + build-and-test.sh) and leave "skip" ones untouched. A PR/MR
# whose head SHA cannot be resolved is emitted with current_sha="" and
# action="re-review" (never "skip") so it self-heals through the checkout path,
# where an unresolvable head becomes a blocking finding.
#
# Env:
#   GITLAB_REPO=group/project  Forwarded to glab when it can't infer the project
#                              from the remote (mirrors the gitlab-mr-* skills).
#
# Requires: jq; git; gh (github) or glab (gitlab).
#
# Exit codes:
#   0  triaged and emitted the JSON array (an empty `[]` is a success — nothing
#      open is not an error, like detect's `forge=unsupported`).
#   2  usage / unsupported-forge / bad id (nothing was changed).
#   1  operational failure (missing dependency, not a git repo, listing failed).
#
# NOTE: strictly `set -uo pipefail` (no `-e`) — a per-PR metadata probe is
# ALLOWED to fail (transient forge error) and must degrade to current_sha=""
# rather than aborting the whole triage. Hard failures go through `die`.

set -uo pipefail

PROG="merge-request:review/triage"

die()  { printf '%s: %s\n' "$PROG" "$*" >&2; exit "${2:-1}"; }
warn() { printf '%s: %s\n' "$PROG" "$*" >&2; }

# --- argument parsing ------------------------------------------------------

forge=""
id=""
data_dir=".data/merge"

while [ $# -gt 0 ]; do
  case "$1" in
    --forge)    forge="${2:-}"; shift 2 || die "usage: --forge needs a value" 2 ;;
    --id)       id="${2:-}"; shift 2 || die "usage: --id needs a value" 2 ;;
    --data-dir) data_dir="${2:-}"; shift 2 || die "usage: --data-dir needs a value" 2 ;;
    -h|--help)  grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done

case "$forge" in
  github|gitlab) : ;;
  "") die "--forge is required (github|gitlab)" 2 ;;
  *)  die "unsupported forge '$forge' — only github and gitlab are supported" 2 ;;
esac
command -v jq  >/dev/null 2>&1 || die "jq is required but not installed"
command -v git >/dev/null 2>&1 || die "git is not installed"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"

# The forge CLI is a hard dependency in BOTH single-ID and batch scope — enforce
# it once, up front, so a missing CLI is an operational failure (`die`) rather
# than degrading resolve_meta to empty metadata and silently skipping the
# fetch-head-SHA-before-checkout gate.
case "$forge" in
  github) command -v gh   >/dev/null 2>&1 || die "gh is required for GitHub but not installed" ;;
  gitlab) command -v glab >/dev/null 2>&1 || die "glab is required for GitLab but not installed" ;;
esac

# A single-ID scope must be a numeric PR/MR id — so a malformed id (e.g.
# `../../etc`) can never make `stash_file` escape the data dir.
if [ -n "$id" ]; then
  case "$id" in ''|*[!0-9]*) die "--id must be a numeric PR/MR id (got '$id')" 2 ;; esac
fi

# Reviews always land in ONE place: the MAIN worktree's data dir. This engine is
# often run while an MR branch is checked out in a linked worktree (under
# .worktrees/); without anchoring, artifacts would scatter across whichever
# worktree happened to be the cwd. `git worktree list` prints the main worktree
# first, so its first entry is the canonical root.
main_root="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
[ -z "$main_root" ] && main_root="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$main_root" ] && main_root="$PWD"
case "$data_dir" in
  /*) : ;;                          # absolute — honor it as given
  *)  data_dir="$main_root/$data_dir" ;;
esac

# glab normally infers the project from the git remote. When the remote host
# isn't one glab recognizes, set GITLAB_REPO=group/project to address it.
glab_repo_args=()
[ -n "${GITLAB_REPO:-}" ] && glab_repo_args=(-R "$GITLAB_REPO")

# --- list candidate ids ----------------------------------------------------

# list_ids — print the candidate PR/MR ids, one per line. A listing FAILURE is an
# operational failure (`die`, exit 1) — NOT an empty result: swallowing it would
# make an auth/network/API error look like "nothing open" and silently skip every
# PR/MR. Only the per-PR metadata probe (resolve_meta) is allowed to degrade.
# Must run in the CURRENT shell (redirected to a file, never `$(...)`) so `die`
# exits the whole script rather than just a command-substitution subshell.
list_ids() {
  if [ -n "$id" ]; then
    printf '%s\n' "$id"
    return 0
  fi
  local out json
  case "$forge" in
    github)
      out="$(gh pr list --state open --json number --jq '.[].number' 2>/dev/null)" \
        || die "could not list open PRs (gh pr list failed — check auth/network)"
      [ -n "$out" ] && printf '%s\n' "$out"
      ;;
    gitlab)
      json="$(glab mr list "${glab_repo_args[@]+"${glab_repo_args[@]}"}" --output json 2>/dev/null)" \
        || die "could not list open MRs (glab mr list failed — check auth/network)"
      out="$(printf '%s\n' "$json" | jq -r '.[].iid' 2>/dev/null)" \
        || die "could not parse the open MR list from glab"
      [ -n "$out" ] && printf '%s\n' "$out"
      ;;
  esac
}

# resolve_meta <one-id> — populate current_sha/title/web_url/head_* for one
# PR/MR from forge API/CLI metadata (the fork-safe, authoritative source). Leaves
# fields empty on a probe failure; the caller then treats an empty head SHA as
# "cannot skip -> re-review".
resolve_meta() {
  local one="$1" meta=""
  current_sha=""; title=""; web_url=""; head_ref=""; head_owner=""; head_repo=""
  case "$forge" in
    github)
      meta="$(gh pr view "$one" \
        --json number,title,url,headRefOid,headRefName,headRepository,headRepositoryOwner \
        2>/dev/null || true)"
      [ -n "$meta" ] || return 0
      current_sha="$(jq -r '.headRefOid // ""'            <<<"$meta" 2>/dev/null)"
      title="$(jq -r      '.title // ""'                  <<<"$meta" 2>/dev/null)"
      web_url="$(jq -r    '.url // ""'                    <<<"$meta" 2>/dev/null)"
      head_ref="$(jq -r   '.headRefName // ""'            <<<"$meta" 2>/dev/null)"
      head_repo="$(jq -r  '.headRepository.name // ""'    <<<"$meta" 2>/dev/null)"
      head_owner="$(jq -r '.headRepositoryOwner.login // ""' <<<"$meta" 2>/dev/null)"
      ;;
    gitlab)
      meta="$(glab mr view "$one" "${glab_repo_args[@]+"${glab_repo_args[@]}"}" --output json 2>/dev/null || true)"
      [ -n "$meta" ] || return 0
      current_sha="$(jq -r '.diff_refs.head_sha // .sha // ""' <<<"$meta" 2>/dev/null)"
      title="$(jq -r      '.title // ""'                       <<<"$meta" 2>/dev/null)"
      web_url="$(jq -r    '.web_url // ""'                     <<<"$meta" 2>/dev/null)"
      head_ref="$(jq -r   '.source_branch // ""'               <<<"$meta" 2>/dev/null)"
      # GitLab's MR json does not expose the fork owner path cleanly; the MR head
      # ref (refs/merge-requests/<iid>/head) is fork-safe regardless, so these
      # stay empty and setup-worktree resolves via that ref.
      head_owner=""
      head_repo=""
      ;;
  esac
}

emit() {
  # $1=id $2=title $3=web_url $4=current_sha $5=recorded_sha $6=action
  # $7=head_ref $8=head_owner $9=head_repo ${10}=stash_file
  jq -n \
    --arg id "$1" --arg title "$2" --arg web_url "$3" \
    --arg current_sha "$4" --arg recorded_sha "$5" --arg action "$6" \
    --arg head_ref "$7" --arg head_owner "$8" --arg head_repo "$9" \
    --arg stash_file "${10}" \
    '{id:($id|tonumber), title:$title, web_url:$web_url,
      current_sha:$current_sha, recorded_sha:$recorded_sha, action:$action,
      head_ref:$head_ref, head_owner:$head_owner, head_repo:$head_repo,
      stash_file:$stash_file}'
}

# Redirect (not `$(list_ids)`) so a `die` inside list_ids exits the whole script
# instead of a command-substitution subshell that the parent would ignore.
ids_tmp="$(mktemp "${TMPDIR:-/tmp}/mr-triage.XXXXXX")" || die "mktemp failed"
trap 'rm -f "$ids_tmp"' EXIT
list_ids > "$ids_tmp"

results=()
while IFS= read -r one; do
  case "$one" in ''|*[!0-9]*) continue ;; esac   # ignore any stray non-numeric token
  resolve_meta "$one"

  file="$data_dir/$one.md"
  if [ ! -f "$file" ]; then
    recorded_sha=""
    action="new"
  else
    # The "Reviewed at commit:" line is the skip/re-review contract (ARTIFACT.md).
    # Pull the first hex token out of it; anything else means the artifact is
    # malformed/legacy and we re-review to self-heal.
    recorded_sha="$(grep -m1 -i '^Reviewed at commit:' "$file" 2>/dev/null \
      | grep -oiE '[0-9a-f]{7,40}' | head -n1 || true)"

    # ── the single skip branch point ─────────────────────────────────────
    if [ -z "$current_sha" ]; then
      action="re-review"                          # head unresolved -> never skip
    elif [ -z "$recorded_sha" ]; then
      action="re-review"                          # unparseable stamp -> self-heal
    elif [ "$recorded_sha" = "$current_sha" ]; then
      action="skip"                               # review is current
    else
      action="re-review"                          # new commits since last review
    fi
    # ─────────────────────────────────────────────────────────────────────
  fi

  results+=("$(emit "$one" "$title" "$web_url" "$current_sha" "$recorded_sha" \
                    "$action" "$head_ref" "$head_owner" "$head_repo" "$file")")
done < "$ids_tmp"

if [ ${#results[@]} -eq 0 ]; then
  printf '[]\n'
else
  printf '%s\n' "${results[@]}" | jq -s '.'
fi

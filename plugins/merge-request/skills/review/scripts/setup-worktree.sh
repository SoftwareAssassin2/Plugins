#!/usr/bin/env bash
#
# setup-worktree.sh — put a PR/MR's head into a real, buildable checkout so the
# review runs against code, not just a unified diff.
#
# Resolution is FORK-SAFE and metadata-preferred (the ARTIFACT/spec contract):
#   1. Ask the forge API/CLI for the authoritative head SHA (and, on GitHub, the
#      fork owner/repo/branch). This handles forked PRs and restricted remotes.
#   2. Transport the objects by fetching the PR/MR head ref
#      (`refs/pull/<n>/head` on GitHub, `refs/merge-requests/<iid>/head` on
#      GitLab) — the base repo exposes these even for forks.
#   3. If the ref fetch fails but metadata gave a head SHA, try fetching that SHA
#      (and, on GitHub with a known fork, the fork's branch) directly.
#   4. If a checkout still cannot be established, exit non-zero with
#      `CHECKOUT=unresolved` — the skill then logs it in `## Build`, raises it as
#      the first `## Findings` entry, and skips build/test (never fails silently).
#
# Worktree policy:
#   * If already INSIDE the dedicated worktree for this PR/MR (branch
#     `merge/<ID>` or a worktree dir named `merge-<ID>`), REUSE it — just reset
#     it to the resolved head.
#   * Otherwise create `.worktrees/merge-<ID>` (off the MAIN worktree) with a
#     checkout branch `merge/<ID>` at the resolved head; an existing one is
#     fast-forwarded (reset) to the new head — exactly what re-review wants.
#
# Usage:
#   setup-worktree.sh --forge <github|gitlab> --id <ID>
#
# Machine-readable stdout the caller parses:
#   WORKTREE=<path>
#   HEAD_SHA=<resolved head sha>
#   BRANCH=merge/<ID>
#   CHECKOUT=ok|unresolved
#   STATE=created|updated|reused
#   RESOLUTION=metadata|refs|metadata+refs|sha|fork
#
# On CHECKOUT=unresolved the script also prints `REASON=<text>` and exits 1.
#
# Env:
#   GITLAB_REPO=group/project  Forwarded to glab when it can't infer the project.
#
# Requires: git; jq; gh (github) or glab (gitlab).
#
# Exit codes:
#   0  a checkout was established (CHECKOUT=ok).
#   2  usage / unsupported-forge / bad id (nothing was changed).
#   1  operational failure OR an unresolvable head (CHECKOUT=unresolved).
#
# NOTE: strictly `set -uo pipefail` (no `-e`) — every fetch attempt is ALLOWED to
# fail so the next fallback can run; the unresolved path is reported, not aborted.

set -uo pipefail

PROG="merge-request:review/setup-worktree"

die()  { printf '%s: %s\n' "$PROG" "$*" >&2; exit "${2:-1}"; }
warn() { printf '%s: %s\n' "$PROG" "$*" >&2; }

# unresolved <reason> — emit the machine tail for an unresolvable head and exit 1
# so the skill raises the blocking checkout finding instead of failing silently.
unresolved() {
  warn "$1"
  printf 'CHECKOUT=unresolved\n'
  printf 'REASON=%s\n' "$1"
  exit 1
}

# --- argument parsing ------------------------------------------------------

forge=""
id=""

while [ $# -gt 0 ]; do
  case "$1" in
    --forge)    forge="${2:-}"; shift 2 || die "usage: --forge needs a value" 2 ;;
    --id)       id="${2:-}"; shift 2 || die "usage: --id needs a value" 2 ;;
    -h|--help)  grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done

case "$forge" in
  github|gitlab) : ;;
  "") die "--forge is required (github|gitlab)" 2 ;;
  *)  die "unsupported forge '$forge' — only github and gitlab are supported" 2 ;;
esac
[ -n "$id" ] || die "--id is required" 2
case "$id" in ''|*[!0-9]*) die "--id must be a numeric PR/MR id (got '$id')" 2 ;; esac

command -v git >/dev/null 2>&1 || die "git is not installed"
command -v jq  >/dev/null 2>&1 || die "jq is required but not installed"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"

# Worktrees always hang off the MAIN worktree, never a nested one.
main_root="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
[ -z "$main_root" ] && main_root="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$main_root" ] || die "could not resolve the main worktree root"

# The remote we fetch from: origin if present, else the first configured remote.
remote="$(git -C "$main_root" remote 2>/dev/null | grep -qx origin && echo origin \
          || git -C "$main_root" remote 2>/dev/null | head -n1)"
[ -n "$remote" ] || die "no git remote configured"

glab_repo_args=()
[ -n "${GITLAB_REPO:-}" ] && glab_repo_args=(-R "$GITLAB_REPO")

branch="merge/$id"
wt="$main_root/.worktrees/merge-$id"

# --- 1. metadata (authoritative head, fork-safe) ---------------------------

meta_sha=""
head_owner=""
head_repo=""
head_ref=""
case "$forge" in
  github)
    command -v gh >/dev/null 2>&1 || die "gh is required for GitHub but not installed"
    meta="$(gh pr view "$id" \
      --json headRefOid,headRefName,headRepository,headRepositoryOwner 2>/dev/null || true)"
    if [ -n "$meta" ]; then
      meta_sha="$(jq -r    '.headRefOid // ""'               <<<"$meta" 2>/dev/null)"
      head_ref="$(jq -r    '.headRefName // ""'              <<<"$meta" 2>/dev/null)"
      head_repo="$(jq -r   '.headRepository.name // ""'      <<<"$meta" 2>/dev/null)"
      head_owner="$(jq -r  '.headRepositoryOwner.login // ""' <<<"$meta" 2>/dev/null)"
    fi
    ref="refs/pull/$id/head"
    ;;
  gitlab)
    command -v glab >/dev/null 2>&1 || die "glab is required for GitLab but not installed"
    meta="$(glab mr view "$id" "${glab_repo_args[@]+"${glab_repo_args[@]}"}" --output json 2>/dev/null || true)"
    if [ -n "$meta" ]; then
      meta_sha="$(jq -r '.diff_refs.head_sha // .sha // ""' <<<"$meta" 2>/dev/null)"
      head_ref="$(jq -r '.source_branch // ""'             <<<"$meta" 2>/dev/null)"
    fi
    ref="refs/merge-requests/$id/head"
    ;;
esac

# --- 2/3. resolve + transport the head objects -----------------------------

head_sha=""
resolution=""

# (2) PR/MR head ref transport — fork-safe on the base repo.
if git -C "$main_root" fetch --quiet "$remote" "$ref" 2>/dev/null; then
  fetched="$(git -C "$main_root" rev-parse FETCH_HEAD 2>/dev/null || true)"
  if [ -n "$meta_sha" ] && git -C "$main_root" cat-file -e "${meta_sha}^{commit}" 2>/dev/null; then
    # Metadata is authoritative for WHICH commit the head is; the ref supplied
    # the objects. Prefer the metadata SHA (fork-safe, matches what the forge
    # reports as head) and note both contributed.
    head_sha="$meta_sha"; resolution="metadata+refs"
  elif [ -n "$fetched" ]; then
    head_sha="$fetched"; resolution="refs"
  fi
fi

# (3a) ref transport failed but metadata gave a SHA — try fetching it directly.
if [ -z "$head_sha" ] && [ -n "$meta_sha" ]; then
  if git -C "$main_root" fetch --quiet "$remote" "$meta_sha" 2>/dev/null \
     && git -C "$main_root" cat-file -e "${meta_sha}^{commit}" 2>/dev/null; then
    head_sha="$meta_sha"; resolution="sha"
  fi
fi

# (3b) GitHub fork fallback — build the fork clone URL from the base remote's
# host + the metadata owner/repo and fetch the fork branch directly.
if [ -z "$head_sha" ] && [ "$forge" = "github" ] \
   && [ -n "$head_owner" ] && [ -n "$head_repo" ] && [ -n "$head_ref" ]; then
  base_url="$(git -C "$main_root" remote get-url "$remote" 2>/dev/null || true)"
  host="github.com"
  case "$base_url" in
    *github.com*) host="github.com" ;;
    git@*:*)      host="${base_url#git@}"; host="${host%%:*}" ;;
    https://*)    host="${base_url#https://}"; host="${host%%/*}" ;;
  esac
  fork_url="https://${host}/${head_owner}/${head_repo}.git"
  if git -C "$main_root" fetch --quiet "$fork_url" "$head_ref" 2>/dev/null; then
    head_sha="$(git -C "$main_root" rev-parse FETCH_HEAD 2>/dev/null || true)"
    [ -n "$head_sha" ] && resolution="fork"
  fi
fi

[ -n "$head_sha" ] || unresolved "could not resolve head for $forge PR/MR #$id (metadata + refs both failed)"

# --- worktree: reuse-if-inside, else create/update -------------------------

cur_top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
cur_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"

state=""
if [ "$cur_branch" = "$branch" ] || { [ -n "$cur_top" ] && [ "$(basename "$cur_top")" = "merge-$id" ]; }; then
  # Already inside the dedicated worktree — reuse it, just move it to the head.
  wt="$cur_top"
  git -C "$wt" reset --hard --quiet "$head_sha" || die "could not reset reused worktree to ${head_sha:0:12}"
  state="reused"
elif git -C "$main_root" worktree list --porcelain 2>/dev/null | grep -qx "worktree $wt"; then
  # The dedicated worktree exists but we're not in it — fast-forward it.
  git -C "$wt" reset --hard --quiet "$head_sha" || die "could not update worktree $wt"
  state="updated"
else
  # Create it fresh. `-B` (re)points branch merge/<ID> at the head even if the
  # branch already existed from a prior run.
  git -C "$main_root" worktree add --quiet -B "$branch" "$wt" "$head_sha" \
    || die "could not create worktree $wt (branch $branch)"
  state="created"
fi

printf 'WORKTREE=%s\n'   "$wt"
printf 'HEAD_SHA=%s\n'   "$head_sha"
printf 'BRANCH=%s\n'     "$branch"
printf 'CHECKOUT=ok\n'
printf 'STATE=%s\n'      "$state"
printf 'RESOLUTION=%s\n' "$resolution"

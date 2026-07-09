#!/usr/bin/env bash
#
# post-inline-comment.sh — post ONE approved finding to a pull/merge request,
# inline on the diff when the finding carries valid location metadata, and as a
# general (non-inline) comment otherwise. The deterministic half of
# /merge-request:post-findings's per-finding posting.
#
# The assistant walks the staged `## Findings` (see ../../ARTIFACT.md) one at a
# time; on an approve (or an edit) it calls THIS script to place exactly the
# approved text on the forge. Locking the forge-specific inline-position payload
# here means it behaves identically every run — the assistant only ever passes
# plain arguments (the finding's location fields + the exact body to post).
#
# WHAT IS POSTED IS EXACTLY --body, VERBATIM. --body is the full approved text
# (the finding's Conventional Comments prefix + body). This script never wraps,
# annotates, prefixes, or summarizes it — on the inline path and on the general
# fallback alike, the bytes on the forge are the bytes the user approved.
#
# Location validation & fallback. Inline posting needs, per forge:
#   github: file, (line | line-range), side, head-sha
#   gitlab: file, (line | line-range), base-sha, head-sha   (start-sha := base-sha when omitted)
# When any required field is missing/empty (or --general is passed), the finding
# is posted as a GENERAL comment with exactly --body — never silently dropped.
# This is the ARTIFACT.md contract: a `kind: general` finding, or a `kind: inline`
# finding whose location fields didn't survive, still reaches the author.
#
# Edit consistency (--stage-*). On an edit the assistant re-composes the finding
# record and passes --stage-file/--stage-id/--stage-record so the staged
# `## Findings` entry is rewritten BY ITS STABLE F-<hash> id to match what was
# posted (disk == forge). The rewrite replaces ONLY the one matching record line;
# every other finding and every other section is left byte-for-byte unchanged. The
# rewrite happens ONLY AFTER the post succeeds, so disk never runs ahead of the
# forge; the fid is verified present BEFORE posting so a stale id fails early.
#
# Usage:
#   post-inline-comment.sh --forge <github|gitlab> --id <ID> --body <text> \
#     [--file <path>] [--old-path <path>] \
#     [--line <n> | --line-range <start-end>] [--side <LEFT|RIGHT>] \
#     [--head-sha <sha>] [--base-sha <sha>] [--start-sha <sha>] \
#     [--general] \
#     [--stage-file <artifact> --stage-id <F-hash> --stage-record <json line>]
#
# Machine-readable stdout (the assistant parses these):
#   POSTED=inline|general
#   TARGET=<file:line | file:start-end | general>
#   RESTAGED=1|0
#
# Exit codes:
#   0  the finding was posted (and, if requested, the staged entry rewritten).
#   2  usage / bad arguments (nothing was changed).
#   1  operational failure (missing CLI, forge rejected the post, restage id
#      not found). On a post failure NOTHING is posted and the staged entry is
#      left untouched — the finding is never silently dropped; re-target it to a
#      changed line, edit it, or skip it.
#
# Env:
#   GITLAB_REPO=group/project   Set when glab can't infer the project from the
#                               git remote (mirrors the other merge-request scripts).
#
# Requires: gh (github) or glab (gitlab); jq + sha1sum for the gitlab inline path.
#
# NOTE: strictly `set -uo pipefail` (no `-e`) — every failure is handled
# explicitly via `die` so the machine-readable trailer stays exact.

set -uo pipefail

PROG="merge-request:post-findings/post-inline-comment"

die()  { printf '%s: %s\n' "$PROG" "$*" >&2; exit "${2:-1}"; }
warn() { printf '%s: %s\n' "$PROG" "$*" >&2; }

# --- argument parsing ------------------------------------------------------

forge=""
id=""
body=""
file=""
old_path=""
line=""
line_range=""
side=""
head_sha=""
base_sha=""
start_sha=""
force_general=0
stage_file=""
stage_id=""
stage_record=""
have_body=0

while [ $# -gt 0 ]; do
  case "$1" in
    --forge)        forge="${2:-}"; shift 2 || die "usage: --forge needs a value" 2 ;;
    --id)           id="${2:-}"; shift 2 || die "usage: --id needs a value" 2 ;;
    --body)         body="${2-}"; have_body=1; shift 2 || die "usage: --body needs a value" 2 ;;
    --file)         file="${2:-}"; shift 2 || die "usage: --file needs a value" 2 ;;
    --old-path)     old_path="${2:-}"; shift 2 || die "usage: --old-path needs a value" 2 ;;
    --line)         line="${2:-}"; shift 2 || die "usage: --line needs a value" 2 ;;
    --line-range)   line_range="${2:-}"; shift 2 || die "usage: --line-range needs a value" 2 ;;
    --side)         side="${2:-}"; shift 2 || die "usage: --side needs a value" 2 ;;
    --head-sha)     head_sha="${2:-}"; shift 2 || die "usage: --head-sha needs a value" 2 ;;
    --base-sha)     base_sha="${2:-}"; shift 2 || die "usage: --base-sha needs a value" 2 ;;
    --start-sha)    start_sha="${2:-}"; shift 2 || die "usage: --start-sha needs a value" 2 ;;
    --general)      force_general=1; shift ;;
    --stage-file)   stage_file="${2:-}"; shift 2 || die "usage: --stage-file needs a value" 2 ;;
    --stage-id)     stage_id="${2:-}"; shift 2 || die "usage: --stage-id needs a value" 2 ;;
    --stage-record) stage_record="${2-}"; shift 2 || die "usage: --stage-record needs a value" 2 ;;
    -h|--help)      grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done

case "$forge" in
  github|gitlab) : ;;
  "") die "--forge is required (github|gitlab)" 2 ;;
  *)  die "unsupported forge '$forge' — only github and gitlab" 2 ;;
esac
[ -n "$id" ] || die "--id is required" 2
# PR/MR ids are numeric — enforce it so a malformed id can't smuggle a path into
# the forge API calls below.
case "$id" in ''|*[!0-9]*) die "--id must be a numeric PR/MR id (got '$id')" 2 ;; esac
[ "$have_body" -eq 1 ] || die "--body is required (the exact approved text to post)" 2
[ -n "$body" ] || die "--body must not be empty" 2

# --stage-* is all-or-nothing.
if [ -n "$stage_file" ] || [ -n "$stage_id" ] || [ -n "$stage_record" ]; then
  [ -n "$stage_file" ] && [ -n "$stage_id" ] && [ -n "$stage_record" ] \
    || die "--stage-file, --stage-id, and --stage-record must be given together" 2
  [ -f "$stage_file" ] || die "--stage-file '$stage_file' does not exist" 2
  # Verify the id is present in a `## Findings` record BEFORE posting, so an edit
  # against a stale/wrong id fails early rather than posting then failing to
  # keep disk consistent.
  grep -qE "\"id\"[[:space:]]*:[[:space:]]*\"${stage_id}\"" "$stage_file" \
    || die "restage id '$stage_id' not found in $stage_file — refusing to post an edit that can't be re-staged" 1
fi

# --- line target: single line or a start-end range -------------------------

range_start=""
range_end=""
target_label=""
if [ -n "$line_range" ]; then
  case "$line_range" in
    *-*) range_start="${line_range%%-*}"; range_end="${line_range##*-}" ;;
    *)   range_start="$line_range"; range_end="$line_range" ;;
  esac
elif [ -n "$line" ]; then
  range_start="$line"; range_end="$line"
fi
if [ -n "$range_start" ]; then
  case "$range_start" in ''|*[!0-9]*) die "--line/--line-range start must be an integer (got '$range_start')" 2 ;; esac
  case "$range_end"   in ''|*[!0-9]*) die "--line/--line-range end must be an integer (got '$range_end')" 2 ;; esac
  (( range_start <= range_end )) || die "line range start ($range_start) must be <= end ($range_end)" 2
fi

# --- decide inline vs general ----------------------------------------------
# A finding is postable INLINE only when it carries the full required location
# set for the forge. Anything short of that (or --general) falls back to a
# general comment — the approved text is posted either way, never dropped.

want_inline=1
[ "$force_general" -eq 1 ] && want_inline=0
[ -n "$file" ] || want_inline=0
[ -n "$range_start" ] || want_inline=0
[ -n "$head_sha" ] || want_inline=0
if [ "$forge" = "github" ]; then
  case "$side" in LEFT|RIGHT) : ;; *) want_inline=0 ;; esac
else
  [ -n "$base_sha" ] || want_inline=0
fi

posted_mode=""

# ---------------------------------------------------------------------------
# GitHub
# ---------------------------------------------------------------------------
post_github_inline() {
  # PR review comment on the diff. gh resolves {owner}/{repo} from the repo.
  local fields=(
    -f "body=$body"
    -f "commit_id=$head_sha"
    -f "path=$file"
    -f "side=$side"
  )
  if (( range_start == range_end )); then
    target_label="$file:$range_start"
    fields+=( -F "line=$range_start" )
  else
    target_label="$file:$range_start-$range_end"
    fields+=( -F "start_line=$range_start" -f "start_side=$side" -F "line=$range_end" )
  fi
  local resp
  if ! resp="$(gh api "repos/{owner}/{repo}/pulls/$id/comments" --method POST "${fields[@]}" 2>&1)"; then
    {
      echo "FAILED to post inline comment on PR $id ($target_label):"
      echo "$resp"
      echo
      echo "Most likely the target line isn't part of the PR diff. Re-target a changed"
      echo "line, edit the finding, post it as a general comment (--general), or skip it."
    } >&2
    exit 1
  fi
  echo "Posted inline review comment on PR $id — $target_label"
}

post_github_general() {
  target_label="general"
  local resp
  if ! resp="$(gh pr comment "$id" --body "$body" 2>&1)"; then
    { echo "FAILED to post general comment on PR $id:"; echo "$resp"; } >&2
    exit 1
  fi
  echo "Posted general comment on PR $id"
}

# ---------------------------------------------------------------------------
# GitLab
# ---------------------------------------------------------------------------
gl_proj() { if [ -n "${GITLAB_REPO:-}" ]; then printf '%s' "${GITLAB_REPO//\//%2F}"; else printf ':id'; fi; }

post_gitlab_inline() {
  # GitLab discussion "position" needs the diff SHAs the finding was resolved
  # against: base + start + head. start defaults to base when the review didn't
  # record a distinct start_sha.
  local proj new_path opath st sha1
  proj="$(gl_proj)"
  new_path="$file"
  opath="${old_path:-$file}"
  st="${start_sha:-$base_sha}"
  # GitLab line_code = SHA1(path) + "_" + <old-line-or-0> + "_" + <new-line>.
  sha1="$(printf '%s' "$new_path" | sha1sum | cut -d' ' -f1)"

  local fields=(
    -f "body=$body"
    -f "position[position_type]=text"
    -f "position[base_sha]=$base_sha"
    -f "position[start_sha]=$st"
    -f "position[head_sha]=$head_sha"
    -f "position[old_path]=$opath"
    -f "position[new_path]=$new_path"
  )
  if (( range_start == range_end )); then
    target_label="$file:$range_start"
    fields+=( -f "position[new_line]=$range_start" )
  else
    target_label="$file:$range_start-$range_end"
    fields+=(
      -f "position[new_line]=$range_end"
      -f "position[line_range][start][type]=new"
      -f "position[line_range][start][new_line]=$range_start"
      -f "position[line_range][start][line_code]=${sha1}_0_${range_start}"
      -f "position[line_range][end][type]=new"
      -f "position[line_range][end][new_line]=$range_end"
      -f "position[line_range][end][line_code]=${sha1}_0_${range_end}"
    )
  fi
  local resp
  if ! resp="$(glab api "projects/$proj/merge_requests/$id/discussions" --method POST "${fields[@]}" 2>&1)"; then
    {
      echo "FAILED to post inline comment on MR $id ($target_label):"
      echo "$resp"
      echo
      echo "Most likely the target line isn't part of the MR diff. Re-target a changed"
      echo "line, edit the finding, post it as a general comment (--general), or skip it."
    } >&2
    exit 1
  fi
  echo "Posted inline discussion on MR $id — $target_label"
}

post_gitlab_general() {
  target_label="general"
  local proj resp
  proj="$(gl_proj)"
  if ! resp="$(glab api "projects/$proj/merge_requests/$id/notes" --method POST -f "body=$body" 2>&1)"; then
    { echo "FAILED to post general note on MR $id:"; echo "$resp"; } >&2
    exit 1
  fi
  echo "Posted general note on MR $id"
}

# --- post ------------------------------------------------------------------

if [ "$forge" = "github" ]; then
  command -v gh >/dev/null 2>&1 || die "gh is required for a github forge but not installed"
  if [ "$want_inline" -eq 1 ]; then post_github_inline; posted_mode="inline"; else post_github_general; posted_mode="general"; fi
else
  command -v glab >/dev/null 2>&1 || die "glab is required for a gitlab forge but not installed"
  if [ "$want_inline" -eq 1 ]; then
    command -v jq >/dev/null 2>&1 || die "jq is required for the gitlab inline path"
    command -v sha1sum >/dev/null 2>&1 || die "sha1sum is required for the gitlab inline path"
    post_gitlab_inline; posted_mode="inline"
  else
    post_gitlab_general; posted_mode="general"
  fi
fi

# --- restage the staged finding (edit only), AFTER a successful post -------

restaged=0
if [ -n "$stage_file" ]; then
  tmp="$(mktemp)" || die "could not create temp file for restage"
  # Replace ONLY the one `## Findings` record whose id == stage_id with the new
  # record, verbatim. fid/record travel via the environment (not -v) so any
  # backslashes in the JSON body are not re-interpreted. Every other line is
  # re-emitted exactly as read.
  if REPL="$stage_record" FID="$stage_id" awk '
      BEGIN { fid=ENVIRON["FID"]; repl=ENVIRON["REPL"]; done=0; inF=0 }
      /^## / { inF = ($0 ~ /^## Findings[[:space:]]*$/) ? 1 : 0; print; next }
      {
        if (inF && !done && $0 ~ /^[[:space:]]*\{/ && \
            $0 ~ ("\"id\"[[:space:]]*:[[:space:]]*\"" fid "\"")) {
          print repl; done=1; next
        }
        print
      }
      END { if (!done) exit 3 }
    ' "$stage_file" > "$tmp"; then
    cat "$tmp" > "$stage_file" || { rm -f "$tmp"; die "posted, but failed to write restaged $stage_file"; }
    restaged=1
  else
    rm -f "$tmp"
    die "posted the edit, but the staged id '$stage_id' vanished from $stage_file before restage" 1
  fi
  rm -f "$tmp"
fi

printf 'POSTED=%s\n'   "$posted_mode"
printf 'TARGET=%s\n'   "$target_label"
printf 'RESTAGED=%s\n' "$restaged"

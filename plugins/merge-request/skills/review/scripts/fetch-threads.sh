#!/usr/bin/env bash
#
# fetch-threads.sh — deterministic half of the finding-SELECTION step (fn-11.3).
#
# The review engine (fn-11.2, Steps 0–5) has already scoped the PR/MR, checked it
# out, and run build/test. Before the assistant (being Chris — see ../../SOUL.md)
# selects findings against ../../RUBRIC.md, it needs two mechanical, must-behave-
# identically pieces of forge work that live here so they can't drift:
#
#   * threads    — fetch the PR/MR's EXISTING review comments/discussions and
#                  NORMALIZE each to the forge-agnostic dedupe shape
#                    { author, body, file?, line?, resolved?, kind }
#                  where `file`/`line`/`resolved` are NULLABLE (global/non-inline
#                  comments have none) and `kind` is `inline`|`general`. Covers
#                  GitHub (review threads + issue comments) and GitLab
#                  (discussions + notes). RESOLVED threads are INCLUDED (tagged
#                  resolved:true) — a point someone already raised must suppress a
#                  re-raise even after it was resolved. The assistant reads these
#                  and drops any candidate finding already COVERED ON SUBSTANCE by
#                  anyone (human, prior round, AI reviewer), inline or general.
#                  Substance-matching is the assistant's judgment; this script
#                  only supplies the normalized threads.
#
#   * finding-id — compute the deterministic `F-<hash>` finding id. This is
#                  BYTE-IDENTICAL to the serialization the engine pinned in
#                  ../SKILL.md Step 5 (the blocking-finding id): the tuple
#                    {id}|{file}|{line}|{prefix}|{normalized one-line body}
#                  joined by `|`, piped to `{ sha1sum || shasum; }`, `cut -c1-12`,
#                  prefixed `F-`. Selection uses the SAME implementation so a
#                  selected finding and the engine's blocking finding (and the
#                  `## Declined` ledger) correlate across re-review runs. The body
#                  is passed ALREADY normalized (single line) — this helper does
#                  no extra normalization, so `finding-id --body "$B"` always
#                  equals the inline Step-5 printf for the same `$B`.
#
# Usage:
#   fetch-threads.sh threads    --forge <github|gitlab> --id <ID>
#   fetch-threads.sh finding-id --id <ID> --prefix <prefix> --body <text>
#                               [--file <path>] [--line <n|range>]
#
# `threads` stdout: zero or more JSONL lines (each begins with `{`), one per
# EXISTING thread/comment, followed by a machine-readable trailer of KEY=value
# lines the assistant parses:
#   THREADS_FORGE=github|gitlab
#   THREADS_FETCHED=<int>          # total normalized threads emitted
#   THREADS_INLINE=<int>           # of which kind=inline
#   THREADS_GENERAL=<int>          # of which kind=general
#
# Normalized thread schema (one JSON object per line):
#   { "author":"<login|username>",
#     "body":"<joined comment/note bodies>",
#     "file":"<new-side path>"|null,
#     "line":<int>|null,
#     "resolved":true|false|null,     # null for non-resolvable/global comments
#     "kind":"inline"|"general" }
#
# `finding-id` stdout: a single `F-<12hex>` line.
#
# Exit codes:
#   0  ran and emitted its output (INCLUDING zero threads — an empty PR/MR is a
#      success, mirroring detect's `forge=unsupported`).
#   2  usage / bad arguments (nothing was changed).
#   1  operational failure (missing dependency, not a git repo).
#
# Env:
#   GITLAB_REPO=group/project   Forwarded to glab when it can't infer the project
#                               from the remote (mirrors the other merge-request
#                               scripts and the gitlab-mr-* skills).
#
# Requires: jq; git; gh (github) or glab (gitlab); sha1sum or shasum.
#
# NOTE: strictly `set -uo pipefail` (no `-e`) — forge probes are ALLOWED to fail
# (an unauthenticated CLI, a PR/MR with no threads) and must degrade to "nothing
# fetched" rather than aborting. Hard failures go through `die`.

set -uo pipefail

PROG="merge-request:review/fetch-threads"

die()  { printf '%s: %s\n' "$PROG" "$*" >&2; exit "${2:-1}"; }
warn() { printf '%s: %s\n' "$PROG" "$*" >&2; }

# --- argument parsing ------------------------------------------------------

sub="${1:-}"; shift || true
case "$sub" in
  threads|finding-id) : ;;
  ""|-h|--help)
    grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'
    [ "$sub" = "" ] && exit 2 || exit 0 ;;
  *) die "unknown subcommand '$sub' (threads|finding-id)" 2 ;;
esac

forge=""
id=""
prefix=""
body=""
file=""
line=""

while [ $# -gt 0 ]; do
  case "$1" in
    --forge)  forge="${2:-}";  shift 2 || die "usage: --forge needs a value" 2 ;;
    --id)     id="${2:-}";     shift 2 || die "usage: --id needs a value" 2 ;;
    --prefix) prefix="${2:-}"; shift 2 || die "usage: --prefix needs a value" 2 ;;
    --body)   body="${2:-}";   shift 2 || die "usage: --body needs a value" 2 ;;
    --file)   file="${2:-}";   shift 2 || die "usage: --file needs a value" 2 ;;
    --line)   line="${2:-}";   shift 2 || die "usage: --line needs a value" 2 ;;
    -h|--help) grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done

[ -n "$id" ] || die "--id is required" 2
# PR/MR ids are numeric. Enforce it so a malformed id can never make a forge call
# reach an unexpected resource.
case "$id" in ''|*[!0-9]*) die "--id must be a numeric PR/MR id (got '$id')" 2 ;; esac

# ===========================================================================
# finding-id — deterministic F-<hash>, BYTE-IDENTICAL to SKILL.md Step 5.
#
#   serialize  {id}|{file}|{line}|{prefix}|{body}   (file/line empty for general)
#   hash       sha1sum (fallback shasum) -> first 12 hex chars -> prefix "F-"
#
# Do NOT change this serialization or the hash pipeline without changing Step 5
# in lockstep: the correlation guarantee (selected finding <-> engine blocking
# finding <-> `## Declined` ledger across runs) depends on the two being equal.
# ===========================================================================
if [ "$sub" = "finding-id" ]; then
  [ -n "$prefix" ] || die "finding-id requires --prefix" 2
  [ -n "$body" ]   || die "finding-id requires --body" 2
  printf '%s' "${id}|${file}|${line}|${prefix}|${body}" \
    | { command -v sha1sum >/dev/null 2>&1 && sha1sum || shasum; } \
    | cut -c1-12 | sed 's/^/F-/'
  exit 0
fi

# ===========================================================================
# threads — fetch + normalize existing PR/MR threads
# ===========================================================================
case "$forge" in
  github|gitlab) : ;;
  "") die "--forge is required (github|gitlab)" 2 ;;
  *)  die "unsupported forge '$forge' — only github and gitlab" 2 ;;
esac
command -v jq  >/dev/null 2>&1 || die "jq is required but not installed"
command -v git >/dev/null 2>&1 || die "git is not installed"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"

OUT="$(mktemp "${TMPDIR:-/tmp}/mrthreads.XXXXXX")" || die "mktemp failed"
trap 'rm -f "$OUT"' EXIT

# --- GitHub ----------------------------------------------------------------
# Review threads (kind=inline, resolvable) + issue comments (kind=general,
# resolved=null). reviewThreads is paginated via --paginate/$endCursor so a PR
# with >100 threads never silently drops one; each page is a JSON document and
# the jq filter runs across the concatenated stream. Nested thread comments take
# the first 100 (their joined bodies carry the substance the dedupe matches on).
gather_github() {
  command -v gh >/dev/null 2>&1 || { warn "gh not installed — no GitHub threads"; return 0; }

  # Issue comments — general, non-resolvable.
  gh pr view "$id" --json comments 2>/dev/null \
    | jq -c '.comments[]? | {
        author:(.author.login // "unknown"),
        body:(.body // ""),
        file:null, line:null, resolved:null, kind:"general"
      }' 2>/dev/null >> "$OUT"

  # Review threads — inline, resolvable. Include RESOLVED ones (resolved:true).
  local nwo owner repo
  nwo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  owner="${nwo%%/*}"; repo="${nwo##*/}"
  [ -n "$owner" ] && [ -n "$repo" ] || { warn "could not resolve owner/repo — no GitHub review threads"; return 0; }

  gh api graphql --paginate -F owner="$owner" -F repo="$repo" -F num="$id" -f query='
    query($owner:String!,$repo:String!,$num:Int!,$endCursor:String){
      repository(owner:$owner,name:$repo){
        pullRequest(number:$num){
          reviewThreads(first:100, after:$endCursor){
            pageInfo{hasNextPage endCursor}
            nodes{
              isResolved
              comments(first:100){ nodes{author{login} body path line} }
            }}
        }}}' 2>/dev/null \
    | jq -c '.data.repository.pullRequest.reviewThreads.nodes[]?
        | select(.comments.nodes|length>0)
        | {
            author:(.comments.nodes[0].author.login // "unknown"),
            body:([.comments.nodes[].body] | join("\n---\n")),
            file:(.comments.nodes[0].path // null),
            line:(.comments.nodes[0].line // null),
            resolved:(.isResolved // false),
            kind:"inline"
          }' 2>/dev/null >> "$OUT"
}

# --- GitLab ----------------------------------------------------------------
# Discussions cover BOTH kinds: a discussion whose notes carry a diff `position`
# is inline; one without is a general note. System notes (state changes, label
# churn) are dropped. `resolved` is all-resolvable-notes-resolved, and null when
# the discussion has no resolvable note (a plain general comment).
glab_proj() { if [ -n "${GITLAB_REPO:-}" ]; then printf '%s' "${GITLAB_REPO//\//%2F}"; else printf ':id'; fi; }

gather_gitlab() {
  command -v glab >/dev/null 2>&1 || { warn "glab not installed — no GitLab threads"; return 0; }
  local proj; proj="$(glab_proj)"

  glab api --paginate "projects/$proj/merge_requests/$id/discussions?per_page=100" 2>/dev/null \
    | jq -c '.[]?
        | { notes: [ .notes[] | select(.system==false) ] }
        | select(.notes|length>0)
        | ( [ .notes[].position | select(.!=null) ] | .[0] ) as $pos
        | {
            author:(.notes[0].author.username // "unknown"),
            body:([.notes[].body] | join("\n---\n")),
            file:($pos.new_path // $pos.old_path // null),
            line:($pos.new_line // null),
            resolved:( [ .notes[] | select(.resolvable==true) | .resolved ] as $r
                       | if ($r|length)>0 then ($r|all) else null end ),
            kind:(if $pos != null then "inline" else "general" end)
          }' 2>/dev/null >> "$OUT"
}

case "$forge" in
  github) gather_github ;;
  gitlab) gather_gitlab ;;
esac

# --- emit normalized threads + trailer -------------------------------------
# Drop any malformed/blank lines defensively so the assistant only ever parses
# well-formed objects.
fetched=0; inline=0; general=0
while IFS= read -r t; do
  [ -n "$t" ] || continue
  jq -e . >/dev/null 2>&1 <<<"$t" || continue
  printf '%s\n' "$t"
  fetched=$((fetched+1))
  case "$(jq -r '.kind // ""' <<<"$t" 2>/dev/null)" in
    inline)  inline=$((inline+1)) ;;
    general) general=$((general+1)) ;;
  esac
done < "$OUT"

printf 'THREADS_FORGE=%s\n'   "$forge"
printf 'THREADS_FETCHED=%s\n' "$fetched"
printf 'THREADS_INLINE=%s\n'  "$inline"
printf 'THREADS_GENERAL=%s\n' "$general"
exit 0

#!/usr/bin/env bash
#
# reply-resolve.sh — acknowledge a handled piece of PR/MR feedback: post exactly
# `Fixed` to the originating thread and mark that thread resolved, per forge
# (fn-10.2, the decide-and-apply half of /merge-request:fix).
#
# The assistant runs /detect-source-control first (hard-stops on an unsupported
# forge) and gathers + triages feedback via gather-feedback.sh. Once it has
# IMPLEMENTED a worthy item (tests passed, change committed + pushed), it calls
# THIS script to close the review loop on the originating comment. Locking the
# forge-specific reply+resolve payloads here means the acknowledgement behaves
# identically every run — the assistant only ever passes the item's kind and its
# resolvable id.
#
# The reply body is deterministically `Fixed` (the spec's exact wording). It is
# overridable only for testing via --message; production callers pass nothing.
#
# Resolvability by kind:
#   * thread  — RESOLVABLE. Reply with `Fixed`, then resolve the thread:
#                 GitLab: POST a note to the discussion, then PUT resolved=true.
#                 GitHub: addPullRequestReviewThreadReply, then resolveReviewThread
#                         (both GraphQL, keyed by the thread NODE id).
#   * comment — NON-RESOLVABLE (a plain issue comment / CI annotation with no
#               thread). Post `Fixed` where possible (a general MR/PR note) and
#               SKIP the resolve step — the documented fallback. RESOLVED=skipped.
#
# CI-job items have no thread to acknowledge — the fix IS the pushed commit — so
# the assistant does NOT call this for kind=ci-job; it only writes the ledger.
#
# Usage:
#   reply-resolve.sh --forge <github|gitlab> --id <ID> \
#                    --kind <thread|comment> --source-id <resolvable-id> \
#                    [--message <body>]     # default: Fixed
#
#   --source-id   thread: GitLab discussion id / GitHub review-thread NODE id
#                         (exactly the `source_id` gather-feedback.sh emitted).
#                 comment: the plain-comment id (used only for logging; the
#                         fallback posts a general note, no per-comment reply
#                         endpoint exists).
#
# Machine-readable stdout (the assistant parses these):
#   REPLY_POSTED=1|0        # was the `Fixed` reply/note posted
#   RESOLVED=1|0|skipped    # 1 resolved, 0 attempted-and-failed, skipped=non-resolvable
#   ACK_KIND=<thread|comment>
#   ACK_SOURCE_ID=<id>
#
# Exit codes:
#   0  the reply was posted (thread: AND resolved; comment: resolve skipped).
#   2  usage / bad arguments (nothing was changed).
#   1  operational failure (missing dependency, forge API rejected the mutation).
#
# Env:
#   GITLAB_REPO=group/project   Forwarded to glab when it can't infer the project
#                               from the remote (mirrors the other merge-request
#                               scripts / the gitlab-mr-* skills).
#
# Requires: gh (github) or glab (gitlab).
#
# NOTE: strictly `set -uo pipefail` (no `-e`) — every failure is handled
# explicitly via `die` so the machine-readable trailer semantics stay exact
# (a failed resolve must surface RESOLVED=0, not abort mid-print).

set -uo pipefail

PROG="merge-request:fix/reply-resolve"

die()  { printf '%s: %s\n' "$PROG" "$*" >&2; exit "${2:-1}"; }
warn() { printf '%s: %s\n' "$PROG" "$*" >&2; }

# --- argument parsing ------------------------------------------------------

forge=""
id=""
kind=""
source_id=""
message="Fixed"

while [ $# -gt 0 ]; do
  case "$1" in
    --forge)     forge="${2:-}"; shift 2 || die "usage: --forge needs a value" 2 ;;
    --id)        id="${2:-}"; shift 2 || die "usage: --id needs a value" 2 ;;
    --kind)      kind="${2:-}"; shift 2 || die "usage: --kind needs a value" 2 ;;
    --source-id) source_id="${2:-}"; shift 2 || die "usage: --source-id needs a value" 2 ;;
    --message)   message="${2:-}"; shift 2 || die "usage: --message needs a value" 2 ;;
    -h|--help)   grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done

case "$forge" in
  github|gitlab) : ;;
  "") die "--forge is required (github|gitlab)" 2 ;;
  *)  die "unsupported forge '$forge' — only github and gitlab" 2 ;;
esac
case "$kind" in
  thread|comment) : ;;
  "") die "--kind is required (thread|comment)" 2 ;;
  ci-job) die "ci-job items have no thread to acknowledge — write the ledger, do not call reply-resolve" 2 ;;
  *) die "invalid --kind '$kind' (thread|comment)" 2 ;;
esac
[ -n "$id" ] || die "--id is required" 2
# PR/MR ids are numeric — enforce it so a malformed id can never smuggle a path /
# a URL segment into the forge API calls below.
case "$id" in ''|*[!0-9]*) die "--id must be a numeric PR/MR id (got '$id')" 2 ;; esac
[ -n "$source_id" ] || die "--source-id is required" 2
[ -n "$message" ] || die "--message must not be empty" 2

reply_posted=0
resolved="skipped"

# ===========================================================================
# GitHub
# ===========================================================================
if [ "$forge" = "github" ]; then
  command -v gh >/dev/null 2>&1 || die "gh is required for a github forge but not installed"

  if [ "$kind" = "thread" ]; then
    # source_id is the review-thread NODE id. Reply, then resolve — both GraphQL.
    if gh api graphql -F tid="$source_id" -F body="$message" -f query='
        mutation($tid:ID!,$body:String!){
          addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$tid, body:$body}){
            comment{ id }
          }}' >/dev/null 2>&1; then
      reply_posted=1
    else
      die "failed to post reply to GitHub review thread ${source_id}"
    fi

    if gh api graphql -F tid="$source_id" -f query='
        mutation($tid:ID!){
          resolveReviewThread(input:{threadId:$tid}){ thread{ isResolved } }
        }' >/dev/null 2>&1; then
      resolved="1"
    else
      resolved="0"
      warn "posted '${message}' but failed to resolve GitHub thread ${source_id}"
    fi

  else
    # Non-resolvable plain issue comment — post a general PR note as the fallback,
    # skip the resolve step (there is no thread to resolve).
    if gh pr comment "$id" --body "$message" >/dev/null 2>&1; then
      reply_posted=1
    else
      die "failed to post fallback '${message}' comment on GitHub PR ${id}"
    fi
    resolved="skipped"
  fi

# ===========================================================================
# GitLab
# ===========================================================================
else
  command -v glab >/dev/null 2>&1 || die "glab is required for a gitlab forge but not installed"
  if [ -n "${GITLAB_REPO:-}" ]; then proj="${GITLAB_REPO//\//%2F}"; else proj=":id"; fi

  if [ "$kind" = "thread" ]; then
    # source_id is the discussion id. Reply with a note, then resolve the discussion.
    if glab api "projects/$proj/merge_requests/$id/discussions/$source_id/notes" \
         --method POST -f "body=$message" >/dev/null 2>&1; then
      reply_posted=1
    else
      die "failed to post reply note to GitLab discussion ${source_id} on MR ${id}"
    fi

    if glab api "projects/$proj/merge_requests/$id/discussions/$source_id" \
         --method PUT -f "resolved=true" >/dev/null 2>&1; then
      resolved="1"
    else
      resolved="0"
      warn "posted '${message}' but failed to resolve GitLab discussion ${source_id}"
    fi

  else
    # Non-resolvable plain note — post a general MR note as the fallback, skip resolve.
    if glab api "projects/$proj/merge_requests/$id/notes" \
         --method POST -f "body=$message" >/dev/null 2>&1; then
      reply_posted=1
    else
      die "failed to post fallback '${message}' note on GitLab MR ${id}"
    fi
    resolved="skipped"
  fi
fi

printf 'REPLY_POSTED=%s\n'  "$reply_posted"
printf 'RESOLVED=%s\n'      "$resolved"
printf 'ACK_KIND=%s\n'      "$kind"
printf 'ACK_SOURCE_ID=%s\n' "$source_id"

# A thread reply must succeed to exit 0; a failed resolve (RESOLVED=0) is a real
# operational failure the assistant must see (the thread stays open).
if [ "$reply_posted" != "1" ]; then exit 1; fi
if [ "$kind" = "thread" ] && [ "$resolved" = "0" ]; then exit 1; fi
exit 0

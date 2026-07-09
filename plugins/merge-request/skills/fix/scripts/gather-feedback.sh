#!/usr/bin/env bash
#
# gather-feedback.sh — deterministic half of the /merge-request:fix monitoring
# core (fn-10.1).
#
# The assistant runs /detect-source-control first (hard-stops on an unsupported
# forge), then drives the scheduled-wakeup poll loop. On every wakeup it calls
# this script to do the mechanical, must-behave-identically work:
#
#   * GATHER  — fetch the MR/PR's feedback (human + bot/AI comments, review
#               threads, failing CI jobs) via gh/glab, compute a stable dedupe
#               key per item, diff against the durable `## Handled` ledger in
#               `.data/merge/<ID>.md`, and emit only the UNSEEN-or-CHANGED items
#               as JSONL for the assistant to triage. Also reports MR/PR state
#               (the loop's termination signal) and an adaptive cadence hint.
#   * RECORD  — append a `## Handled` ledger record (the single, canonical
#               ledger writer). fn-10.1 uses it for reported / non-actionable CI
#               items; fn-10.2 reuses it for implemented / declined / pending
#               items. Rewrites the whole `## Handled` section each call so the
#               fenced ```jsonl``` format is always canonical.
#   * LEDGER  — dump the current ledger records as JSONL (debugging / consumers).
#
# The dedupe contract (mirrors the spec):
#   * kind=ci-job         -> dedupe on `fingerprint` ONLY (job/pipeline id churns
#                            on every rerun; the fingerprint is derived from
#                            {forge, job name, commit SHA, normalized error
#                            signature} so a rerun of the same failure is "seen"
#                            but a NEW commit re-surfaces it).
#   * kind=thread|comment -> dedupe on `source_id` + `content_hash` (same id with
#                            a changed hash = an edited comment / new reply =
#                            reconsider). A standing `pending-user` record with an
#                            unchanged hash therefore suppresses re-asking until
#                            the source changes.
#
# Usage:
#   gather-feedback.sh gather --forge <github|gitlab> --id <ID> [--data-dir <dir>]
#                             [--active-window <seconds>]
#   gather-feedback.sh record --id <ID> [--data-dir <dir>]
#                             --kind <thread|comment|ci-job>
#                             --decision <implemented|declined|reported|non-actionable|pending-user>
#                             [--source-id <id>] [--fingerprint <fp>]
#                             [--content-hash <hash>] [--commit <sha>]
#                             [--rationale <text>]
#   gather-feedback.sh ledger --id <ID> [--data-dir <dir>]
#
# `gather` stdout: zero or more JSONL item lines (each begins with `{`) followed
# by a machine-readable trailer of KEY=value lines the assistant parses:
#   MR_STATE=open|closed|merged|unknown
#   MR_UPDATED=<iso8601|unknown>
#   MR_CADENCE=active|idle
#   MR_POLL_SECONDS=<int>          # suggested next-wakeup interval
#   MR_FETCHED_COUNT=<int>         # total feedback items fetched
#   MR_ACTIONABLE_COUNT=<int>      # items emitted (unseen-or-changed)
#
# Item schema (fields present depend on kind):
#   {"kind":"comment|thread|ci-job","source_id":"...","author":"...",
#    "is_bot":true|false,"web_url":"...","commit":"...",
#    # thread|comment: "content_hash","path","line","body","resolved"
#    # ci-job:         "fingerprint","job_name","status","signature"}
#
# Exit codes:
#   0  ran and emitted its output (INCLUDING an empty/closed MR — nothing to do
#      is a success, like detect's `forge=unsupported`).
#   2  usage / bad arguments (nothing was changed).
#   1  operational failure (missing dependency, not a git repo, ledger unwritable).
#
# Env:
#   GITLAB_REPO=group/project   Forwarded to glab when it can't infer the project
#                               from the remote (mirrors the gitlab-mr-* skills).
#
# Requires: jq; git; gh (github) or glab (gitlab); sha1sum or shasum.
#
# NOTE: strictly `set -uo pipefail` (no `-e`) — forge probes are ALLOWED to fail
# (no CI configured, an unauthenticated CLI) and must degrade to "nothing
# fetched" rather than aborting the whole wakeup. Hard failures go through `die`.

set -uo pipefail

PROG="merge-request:fix/gather-feedback"

die()  { printf '%s: %s\n' "$PROG" "$*" >&2; exit "${2:-1}"; }
warn() { printf '%s: %s\n' "$PROG" "$*" >&2; }

# jq filter computing an item/record's canonical dedupe match-key. Shared by the
# ledger read (build the "seen" set) and the candidate filter so both sides agree
# byte-for-byte.
MATCHKEY='if .kind=="ci-job" then "ci:"+(.fingerprint//"") else (.kind)+":"+(.source_id//"")+":"+(.content_hash//"") end'

# --- small dependency-tolerant helpers -------------------------------------

_sha1() {
  if command -v sha1sum >/dev/null 2>&1; then sha1sum | awk '{print $1}'
  else shasum | awk '{print $1}'; fi
}

_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# _epoch <iso8601> -> unix seconds (GNU `date -d` first, then BSD `date -j -f`).
# Prints nothing and returns 1 when it can't parse (caller defaults to active).
_epoch() {
  local iso="$1" e t
  e="$(date -u -d "$iso" +%s 2>/dev/null)" && { printf '%s' "$e"; return 0; }
  t="${iso%Z}"; t="${t%.*}"
  e="$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "$t" +%s 2>/dev/null)" && { printf '%s' "$e"; return 0; }
  return 1
}

# _ci_sig — read a CI job trace on stdin, emit a stable hash of the failure-
# relevant tail with volatile noise stripped (ANSI, timestamps, addresses,
# durations). Empty output when nothing failure-like is present (caller then
# fingerprints on job+commit alone).
_ci_sig() {
  sed -e 's/\x1b\[[0-9;]*m//g' \
      -e 's/[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}[T ][0-9:.]*Z\{0,1\}//g' \
      -e 's/0x[0-9a-fA-F]\{1,\}/0xADDR/g' \
      -e 's/[0-9]\{1,\}\.[0-9]\{1,\}s//g' \
      -e 's/[0-9]\{1,\}ms//g' 2>/dev/null \
    | grep -iE 'error|fail|assert|exception|expected|not ok|panic|traceback' 2>/dev/null \
    | tail -n 40 \
    | _sha1
}

# _text_sig — read arbitrary failure text on stdin (e.g. a GitHub check run's
# output title/summary/annotations) and emit a stable hash with volatile noise
# normalized: ANSI stripped, timestamps/addresses removed, every digit run
# collapsed to `N` (so counts/durations don't churn the hash while test/error
# names still discriminate). Empty in -> empty out (caller falls back to
# job+commit alone).
_text_sig() {
  local t; t="$(cat)"
  [ -n "$(printf '%s' "$t" | tr -d '[:space:]')" ] || return 0
  printf '%s' "$t" \
    | sed -e 's/\x1b\[[0-9;]*m//g' \
          -e 's/[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}[T ][0-9:.]*Z\{0,1\}//g' \
          -e 's/0x[0-9a-fA-F]\{1,\}/0xADDR/g' \
          -e 's/[0-9]\{1,\}/N/g' 2>/dev/null \
    | tr -s '[:space:]' ' ' \
    | _sha1
}

# _gh_rest_comments <thread-node-id> <after-cursor> -> the bodies of a GitHub
# review thread's comments PAST the first page, joined with the same separator
# the inline body uses, so a thread with >100 replies is fully captured (its
# content_hash then reflects every reply). Walks the nested comments connection
# by node id until hasNextPage=false. Empty when there is nothing more.
_gh_rest_comments() {
  local tid="$1" cursor="$2" resp bodies="" hasnext
  while [ -n "$cursor" ] && [ "$cursor" != "null" ]; do
    resp="$(gh api graphql -F id="$tid" -F after="$cursor" -f query='
      query($id:ID!,$after:String){
        node(id:$id){ ... on PullRequestReviewThread {
          comments(first:100, after:$after){
            pageInfo{hasNextPage endCursor}
            nodes{body}
          }}}}' 2>/dev/null)" || break
    [ -n "$resp" ] || break
    bodies="${bodies}$(jq -r '.data.node.comments.nodes[]?.body' <<<"$resp" 2>/dev/null | sed 's/$/\'$'\n''---/')"
    hasnext="$(jq -r '.data.node.comments.pageInfo.hasNextPage // false' <<<"$resp" 2>/dev/null)"
    if [ "$hasnext" = "true" ]; then
      cursor="$(jq -r '.data.node.comments.pageInfo.endCursor // ""' <<<"$resp" 2>/dev/null)"
    else
      cursor=""
    fi
  done
  printf '%s' "$bodies"
}

# _is_bot <login> -> "true" if the account looks like a bot / AI reviewer.
_is_bot() {
  case "$1" in
    *'[bot]'|*-bot|bot-*|*_bot) echo true; return ;;
  esac
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    *bot*|*claude*|github-actions|renovate|codecov|sonarcloud|gitlab-duo|coderabbit*)
      echo true ;;
    *) echo false ;;
  esac
}

# --- ledger read -----------------------------------------------------------

# _read_ledger <stash-file> -> the JSONL records inside the fenced block(s) under
# the `## Handled` heading, one per line. Empty when the file/section is absent.
_read_ledger() {
  [ -f "$1" ] || return 0
  awk '
    /^## Handled[[:space:]]*$/ { insec=1; next }
    insec && /^## /            { insec=0 }
    insec && /^```/            { fence = !fence; next }
    insec && fence             { if ($0 !~ /^[[:space:]]*$/) print }
  ' "$1"
}

# --- argument parsing ------------------------------------------------------

sub="${1:-}"; shift || true
case "$sub" in
  gather|record|ledger) : ;;
  ""|-h|--help)
    grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'
    [ "$sub" = "" ] && exit 2 || exit 0 ;;
  *) die "unknown subcommand '$sub' (gather|record|ledger)" 2 ;;
esac

forge=""
id=""
data_dir=".data/merge"
active_window="1200"   # <=20 min since last activity => "active" cadence tier
kind=""
decision=""
source_id=""
fingerprint=""
content_hash=""
commit=""
rationale=""

while [ $# -gt 0 ]; do
  case "$1" in
    --forge)         forge="${2:-}"; shift 2 || die "usage: --forge needs a value" 2 ;;
    --id)            id="${2:-}"; shift 2 || die "usage: --id needs a value" 2 ;;
    --data-dir)      data_dir="${2:-}"; shift 2 || die "usage: --data-dir needs a value" 2 ;;
    --active-window) active_window="${2:-}"; shift 2 || die "usage: --active-window needs a value" 2 ;;
    --kind)          kind="${2:-}"; shift 2 || die "usage: --kind needs a value" 2 ;;
    --decision)      decision="${2:-}"; shift 2 || die "usage: --decision needs a value" 2 ;;
    --source-id)     source_id="${2:-}"; shift 2 || die "usage: --source-id needs a value" 2 ;;
    --fingerprint)   fingerprint="${2:-}"; shift 2 || die "usage: --fingerprint needs a value" 2 ;;
    --content-hash)  content_hash="${2:-}"; shift 2 || die "usage: --content-hash needs a value" 2 ;;
    --commit)        commit="${2:-}"; shift 2 || die "usage: --commit needs a value" 2 ;;
    --rationale)     rationale="${2:-}"; shift 2 || die "usage: --rationale needs a value" 2 ;;
    -h|--help)       grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done

command -v jq  >/dev/null 2>&1 || die "jq is required but not installed"
[ -n "$id" ] || die "--id is required" 2
# PR/MR ids are numeric. Enforce it so a malformed id (e.g. `../../etc`) can never
# make `stash_path` escape the data dir when record/ledger write to it.
case "$id" in ''|*[!0-9]*) die "--id must be a numeric PR/MR id (got '$id')" 2 ;; esac

stash_path="${data_dir}/${id}.md"

# ===========================================================================
# record — append a canonical `## Handled` ledger entry
# ===========================================================================
if [ "$sub" = "record" ]; then
  case "$kind" in
    thread|comment|ci-job) : ;;
    "") die "--kind is required (thread|comment|ci-job)" 2 ;;
    *)  die "invalid --kind '$kind'" 2 ;;
  esac
  case "$decision" in
    implemented|declined|reported|non-actionable|pending-user) : ;;
    "") die "--decision is required" 2 ;;
    *)  die "invalid --decision '$decision'" 2 ;;
  esac
  # Per-kind dedupe-key requirement (so a record is always matchable later).
  if [ "$kind" = "ci-job" ]; then
    [ -n "$fingerprint" ] || die "ci-job records require --fingerprint" 2
  else
    [ -n "$source_id" ]    || die "$kind records require --source-id" 2
    [ -n "$content_hash" ] || die "$kind records require --content-hash" 2
  fi

  ts="$(_now)"
  record="$(jq -cn \
    --arg kind "$kind" --arg source_id "$source_id" --arg fingerprint "$fingerprint" \
    --arg content_hash "$content_hash" --arg decision "$decision" \
    --arg commit "$commit" --arg rationale "$rationale" --arg ts "$ts" '
    {kind:$kind, decision:$decision, timestamp:$ts}
    + (if $source_id    != "" then {source_id:$source_id}       else {} end)
    + (if $fingerprint  != "" then {fingerprint:$fingerprint}   else {} end)
    + (if $content_hash != "" then {content_hash:$content_hash} else {} end)
    + (if $commit       != "" then {commit:$commit}             else {} end)
    + (if $rationale    != "" then {rationale:$rationale}       else {} end)
  ')" || die "could not build ledger record"

  mkdir -p "$data_dir" || die "could not create data dir '${data_dir}'"
  [ -f "$stash_path" ] || printf '# Merge request %s\n' "$id" > "$stash_path" \
    || die "could not create stash '${stash_path}'"

  # Rebuild the whole `## Handled` section: existing records + the new one, in a
  # single canonical fenced block. Other sections (## Intent, ## Change scope,
  # ## Declined) are preserved verbatim.
  tmp="$(mktemp "${TMPDIR:-/tmp}/mrfix.XXXXXX")" || die "mktemp failed"
  {
    # Preserve every section EXCEPT an existing `## Handled` (rebuilt below),
    # trimming trailing blank lines so the rebuilt section is cleanly separated.
    awk '
      /^## Handled[[:space:]]*$/ { skip=1; next }
      skip && /^## /             { skip=0 }
      !skip                      { line[NR]=$0; last=NR }
      END {
        while (last>0 && line[last] ~ /^[[:space:]]*$/) last--
        for (i=1; i<=last; i++) if (i in line) print line[i]
      }
    ' "$stash_path"
    printf '\n## Handled\n\n'
    printf '<!-- Durable idempotency ledger for /merge-request:fix. One JSON record per line. -->\n\n'
    printf '```jsonl\n'
    _read_ledger "$stash_path"
    printf '%s\n' "$record"
    printf '```\n'
  } > "$tmp" || die "could not assemble updated stash"
  mv "$tmp" "$stash_path" || die "could not write stash '${stash_path}'"

  printf 'HANDLED_WRITTEN=1\n'
  printf 'HANDLED_KIND=%s\n' "$kind"
  printf 'HANDLED_DECISION=%s\n' "$decision"
  printf 'HANDLED_STASH=%s\n' "$stash_path"
  exit 0
fi

# ===========================================================================
# ledger — dump current records
# ===========================================================================
if [ "$sub" = "ledger" ]; then
  _read_ledger "$stash_path"
  exit 0
fi

# ===========================================================================
# gather — fetch feedback, dedupe against the ledger, emit actionable items
# ===========================================================================
case "$forge" in
  github|gitlab) : ;;
  "") die "--forge is required (github|gitlab)" 2 ;;
  *)  die "unsupported forge '$forge' — only github and gitlab" 2 ;;
esac
command -v git >/dev/null 2>&1 || die "git is not installed"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"

CAND="$(mktemp "${TMPDIR:-/tmp}/mrfix-cand.XXXXXX")" || die "mktemp failed"
trap 'rm -f "$CAND" "${SEENF:-}"' EXIT

mr_state="unknown"
mr_updated="unknown"

# add_item <json> — stash a candidate item for the dedupe pass.
add_item() { printf '%s\n' "$1" >> "$CAND"; }

# --- GitHub ----------------------------------------------------------------
gather_github() {
  command -v gh >/dev/null 2>&1 || { warn "gh not installed — no GitHub feedback"; return 0; }

  local meta
  meta="$(gh pr view "$id" --json state,updatedAt,headRefOid 2>/dev/null || true)"
  if [ -n "$meta" ]; then
    case "$(jq -r '.state // "" | ascii_downcase' <<<"$meta")" in
      open)   mr_state="open" ;;
      merged) mr_state="merged" ;;
      closed) mr_state="closed" ;;
    esac
    mr_updated="$(jq -r '.updatedAt // "unknown"' <<<"$meta")"
  fi
  [ -n "$meta" ] || meta='{}'
  local head; head="$(jq -r '.headRefOid // ""' <<<"$meta")"

  # Plain issue comments (non-resolvable).
  gh pr view "$id" --json comments 2>/dev/null \
    | jq -c --arg commit "$head" '.comments[]? | {
        kind:"comment",
        source_id:(.id|tostring),
        author:(.author.login // "unknown"),
        body:(.body // ""),
        web_url:(.url // ""),
        commit:$commit
      }' 2>/dev/null | while IFS= read -r c; do
        [ -n "$c" ] || continue
        local body author ch bot
        body="$(jq -r '.body' <<<"$c")"
        author="$(jq -r '.author' <<<"$c")"
        ch="$(printf '%s' "$body" | _sha1)"
        bot="$(_is_bot "$author")"
        add_item "$(jq -c --arg ch "$ch" --argjson bot "$bot" '. + {content_hash:$ch, is_bot:$bot, resolved:false}' <<<"$c")"
      done

  # Review threads (resolvable; source_id is the thread node id fn-10.2 resolves).
  # `--paginate` walks the reviewThreads connection via pageInfo/$endCursor so a
  # PR with >100 unresolved threads never silently drops feedback. gh emits one
  # JSON document per page; the jq filter runs across the concatenated stream.
  # Nested comments are FULLY paginated too: the first page (with its pageInfo)
  # comes back inline, and any thread reporting `has_more` gets its remaining
  # replies fetched via _gh_rest_comments before the content_hash is computed, so
  # an edited/new reply beyond the first 100 still re-surfaces the thread.
  local nwo owner repo
  nwo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  owner="${nwo%%/*}"; repo="${nwo##*/}"
  if [ -n "$owner" ] && [ -n "$repo" ]; then
    gh api graphql --paginate -F owner="$owner" -F repo="$repo" -F num="$id" -f query='
      query($owner:String!,$repo:String!,$num:Int!,$endCursor:String){
        repository(owner:$owner,name:$repo){
          pullRequest(number:$num){
            reviewThreads(first:100, after:$endCursor){
              pageInfo{hasNextPage endCursor}
              nodes{
                id isResolved
                comments(first:100){
                  pageInfo{hasNextPage endCursor}
                  nodes{author{login} body path line url}
                }
              }}
          }}}' 2>/dev/null \
      | jq -c --arg commit "$head" '.data.repository.pullRequest.reviewThreads.nodes[]?
          | select(.isResolved|not)
          | {
              kind:"thread",
              source_id:.id,
              author:(.comments.nodes[0].author.login // "unknown"),
              path:(.comments.nodes[0].path // null),
              line:(.comments.nodes[0].line // null),
              web_url:(.comments.nodes[0].url // ""),
              body:([.comments.nodes[].body] | join("\n---\n")),
              has_more:(.comments.pageInfo.hasNextPage // false),
              cursor:(.comments.pageInfo.endCursor // null),
              resolved:false,
              commit:$commit
            }' 2>/dev/null | while IFS= read -r t; do
        [ -n "$t" ] || continue
        local body author ch bot tid more cursor
        body="$(jq -r '.body' <<<"$t")"
        author="$(jq -r '.author' <<<"$t")"
        more="$(jq -r '.has_more' <<<"$t")"
        if [ "$more" = "true" ]; then
          tid="$(jq -r '.source_id' <<<"$t")"
          cursor="$(jq -r '.cursor' <<<"$t")"
          body="$body"$'\n---\n'"$(_gh_rest_comments "$tid" "$cursor")"
        fi
        ch="$(printf '%s' "$body" | _sha1)"
        bot="$(_is_bot "$author")"
        # Drop the pagination scaffolding from the emitted item; carry the FULL body.
        add_item "$(jq -c --arg ch "$ch" --arg body "$body" --argjson bot "$bot" \
          'del(.has_more,.cursor) + {content_hash:$ch, is_bot:$bot, body:$body}' <<<"$t")"
      done
  fi

  # Failing CI checks (statusCheckRollup covers both CheckRuns and external
  # status contexts). The logical fingerprint includes a normalized ERROR
  # SIGNATURE (spec: {job, failing test/file, error signature, commit}) so a
  # same-commit rerun that fails for a DIFFERENT reason is not suppressed by a
  # prior ledger record. The signature is derived from each check run's
  # output.title/summary (fetched once for the head commit); external status
  # contexts without a check-run body fall back to job+commit.
  local runs=""
  if [ -n "$owner" ] && [ -n "$repo" ] && [ -n "$head" ]; then
    runs="$(gh api "repos/$owner/$repo/commits/$head/check-runs" --paginate \
              -q '.check_runs[]' 2>/dev/null | jq -s '.' 2>/dev/null || true)"
  fi
  [ -n "$runs" ] || runs='[]'

  gh pr view "$id" --json statusCheckRollup 2>/dev/null \
    | jq -c '.statusCheckRollup[]? | select(
          ((.conclusion // "") | ascii_downcase) as $c
          | ($c=="failure" or $c=="timed_out" or $c=="cancelled" or $c=="action_required" or $c=="startup_failure")
          or ((.state // "") | ascii_downcase | (.=="failure" or .=="error"))
        ) | {
          job_name:(.name // .context // "check"),
          status:((.conclusion // .state) | ascii_downcase),
          web_url:(.detailsUrl // .targetUrl // "")
        }' 2>/dev/null | while IFS= read -r j; do
      [ -n "$j" ] || continue
      local name sigtext sig fp
      name="$(jq -r '.job_name' <<<"$j")"
      sigtext="$(jq -r --arg n "$name" '
        [ .[] | select(.name==$n) | ((.output.title // "")+"\n"+(.output.summary // "")) ]
        | first // ""' <<<"$runs" 2>/dev/null)"
      sig="$(printf '%s' "$sigtext" | _text_sig)"
      fp="$(printf '%s|%s|%s|%s' github "$name" "$head" "$sig" | _sha1)"
      add_item "$(jq -c --arg fp "$fp" --arg sig "$sig" --arg commit "$head" \
        '{kind:"ci-job", source_id:.job_name, job_name:.job_name, status:.status, web_url:.web_url, fingerprint:$fp, signature:$sig, commit:$commit, is_bot:true}' <<<"$j")"
    done
}

# --- GitLab ----------------------------------------------------------------
glab_proj() { if [ -n "${GITLAB_REPO:-}" ]; then printf '%s' "${GITLAB_REPO//\//%2F}"; else printf ':id'; fi; }

gather_gitlab() {
  command -v glab >/dev/null 2>&1 || { warn "glab not installed — no GitLab feedback"; return 0; }
  local proj; proj="$(glab_proj)"

  local meta head
  meta="$(glab api "projects/$proj/merge_requests/$id" 2>/dev/null || true)"
  if [ -n "$meta" ]; then
    case "$(jq -r '.state // "" | ascii_downcase' <<<"$meta")" in
      opened) mr_state="open" ;;
      merged) mr_state="merged" ;;
      closed|locked) mr_state="closed" ;;
    esac
    mr_updated="$(jq -r '.updated_at // "unknown"' <<<"$meta")"
  fi
  [ -n "$meta" ] || meta='{}'
  head="$(jq -r '.sha // .diff_refs.head_sha // ""' <<<"$meta")"

  # Discussions -> one item per discussion carrying its non-system notes.
  glab api --paginate "projects/$proj/merge_requests/$id/discussions?per_page=100" 2>/dev/null \
    | jq -c --arg commit "$head" '.[]?
        | { notes: [ .notes[] | select(.system==false) ] } + {id:.id}
        | select(.notes|length>0)
        | {
            kind:"thread",
            source_id:(.id|tostring),
            author:(.notes[0].author.username // "unknown"),
            path:(.notes[-1].position.new_path // .notes[0].position.new_path // null),
            line:(.notes[-1].position.new_line // .notes[0].position.new_line // null),
            web_url:"",
            body:([.notes[].body] | join("\n---\n")),
            resolved:([.notes[].resolved] | any),
            commit:$commit
          }
        | select(.resolved|not)' 2>/dev/null | while IFS= read -r d; do
      [ -n "$d" ] || continue
      local body author ch bot
      body="$(jq -r '.body' <<<"$d")"
      author="$(jq -r '.author' <<<"$d")"
      ch="$(printf '%s' "$body" | _sha1)"
      bot="$(_is_bot "$author")"
      add_item "$(jq -c --arg ch "$ch" --argjson bot "$bot" '. + {content_hash:$ch, is_bot:$bot}' <<<"$d")"
    done

  # Latest MR pipeline -> failing, non-allow-failure jobs -> fingerprint w/ trace sig.
  local pid
  pid="$(glab api "projects/$proj/merge_requests/$id/pipelines" 2>/dev/null \
         | jq -r 'if type=="array" then (.[0].id // empty) else empty end' 2>/dev/null)"
  [ -n "$pid" ] || return 0
  glab api "projects/$proj/pipelines/$pid/jobs" 2>/dev/null \
    | jq -c '.[]? | select((.status // "")=="failed" and (.allow_failure|not))
        | {job_id:.id, job_name:(.name // "job"), status:.status}' 2>/dev/null \
    | while IFS= read -r j; do
        [ -n "$j" ] || continue
        local jid name sig fp trace
        jid="$(jq -r '.job_id' <<<"$j")"
        name="$(jq -r '.job_name' <<<"$j")"
        trace="$(glab api "projects/$proj/jobs/$jid/trace" 2>/dev/null || true)"
        sig="$(printf '%s' "$trace" | _ci_sig)"
        fp="$(printf '%s|%s|%s|%s' gitlab "$name" "$head" "$sig" | _sha1)"
        add_item "$(jq -c --arg fp "$fp" --arg sig "$sig" --arg commit "$head" --arg jid "$jid" \
          '{kind:"ci-job", source_id:$jid, job_name:.job_name, status:.status, web_url:"", fingerprint:$fp, signature:$sig, commit:$commit, is_bot:true}' <<<"$j")"
      done
}

case "$forge" in
  github) gather_github ;;
  gitlab) gather_gitlab ;;
esac

# --- dedupe candidates against the ledger ----------------------------------
# Build the "seen" match-key set as a file (bash 3.2 has no associative arrays),
# then a fixed-string full-line grep decides suppression.
SEENF="$(mktemp "${TMPDIR:-/tmp}/mrfix-seen.XXXXXX")" || die "mktemp failed"
: > "$SEENF"
while IFS= read -r rec; do
  [ -n "$rec" ] || continue
  mk="$(jq -r "$MATCHKEY" <<<"$rec" 2>/dev/null)" || continue
  [ -n "$mk" ] && printf '%s\n' "$mk" >> "$SEENF"
done < <(_read_ledger "$stash_path")

fetched=0
actionable=0
while IFS= read -r item; do
  [ -n "$item" ] || continue
  fetched=$((fetched+1))
  mk="$(jq -r "$MATCHKEY" <<<"$item" 2>/dev/null)" || continue
  if [ -n "$mk" ] && grep -Fxq -- "$mk" "$SEENF" 2>/dev/null; then continue; fi
  # Emit (drop nothing — the item is already the public schema).
  jq -c '.' <<<"$item"
  actionable=$((actionable+1))
done < "$CAND"

# --- adaptive cadence hint -------------------------------------------------
cadence="active"; poll="150"
if [ "$mr_updated" != "unknown" ]; then
  if up_epoch="$(_epoch "$mr_updated")"; then
    now_epoch="$(date -u +%s)"
    if [ "$((now_epoch - up_epoch))" -gt "$active_window" ] 2>/dev/null; then
      cadence="idle"; poll="1080"
    fi
  fi
fi

printf 'MR_STATE=%s\n'            "$mr_state"
printf 'MR_UPDATED=%s\n'          "$mr_updated"
printf 'MR_CADENCE=%s\n'          "$cadence"
printf 'MR_POLL_SECONDS=%s\n'     "$poll"
printf 'MR_FETCHED_COUNT=%s\n'    "$fetched"
printf 'MR_ACTIONABLE_COUNT=%s\n' "$actionable"

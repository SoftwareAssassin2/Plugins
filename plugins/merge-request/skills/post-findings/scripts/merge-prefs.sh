#!/usr/bin/env bash
#
# merge-prefs.sh — the deterministic half of /merge-request:post-findings's
# learned-preferences loop. It owns the on-disk preferences model so the
# assistant only ever passes plain arguments; the fiddly keyed merge, the
# scoped confirmed write, and the append-only `## Declined` record behave
# identically every run.
#
# There is NO free-form judgement in here — the assistant infers a proposal
# (Don't-raise / Wording / Confirmed-valued) from the user's skip/edit/approve
# and CONFIRMS it with the user; only then does it call `upsert --confirm` to
# land the entry. Without --confirm this script writes NOTHING (it prints the
# PROPOSED entry and exits) — the confirm step is the only thing that writes.
#
# Storage + merge model
# ---------------------
# Preferences live in a global base (`~/.claude/merge-request-preferences.md`)
# plus an OPTIONAL project override (`.data/merge/preferences.md`). Four
# sections, every entry carrying a normalized, space-free `key`:
#
#   ## Don't raise        key = <rubric-category>/<normalized-pattern>   (carries a count)
#   ## Wording            key = <phrasing-rule id>
#   ## Confirmed valued   key = <rubric-category>/<normalized-pattern>
#   ## Rubric weighting   key = <flag name>   (merge/preserve-only — never inferred)
#
# Keyed identity: a project entry with the SAME key REPLACES the global one;
# DIFFERENT keys UNION (additive). "Similar" == same key. Don't-raise entries
# carry a `(count: N)` — the confidence signal that grows on repeated same-key
# skips. `## Rubric weighting` is merge/preserve-only: no interaction infers it
# (`upsert` refuses to write it), it is hand-edited and merged by the same model.
#
# Subcommands
# -----------
#   merge   --global <file> --project <file>
#       Emit the merged, normalized view (same-key project replaces global,
#       different keys union) on stdout. Either file may be absent. This is the
#       view /merge-request:review (fn-11.3) reads; fn-12 OWNS producing it.
#
#   upsert  --scope <global|project> --file <path> --section <section-token>
#           --key <key> --text <description> [--increment] [--confirm]
#       Propose (default) or, with --confirm, WRITE one confirmed preference to
#       the chosen scope's file. section-token ∈ dont-raise|wording|confirmed-valued
#       (rubric-weighting is refused — it is merge/preserve-only). On a Don't-raise
#       whose key already exists, --increment bumps its count; a brand-new
#       Don't-raise starts at count 1. Every other section/entry is preserved
#       byte-for-byte. Without --confirm nothing is written.
#
#   declined-append --file <artifact> --finding-id <F-hash> --summary <text>
#           [--rationale <text>]
#       Append the skipped finding to the `## Declined` section of the staged
#       `.data/merge/<ID>.md` (append-only; every other section preserved
#       byte-for-byte). Fulfils the shared `## Declined` contract in
#       ../../ARTIFACT.md (fix/fn-10 owns the other half). Default rationale:
#       "declined at post gate".
#
# Machine-readable stdout (the assistant parses these):
#   merge:            the merged markdown document
#   upsert (propose): PROPOSED=<entry line> / SCOPE=<scope> / TARGET=<file>
#   upsert (--confirm): WROTE=<scope> / ACTION=created|updated|incremented|appended
#                       SECTION=<heading> / KEY=<key> / COUNT=<n> / TARGET=<file>
#   declined-append:  DECLINED=<F-hash> / TARGET=<file>
#
# Exit codes:
#   0  success (a propose with no write is still success).
#   2  usage / bad arguments (nothing was changed).
#   1  operational failure (could not read/write a file).
#
# NOTE: strictly `set -uo pipefail` (no `-e`) — every failure is handled
# explicitly via `die` so the machine-readable trailer stays exact.

set -uo pipefail

PROG="merge-request:post-findings/merge-prefs"

die()  { printf '%s: %s\n' "$PROG" "$*" >&2; exit "${2:-1}"; }

# Canonical section-token -> heading map (kept in sync with review/fn-11.3).
section_heading() {
  case "$1" in
    dont-raise)        printf "Don't raise" ;;
    wording)           printf "Wording" ;;
    confirmed-valued)  printf "Confirmed valued" ;;
    rubric-weighting)  printf "Rubric weighting" ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# awk programs (quoted heredocs — no shell interpolation inside).
# ---------------------------------------------------------------------------

# merge: read global then project, emit the normalized merged view. Entries are
# `- ` + backtick-delimited key. Same-key project replaces global; new project
# keys union after the global ones. Non-entry prose inside sections is dropped —
# the merged file is a machine-derived view.
read -r -d '' MERGE_AWK <<'AWK'
BEGIN {
  n = split("dont-raise wording confirmed-valued rubric-weighting", tok, " ")
}
FNR==1 { fi++ }                              # fi=1 global, fi=2 project
{
  h=$0; sub(/[[:space:]]+$/,"",h)
  if (h ~ /^## /) {
    sub(/^## /,"",h)
    sec=""
    if (h=="Don't raise") sec="dont-raise"
    else if (h=="Wording") sec="wording"
    else if (h=="Confirmed valued") sec="confirmed-valued"
    else if (h=="Rubric weighting") sec="rubric-weighting"
    next
  }
  if (sec!="" && $0 ~ /^- `/) {
    s=substr($0, index($0,"`")+1)
    if (index(s,"`")==0) next
    k=substr(s,1,index(s,"`")-1)
    if (k=="") next
    if (fi==1) {
      if (!((sec,k) in gseen)) { gorder[sec]=gorder[sec] " " k; gseen[sec,k]=1 }
      gline[sec,k]=$0
    } else {
      if (!((sec,k) in pseen)) { porder[sec]=porder[sec] " " k; pseen[sec,k]=1 }
      pline[sec,k]=$0
    }
  }
}
END {
  print "# Merge-request review — learned preferences (merged view)"
  print ""
  print "Derived from the global base + optional project override by merge-prefs.sh."
  print "Same-key project entry replaces global; different keys union."
  print ""
  for (i=1;i<=n;i++) {
    t=tok[i]
    hd = (t=="dont-raise") ? "Don't raise" \
       : (t=="wording") ? "Wording" \
       : (t=="confirmed-valued") ? "Confirmed valued" : "Rubric weighting"
    print "## " hd
    print ""
    gc=split(gorder[t], gk, " ")
    for (j=1;j<=gc;j++) {
      k=gk[j]; if (k=="") continue
      if ((t,k) in pline) print pline[t,k]; else print gline[t,k]
      used[t,k]=1
    }
    pc=split(porder[t], pk, " ")
    for (j=1;j<=pc;j++) {
      k=pk[j]; if (k=="") continue
      if (!((t,k) in used)) print pline[t,k]
    }
    print ""
  }
}
AWK

# upsert: modify exactly one section of the target file, preserving the header
# and every other section byte-for-byte. Emits the new file on stdout and writes
# ACTION/COUNT/ENTRY metadata to the file named in ENVIRON["META"].
read -r -d '' UPSERT_AWK <<'AWK'
function gettext(l,   p) { p=index(l, SEP); return (p>0) ? substr(l, p+length(SEP)) : "" }
function mkdr(k,c,tx)    { return "- `" k "` (count: " c ")" SEP tx }
function mkentry(k,tx)   { return (T=="dont-raise") ? mkdr(k,1,tx) : ("- `" k "`" SEP tx) }
function flush(   i,done,s,k,cnt,c,txt,last) {
  done=0
  for (i=1;i<=bn && !done;i++) {
    if (buf[i] ~ /^- `/) {
      s=substr(buf[i], index(buf[i],"`")+1)
      if (index(s,"`")==0) continue
      k=substr(s,1,index(s,"`")-1)
      if (k==K) {
        if (INC=="1") {
          cnt=1
          if (match(buf[i], /\(count:[[:space:]]*[0-9]+\)/)) {
            c=substr(buf[i], RSTART, RLENGTH); gsub(/[^0-9]/,"",c); cnt=c+0
          }
          newcount=cnt+1
          txt=gettext(buf[i]); if (txt=="") txt=TX
          buf[i]=mkdr(K, newcount, txt); action="incremented"
        } else {
          buf[i]=mkentry(K, TX); action="updated"
          if (T=="dont-raise") newcount=1
        }
        RESULT=buf[i]; done=1
      }
    }
  }
  if (!done) {
    RESULT = (T=="dont-raise") ? mkdr(K,1,TX) : mkentry(K,TX)
    if (T=="dont-raise") newcount=1
    action="appended"
    last=0
    for (i=1;i<=bn;i++) if (buf[i] !~ /^[[:space:]]*$/) last=i
    for (i=bn;i>last;i--) buf[i+1]=buf[i]
    buf[last+1]=RESULT; bn++
  }
  for (i=1;i<=bn;i++) print buf[i]
  emitted=1
}
BEGIN {
  SEP=" \xe2\x80\x94 "; inSec=0; bn=0; seen=0; newcount=0; action=""; emitted=0
  K=ENVIRON["K"]; TX=ENVIRON["TX"]     # free text via ENVIRON: no -v backslash re-interpretation
}
{
  h=$0; sub(/[[:space:]]+$/,"",h)
  if (h ~ /^## /) {
    if (inSec) { flush(); inSec=0 }
    if (h==("## " H)) { seen=1; inSec=1; bn=0; print; next }
    print; next
  }
  if (inSec) { buf[++bn]=$0; next }
  print
}
END {
  if (inSec) flush()
  if (!seen) {
    # target section absent — append heading + entry at EOF.
    print ""
    print "## " H
    print ""
    RESULT = (T=="dont-raise") ? mkdr(K,1,TX) : mkentry(K,TX)
    if (T=="dont-raise") newcount=1
    action="appended"
    print RESULT
  }
  meta=ENVIRON["META"]
  printf "ACTION=%s\n", action  > meta
  printf "COUNT=%s\n",  newcount > meta
  printf "ENTRY=%s\n",  RESULT   > meta
}
AWK

# declined-append: append one bullet to `## Declined`, preserving everything
# else byte-for-byte. Creates the heading at EOF when absent (append-only, per
# ../../ARTIFACT.md — headings are found by name, not position).
read -r -d '' DECLINED_AWK <<'AWK'
BEGIN { inSec=0; bn=0; seen=0; BULLET=ENVIRON["BULLET"] }
function flush(   i,last) {
  last=0
  for (i=1;i<=bn;i++) if (buf[i] !~ /^[[:space:]]*$/) last=i
  for (i=bn;i>last;i--) buf[i+1]=buf[i]
  buf[last+1]=BULLET; bn++
  for (i=1;i<=bn;i++) print buf[i]
}
{
  h=$0; sub(/[[:space:]]+$/,"",h)
  if (h ~ /^## /) {
    if (inSec) { flush(); inSec=0 }
    if (h=="## Declined") { seen=1; inSec=1; bn=0; print; next }
    print; next
  }
  if (inSec) { buf[++bn]=$0; next }
  print
}
END {
  if (inSec) flush()
  if (!seen) { print ""; print "## Declined"; print ""; print BULLET }
}
AWK

# ---------------------------------------------------------------------------
# subcommand dispatch
# ---------------------------------------------------------------------------

[ $# -ge 1 ] || die "usage: merge-prefs.sh <merge|upsert|declined-append> ..." 2
cmd="$1"; shift

case "$cmd" in
  -h|--help) grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; exit 0 ;;
esac

# ---- merge ----------------------------------------------------------------
cmd_merge() {
  local global="" project=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --global)  global="${2:-}";  shift 2 || die "usage: --global needs a value" 2 ;;
      --project) project="${2:-}"; shift 2 || die "usage: --project needs a value" 2 ;;
      *) die "unknown argument: $1" 2 ;;
    esac
  done
  [ -n "$global" ] || [ -n "$project" ] || die "merge needs at least one of --global/--project" 2
  # An absent (optional) file reads as empty.
  [ -n "$global"  ] && [ -f "$global"  ] || global="/dev/null"
  [ -n "$project" ] && [ -f "$project" ] || project="/dev/null"
  awk "$MERGE_AWK" "$global" "$project" || die "merge failed"
}

# ---- upsert ---------------------------------------------------------------
cmd_upsert() {
  local scope="" file="" section="" key="" text="" increment=0 confirm=0 have_text=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --scope)     scope="${2:-}";   shift 2 || die "usage: --scope needs a value" 2 ;;
      --file)      file="${2:-}";    shift 2 || die "usage: --file needs a value" 2 ;;
      --section)   section="${2:-}"; shift 2 || die "usage: --section needs a value" 2 ;;
      --key)       key="${2:-}";     shift 2 || die "usage: --key needs a value" 2 ;;
      --text)      text="${2-}"; have_text=1; shift 2 || die "usage: --text needs a value" 2 ;;
      --increment) increment=1; shift ;;
      --confirm)   confirm=1; shift ;;
      *) die "unknown argument: $1" 2 ;;
    esac
  done

  case "$scope" in
    global|project) : ;;
    "") die "--scope is required (global|project)" 2 ;;
    *)  die "--scope must be global or project (got '$scope')" 2 ;;
  esac
  [ -n "$file" ] || die "--file is required (the target scope's path)" 2
  local heading
  heading="$(section_heading "$section")" \
    || die "--section must be one of: dont-raise, wording, confirmed-valued (got '$section')" 2
  [ "$section" != "rubric-weighting" ] \
    || die "rubric-weighting is merge/preserve-only — it is hand-edited, never inferred; refusing to write it" 2
  # Only Don't-raise carries a count, so --increment is meaningless (and would
  # corrupt a Wording/Confirmed-valued entry into a counted one) anywhere else.
  [ "$increment" -eq 0 ] || [ "$section" = "dont-raise" ] \
    || die "--increment applies only to --section dont-raise (only Don't-raise entries carry a count)" 2
  [ -n "$key" ] || die "--key is required" 2
  case "$key" in *[[:space:]]*) die "--key must be a normalized, space-free token (got '$key')" 2 ;; esac
  [ "$have_text" -eq 1 ] || die "--text is required (the entry description)" 2
  [ -n "$text" ] || die "--text must not be empty" 2

  # Propose-only path: compute nothing on disk, print the proposal, write nothing.
  # The PROPOSED entry MUST be byte-identical to what --confirm would land, so
  # the user confirms exactly what gets written. For a Don't-raise --increment on
  # an existing key the write keeps the EXISTING text and only bumps the count —
  # so the preview must reuse that existing text, not the passed --text.
  if [ "$confirm" -ne 1 ]; then
    local proposed
    if [ "$section" = "dont-raise" ]; then
      local cur=0 found=""
      if [ -f "$file" ]; then
        found="$(K="$key" awk '
          BEGIN { k=ENVIRON["K"]; SEP=" \xe2\x80\x94 " }
          $0 ~ /^- `/ {
            s=substr($0, index($0,"`")+1); if (index(s,"`")==0) next
            kk=substr(s, 1, index(s,"`")-1)
            if (kk==k) {
              c=1
              if (match($0, /\(count:[[:space:]]*[0-9]+\)/)) {
                cc=substr($0, RSTART, RLENGTH); gsub(/[^0-9]/,"",cc); c=cc+0
              }
              p=index($0, SEP); t=(p>0) ? substr($0, p+length(SEP)) : ""
              printf "%d\t%s", c, t; exit
            }
          }' "$file")"
      fi
      local nxt=1 ptext="$text"
      if [ -n "$found" ]; then
        cur="${found%%$'\t'*}"
        # An existing key with --increment keeps its text and bumps the count;
        # without --increment the write resets to count 1 with the new --text.
        if [ "$increment" -eq 1 ]; then
          nxt=$((cur+1))
          ptext="${found#*$'\t'}"
        fi
      fi
      proposed="- \`${key}\` (count: ${nxt}) — ${ptext}"
    else
      proposed="- \`${key}\` — ${text}"
    fi
    printf 'PROPOSED=%s\n' "$proposed"
    printf 'SCOPE=%s\n' "$scope"
    printf 'TARGET=%s\n' "$file"
    return 0
  fi

  # Confirmed write. Seed a skeleton if the file is missing.
  if [ ! -f "$file" ]; then
    local dir; dir="$(dirname -- "$file")"
    [ -d "$dir" ] || mkdir -p "$dir" || die "could not create directory $dir"
    cat > "$file" <<'SKEL' || die "could not seed $file"
# Merge-request review — learned preferences

Chris's evolving preferences for what review findings to raise and how to word
them. Read by /merge-request:review before staging findings and applied to
selection, phrasing, retention, and priority. Entries are keyed; a project
override with the same key replaces the global entry, different keys union.

## Don't raise

## Wording

## Confirmed valued

## Rubric weighting
SKEL
  fi

  local tmp meta
  tmp="$(mktemp)"  || die "could not create temp file"
  meta="$(mktemp)" || { rm -f "$tmp"; die "could not create temp file"; }
  if META="$meta" K="$key" TX="$text" awk -v T="$section" -v H="$heading" \
        -v INC="$increment" "$UPSERT_AWK" "$file" > "$tmp"; then
    cat "$tmp" > "$file" || { rm -f "$tmp" "$meta"; die "failed to write $file"; }
  else
    rm -f "$tmp" "$meta"; die "failed to compute the updated preferences"
  fi

  local action count entry
  action="$(sed -n 's/^ACTION=//p' "$meta")"
  count="$(sed -n 's/^COUNT=//p' "$meta")"
  entry="$(sed -n 's/^ENTRY=//p' "$meta")"
  rm -f "$tmp" "$meta"

  printf 'WROTE=%s\n'   "$scope"
  printf 'ACTION=%s\n'  "$action"
  printf 'SECTION=%s\n' "$heading"
  printf 'KEY=%s\n'     "$key"
  printf 'COUNT=%s\n'   "$count"
  printf 'ENTRY=%s\n'   "$entry"
  printf 'TARGET=%s\n'  "$file"
}

# ---- declined-append ------------------------------------------------------
cmd_declined_append() {
  local file="" fid="" summary="" rationale="declined at post gate" have_summary=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --file)       file="${2:-}";     shift 2 || die "usage: --file needs a value" 2 ;;
      --finding-id) fid="${2:-}";      shift 2 || die "usage: --finding-id needs a value" 2 ;;
      --summary)    summary="${2-}"; have_summary=1; shift 2 || die "usage: --summary needs a value" 2 ;;
      --rationale)  rationale="${2:-}"; shift 2 || die "usage: --rationale needs a value" 2 ;;
      *) die "unknown argument: $1" 2 ;;
    esac
  done
  # Argument validation (exit 2) precedes the operational file check (exit 1).
  [ -n "$file" ] || die "--file is required (the staged .data/merge/<ID>.md)" 2
  [ -n "$fid" ] || die "--finding-id is required (the stable F-<hash> id)" 2
  case "$fid" in F-*) : ;; *) die "--finding-id must be a stable F-<hash> id (got '$fid')" 2 ;; esac
  [ "$have_summary" -eq 1 ] && [ -n "$summary" ] || die "--summary is required (a one-line summary)" 2
  [ -n "$rationale" ] || rationale="declined at post gate"
  [ -f "$file" ] || die "--file '$file' does not exist — run /merge-request:review first" 1

  local bullet
  bullet="- **${fid}** — ${summary} — ${rationale}"

  local tmp
  tmp="$(mktemp)" || die "could not create temp file"
  if BULLET="$bullet" awk "$DECLINED_AWK" "$file" > "$tmp"; then
    cat "$tmp" > "$file" || { rm -f "$tmp"; die "failed to write $file"; }
  else
    rm -f "$tmp"; die "failed to append the declined record"
  fi
  rm -f "$tmp"

  printf 'DECLINED=%s\n' "$fid"
  printf 'TARGET=%s\n'   "$file"
}

case "$cmd" in
  merge)           cmd_merge "$@" ;;
  upsert)          cmd_upsert "$@" ;;
  declined-append) cmd_declined_append "$@" ;;
  *) die "unknown subcommand '$cmd' — expected merge, upsert, or declined-append" 2 ;;
esac

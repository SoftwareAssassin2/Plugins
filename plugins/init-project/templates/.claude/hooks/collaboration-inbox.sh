#!/usr/bin/env bash
# Description: Read-only SessionStart hook for async team collaboration — resolves
# the current teammate via git identity (user.email) and surfaces threads where
# it's their turn, via the SessionStart additionalContext JSON envelope. It is the
# read half of the protocol in docs/collaboration.md; the agent does every write.
#
# Wired via .claude/settings.json -> hooks.SessionStart (a PROJECT-level hook, not
# a plugin hook: a plugin SessionStart hook's additionalContext does not reach
# Claude — issue #16538 — but a project .claude/settings.json hook's stdout /
# additionalContext IS injected). Coexists with the Stop hook in the same file.
#
# Contract:
#   - Read-only: NO writes, NO network, NO `git fetch`/`git pull`. Reads only the
#     already-pulled working tree.
#   - Fast, non-blocking, idempotent: safe to re-fire on resume/clear/compact.
#   - Identity is read at the PROJECT ROOT (git -C <project_root> config user.email),
#     repo-local resolving to global. user.email is the SINGLE match key; user.name
#     is display-only. Three cases (per collaboration.md "Confirm before attributing"):
#       (a) no user.email            -> silent (nothing to attribute)
#       (b) email not in team.md     -> register advisory (additionalContext envelope)
#       (c) email in team.md         -> recognized; surface their pending turns
#   - Routing is latest-turn-wins: per thread, the highest-<n> turn's status decides
#     — assignee alerted on awaiting-assignee, asker on awaiting-asker; resolved (or a
#     superseded earlier status) never alerts.
#   - additionalContext is JSON-escaped with a robust encoder (jq); if jq is absent,
#     fall back to raw-text stdout (also injected by SessionStart) rather than risk
#     emitting malformed JSON.
#   - Freshness ("as of your last pull" + suggest `git pull`) is appended ONLY when
#     context is already being surfaced; a no-pending session stays silent.
#   - ALWAYS exit 0; never block the session.
#
# Uses `set -uo pipefail` (NOT -e, like statusline.sh): it runs tolerant git/jq
# probes that may exit non-zero, and must degrade gracefully rather than abort.

set -uo pipefail

# Drain and ignore the hook JSON Claude Code passes on stdin (the marker we need is
# the git identity + the inboxes, not anything on stdin).
cat >/dev/null 2>&1 || true

# --- emit: wrap free-form markdown in the SessionStart additionalContext envelope --
# JSON-escape with jq (robust against quotes/newlines/backslashes in the body). If
# jq is unavailable, fall back to raw-text stdout (SessionStart injects that too)
# rather than risk emitting malformed JSON.
emit() {
  local text="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg ctx "$text" \
      '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
  else
    printf '%s\n' "$text"
  fi
}

# --- slugify: whole-email slug, matching collaboration.md "Handles" -----------------
# lowercase the WHOLE string; every run of non-[a-z0-9] -> a single '-'; trim '-'.
# Used ONLY to suggest a handle in the unregistered advisory; the recognized path
# uses the STORED team.md handle, never a re-derived one.
slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

# --- trim: strip surrounding whitespace -------------------------------------------
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# --- header_field: pull a `key:value` field from a `|`-delimited header line --------
header_field() {
  # $1 = header line, $2 = field name (e.g. asker)
  local line="$1" key="$2" seg v
  # Trailing newline so `read` also yields the final segment (the unterminated
  # last `|`-field — e.g. `subject:` — would otherwise be dropped).
  while IFS= read -r seg; do
    seg="$(trim "$seg")"
    case "$seg" in
      "$key":*)
        v="${seg#"$key":}"
        trim "$v"
        return
        ;;
    esac
  done < <(printf '%s\n' "$line" | tr '|' '\n')
}

# Resolve the project root relative to THIS script (hooks/ is under .claude/), so the
# hook works regardless of the session's current working directory.
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 0
claude_dir="$(cd -- "$script_dir/.." && pwd)" || exit 0
project_root="$(cd -- "$claude_dir/.." && pwd)" || exit 0

# --- Identity (case (a): no user.email -> silent) ---------------------------------
# user.email is the single match key; guarded so a missing config / no-git never errors.
my_email="$(git -C "$project_root" config --get user.email 2>/dev/null || true)"
[[ -z "$my_email" ]] && exit 0

# --- Parse team.md: find MY row by git-email, capture my STORED handle --------------
# Table columns (fixed): handle | name | git-email | computer-name | reports-to
# Skip the header row and the |---| separator row; the fake placeholder example row
# is harmless (its placeholder email never matches a real user.email). Identity keys
# off git-email; routing then uses that row's stored handle (never re-derived).
team_file="$project_root/docs/team.md"
my_handle=""
if [[ -f "$team_file" ]]; then
  while IFS= read -r line; do
    [[ "$line" == \|* ]] || continue          # table rows only
    case "$line" in
      *[!\|\ :-]*) : ;;                         # has a real char -> content/header row
      *) continue ;;                            # all '|', ' ', ':', '-' -> separator
    esac
    IFS='|' read -r _lead c_handle _c_name c_email _rest <<<"$line"
    c_handle="$(trim "$c_handle")"
    c_email="$(trim "$c_email")"
    [[ "$c_email" == "git-email" ]] && continue # header row
    if [[ -n "$c_email" && "$c_email" == "$my_email" ]]; then
      my_handle="$c_handle"
      break
    fi
  done < "$team_file"
fi

# --- Freshness probe (R10): guarded; NEVER fetches ---------------------------------
# Only as fresh as the last pull. @{u} is fragile (no upstream / detached HEAD /
# unfetched) — guard it before any rev-list so it never errors the hook.
freshness_note() {
  local upstream behind
  upstream="$(git -C "$project_root" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  if [[ -n "$upstream" ]]; then
    behind="$(git -C "$project_root" rev-list --left-right --count 'HEAD...@{u}' 2>/dev/null | awk '{print $2}')"
    if [[ -n "${behind:-}" && "$behind" != "0" ]]; then
      # The backticked `git pull` is literal markdown advice, not a command sub.
      # shellcheck disable=SC2016
      printf '_Shown as of your last pull. %s is %s commit(s) ahead — run `git pull` for the latest._' "$upstream" "$behind"
      return
    fi
  fi
  # shellcheck disable=SC2016
  printf '_Shown as of your last pull — run `git pull` if you want the latest._'
}

# --- Case (b): email present but not registered -> register advisory ----------------
if [[ -z "$my_handle" ]]; then
  suggested="$(slugify "$my_email")"
  body="$(printf '%s\n\n%s' \
    "**Async collaboration:** your git identity \`$my_email\` isn't in \`docs/team.md\` yet." \
    "Tell me your display name and who you report to and I'll register you (suggested handle: \`$suggested\`). See \`docs/collaboration.md\`." )"
  emit "$body"   # no freshness on the advisory (no surfaced threads)
  exit 0
fi

# --- Case (c): recognized -> scan inboxes, surface MY pending turns -----------------
# Streaming parse, top-to-bottom: a `## thread:` header starts the current thread
# (carrying id/asker/assignee); subsequent `### turn` lines belong to it until the
# next header. For each thread take the HIGHEST-<n> turn and route ONLY off that
# latest turn's status (latest-turn-wins): assignee on awaiting-assignee, asker on
# awaiting-asker, nobody on resolved/superseded.
collab_dir="$project_root/docs/collaboration"
pending=""
pending_count=0

# Decide whether the just-parsed thread awaits me, and if so append a line.
flush_thread() {
  # globals in: t_has t_max_n t_latest_status t_assignee t_asker t_id t_subject my_handle
  # globals out: pending pending_count
  [[ "$t_has" -eq 1 ]] || return 0
  [[ "$t_max_n" -ge 0 ]] || return 0
  local target="" role who
  case "$t_latest_status" in
    awaiting-assignee) target="$t_assignee" ;;
    awaiting-asker)    target="$t_asker" ;;
    *) return 0 ;;   # resolved / unknown -> nobody
  esac
  [[ -n "$target" && "$target" == "$my_handle" ]] || return 0
  if [[ "$t_latest_status" == "awaiting-assignee" ]]; then
    role="awaiting you"; who="from \`${t_asker:-unknown}\`"
  else
    role="answered — your turn"; who="\`${t_assignee:-unknown}\` replied"
  fi
  pending="${pending}- **${t_subject:-(no subject)}** (thread \`${t_id:-?}\`, ${who}) — ${role}"$'\n'
  pending_count=$((pending_count + 1))
}

if [[ -d "$collab_dir" ]]; then
  shopt -s nullglob 2>/dev/null || true
  for inbox in "$collab_dir"/*.md; do
    [[ -f "$inbox" ]] || continue
    t_has=0; t_id=""; t_asker=""; t_assignee=""; t_subject=""
    t_max_n=-1; t_latest_status=""
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        "## thread:"*)
          flush_thread                     # close the previous thread first
          t_has=1
          t_id="$(header_field "${line#"## "}" thread)"
          t_asker="$(header_field "$line" asker)"
          t_assignee="$(header_field "$line" assignee)"
          t_subject="$(header_field "$line" subject)"
          t_max_n=-1; t_latest_status=""
          ;;
        "### turn "*)
          rest="${line#"### turn "}"
          n="${rest%%[!0-9]*}"             # leading digits = the turn counter
          [[ -n "$n" ]] || continue
          status="$(header_field "$line" status)"
          if [[ "$n" -gt "$t_max_n" ]]; then
            t_max_n="$n"
            t_latest_status="$status"
          fi
          ;;
        *) : ;;
      esac
    done < "$inbox"
    flush_thread                            # close the final thread of the file
  done
fi

# --- Nothing pending -> silent (no bare freshness) ---------------------------------
[[ "$pending_count" -eq 0 ]] && exit 0

# --- Surface context + freshness (R10: freshness ONLY alongside surfaced context) --
header="**Async collaboration — $pending_count thread(s) need you:**"
body="$(printf '%s\n\n%s\n%s' "$header" "$pending" "$(freshness_note)")"
emit "$body"
exit 0

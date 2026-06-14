#!/usr/bin/env bash
# Description: Claude Code status line — shows "<branch> | <model> | <ctx>% ctx".
#
# Claude Code invokes this with the status-line JSON on stdin. Fields used:
#   .model.display_name              -> the active model's friendly name
#   .workspace.current_dir           -> cwd (for the git branch lookup)
#   .context.used_pct / .cost.*      -> context-window usage, when available
# Anything missing degrades gracefully (the segment is dropped, never an error).
#
# Wired via .claude/settings.json -> statusLine. Activated by /init-project's
# git phase; coexists with the Stop hook in the same settings.json.

set -uo pipefail

input="$(cat)"

jq_get() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }

model="$(jq_get '.model.display_name')"
[[ -z "$model" ]] && model="$(jq_get '.model.id')"

cwd="$(jq_get '.workspace.current_dir')"
[[ -z "$cwd" ]] && cwd="$(jq_get '.cwd')"
[[ -z "$cwd" ]] && cwd="$PWD"

# Git branch (silent if not a repo).
branch=""
if branch="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)"; then
  [[ "$branch" == "HEAD" ]] && branch="$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null)"
fi

# Context-window usage as a percentage, from whichever field the host provides.
ctx="$(jq_get '.context.used_pct')"
[[ -z "$ctx" ]] && ctx="$(jq_get '.cost.context_used_pct')"

segments=()
[[ -n "$branch" ]] && segments+=("$branch")
[[ -n "$model" ]]  && segments+=("$model")
if [[ -n "$ctx" ]]; then
  # Round to a whole percent if it's numeric.
  ctx_round="$(printf '%.0f' "$ctx" 2>/dev/null || printf '%s' "$ctx")"
  segments+=("${ctx_round}% ctx")
fi

# Join with " | ".
out=""
for s in "${segments[@]}"; do
  [[ -n "$out" ]] && out+=" | "
  out+="$s"
done

printf '%s' "$out"

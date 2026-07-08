#!/usr/bin/env bash
# Description: Claude Code status line — "<branch> | <model> | <ctx>% ctx | <5h>% 5h | <wk>% wk".
#
# Claude Code invokes this with the status-line JSON on stdin. Fields used:
#   .model.display_name                      -> the active model's friendly name
#   .workspace.current_dir                   -> cwd (for the git branch lookup)
#   .context_window.used_percentage          -> context-window fill (% of window)
#   .rate_limits.five_hour.used_percentage   -> plan token usage, 5-hour window
#   .rate_limits.seven_day.used_percentage   -> plan token usage, 7-day window
# Anything missing degrades gracefully (the segment is dropped, never an error).
# rate_limits are Claude.ai (Pro/Max) only and appear after the first API call —
# API-key/Bedrock/Vertex sessions simply won't render the 5h/wk segments.
#
# Wired via .claude/settings.json -> statusLine. Activated by /init-project's
# git phase; coexists with the Stop hook in the same settings.json.

set -uo pipefail

input="$(cat)"

jq_get() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }

# Round a numeric percentage to a whole number; pass anything non-numeric through.
round_pct() { printf '%.0f' "$1" 2>/dev/null || printf '%s' "$1"; }

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

# Context-window fill: how full this session's context window is.
ctx="$(jq_get '.context_window.used_percentage')"

# Plan token-limit usage: % of the Pro/Max token allowance consumed in each
# rolling window (5-hour and 7-day). Distinct from context fill above.
rl5="$(jq_get '.rate_limits.five_hour.used_percentage')"
rl7="$(jq_get '.rate_limits.seven_day.used_percentage')"

segments=()
[[ -n "$branch" ]] && segments+=("$branch")
[[ -n "$model" ]]  && segments+=("$model")
[[ -n "$ctx" ]]    && segments+=("$(round_pct "$ctx")% ctx")
[[ -n "$rl5" ]]    && segments+=("$(round_pct "$rl5")% 5h")
[[ -n "$rl7" ]]    && segments+=("$(round_pct "$rl7")% wk")

# Join with " | ".
out=""
for s in "${segments[@]}"; do
  [[ -n "$out" ]] && out+=" | "
  out+="$s"
done

printf '%s' "$out"

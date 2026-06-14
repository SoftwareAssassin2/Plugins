#!/usr/bin/env bash
# Description: Non-blocking Stop hook — remind to refresh CLAUDE.md / docs when a
# doc-worthy update was surfaced this session. Fires ONLY when the marker file
# .claude/.claude-md-dirty exists; prints the reminder to stdout and clears the
# marker. Otherwise it is silent. It NEVER edits CLAUDE.md or any doc itself.
#
# Wired via .claude/settings.json -> hooks.Stop. Claude Code passes the hook JSON
# on stdin; this hook ignores it (the marker is the only signal it needs).
#
# Contract: always exit 0. A Stop hook must never block the session from
# stopping; this is purely advisory.

set -euo pipefail

# Resolve the project's .claude dir relative to this script (hooks/ is under it),
# so the hook works regardless of the session's current working directory.
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
claude_dir="$(cd -- "$script_dir/.." && pwd)"
marker="$claude_dir/.claude-md-dirty"

if [[ -f "$marker" ]]; then
  rm -f "$marker"
  cat <<'EOF'
[reminder] This session surfaced an update worth persisting.
Consider refreshing CLAUDE.md and/or the relevant docs/ standard before moving on.
(This reminder is advisory and was cleared automatically — nothing was edited.)
EOF
fi

exit 0

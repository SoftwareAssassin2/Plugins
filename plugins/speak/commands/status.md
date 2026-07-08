---
description: Full speak diagnostic — toggle state, detected mode, port, listener reachability, dependencies
---

# /speak:status — full diagnostic

Run this exact command with the Bash tool (a NON-ZERO exit simply means the install is unhealthy — the report is still printed, so show it either way; do not treat the exit code as a tool error):

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/speak" doctor
```

Then report to the user:

1. Show the diagnostic output (verbatim or lightly formatted — keep every row: toggle state, detected mode, SPEAK_PORT, listener reachability, and each dependency with its required-vs-optional label).
2. State the bottom line from the `result:` line — healthy, or what exactly to fix (the report names the missing tool/capability and its install guidance).
3. If the listener is the problem and the user is in forward mode, spell out the fix: open a terminal ON THE HOST at the workspace root and run `./plugins/speak/bin/speak --serve`.

Do not "fix" anything yourself — this command only diagnoses and reports.

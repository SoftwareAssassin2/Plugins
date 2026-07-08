---
description: Run the speak plugin's bundled test suite and report pass/fail
---

# /speak:test — run the bundled tests

Run this exact command with the Bash tool. The explicit `${CLAUDE_PLUGIN_ROOT}` path matters (plugin commands run from arbitrary working directories), and `--plain` skips kcov instrumentation so the run is fast and deterministic:

```bash
"${CLAUDE_PLUGIN_ROOT}/tests/coverage.sh" --plain
```

Exit code 0 means every suite passed; non-zero means at least one check failed (this is a test verdict, not a tool error — the output says exactly which checks failed).

Then report to the user:

1. The `RESULT:` line from each suite (`cli_test.sh`, `listener_test.sh`, `hook_test.sh`) — passed/failed counts.
2. The bottom line: all green, or the failing `FAIL -` check lines verbatim.

Do not fix anything as part of this command — it only runs the suite and reports. (For line-coverage numbers, run `tests/coverage.sh` with no flags in a terminal on native Linux; kcov records no shell lines on macOS.)

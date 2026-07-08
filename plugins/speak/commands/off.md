---
description: Turn auto-speak off — assistant responses are no longer spoken automatically
---

# /speak:off — disable auto-speak

Run this exact command with the Bash tool:

```bash
SPEAK_DATA_DIR="${CLAUDE_PLUGIN_DATA}" "${CLAUDE_PLUGIN_ROOT}/bin/speak" off
```

Then report the outcome:

- **Success** (it prints `speak: auto-speak is now off ...`): confirm to the user that auto-speak is OFF — responses are no longer spoken automatically (they can still use `/speak:speak` or `/speak:specify` on demand). Note: this does not interrupt any speech already playing.
- **Failure**: relay the CLI's error message as-is (e.g. "toggle unavailable" means neither `SPEAK_DATA_DIR` nor `CLAUDE_PLUGIN_DATA` is set). Suggest `/speak:status` for the full diagnostic.

Do not do anything else — no cleanup, no extra commands.

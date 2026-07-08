---
description: Turn auto-speak on — every assistant response is spoken aloud until /speak:off
---

# /speak:on — enable auto-speak

Run this exact command with the Bash tool:

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/speak" on
```

Then report the outcome:

- **Success** (it prints `speak: auto-speak is now on ...`): confirm to the user that auto-speak is ON — from now on the Stop hook speaks every assistant response aloud, until they run `/speak:off`.
- **Failure**: relay the CLI's error message as-is (e.g. "toggle unavailable" means neither `SPEAK_DATA_DIR` nor `CLAUDE_PLUGIN_DATA` is set). Suggest `/speak:status` for the full diagnostic.

Do not do anything else — no cleanup, no extra commands.

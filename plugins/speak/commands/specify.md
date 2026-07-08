---
description: Speak a chosen recent assistant response aloud (asks which one first, works regardless of the auto-speak toggle)
---

# /speak:specify — pick a recent assistant response and speak it aloud

Speak one of the recent assistant responses in this conversation out loud via the speak plugin CLI. This works regardless of whether auto-speak is on or off. Follow these steps exactly.

## 1. Ask which response to read — ALWAYS ask first

Several assistant responses may have accumulated since the user's last prompt, so never assume the latest one is wanted. Use the AskUserQuestion tool to present a pick list of the recent assistant responses in this conversation:

- Most-recent first, up to the last 4 assistant responses.
- Label each option with a short one-line summary of that response (e.g. "Explained the doctor exit codes"), and mark which one is the most recent.
- Ask even when only one response is available (the user can still decline).

Only the explicit `/speak:specify` path offers this selection — `/speak:speak` speaks the very last response without asking, and auto-speak (the Stop hook) never asks and only ever speaks the just-finished response.

## 2. Hand the chosen text to the CLI — robust stdin handoff

Recover the chosen response's body **as faithfully as possible** — best-effort verbatim, including its markdown, code fences, backticks, and URLs. Do NOT pre-clean, summarize, reformat, or shorten it: the CLI does its own cleaning (strips code blocks, markdown, URLs) before speaking.

Raw assistant markdown can contain backticks, code fences, quotes, and any delimiter, so never paste the text inline into a shell command line. Use a temp file:

1. Write the exact text to a temp file (use the Write tool with a path like `/tmp/speak-specify-<random>.txt`, or `mktemp`).
2. Feed it to the CLI as stdin with the Bash tool:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/bin/speak" < /tmp/speak-specify-<random>.txt
   ```

3. Remove the temp file afterwards (`rm -f`).

If you must inline instead of using a temp file, the only acceptable form is a QUOTED heredoc with a generated unlikely delimiter (so no line of the text can terminate it early), e.g. `<<'SPEAK_EOF_x7k9q2'` ... `SPEAK_EOF_x7k9q2`. Never use an unquoted or common delimiter like `EOF`.

Never invent or use a `--last`-style flag: the terminal command surface is fixed and has no such command — the text always travels via stdin as above.

## 3. Report the outcome

- **Exit 0:** briefly confirm the chosen response is being spoken.
- **Non-zero with an unreachable-listener error** (stderr says "could not reach the host listener"): tell the user **immediately and clearly** — the user asked explicitly, so this message is never softened, suppressed, or debounced. Include the fix verbatim: open a terminal ON THE HOST at the workspace root and run `./plugins/speak/bin/speak --serve`.
- **Any other failure** (missing dependency, invalid `SPEAK_PORT`/`SPEAK_MODE`, unsupported host): relay the CLI's stderr message to the user as-is, and suggest `/speak:status` for the full diagnostic.

---
description: Speak the very last assistant response aloud immediately (no selection prompt; works regardless of the auto-speak toggle)
---

# /speak:speak — speak the last assistant response aloud, immediately

Speak the most recent assistant response in this conversation out loud via the speak plugin CLI. This works regardless of whether auto-speak is on or off. Because the plugin is named `speak`, this command also answers to the unprefixed form `/speak` when no other installed command claims that name.

## 1. Take the last response — do NOT ask

Use the very last assistant response — the one immediately before this command. Do NOT use AskUserQuestion, do NOT offer a pick list, and do NOT confirm. (The user who wants to choose among several recent responses uses `/speak:specify` instead.) If there is no prior assistant response in the conversation, say so briefly and stop — do not speak anything.

## 2. Hand the text to the CLI — robust stdin handoff

Recover the response's body **as faithfully as possible** — best-effort verbatim, including its markdown, code fences, backticks, and URLs. Do NOT pre-clean, summarize, reformat, or shorten it: the CLI does its own cleaning (strips code blocks, markdown, URLs) before speaking.

Raw assistant markdown can contain backticks, code fences, quotes, and any delimiter, so never paste the text inline into a shell command line. Use a temp file:

1. Write the exact text to a temp file (use the Write tool with a path like `/tmp/speak-last-<random>.txt`, or `mktemp`).
2. Feed it to the CLI as stdin with the Bash tool:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/bin/speak" < /tmp/speak-last-<random>.txt
   ```

3. Remove the temp file afterwards (`rm -f`).

If you must inline instead of using a temp file, the only acceptable form is a QUOTED heredoc with a generated unlikely delimiter (so no line of the text can terminate it early), e.g. `<<'SPEAK_EOF_x7k9q2'` ... `SPEAK_EOF_x7k9q2`. Never use an unquoted or common delimiter like `EOF`.

Never invent or use a `--last`-style flag: the terminal command surface is fixed and has no such command — the text always travels via stdin as above.

## 3. Report the outcome

- **Exit 0:** briefly confirm the last response is being spoken.
- **Non-zero with an unreachable-listener error** (stderr says "could not reach the host listener"): tell the user **immediately and clearly** — the user asked explicitly, so this message is never softened, suppressed, or debounced. Include the fix verbatim — recommended (one-time, on the Mac host): from the Plugins repo run `./plugins/speak/bin/speak agent install` (installs a LaunchAgent: starts the listener now, at every login, and restarts it if it dies); one-off alternative: `./plugins/speak/bin/speak --serve` in a Mac terminal.
- **Any other failure** (missing dependency, invalid `SPEAK_PORT`/`SPEAK_MODE`, unsupported host): relay the CLI's stderr message to the user as-is, and suggest `/speak:status` for the full diagnostic.

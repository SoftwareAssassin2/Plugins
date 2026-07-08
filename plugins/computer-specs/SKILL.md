---
name: computer-specs
description: Profile the hardware of the machine you're running on — RAM, CPU(s), GPU(s), and free disk space — then describe it in plain natural language. Use whenever the user asks about their computer's specs or hardware — e.g. "what are my specs", "what's my hardware", "how much RAM / how many cores / what GPU do I have", "system profile", "spec out this machine", or "can my computer handle <workload>".
---

# computer-specs

Report the running machine's hardware, in natural language.

## How

1. **Run the bundled profiler:** `bash "${CLAUDE_PLUGIN_ROOT:-plugins/computer-specs}/specs.sh"`. It is cross-platform (macOS + Linux), read-only, and degrades gracefully — a field it can't determine comes back as `unknown` rather than failing. It prints a labeled block:
   ```
   OS:    <os / kernel / arch>
   CPU:   <model — cores/threads>
   RAM:   <total>
   GPU:   <chipset(s)>
   Disk:  root volume / — <total> total, <free> free
   ```
2. **Translate that block into a natural-language profile** — don't just echo it back. Open with a one-line headline (e.g. *"You're on a well-specced Apple Silicon Mac…"*), then describe the RAM, CPU(s), GPU(s), and free disk in prose. If the user asked in the context of a workload ("can it handle X?"), answer that using the numbers.
3. If a field is `unknown` (a tool wasn't available on this OS), **say so plainly** — never guess or invent a value.

## Notes

- **Read-only.** The script only queries hardware; it changes nothing.
- Keep it conversational and brief — a profile, not a data dump.
- Covers macOS and Linux; on any other OS it reports that plainly.

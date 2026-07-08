---
name: speak
description: Speak Claude's responses aloud through the native OS voice (macOS `say`) — on demand via /speak:speak (last response) or /speak:specify (pick one), or automatically on every response via a toggleable Stop hook. Works locally on a Mac and, through a manually started host listener, from inside a Dev Container. Use when the user wants responses read aloud / spoken / voice output, wants auto-speak turned on or off, or asks whether the speak install is healthy.
argument-hint: "[optional: text to speak]"
---

# speak — spoken voice output for Claude responses

Give Claude a voice: responses are cleaned of markdown/code/URLs and spoken
through the Mac's system voice (`say`). One `speak` CLI is the primitive
everything calls — the slash commands, the Stop hook, and the user in a
terminal. Full setup, dependency, and troubleshooting detail lives in
[README.md](README.md).

## Commands

The command surface is exactly six slash commands (namespaced by the plugin
name — these are `/speak:*`, not `/speak-*`):

| Command | What it does |
|---|---|
| `/speak:speak` | Speak the very last assistant response immediately — never asks. Also answers to unprefixed `/speak` while no other installed command claims the name. Works regardless of the auto-speak toggle. |
| `/speak:specify` | Speak a chosen recent assistant response. Always asks WHICH response first (pick list, most-recent first) — several responses can accumulate between prompts. Works regardless of the auto-speak toggle. |
| `/speak:on` | Turn auto-speak ON — the Stop hook speaks every assistant response until `/speak:off`. Defaults to OFF; opt-in. |
| `/speak:off` | Turn auto-speak OFF. |
| `/speak:status` | Full diagnostic (`speak doctor`): toggle state, detected mode, port, listener reachability, per-dependency presence with required-vs-optional labels. |
| `/speak:test` | Run the bundled test suite (`tests/coverage.sh --plain`) and report pass/fail. |

Terminal forms of the same CLI: `speak <text>` (or `echo text \| speak`),
`speak --serve`, `speak doctor [--hook|--listener]` (`speak status` is an
alias), and `speak on` / `speak off`. An exact reserved first arg
(`--serve`/`doctor`/`status`/`on`/`off`) dispatches to that subcommand; to
speak a literal reserved word use stdin or `speak -- doctor`.

## Two modes, one transport

Context detection is separate from dependency availability:

- **Local (macOS host):** Darwin → play directly via `say`. A missing/broken
  `say` is reported as a missing local dependency — never a silent switch to
  forwarding.
- **Forward (Dev Container):** Linux plus a container marker (`/.dockerenv` /
  `/run/.containerenv`), or explicit `SPEAK_MODE=forward` → the response is
  base64-encoded and sent over TCP (`nc`) to a listener on the Mac at
  `host.docker.internal:${SPEAK_PORT:-8765}`. This container→host path is the
  shipped, verified transport — no fallback needed.
- Anything else (bare non-container Linux, unknown OS) → a clear "unsupported
  host OS" diagnostic, never a guessed forward attempt.

## The host listener (manual, never auto-started)

Forward mode needs `speak --serve` running on the Mac. The plugin NEVER starts
it for you: open a terminal **on the host** at the workspace root and run
`./plugins/speak/bin/speak --serve`. It binds `127.0.0.1:${SPEAK_PORT:-8765}`,
queues incoming utterances, and plays them through `say`. Ctrl-C stops it.

## Auto-speak toggle + debounced notice

The toggle is a single global flag file managed atomically by
`/speak:on` / `/speak:off` and read by the Stop hook; absent/unreadable reads
as OFF. When auto-speak is ON and something is wrong (listener unreachable,
missing dependency, invalid config), the hook emits at most ONE non-blocking
notice per session per reason — reason-specific, naming the exact fix (the
listener-unreachable notice contains the `./plugins/speak/bin/speak --serve`
command). It never blocks or fails the response.

## OS support

macOS is the only implemented TTS backend today. The playback path is isolated
behind a single OS seam (`play_local`), so Windows support can be added later
without rearchitecting — non-Darwin forced-local reports "unsupported local
TTS backend" rather than guessing. Remote dev containers / Codespaces are out
of scope: audio only works when the container runs on the same machine as the
speakers.

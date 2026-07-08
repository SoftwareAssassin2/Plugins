# speak — spoken voice output for Claude responses

The speak plugin gives Claude a voice: assistant responses are cleaned of
markdown, code blocks, and URLs, then spoken through the Mac's native system
voice (`say`). It works in the two supported scenarios: Claude Code running
**locally on a Mac** (direct playback) and Claude Code running **inside a Dev
Container** (the text is forwarded over TCP to a listener you run on the Mac).
Speech is on-demand via `/speak:speak` (last response, immediately — also reachable as plain `/speak` while no other command claims that name) or `/speak:specify` (pick which response), or automatic for every response via a
Stop hook governed by an opt-in toggle (`/speak:on` / `/speak:off`, default
OFF).

## Host listener setup (required for Dev Container use only)

The listener is started **manually by you — the plugin never auto-starts it**.
From the **workspace root, in a terminal ON THE HOST (a Mac terminal, not a
container terminal)**, run:

```bash
./plugins/speak/bin/speak --serve
```

It binds `127.0.0.1:${SPEAK_PORT:-8765}` and plays each forwarded response
through `say`. Leave it running while you want voice; Ctrl-C stops it. This is
exactly the command the hook's "listener unreachable" notice tells you to run.

Inside the container, the forward client connects to
`host.docker.internal:${SPEAK_PORT:-8765}` — Docker Desktop routes that name to
the host, where the loopback-bound listener answers. This container→host path
is the shipped, verified transport (proven green end-to-end); no extra
devcontainer network config is needed.

**macOS firewall caveat:** the first time the listener binds, macOS may show an
"allow incoming network connections" prompt for the binding process — allow it.
The loopback-only bind minimizes (and usually avoids) the prompt, but if speech
from the container silently never arrives, check System Settings → Network →
Firewall.

## Commands

Five slash commands (namespaced by the plugin name — `/speak:*`):

| Command | What it does |
|---|---|
| `/speak:speak` | Speak the very last assistant response immediately — no selection prompt. Unprefixed `/speak` resolves here when unambiguous. Works regardless of the toggle. |
| `/speak:specify` | Speak a chosen recent assistant response — asks which one first (pick list, most-recent first). Works regardless of the toggle. |
| `/speak:on` | Auto-speak ON: the Stop hook speaks every response. |
| `/speak:off` | Auto-speak OFF (the default). |
| `/speak:status` | Full diagnostic (`speak doctor`). |
| `/speak:test` | Run the bundled test suite. |

The same CLI works in a terminal: `speak <text>` (or `echo text | speak`),
`speak --serve`, `speak doctor [--hook|--listener]` (`speak status` is an
alias), `speak on` / `speak off`. A reserved first word is a subcommand; to
*speak* a literal reserved word use stdin or `speak -- doctor`.

## Dependencies (per context — not "everything everywhere")

Each context needs only its own tools; a missing tool degrades gracefully with
a notice naming what to install (never a hard crash):

| Context | Required tools | Notes |
|---|---|---|
| Local CLI (Mac, direct playback) | `say` | `base64` is wire-transport only — NOT needed for local playback |
| Forward client (Dev Container) | `base64`, usable `nc` | `nc` needs real capability: connect-timeout (`-G`/`-w`), EOF-shutdown (`-N`/`-q 0`), zero-I/O probe (`-z`) |
| Listener (Mac, `speak --serve`) | `say`, `base64`, `nc` | listen (`-l`) capability is never pre-probed — proven by `--serve` actually binding |
| Stop hook (auto-speak) | `jq` + the speak CLI | `jq` is hook-only, but that means it's needed on the **host** too — the hook parses transcript JSON wherever Claude runs |

**Installing what's missing:**

- `say` ships with macOS.
- `jq`: `brew install jq` (macOS) / `apt-get install jq` (Debian/Ubuntu).
- `nc`: install **`netcat-openbsd`** (`apt-get install netcat-openbsd`) — the
  preferred, capability-compatible netcat. Generic `netcat` packages may lack
  the connect-timeout/EOF-shutdown/`-z` behavior the transport needs; `doctor`
  reports an incapable `nc` as unusable, not merely present.

**Dev Container provisioning (not auto-installed):** a project that uses speak
from a Dev Container must add `netcat-openbsd` (and `jq`) to its
`.devcontainer/setup.sh`, per the repo's dev-container standard
(`docs/dev-container.md` in scaffolded projects). The plugin does **not**
auto-provision these — this plugins repo has no `.devcontainer` of its own.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `SPEAK_PORT` | `8765` | Listener/forward port. Validated as an integer 1..65535 by the client, the listener, and `doctor`; an invalid value fails clearly (and yields a debounced `invalid-port` hook notice). |
| `SPEAK_MAX_CHARS` | unset | Optional cap on spoken text length. Unset/empty = no cap; an invalid value is treated as unset with a stderr diagnostic. |
| `SPEAK_SESSION` | hostname | Optional session id for the terminal path's wire frames. |
| `SPEAK_DATA_DIR` | see note | Controls BOTH the listener's runtime-state dir (pid/log/spool; default `~/.local/state/speak`) AND the authoritative toggle/debounce dir. Inside Claude Code the toggle dir comes from `CLAUDE_PLUGIN_DATA`; for terminal `speak on`/`speak off` **outside** Claude you must set `SPEAK_DATA_DIR` (or `CLAUDE_PLUGIN_DATA`) — with neither set the toggle is reported "unavailable" rather than silently writing a dir the hook never reads. |

No voice/rate knobs — the system default voice is used.

## Diagnostics

`speak doctor` (aliased by `speak status`, surfaced as `/speak:status`) reports
toggle state, detected mode, port, listener reachability, and each dependency
labelled required-for-the-detected-mode vs optional. It exits non-zero only
when something **required for the current mode** is broken — in local mode the
listener is "not needed" and never fails the check, and `jq` is reported as
"required for the Stop hook" without failing local/forward mode.

- `speak doctor --hook` — Stop-hook readiness-if-enabled: `jq` plus the
  detected-mode playback path. It fails when auto-speak *would* fail if turned
  on; the current toggle state (including OFF) is shown separately and never
  gates the result.
- `speak doctor --listener` — host-only, **four-way** classification of the
  listener:
  1. reachable ∧ our identity → healthy (exit 0);
  2. reachable but NOT recognized as our listener (after stale cleanup) →
     "port reachable but not recognized as this listener" (non-zero — port in
     use by another process?);
  3. unreachable with no valid pidfile/lock → "unrelated process / nothing on
     port" (non-zero);
  4. a live listener from this state dir recorded on a DIFFERENT port →
     "listener running on :recorded, not :checked" (non-zero, markers
     preserved).

  In a container/forward context it degrades to TCP-reachability only —
  container-side files can't describe the host listener (unless you
  deliberately share `SPEAK_DATA_DIR` via a mount).

Listen (`-l`) capability is never pre-probed anywhere — only a real
`speak --serve` bind proves it; `doctor` says so explicitly.

## How forwarding works (wire format)

One newline-terminated line per utterance:
`<session-id>\t<base64(cleaned text)>` — exactly one tab, interior base64
newlines collapsed, encoded frame capped at 64 KiB. The listener validates
each frame, queues it (spool cap 50, drop-oldest), and plays sequentially. The
hook's reachability probe is advisory only; the send itself uses bounded
retry/backoff, so a momentary listener respawn gap doesn't drop speech.

## Boundaries

- **Remote is out of scope.** Remote dev containers / Codespaces / remote-SSH
  point `host.docker.internal` at a machine that isn't your Mac — audio only
  works when the container runs on the same machine as the speakers.
- **macOS today, Windows later.** Playback is isolated behind a single OS seam
  (`play_local`), so a Windows TTS backend can be added later without
  rearchitecting. On a non-Darwin host, forced-local mode reports "unsupported
  local TTS backend"; a bare non-container host reports "unsupported host OS".

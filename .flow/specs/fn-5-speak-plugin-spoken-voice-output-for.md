## Conversation Evidence

```
> user (turn 1): "I'd like to create a plugin that gives you a voice and let's you speak your responses to me. I'd like it to work for both of the following scenarios: 1. Running locally on the host machine 2. Running from within a Dev Container. I'd like it to be OS agnostic, but at the very least it has to work on a Mac."
> user (AskUserQuestion, TTS engine): "Native OS voices"
> user (AskUserQuestion, spoken content): "Cleaned full response"
> user (AskUserQuestion, trigger): "Auto every response + toggle"
> user (commands): "/speak ^^ tells AI to speak it's last response  /speak-on ^^ turns the auto-speak on so AI automatically speaks every response  /speak-off ^^ turns the auto-speak off"
> user (hook): "I'd like the hook message to provide instructions as to how to install/setup the listener."
> user (listener): "let's go with the manual execution of speak --serve in a Mac terminal when you want voice, plus the detect-and-instruct hook from #1"
> user (debounce): "I also like the debounced concept you noted."
> user (Windows): "Let's make this compatible with Mac right now, but let's build it in a way that we can add support for Windows later."
> user (remote limitation): "Great. This limitation is acceptible."
> user (default-off): "A: perfect." (confirming auto-speak defaults to OFF, opt-in via /speak-on)
> user (plugin root): "Let's change the root path of the plugin from ./src/speak to ./plugins/speak."
> user (host path): "Let's not worry about full physical path. It's not worth the added complexity. The relative path from workspace root is totally acceptible."
```

## Goal & Context
<!-- Source-tag breakdown: ~80% [user] / ~20% [paraphrase] -->

Give Claude Code a voice: a plugin that speaks the assistant's responses aloud to the user. [user] It must work in two scenarios — Claude running locally on the host machine, and Claude running inside a Dev Container. [user] The aspiration is OS-agnostic, but macOS is the hard requirement for the first build. [user] The target user is the author running Claude Code locally on a Mac. [paraphrase]

## Architecture & Data Models
<!-- Source-tag breakdown: ~35% [user] / ~45% [paraphrase] / ~20% [inferred] -->

**One CLI, two transports.** A single `speak` CLI is the primitive everything calls — the Stop hook, the slash commands, and the user in a terminal. [paraphrase] It auto-detects its mode: on macOS with `say` available it plays audio locally; otherwise (a Linux dev container) it forwards the text to a host listener. [user] This matches the two supported scenarios exactly — host = Mac, container = Linux. [paraphrase]

**Forwarding protocol.** The container-side CLI base64-encodes the cleaned text and sends it as a single line over a raw TCP connection via `nc`; the message also carries a session identifier. [paraphrase] The host listener (`speak --serve`) decodes each line and pipes it to `say`. base64 + one-line framing avoids HTTP parsing in bash 3.2 and is newline-safe. [inferred]

**Listener.** `speak --serve` binds `127.0.0.1:8765` (override `SPEAK_PORT`), accepts connections in a respawn loop, and **queues** utterances FIFO so concurrent arrivals never overlap. [user/paraphrase] It shows a live status line: current state, count of active sessions being read, and running success/failure totals. [user] A malformed/undecodable payload is logged and skipped; the listener keeps serving. [user]

**State on disk.** Auto-speak on/off is a single **global** flag in the plugin data dir (`${CLAUDE_PLUGIN_DATA}`), written by `/speak-on`/`/speak-off` and read by the Stop hook. [user] The once-per-session "listener unreachable" notice is gated by a marker file keyed by the hook's `session_id`. [user] The Stop hook reads the assistant's last message from the transcript JSONL it is handed on stdin; `/speak` instead receives the last response piped in by Claude. [user/paraphrase]

**OS seam.** TTS playback is isolated behind a single backend function (`say` today) so Windows/Linux backends can be added later without touching the transport, hook, or command layers. [user]

## API Contracts
<!-- Source-tag breakdown: ~70% [user] / ~30% [inferred] -->

**Slash commands (exactly five):** [user]
- `/speak` — speak the most recent assistant response on demand (regardless of the toggle; Claude pipes the text to the CLI).
- `/speak-on` — enable auto-speak (writes the global flag).
- `/speak-off` — disable auto-speak.
- `/speak-status` — full diagnostic: toggle state, detected mode (local/forward), port, listener reachability, dependency presence.
- `/speak-test` — run the bundled test suite and report pass/fail.

**Terminal CLI:** [user/paraphrase]
- `speak "<text>"` (or stdin) — the primitive: clean → play locally or forward.
- `speak --serve` — host listener (started manually).
- `speak doctor` — same diagnostic as `/speak-status`.

**Wire protocol:** one line per utterance = base64(cleaned-text) plus a session id, over TCP to `127.0.0.1:${SPEAK_PORT:-8765}`. [paraphrase]

**Environment:** `SPEAK_PORT` (default 8765, honored by client + listener), `SPEAK_MAX_CHARS` (unset = no cap). [paraphrase] No voice/rate env knobs — system default voice only. [user]

**Exit codes:** simple `0` = success, non-zero = failure. [user] **Hook notice channel:** the Stop hook emits its user-facing message via the hook `systemMessage` JSON field (non-blocking, exit 0). [paraphrase]

## Edge Cases & Constraints
<!-- Source-tag breakdown: ~30% [user] / ~70% [inferred] -->

- **bash 3.2 floor.** macOS ships bash 3.2.57; the CLI must run on that lower bar (no associative arrays, no `${var,,}`) so one script works host-side and container-side. [inferred]
- **No `/dev/tcp`.** Apple's bash has `/dev/tcp` disabled, so transport and reachability checks go through `nc`. No `timeout`/`gtimeout` on the host, so reachability uses `nc`'s own connect-timeout flags. [inferred]
- **Missing container deps.** `nc`, `base64`, and `jq` are required container-side; if any is missing the plugin degrades gracefully and the notice names what to install (no hard crash). [user]
- **Listener down — auto vs explicit.** When the Stop hook can't reach the listener, the notice is non-blocking and debounced to once per session. An explicit `/speak` against an unreachable listener instead shows an immediate, clear message (bypasses the debounce). [user]
- **Double-start.** Running `speak --serve` when the port is already held exits cleanly with a friendly "already running on 8765" message rather than a raw `nc` error. [user]
- **Security.** Listener binds loopback only and treats incoming text as data (passed to `say` as argv/stdin, never interpolated into a shell) — no command injection. [inferred]
- **Length.** Full cleaned response is spoken by default; `SPEAK_MAX_CHARS` truncates with a brief notice when set. [user]
- **macOS firewall.** First bind may trigger a macOS "allow incoming connections" prompt (documented). [inferred]
- **Remote hosts.** `host.docker.internal` resolves to the Docker host; remote/Codespaces containers point at a machine that isn't the user's Mac — out of scope (see Boundaries). [paraphrase]

## Acceptance Criteria
<!-- scope: both -->

- **R1:** On a macOS host, the `speak` CLI speaks supplied text aloud via the OS TTS voice. [user]
- **R2:** Spoken output is the "cleaned" response — markdown, code blocks, and formatting are stripped before TTS. [user]
- **R3:** A `Stop` hook automatically speaks each assistant response when auto-speak is enabled. [user]
- **R4:** Auto-speak defaults to OFF; `/speak-on` enables and `/speak-off` disables it, persisted so the Stop hook reads the current state. [user]
- **R5:** `/speak` speaks the most recent assistant response on demand, regardless of the toggle. [user]
- **R6:** When Claude runs in a Dev Container, the CLI forwards spoken text to a host listener so audio plays on the host. [user]
- **R7:** The host listener is started manually by the user (`speak --serve`); the plugin never auto-starts it. [user]
- **R8:** When the hook cannot reach the listener from the container, it surfaces a non-blocking text notice containing the workspace-relative command to start it (e.g. `./plugins/speak/bin/speak --serve`). [user]
- **R9:** That unreachable-listener notice is debounced — shown at most once per session. [user]
- **R10:** On a host (no container), the CLI plays audio directly with no listener required. [paraphrase]
- **R11:** OS-specific TTS is isolated so macOS works now and Windows can be added later without rearchitecting. [user]
- **R12:** The plugin is registered in the marketplace at `./plugins/speak`. [user]
- **R13:** `/speak-status` reports whether auto-speak is on and whether the listener is reachable. [inferred]
- **R14:** The forwarding transport is base64-encoded text, one utterance per line, over a raw TCP connection via `nc`; each message carries a session identifier. [paraphrase]
- **R15:** The listener binds `127.0.0.1` on port 8765 by default, overridable via `SPEAK_PORT` (honored by both client and listener). [paraphrase]
- **R16:** The listener queues utterances and plays them FIFO; concurrent arrivals never overlap. [user]
- **R17:** `speak --serve` displays a live status line including current state, active-session count, and running success/failure totals. [user]
- **R18:** A malformed or undecodable payload is logged and skipped; the listener keeps serving. [user]
- **R19:** Cleaning drops fenced code blocks entirely, strips markdown syntax (headers/bullets/emphasis), drops URLs (keeping link text), and collapses whitespace. [paraphrase]
- **R20:** The full cleaned response is spoken by default; when `SPEAK_MAX_CHARS` is set, output is truncated with a brief notice. [user/paraphrase]
- **R21:** Auto-speak state is a single global flag in the plugin data dir, written by the toggle commands and read by the Stop hook. [user]
- **R22:** Mode is auto-detected — macOS with `say` plays locally; otherwise the CLI forwards to the listener. [user]
- **R23:** Required container tools (`nc`, `base64`, `jq`) are detected; if any is missing the plugin degrades gracefully and the notice names what to install. [user]
- **R24:** `/speak-status` (and `speak doctor`) report a full diagnostic: toggle state, detected mode, port, listener reachability, and dependency presence. [user]
- **R25:** An explicit `/speak` against an unreachable listener shows an immediate clear message, bypassing the once-per-session debounce. [user]
- **R26:** The plugin ships bash tests for pure-logic units (cleaning, base64 round-trip, last-message handling, mode detection) plus a coverage script; `/speak-test` runs them. [user]
- **R27:** Starting `speak --serve` when a listener already holds the port exits cleanly with a friendly "already running" message. [user]
- **R28:** The Stop hook surfaces its user-facing notice via the hook `systemMessage` JSON field (non-blocking, exit 0). [paraphrase]
- **R29:** The command surface is exactly `/speak`, `/speak-on`, `/speak-off`, `/speak-status`, `/speak-test`, plus terminal `speak <text>`, `speak --serve`, `speak doctor`. [user]
- **R30:** The `speak` CLI uses simple exit codes — 0 for success, non-zero for failure. [user]

## Boundaries
<!-- scope: business -->

- No auto-start / login-item / LaunchAgent for the listener in this iteration. [user]
- Non-macOS hosts are not implemented now (structure for Windows later, but don't build it). [user]
- Remote dev containers / Codespaces / remote-SSH are out of scope — audio only works when the container runs on the same machine as the speakers. [user]
- High-quality cloud TTS (ElevenLabs/OpenAI etc.) is not in scope; native OS voice only. [user]

## Decision Context
<!-- scope: both -->

- **TTS engine:** native OS voices (macOS `say`) chosen over a cloud API — free, offline, no keys. [user]
- **Trigger model:** auto-speak via Stop hook with an on/off toggle, defaulting to OFF (opt-in). [user]
- **Listener lifecycle:** manual `speak --serve` rather than auto-start, because a container cannot (and should not) launch a process on the host — that isolation boundary is deliberate. [paraphrase] The detect-and-instruct hook is the safety net. [user]
- **Host-path in the hook notice:** use the workspace-relative path, not a full physical path — "not worth the added complexity." [user]
- **Windows:** deferred but designed-for via isolated OS seams. [user]
- **Transport:** raw base64 line over `nc` chosen over hand-rolled HTTP — robust in bash 3.2, newline-safe, and we own both ends. [paraphrase]
- **Concurrency:** FIFO queue chosen over drop-if-busy or interrupt — nothing is lost and ordering matches the order responses were produced. [paraphrase]
- **Voice config:** system default voice only (no env knobs) — change it in System Settings if desired. [user]
- **Toggle scope:** global rather than per-project — voice is a personal "on right now" preference. [user]
- **`/speak` text source:** Claude pipes its last message rather than the CLI re-locating the transcript — simpler for the on-demand path. [user]
- **Exit codes:** simple 0/1 rather than the repo's 64/127 contract — the user's explicit call for this CLI. [user]

## Resolved via Codebase

- macOS system bash is **3.2.57** (probed) → CLI must be bash-3.2-compatible.
- `bash /dev/tcp` is **disabled** in Apple's bash (probed, connect failed) → transport + reachability use `nc`.
- Host has `nc` (BSD), `say`, `base64`; **no** `timeout`/`gtimeout` (probed) → reachability uses `nc` connect-timeout flags.
- Plugin layout (claude-code-guide): hooks at `hooks/hooks.json` (auto-discovered, not referenced in plugin.json); slash commands at `commands/*.md`; executables at `bin/`. `bin/` is on PATH only **inside** Claude's Bash tool, **not** the host shell → host must invoke `speak --serve` by path (hence the workspace-relative notice).
- Stop hook receives JSON on stdin including `transcript_path`; a non-blocking user notice is shown via the `systemMessage` JSON field with exit 0 (claude-code-guide).
- Existing plugins register in `.claude-plugin/marketplace.json` with `"source": "./plugins/<name>"`; each has `.claude-plugin/plugin.json` (name/displayName/version/description/author) — follow the `init-project` shape.
- Repo test convention: `tests/*_test.sh` + a `coverage.sh` (per `init-project`) — `/speak-test` runs this suite.

## Open Questions

- Exact transcript-JSONL schema for extracting the last assistant message in the Stop hook (transcript_path is provided; confirm field shape at build).
- Confirm `host.docker.internal` reachability needs no extra devcontainer config on the target Docker Desktop setup (assumed; verify).
- macOS firewall first-bind prompt UX — document, and confirm loopback bind minimizes it.

## Requirement coverage

| R-ID | Task |
|------|------|
| R1–R30 | fn-5.M (TBD — populate via `/flow-next:plan`) |

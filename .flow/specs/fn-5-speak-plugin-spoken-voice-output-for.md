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
<!-- Source-tag breakdown: ~50% [user] / ~30% [paraphrase] / ~20% [inferred] -->

A single `speak` CLI is the primitive everything calls. [paraphrase] On a host it plays audio through the OS text-to-speech voice; inside a container it forwards the spoken text to a listener running on the host (reached via the container-to-host gateway) so audio plays on the host's speakers. [user/paraphrase] A `Stop` hook (runs when Claude finishes a response) drives automatic speech; slash commands drive on-demand speech and the on/off toggle. [paraphrase] OS-specific behavior (the TTS backend) is isolated so macOS works now and other platforms can be added later. [user] A default listener port is assumed for the container-to-host transport. [inferred]

## API Contracts
<!-- Source-tag breakdown: ~75% [user] / ~25% [inferred] -->

Slash commands: [user]
- `/speak` — speak the most recent assistant response on demand.
- `/speak-on` — enable auto-speak.
- `/speak-off` — disable auto-speak.
- `/speak-status` — report auto-speak state + listener reachability. [inferred]

CLI (terminal): `speak "<text>"` (primitive), `speak --serve` (host listener, started manually). [user/paraphrase]

## Edge Cases & Constraints
<!-- Source-tag breakdown: ~40% [user] / ~60% [inferred] -->

- The host listener must be started manually; if it isn't running, container speech is a no-op plus a one-time notice. [user]
- The unreachable notice must be non-blocking — it never delays or fails a response. [inferred]
- macOS ships an old system bash; the CLI must run on that lower bar so one script works host-side and container-side. [inferred]
- The listener should bind locally and treat incoming text as data (no shell injection). [inferred]

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

## Requirement coverage

| R-ID | Task |
|------|------|
| R1–R13 | fn-5.M (TBD — populate via `/flow-next:plan`) |

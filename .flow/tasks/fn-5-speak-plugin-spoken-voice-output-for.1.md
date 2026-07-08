---
satisfies: [R1, R2, R10, R11, R12, R19, R20, R22, R29, R30]
---

## Description

Stand up the plugin skeleton and the `speak` CLI foundation: a subcommand dispatcher, the text-cleaning function, macOS local playback via `say`, host/forward mode detection, and the plugin manifest + marketplace registration. This is the foundation every later task builds on.

**Size:** M
**Files:** `plugins/speak/bin/speak`, `plugins/speak/.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`

> Note: local `say` playback needs **only `say`** — `base64` is wire-transport (forward/listener) only, not a local-mode dependency.

## Approach

- Mirror the dispatcher + house style from `plugins/init-project/templates/system.sh` (`set -euo pipefail`, `BASH_SOURCE` dir resolution) and the `die()`/`usage()` helpers at `plugins/init-project/scaffold.sh:33-37`. Use the source-guard idiom `plugins/init-project/scaffold.sh:193-195` so tests can source functions without running `main`. Enable `set -euo pipefail` **only when executed** (inside the source-guard), NOT at top level — so sourcing `bin/speak` (by `.6`'s tests and `.4`'s hook) never leaks strict mode and breaks the hook's always-exit-0 contract.
- **Exit codes are simple 0/1** per the spec decision — NOT the repo's 64/127 contract.
- **Dispatch precedence:** an exact reserved first arg (`--serve`/`doctor`/`status`/`on`/`off`) routes to that subcommand — in this task those reserved words route to **stub/"not yet implemented" handlers** (final behavior owned by `.3`/`.4`/`.5`); the point here is that reserved words are NOT spoken. An exact reserved first arg is that subcommand; to speak a literal reserved word use stdin (`echo doctor | speak`) or `speak -- doctor`. Otherwise input is `speak "<text>"` (argv) **or** stdin (`echo … | speak`); when both non-reserved argv and stdin are present, **argv wins**. Cleaning is a pure stdin→stdout function (unit-testable): drop fenced ``` ``` ``` blocks entirely, strip markdown (headers `#`, list bullets, `*`/`_` emphasis), drop URLs but keep link text, collapse whitespace.
- `SPEAK_MAX_CHARS`: unset = no cap; a positive integer truncates with a brief notice **to stderr/log only — never into the text sent to `say` or any hook stdout**; an invalid value (zero/negative/non-numeric) is treated as unset (no cap) with a diagnostic to stderr.
- **Context detection** implements **C1** exactly (epic §Canonical Contracts — authoritative; do not restate-and-drift). The forward branch itself is implemented in `.2`; this task owns the detection + the local branch. Isolate playback behind ONE backend function (`say` today) for the Windows-later seam.
- Local playback passes text to `say` via **stdin** (`printf '%s' "$text" | say`) — never interpolate into a shell string (injection + arg-joining).
- `plugin.json`: five-field shape per `plugins/init-project/.claude-plugin/plugin.json:1-7` (name `speak`, displayName, version `0.1.0`, description, author `Chris Green (Software Assassin)`). Append a marketplace entry with `"source": "./plugins/speak"` per `.claude-plugin/marketplace.json:27-32`.

## Investigation targets
**Required:**
- `plugins/init-project/templates/system.sh:1-43` — dispatcher pattern
- `plugins/init-project/scaffold.sh:33-37,193-195` — die()/usage() + source-guard
- `plugins/init-project/.claude-plugin/plugin.json:1-7` — manifest shape
- `.claude-plugin/marketplace.json:27-32` — local entry shape

## Acceptance
- [ ] Reserved first arg (`--serve`/`doctor`/`status`/`on`/`off`) dispatches as subcommand; literal reserved word spoken via stdin or `speak -- <word>`; otherwise both `speak "<markdown>"` (argv) and `echo … | speak` (stdin) speak the cleaned text via `say`, argv winning when both present (R1, R2, R29)
- [ ] Mode detection matches C1 exactly — spot-checks: `SPEAK_MODE=local` on non-Darwin → "unsupported local TTS backend"; Darwin with broken `say` + no `SPEAK_MODE` stays local (missing dep); bare non-Darwin → "unsupported host OS", no silent forward (R22)
- [ ] Cleaning drops fenced code blocks, strips headers/bullets/emphasis, keeps link text + drops URLs, collapses whitespace (R19)
- [ ] `SPEAK_MAX_CHARS` (positive int) truncates with a notice; unset or invalid (zero/negative/non-numeric) → no cap + stderr diagnostic (R20)
- [ ] Playback is a single isolated backend function (`say` today — the Windows-later seam) (R10, R11)
- [ ] CLI returns 0 on success, non-zero on failure (R30)
- [ ] `plugins/speak/.claude-plugin/plugin.json` present (five-field); `speak` registered in `.claude-plugin/marketplace.json` as `./plugins/speak` (R12)
- [ ] Text reaches `say` via stdin, never shell-interpolated
- [ ] `bin/speak` enables `set -euo pipefail` only when executed (source-guard) — sourcing it does not leak strict mode
- [ ] `SPEAK_MAX_CHARS` truncation notice goes to stderr/log only, never into the `say` text
- [ ] `plugins/speak/bin/speak` is committed executable (`test -x`)

## Done summary
Stood up the speak plugin skeleton: plugins/speak/bin/speak (bash-3.2, source-guarded strict mode) with reserved-word dispatcher + stubs, pure stdin->stdout markdown cleaning, C1 mode detection with distinct probe return codes, the isolated play_local macOS `say` backend (stdin-fed, injection-safe), and SPEAK_MAX_CHARS truncation with stderr-only notices. Added the five-field plugin manifest and registered speak in .claude-plugin/marketplace.json at ./plugins/speak; Codex review verdict SHIP on first pass.
## Evidence
- Commits: 839501e004163426d978c4624f756e6b58aca640
- Tests: /bin/bash scratchpad/smoke.sh (40-check bash-3.2 smoke suite: dispatcher, cleaning, C1 mode detection, SPEAK_MAX_CHARS, stdin-to-say injection safety, source-guard) — 40 passed, 0 failed, /bin/bash -n plugins/speak/bin/speak (bash 3.2.57 syntax check), jq -e . on plugin.json and marketplace.json
- PRs:
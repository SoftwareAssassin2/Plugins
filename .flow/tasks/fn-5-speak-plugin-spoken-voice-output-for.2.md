---
satisfies: [R6, R14, R22]
---

## Description

Add the container-side forwarding path to `speak`: base64-encode the cleaned text, stamp a session id, send it as one line over `nc` to the host listener, and provide a fast reachability probe callers can branch on.

**Size:** M
**Files:** `plugins/speak/bin/speak`

## Approach

- base64-encode the cleaned text and **strip all newlines** (e.g. `base64 | tr -d '\r\n'`) so each utterance is exactly one newline-terminated line — GNU `base64` (container side) wraps at 76 cols by default, so a "single line" cannot be assumed. The listener (`.3`) decodes it.
- Payload carries a session id: `${SPEAK_SESSION:-$(hostname)}` (the Stop hook passes its `session_id` via `SPEAK_SESSION`). **Sanitize the session id to `[A-Za-z0-9._-]` (capped length) before framing/logging** — `SPEAK_SESSION` is user-controlled; if sanitization yields an empty string (e.g. `'///'`), fall back to a safe non-empty value (`unknown`/short hash) so the frame never has an empty id. The frame is **exactly `<sanitized-session-id>\t<base64-cleaned-text>\n`** (tab-separated, single newline-terminated line) — this is the fixed interop contract with `.3`. **Sender-side encoded-length check:** before sending, ensure `len(session)+1(tab)+len(base64(text))+1(newline) ≤ 65536` (`SPEAK_MAX_FRAME_BYTES`); when over, truncate the cleaned text **by bytes on a UTF-8 char boundary** (never mid-multibyte) until it fits — via a documented helper (`.6` proves it with multibyte text near the cap; exact bash-3.2 mechanism is an implementation detail for `/flow-next:work`) — with a stderr/log notice (same "notice not spoken" rule as `SPEAK_MAX_CHARS`) — an explicit R20 exception for forward mode, not a silent listener drop.
- Send to `host.docker.internal:${SPEAK_PORT:-8765}` via `nc`. **Own the shared `nc` capability helper here (`.2` runs first):** detect connect-timeout (`-G` else `-w`), EOF-shutdown (`-N` else `-q 0`), and `-z` probe support by **option/usage-error probing** with a **distinct unsupported-capability return code** that callers (and `.5` `doctor`) never conflate with a refused/unreachable connection; **no dependency on `nc -l`**. If neither EOF-shutdown flag exists, fail with clear "install netcat-openbsd" guidance (otherwise the sender hangs). Use the detected connect-timeout flag + **bounded retry/backoff** (a few attempts) to tolerate the listener's one-shot `nc -l` respawn gap; do NOT gate the send on a prior `-z` probe (probe-then-send races the respawn). On exhausting retries, fail fast + clear (never hang).
- Reachability probe: a **zero-byte `nc -z` connect** using the detected connect-timeout flag — `-G1` (BSD) else `-w1` (GNU/OpenBSD) — exposed as a sourceable `listener_reachable` helper returning a distinct status (the listener treats the zero-byte connect as a silent health check, never a malformed frame). The **single fast probe is for the hook's advisory notify decision only**; `doctor`/health (in `.5`) layer bounded retry/backoff on top so the respawn gap doesn't false-fail. In **forward/client** context the helper targets `host.docker.internal`; the host/listener context (`.5`) targets `127.0.0.1`. Validate `SPEAK_PORT` as an integer **1..65535** before connecting (fail clearly if invalid).
- This is the forward branch of the mode detection from `.1` (reached when `SPEAK_MODE=forward` or a container marker is detected; a bare non-Darwin host without `SPEAK_MODE` gets the "unsupported host OS" diagnostic, never a silent `host.docker.internal` attempt).

## Investigation targets
**Required:**
- `plugins/speak/bin/speak` — extend the `.1` mode-detect + cleaning
**Optional:**
- practice-scout notes on `nc -N` and BSD-vs-GNU flag asymmetry

## Acceptance
- [ ] Cleaned text is base64-encoded with newlines stripped to exactly one line (tested with payloads >76 chars) + a session id, sent over `nc` to `host.docker.internal:${SPEAK_PORT:-8765}` (R14)
- [ ] Shared `nc` capability helper (owned here) detects connect-timeout/EOF-shutdown/`-z` via usage-error probing with a distinct unsupported-capability return (never conflated with refused/unreachable), no `nc -l` dependency; send uses detected EOF-shutdown (`-N` else `-q 0`) so it doesn't hang; neither exists → clear "install netcat-openbsd"
- [ ] A reachability probe (zero-byte `nc -z`, detected `-G1`/`-w1`) reports reachable/unreachable quickly via a sourceable `listener_reachable` helper (R6)
- [ ] `SPEAK_PORT` is validated as an integer 1..65535; invalid → clear failure
- [ ] Session id = `SPEAK_SESSION` or hostname fallback, sanitized to `[A-Za-z0-9._-]` (capped); empty-after-sanitize → safe non-empty fallback (`unknown`/hash); helper targets `host.docker.internal` in client context
- [ ] Frame is exactly `<sanitized-session-id>\t<base64>\n` (tab-separated, one newline-terminated line) (R14)
- [ ] Sender checks total encoded-frame bytes (`session+tab+base64+newline ≤ 65536`) before sending; over-cap → truncate cleaned text by bytes on a UTF-8 boundary + stderr/log notice (not spoken), not a silent listener drop (R20 forward exception)
- [ ] Forward send uses bounded retry/backoff (tolerates the respawn gap); terminal forward `speak "<text>"` with the listener down fails fast + clearly, never hangs
- [ ] In forward mode the CLI does not attempt local `say` (R22)

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

---
satisfies: [R6, R14, R22]
---

## Description

Add the container-side forwarding path to `speak`: base64-encode the cleaned text, stamp a session id, send it as one line over `nc` to the host listener, and provide a fast reachability probe callers can branch on.

**Size:** M
**Files:** `plugins/speak/bin/speak`

## Approach

**Contracts (epic §Canonical Contracts is authoritative):** C2 (frame + cap + sender pre-check), C4 (probe vs send, targets), C6 (nc capability detection — owned HERE, everyone else reuses it), C8 (`sanitize_session_id`), C9 (port validation).

- Build the frame per **C2**: base64-encode the cleaned text stripping all newlines (e.g. `base64 | tr -d '\r\n'` — GNU base64 wraps at 76 cols), prepend the sanitized session id + tab, terminate with one newline. Session id = `${SPEAK_SESSION:-$(hostname)}` (the Stop hook passes its `session_id` via `SPEAK_SESSION`), sanitized per **C8**. Enforce C2's sender-side encoded-length pre-check with the UTF-8-boundary truncation + stderr/log notice via a documented helper (`.6` proves it with multibyte text near the cap; the exact bash-3.2 mechanism is an implementation detail for `/flow-next:work`) — an explicit R20 exception for forward mode, not a silent listener drop. The listener (`.3`) decodes it.
- Send to `host.docker.internal:${SPEAK_PORT:-8765}` via `nc`. **Own the shared `nc` capability helper here (`.2` runs first) per C6.** Use the detected connect-timeout flag + **bounded retry/backoff** (a few attempts) to tolerate the listener's one-shot `nc -l` respawn gap; per **C4**, never gate the send on a prior `-z` probe (probe-then-send races the respawn). On exhausting retries, fail fast + clear (never hang).
- Reachability probe per **C4**: a zero-byte `nc -z` connect (detected `-G1`/`-w1`) exposed as a sourceable `listener_reachable` helper returning a distinct status — advisory only (the hook's notify decision); `doctor`/health (`.5`) layer retry/backoff on top. Forward/client context targets `host.docker.internal`; host/listener context (`.5`) targets `127.0.0.1`. Validate `SPEAK_PORT` per **C9** before connecting.
- This is the forward branch of `.1`'s C1 mode detection (reached only via `SPEAK_MODE=forward` or a container marker — C1 forbids a silent `host.docker.internal` attempt on a bare non-Darwin host).

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
Added the container-side forward path to plugins/speak/bin/speak: C6 nc capability detection (usage-error probing for -G/-w, -N/-q 0, -z with distinct unsupported/missing/unreachable return codes), C9 port validation, C8 session-id sanitization, C2 frame building (sid\tb64\n, 65536-byte cap with UTF-8-boundary sender-side truncation), C4 advisory listener_reachable probe, and forward_send with bounded retry/backoff that never gates on a probe and never attempts local say in forward mode.
## Evidence
- Commits: bde254f05dd23208464d93919b27d46949c4f502
- Tests: shellcheck plugins/speak/bin/speak, bash -n plugins/speak/bin/speak, sourced-helper unit tests under /bin/bash 3.2: speak_port (10 cases incl. 0/65536/alpha/leading-zeros), sanitize_session_id (charset/cap-64/empty->unknown), speak_session_id (SPEAK_SESSION + hostname fallback), nc capability detection on Apple BSD nc (-G detected, -N correctly rejected as arg-taking, -q invalid -> EOF rc=5 distinct) and on shim GNU/OpenBSD flavor (-w/-N/-z detected), build_frame: >76-char payload one line/one tab/one newline + base64 round-trip; 65536 cap enforced for ASCII+multibyte with UTF-8-boundary truncation (emoji/euro cut at every byte offset stays valid UTF-8); exact-fit emits no notice, listener_reachable: real nc -l listener up rc=0 / down rc=1 / bad port rc=6, 19ms probe, forward_send E2E via shim nc: frame delivered + decoded, retry succeeds on 3rd attempt after 2 simulated respawn-gap failures, listener-down fails in ~1s rc=1 with --serve guidance, invalid SPEAK_PORT clear failure, nc/base64 missing rc=3, R22: shim say never invoked in forward mode; local-mode regression: say invoked, codex impl-review verdict SHIP (first pass, 0 findings)
- PRs:
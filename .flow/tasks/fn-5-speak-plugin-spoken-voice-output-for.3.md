---
satisfies: [R6, R7, R15, R16, R17, R18]
---

## Description

Implement the core of `speak --serve` — the host listener that accepts forwarded frames, validates + decodes them, and plays them via `say` through a bounded ordered spool queue with a live status line — and run the container→host **PROOF** that gates the rest of the epic. Pre-split from the original L-sized listener task: identity/lock/double-start is `.8`, watchdog + bounded capture is `.9`. Until `.9` lands the accept path is provisionally unhardened — acceptable inside the epic; the epic does not ship without `.8`/`.9`.

**Size:** M
**Files:** `plugins/speak/bin/speak`

## Approach

**Contracts (epic §Canonical Contracts is authoritative):** C2 (frame + rejects), C3 (`listener_state_dir` for all listener state), C4 (reachability targets), C5 (listen never pre-probed), C6 (nc detection — reuse `.2`'s helper), C9 (constants).

- Bind `127.0.0.1:${SPEAK_PORT:-8765}` (loopback only — security) via a small **`nc_listen_args` helper** that pins the macOS-first listen form (`nc -l 127.0.0.1 <port>` / BSD positional-port behavior) and documents the BSD/OpenBSD variance. Wrap it in a `while :; do ...; done` respawn loop (BSD `nc -l` serves one connection then exits).
- **Fast accept→enqueue, separate single playback worker.** The accept loop must NOT block on `say` (a naive `nc -l | say` blocks accepting during playback). Decode each base64 line (**detect the decode flag — BSD `-D` vs GNU `-d`**) and enqueue into the bounded spool — a temp dir of sequentially-named files (atomic enqueue, drop-oldest beyond the C9 cap, logged; NOT a named pipe, which can't drop-oldest and blocks writers). A single playback worker drains the spool to `say` via stdin in order, so utterances never overlap.
- Frame validation per C2: require exactly one tab; reject zero/>1 tab, empty session id, empty payload, undecodable base64 → log + skip, keep serving (R18). A zero-byte / EOF-only connection (the `nc -z` probe) is a **silent** health check — neither logged nor counted.
- **File-backed state.** bash background workers/subshells can't propagate variables to the parent, so playback success/failure totals and the active-session log are written to state files by the worker and read by the status line. Counters are **playback outcomes only** — malformed/dropped/probe events go to `<listener_state_dir>/listener.log`, never the totals. A `say` failure (no audio device / removed voice) increments failures and is logged; it never crashes the listener.
- **Status renderer.** A background renderer reads the file-backed state at an interval and repaints the live status line (current state idle/speaking, active-session count = distinct session ids within the C9 window, success/failure totals); cleaned up by the same INT/TERM trap.
- **Concurrency/locking.** Guard enqueue / prune / counter / session-log updates with an atomic `mkdir` lock dir (trap cleanup); spool entries use atomic `mktemp` names with a sortable key — no duplicate or reordered sequence numbers, and never prune a file mid-processing.
- **Preflight + port.** `speak --serve` validates `SPEAK_PORT` (C9) and preflights listener deps (`say`/`base64`/`nc`) before binding. The **real `SPEAK_PORT` bind is the ONLY authoritative listen check** (C5) — no `nc -l` pre-probe of any kind. (Friendly already-running / port-in-use classification arrives with `.8`.)
- **Sourceable helpers.** Frame validation, lock acquire/release, enqueue, sequence allocation, queue pruning, counter/session-log updates, and the session-window calculation live in sourceable helper functions so `.6` can unit-test them without spinning up the listener.
- `trap` INT/TERM → stop accepting and remove the spool temp dir.

## Investigation targets
**Required:**
- `plugins/speak/bin/speak` — the `.2` transport/encode side to interoperate with
**Optional:**
- practice-scout notes: `nc -l` one-shot behavior, `-k`/`-w` caveats, loopback reachability

## Acceptance
- [ ] `speak --serve` binds `127.0.0.1:8765` (`SPEAK_PORT` override) and serves repeatedly via a respawn loop; bind uses the `nc_listen_args` helper (BSD/OpenBSD variance documented) (R15)
- [ ] Forwarded lines are decoded (detected `-d`/`-D` flag) and spoken via non-blocking accept→enqueue + a single playback worker; concurrent arrivals queue in the bounded spool (drop-oldest at the C9 cap of 50, logged), never overlap; accepting never blocks on `say` (R6, R16)
- [ ] Live status shows state + active-session count (C9 window, 60s) + success/failure totals, **file-backed** so worker-side updates are reflected (R17)
- [ ] Frame validation per C2 — exactly one tab; zero/>1 tab, empty id, empty payload, undecodable base64 → logged + skipped, listener keeps serving; a zero-byte `nc -z` probe is silent (not logged, not counted) (R18)
- [ ] success/failure totals are playback-only; malformed/dropped/probe events go to `<listener_state_dir>/listener.log`, not the counters; a `say` failure increments failures without crashing the listener (R17, R18)
- [ ] Listener state (counters, log, spool) resolves via `listener_state_dir` per C3 (NOT `CLAUDE_PLUGIN_DATA`)
- [ ] Concurrent enqueue/prune/counter updates are mkdir-lock-guarded with mktemp sortable spool names — live spot-check of no dup/reorder here; repeatable unit coverage owned by `.6`
- [ ] All queue/counter/validation primitives are exposed as sourceable helpers for `.6`
- [ ] `speak --serve` validates `SPEAK_PORT` (C9) and preflights `say`/`base64`/`nc` before binding; the real bind is the only authoritative listen check — no `nc -l` pre-probe (C5)
- [ ] INT/TERM cleans up the spool temp dir (no named pipe is used)
- [ ] **PROOF (gates `.4`–`.9`):** a base64 line sent from a Linux container reaches the loopback listener via `host.docker.internal` and produces audio; the listener is never auto-started (R6, R7). On a red proof, STOP — record the chosen fallback (bind/flags/shared-mount), update epic §Canonical Contracts FIRST, then every affected task spec (bind/security, reachability target, hook notice, README command, doctor, tests) before `.4`–`.9` resume

## Done summary
Implemented the `speak --serve` listener core in plugins/speak/bin/speak: loopback-bound nc -l respawn loop (nc_listen_args), C2 frame validation + detected base64 decode flag (-d/-D), fast accept->enqueue into a bounded mkdir-lock-guarded file spool (drop-oldest at cap 50, logged) drained in order by a single playback worker through `say`, file-backed playback-only counters + active-session window + state driving a live status line, SPEAK_PORT + say/base64/nc preflight with no listen pre-probe (C5), and INT/TERM cleanup of the spool temp dir — all queue/counter/validation primitives exposed as sourceable helpers for .6. PROOF POINT GREEN: a base64 frame from the real .2 forward client inside an Alpine Linux container reached the 127.0.0.1:8765 listener via host.docker.internal and produced audio on the host; no fallback transport needed, Canonical Contracts unchanged, .4-.9 unblocked. Codex impl-review: SHIP (after fixing the lock-timeout mutation / foreign-lock-release finding).
## Evidence
- Commits: 73133b57ffcf2c76c99c74014e13be47b0d5e78f, f7f31bc0e93b23c53d9b055d2f04ce7d4bd0d67e
- Tests: shellcheck plugins/speak/bin/speak && bash -n plugins/speak/bin/speak (clean), bash-3.2 sourced-helper spot checks (47/47): validate_frame rc 0/10/11/12, -d/-D decode-flag detection + round-trip + garbage rejection, counters, session window (distinct sids, stale excluded + pruned), spool enqueue/claim order, drop-oldest at cap logged, 20 concurrent enqueues -> 20 distinct ordered seq names, process_frame_line (enqueue/reject/sanitized-sid/over-cap), lock-timeout: mutations skip + rc=1 + foreign lock never released + temp cleaned, status line shape, nc_listen_args, live listener smoke (27/27): bind 127.0.0.1:18765, nc -z probe silent+uncounted, 3 frames spoken via real say (ok=3, fail=0), 2 distinct active sessions, malformed/undecodable/empty-sid logged + skipped + never counted, listener keeps serving, file-backed status line shows idle/speaking + sessions + totals, TERM removes spool dir + frees port (no stale nc), broken-say shim: failure counted+logged, listener survives and keeps accepting, PROOF (gates .4-.9) GREEN 9/9 (re-run on final commit): manually-started listener bound loopback-only 127.0.0.1:8765 (lsof-verified); real .2 forward client in alpine Linux container (netcat-openbsd, SPEAK_MODE=forward) sent base64 frame via host.docker.internal:8765; exit 0; host decoded + played via say (success total 1, 0 failures); session 'proof-container' recorded; status line updated; clean teardown. No fallback transport needed - Canonical Contracts unchanged.
- PRs:
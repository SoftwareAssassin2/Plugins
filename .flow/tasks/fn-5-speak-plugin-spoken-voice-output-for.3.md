---
satisfies: [R6, R7, R15, R16, R17, R18, R27]
---

## Description

Implement `speak --serve` — the host listener that decodes forwarded lines and plays them via `say`, with a bounded ordered spool queue (temp-dir files, not a named pipe), a live status line, and resilience to bad input and port conflicts. **Early proof point:** exercised against the `.2` forward client, this validates that a base64 line from a Linux container reaches a loopback listener on the Mac via `host.docker.internal` and produces audio.

**Size:** L (listener core + bounded-capture watchdog + lock/pid identity + file-backed counters + concurrent queue + status renderer + stale cleanup + live proof). `/flow-next:work` MAY split into listener-core / identity+locking / proof-hardening sub-tasks to reduce implementation risk; the architecture is unchanged either way.
**Files:** `plugins/speak/bin/speak`

## Approach

- Bind `127.0.0.1:${SPEAK_PORT:-8765}` (loopback only — security) via a small **`nc_listen_args` helper** that pins the macOS-first listen form (`nc -l 127.0.0.1 <port>` / BSD positional-port behavior) and documents the BSD/OpenBSD variance, rather than scattering raw `nc -l` flags. Wrap it in a `while :; do ...; done` respawn loop (BSD `nc -l` serves one connection then exits).
- **Fast accept→enqueue, separate single playback worker.** The accept loop must NOT block on `say` (a naive `nc -l | say` blocks accepting new connections during playback). Decode each base64 line (**detect the decode flag — BSD `-D` vs GNU `-d`**) and enqueue it into a **bounded spool queue** — a temp dir of sequentially-named files (atomic enqueue, drop-oldest beyond a cap, logged); NOT a named pipe (can't drop-oldest, blocks writers). A single playback worker drains the spool to `say` via stdin in order, so utterances never overlap. The active-session count = distinct session ids seen within a recent rolling window.
- Live status line: current state (idle/speaking), active-session count, and running success/failure totals (a `say` failure increments failures).
- Parse each frame as `<session-id>\t<base64>` (the fixed `.2` contract): require **exactly one tab**; reject zero or >1 tab, an empty session id, an empty payload, or undecodable base64 → log + skip, keep serving (R18).
- **Per-connection read must not wedge the accept loop.** macOS has no `timeout` binary and nc listen-timeout flags vary, so use a concrete bash-3.2 watchdog: run each accept/read as a backgrounded child and, on a fixed deadline, **kill the concrete `nc` PID (or its process group)** — not just a wrapping subshell — and **reap the guard**, so no stale `nc` keeps holding the port. Rely on the `.2` sender's EOF-shutdown for the normal path; the watchdog covers stalled/newline-less clients.
- **Counters are playback-only.** success/failure totals count playback outcomes only; malformed/dropped frames and probes are logged (optionally a separate dropped counter), never added to the failure total.
- **Listener-side size guard.** **Bounded accept (bash-3.2 primitive):** the accept path is itself bounded — `nc -l …` piped through a cap+1-byte reader/helper (`head -c $((MAX+1))` / bounded `dd`) that stops at `SPEAK_MAX_FRAME_BYTES` (**internal-only** const, fixed **65536** = 64 KiB), with the concrete `nc` PID/process group killed + reaped once the cap is exceeded or no newline arrives. **NOT** `nc … > file` (which would grow disk unbounded during the watchdog window) — an oversized/newline-less stream is never fully buffered to memory OR disk (no `coproc`/`timeout` in bash 3.2; a small helper is acceptable if pure bash proves brittle); a line over the cap, or with no newline within the cap, is dropped + logged BEFORE decode/enqueue. The cap is on the **encoded frame line** (effective outer bound; decoded ≤ ~48 KiB after base64 expansion). Client-side `SPEAK_MAX_CHARS` does not protect the listener; this does — a hostile/buggy client can't cause memory pressure ahead of the count bound.
- **Data dir + identity/pidfile.** Resolve listener runtime state (pid/log/spool) via `${SPEAK_DATA_DIR:-$HOME/.local/state/speak}` — **deliberately NOT `CLAUDE_PLUGIN_DATA`**, so the terminal-started listener and Claude-context `doctor --listener` agree on the same dir (otherwise the real listener is misclassified "port in use"). The listener writes `<data-dir>/listener.pid` recording **pid + script path + port (+ start time when available)**; **Identity (NO reachability) = pid alive + live `ps` command contains `bin/speak` and `--serve` + the pidfile's recorded port == the checked port + the lifetime lock** (NO opaque token in `ps`; NOT an exact script-path match — `./plugins/speak/bin/speak` vs `${CLAUDE_PLUGIN_ROOT}/bin/speak` resolve differently). **Health = identity + reachable**; reachability is reported separately (with retry/backoff) and a momentary respawn-gap unreachable **must NOT** delete the pidfile or mark the listener stale. Stale = dead/mismatched pid, ps shape, port, or lock — those markers ARE removed. Pidfile schema: `pid=<n>\nport=<n>\ncmd=<argv0>\nstarted=<epoch-or-unknown>`. Malformed-frame and dropped (over-cap / queue-evicted) events are written to `<data-dir>/listener.log` (NOT folded into the status counters); the zero-byte `nc -z` probe is **silent** — neither logged nor counted.
- **Internal constants:** spool queue cap default **50** (drop-oldest beyond it, logged); active-session rolling window default **60s**.
- **File-backed state.** bash background workers/subshells can't propagate variables to the parent, so success/failure totals and the active-session log are written to **state files** by the playback worker and read by the status line (no in-memory counters in a backgrounded process).
- **Sourceable helpers.** Frame validation, lock acquire/release, enqueue, sequence allocation, queue pruning (drop-oldest), counter/session-log updates, and the session-window calculation all live in sourceable helper functions so `.6` can unit-test them (incl. parallel-enqueue concurrency) without spinning up the listener.
- **Concurrency/locking.** Guard enqueue / prune / counter / session-log updates with an atomic `mkdir` lock dir (trap cleanup); spool entries use atomic `mktemp` names with a sortable key — no duplicate or reordered sequence numbers, and never prune a file mid-processing.
- **Health probe.** A zero-byte / EOF-only connection (the `nc -z` reachability probe) is a silent health check — not logged as malformed, not counted in totals.
- **Preflight + port.** `speak --serve` validates `SPEAK_PORT` (1..65535) and runs a listener-context dependency preflight (`say`/`base64`/`nc`) before binding, reporting any missing tool. **Do NOT pre-probe `nc -l` on an ephemeral port** — portable `nc`/bash 3.2 can't bind port 0 and discover the chosen port. The **real `SPEAK_PORT` bind is the ONLY authoritative listen check**: a bind failure (with no valid pidfile/lock) means "can't listen / port in use" (R27). `doctor` reports listen capability as **"not checked; proven by --serve"** — there is NO separate `nc -l` probe (no random-port/best-effort report).
- **Status renderer.** A background renderer reads the file-backed state at an interval and repaints the live status line (so it stays current while the main path blocks in repeated `nc -l` accepts); it is cleaned up by the same INT/TERM trap.
- Double-start: acquire a **lifetime lock** `<listener_state_dir>/listener.lock` (atomic `mkdir`, stale-lock validated against the pidfile) and **check the validated pidfile/lock BEFORE binding** — not only on bind-failure — because the one-shot `nc -l` respawn loop leaves the port briefly unbound, so a second `--serve` could win the bind during the gap. A valid lock/pidfile → friendly "already running on :PORT" + clean exit; bind-failure with no valid marker → "port :PORT in use by another process" + non-zero exit (never misdiagnose an unrelated process as our listener). Release the lock on shutdown (trap) (R27).
- `trap` INT/TERM → stop accepting and remove the spool temp dir (no named pipe is used).

## Investigation targets
**Required:**
- `plugins/speak/bin/speak` — the `.2` transport/encode side to interoperate with
**Optional:**
- practice-scout notes: `nc -l` one-shot behavior, `-k`/`-w` caveats, loopback reachability

## Acceptance
- [ ] `speak --serve` binds `127.0.0.1:8765` (`SPEAK_PORT` override) and serves repeatedly via a respawn loop (R15)
- [ ] Forwarded lines are decoded (detected `-d`/`-D` flag) and spoken via a non-blocking accept→enqueue + single playback worker; concurrent arrivals queue in a bounded spool dir (drop-oldest), never overlap, and accepting never blocks on `say` (R6, R16)
- [ ] Live status shows state + active-session count (distinct session ids in a recent rolling window) + success/failure totals, with the counts **file-backed** so worker-side success/failure updates are reflected (R17)
- [ ] Frame validation, lock, enqueue, sequence allocation, queue pruning, counter/session-log updates, and session-window calc are **exposed as sourceable helpers** for `.6` to unit-test (the test obligation is owned by `.6`)
- [ ] Listener writes a validated pidfile (schema pid/port/cmd/started); identity = pid alive + ps shape + pidfile port + lifetime lock (NO reachability); stale = dead/mismatched pid/ps/port/lock → removed (R27)
- [ ] Malformed-frame + dropped (over-cap/evicted) events go to `<listener_state_dir>/listener.log`, not the status counters; zero-byte `nc -z` probes are **silent** (neither logged nor counted)
- [ ] Bounded capture reads at most `SPEAK_MAX_FRAME_BYTES`+1 (default 65536) of the encoded line — an oversized OR newline-less frame is dropped + logged before decode/enqueue, never buffered unbounded — tested (incl. oversized newline-less input)
- [ ] Identity check is path-normalization-resilient (pid alive + `ps` cmd contains `bin/speak` and `--serve` + pidfile recorded port matches + lifetime lock; **NO reachability, no opaque token in `ps`**), not an exact script-path match
- [ ] Concurrent enqueue/prune/counter updates are lock-guarded (atomic `mkdir` lock + `mktemp` sortable spool) and **exposed as sourceable helpers**; live proof of no dup/reorder here, with repeatable unit coverage owned by `.6`
- [ ] Bind uses an `nc_listen_args` helper pinning the macOS-first listen form (BSD/OpenBSD variance documented)
- [ ] A zero-byte `nc -z` probe is a silent health check (not logged malformed, not counted) (R18)
- [ ] `speak --serve` validates `SPEAK_PORT` (1..65535) and preflights `say`/`base64`/`nc` before binding
- [ ] Frame validation: exactly one tab required; zero/>1 tab, empty session id, empty payload, or undecodable base64 → logged + skipped; listener keeps serving (R18)
- [ ] **Proof evidence (owned here, not `.6`):** scripted/manual proof of container→listener audio AND that a stalled/missing-newline client does not wedge the listener (watchdog kills the concrete `nc` PID/process group, reaps the guard, leaves **no stale listener/zombie**). `.6` owns the repeatable unit coverage of the sourceable helpers.
- [ ] Listener state (`listener.pid`, counters, log, spool) uses `${SPEAK_DATA_DIR:-$HOME/.local/state/speak}` (NOT `CLAUDE_PLUGIN_DATA`) so terminal listener and Claude `doctor --listener` agree
- [ ] success/failure totals are playback-only; malformed/dropped/probe events are logged, not counted as failures (R17, R18)
- [ ] Spool cap (default 50) drops oldest beyond the cap (logged); active-session window default 60s — exercised
- [ ] Lifetime lock (`listener.lock`, atomic mkdir) acquired + pidfile/lock checked BEFORE binding (closes the respawn-gap double-start race); valid lock/pidfile → "already running" (clean exit); bind-failure + no valid marker → "port in use by another process" + non-zero exit (unrelated-process case tested); lock released on shutdown (R27)
- [ ] Identity (pid+ps+port+lock) is separate from reachability; a momentary respawn-gap unreachable never deletes the pidfile or marks the listener stale
- [ ] The real `SPEAK_PORT` bind is the ONLY authoritative listen check (no `nc -l` pre-probe at all); `doctor` reports listen "not checked; proven by --serve"
- [ ] INT/TERM cleans up the spool temp dir (no named pipe is used)
- [ ] **PROOF:** a base64 line sent from a Linux container reaches the loopback listener via `host.docker.internal` and produces audio; listener is never auto-started (R6, R7). On a red proof, STOP — record the chosen fallback (bind/flags/shared-mount) AND update the epic + every affected task spec (bind/security, reachability target, hook notice, README command, doctor, tests) before `.4`–`.7` resume

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

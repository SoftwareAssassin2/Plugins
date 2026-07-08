---
satisfies: [R18]
---

## Description

Harden the listener accept path: the per-connection watchdog and the bounded-capture size guard, so a stalled, newline-less, or oversized client can never wedge the accept loop, leak a stale `nc` holding the port, or buffer unbounded data to memory or disk. Split out of the original `.3` listener task.

**Prerequisite:** fn-5.3's container→host proof is green (or the fallback transport is recorded) before this task starts.

**Size:** S–M
**Files:** `plugins/speak/bin/speak`

## Approach

**Contracts (epic §Canonical Contracts is authoritative):** C2 (65536-byte encoded-frame cap), C9 (constants).

- **Watchdog (bash 3.2 — no `coproc`, no `timeout` binary on macOS):** run each accept/read as a backgrounded child and, on a fixed deadline, kill the **concrete `nc` PID (or its process group)** — not just a wrapping subshell — and **reap the guard**, so no stale `nc` keeps holding the port and no zombie listener remains. The `.2` sender's EOF-shutdown covers the normal path; the watchdog covers stalled/newline-less clients.
- **Bounded capture:** pipe `nc -l …` through a cap+1-byte reader (`head -c $((MAX+1))` / a bounded `dd`) that stops at `SPEAK_MAX_FRAME_BYTES` (C2) — **NOT** `nc … > file`, which would grow disk unbounded during the watchdog window. A line over the cap, or with no newline within the cap, is dropped + logged BEFORE decode/enqueue — an oversized/newline-less stream is never fully buffered to memory OR disk. A small helper is acceptable if pure bash proves too brittle. (Client-side `SPEAK_MAX_CHARS` does not protect the listener; this does.)
- Over-cap / newline-less drops go to `<listener_state_dir>/listener.log`, never the status counters (per `.3`'s playback-only counter rule).

## Investigation targets
**Required:**
- `plugins/speak/bin/speak` — `.3`'s accept loop to wrap

## Acceptance
- [ ] Bounded capture reads at most `SPEAK_MAX_FRAME_BYTES`+1 (65536+1) bytes of the encoded line; an oversized OR newline-less frame is dropped + logged before decode/enqueue, never buffered unbounded to memory or disk (R18)
- [ ] Watchdog kills the concrete `nc` PID/process group on deadline and reaps the guard — no stale `nc` holding the port, no zombie listener
- [ ] Drops are logged to `<listener_state_dir>/listener.log`, not counted in the status totals
- [ ] **Proof evidence (owned here):** scripted/manual proof that a stalled/missing-newline client does not wedge the listener and leaves no zombie; `.6` owns the repeatable unit coverage of the bounded-capture helpers (incl. oversized newline-less input)

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

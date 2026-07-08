---
satisfies: [R27]
---

## Description

Listener identity, lifetime lock, and double-start handling for `speak --serve`: the pidfile, the identity rule, stale-marker cleanup, the before-bind lock check, and the friendly "already running" vs "port in use by another process" classification. Split out of the original `.3` listener task.

**Prerequisite:** fn-5.3's container→host proof is green (or the fallback transport is recorded) before this task starts.

**Size:** S–M
**Files:** `plugins/speak/bin/speak`

## Approach

**Contracts (epic §Canonical Contracts is authoritative):** C3 (`listener_state_dir`), C4 (reachability never folded into identity), C7 (pidfile schema + identity rule + lifetime lock).

- On `--serve` startup (after `.3`'s dep/port preflight, BEFORE binding): acquire the lifetime lock and validate any existing pidfile per C7 — the one-shot `nc -l` respawn loop leaves the port briefly unbound between accepts, so a bind-failure-only check would let a second `--serve` win the bind during the gap. A valid live lock/pidfile → friendly "already running on :PORT" + clean exit 0.
- Bind failure with NO valid marker → "port :PORT in use by another process" + non-zero exit — never misdiagnose an unrelated process as our listener.
- Write the pidfile (exact C7 schema) after binding. Remove stale markers (dead/mismatched pid, ps shape, port, or lock). Per C4, a momentary respawn-gap unreachable NEVER deletes the pidfile or marks the listener stale — reachability plays no part in identity.
- Release the lock + remove the pidfile in the same INT/TERM trap `.3` installed.
- Identity/lock validation lives in **sourceable helpers** — reused verbatim by `.5`'s `doctor --listener` (no re-derivation) and unit-tested by `.6`.

## Investigation targets
**Required:**
- `plugins/speak/bin/speak` — `.3`'s listener startup/trap path to extend

## Acceptance
- [ ] Pidfile written with the exact C7 schema (`pid=`/`port=`/`cmd=`/`started=`); identity = pid alive + live `ps` command contains `bin/speak` AND `--serve` + recorded port == checked port + lifetime lock — NO reachability folded in, no opaque token, path-normalization-resilient (not an exact script-path match) (R27)
- [ ] Lifetime lock (`listener.lock`, atomic `mkdir`, stale-validated against the pidfile) acquired + validated pidfile/lock checked BEFORE binding (closes the respawn-gap double-start race); released on shutdown via the trap (R27)
- [ ] Valid lock/pidfile → "already running on :PORT" + exit 0; bind-failure + no valid marker → "port :PORT in use by another process" + non-zero (unrelated-process case exercised) (R27)
- [ ] Stale markers (dead/mismatched pid/ps/port/lock) are removed; a respawn-gap unreachable never deletes or stales anything (C4, C7)
- [ ] Identity/lock validation is exposed as sourceable helpers (reused by `.5` doctor, unit-tested by `.6`)

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

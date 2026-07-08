---
title: mkdir-lock helpers released a lock they never acquired on timeout
date: "2026-07-08"
track: bug
category: runtime-errors
module: plugins/speak/bin/speak
tags: [bash, locking, mkdir-lock, concurrency, listener, pidfile, stale-cleanup]
problem_type: runtime-error
symptoms: Lock-acquire timeout still mutated shared state and rmdir-ed another process's lock dir
root_cause: acquire || true followed by unconditional speak_lock_release in every mutation helper
resolution_type: fix
last_updated: "2026-07-08"
---

## Problem
The speak listener's mkdir-mutex helpers (`counter_incr`, `session_log_append`, `spool_enqueue`, `spool_claim`) used the pattern `speak_lock_acquire || true` and then mutated shared state AND called `speak_lock_release` unconditionally. On an acquire timeout (lock held by another process) this (a) mutated queue/counter/session state with no exclusion and (b) `rmdir`-ed a lock directory some OTHER process still held — silently breaking that holder's critical section. Caught by codex impl-review (Major, fn-5.3).

## What Didn't Work
Treating lock acquisition as advisory ("proceed carefully on timeout") on the theory that there is one accept loop and one worker in practice. The failure mode isn't the happy path — it's a stale/contended lock, where proceed-anyway both corrupts and unlocks.

## Solution
`speak_lock_acquire` timeout now returns 1 and every mutation path handles it: log a `lock timeout: ... skipped` line to listener.log, skip the mutation, return 1, and never call `speak_lock_release` for a lock this process did not acquire (`plugins/speak/bin/speak`, counter_incr / session_log_append / spool_enqueue / spool_claim). `spool_enqueue` also removes its mktemp temp file on the skip path; the playback worker treats a failed claim as "retry next tick". Stale-lock cleanup stays at well-defined ownership points only (startup rm of the previous run's lock, shutdown release after all children are dead).

## Prevention
For any mkdir-lock helper pair: the acquire's failure branch must be written first and the release must be reachable ONLY from the acquired branch — grep for `lock_acquire || true` followed by an unconditional release; that pattern is always wrong. Unit-test the held-lock case explicitly: pre-create the lock dir, assert mutation rc=1, state unchanged, and the foreign lock dir still present.

## Update 2026-07-08

## Problem
The fn-5.8 listener identity/lifetime-lock work went through four codex NEEDS_WORK rounds, all one theme: every ordering choice around WHEN identity markers (pidfile + mkdir lock) are written/removed opens a distinct race. (1) Treating a lock-without-pidfile as instantly stale let a second `--serve` rm a just-starting listener's live lock (the very double-start race the lock exists to close). (2) Writing the pidfile immediately after lock acquisition (before bind) made a bind-doomed startup present valid identity, so a concurrent starter said "already running" + exit 0 while nothing ended up serving. (3) Taking the spec's "mismatched port ⇒ stale" literally deleted the live markers of a healthy listener running on a different port. (4) Log-and-continue on pidfile-write failure produced a running listener that could never be identified — and whose lock would later be grace-cleaned out from under it.

## What Didn't Work
Point-in-time marker validation with immediate cleanup: "pidfile missing/mismatched ⇒ stale ⇒ remove" is wrong whenever startup is a multi-step window (lock → bind → pidfile). Also wrong: publishing identity before the resource (the port bind) is actually held, and reading a spec's stale-marker word list ("port") without asking whether the process behind the marker is alive and consistent.

## Solution
`plugins/speak/bin/speak` (fn-5.8): (a) lock-without-pidfile is only stale after an mtime grace window (`SPEAK_LOCK_GRACE_SECS`, test-shrinkable) — younger means startup in flight; (b) the pidfile is published only after the accept loop out-survives the bind-failure give-up window, so identity is never true for a startup that fails to bind — the concurrent-starter branch says "starting or running" without claiming a valid listener; (c) live-process-different-port returns a distinct rc (11) and removes nothing — `--serve` refuses with advice instead; (d) pidfile-write failure calls `serve_shutdown 1` — never serve without an identity marker.

## Prevention
For any pidfile/lockfile lifecycle: enumerate the startup window states (lock-no-pidfile, pidfile-no-bind, marker-for-other-resource, marker-write-failed) and decide each one explicitly — the default "clean anything invalid now" reopens the race the lock was added to close. Publish identity only after the guarded resource is actually held; make marker-write failure fatal; and treat "live process, wrong resource" as refuse-not-clean. Unit-test each window state (pre-created lock, dead pid, different port, forced write failure).

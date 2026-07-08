---
title: mkdir-lock helpers released a lock they never acquired on timeout
date: "2026-07-08"
track: bug
category: runtime-errors
module: plugins/speak/bin/speak
tags: [bash, locking, mkdir-lock, concurrency, listener]
problem_type: runtime-error
symptoms: Lock-acquire timeout still mutated shared state and rmdir-ed another process's lock dir
root_cause: acquire || true followed by unconditional speak_lock_release in every mutation helper
resolution_type: fix
---

## Problem
The speak listener's mkdir-mutex helpers (`counter_incr`, `session_log_append`, `spool_enqueue`, `spool_claim`) used the pattern `speak_lock_acquire || true` and then mutated shared state AND called `speak_lock_release` unconditionally. On an acquire timeout (lock held by another process) this (a) mutated queue/counter/session state with no exclusion and (b) `rmdir`-ed a lock directory some OTHER process still held — silently breaking that holder's critical section. Caught by codex impl-review (Major, fn-5.3).

## What Didn't Work
Treating lock acquisition as advisory ("proceed carefully on timeout") on the theory that there is one accept loop and one worker in practice. The failure mode isn't the happy path — it's a stale/contended lock, where proceed-anyway both corrupts and unlocks.

## Solution
`speak_lock_acquire` timeout now returns 1 and every mutation path handles it: log a `lock timeout: ... skipped` line to listener.log, skip the mutation, return 1, and never call `speak_lock_release` for a lock this process did not acquire (`plugins/speak/bin/speak`, counter_incr / session_log_append / spool_enqueue / spool_claim). `spool_enqueue` also removes its mktemp temp file on the skip path; the playback worker treats a failed claim as "retry next tick". Stale-lock cleanup stays at well-defined ownership points only (startup rm of the previous run's lock, shutdown release after all children are dead).

## Prevention
For any mkdir-lock helper pair: the acquire's failure branch must be written first and the release must be reachable ONLY from the acquired branch — grep for `lock_acquire || true` followed by an unconditional release; that pattern is always wrong. Unit-test the held-lock case explicitly: pre-create the lock dir, assert mutation rc=1, state unchanged, and the foreign lock dir still present.

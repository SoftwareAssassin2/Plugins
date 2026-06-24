---
title: "Custom token-bucket pacer: sub-1 rate deadlock, RetryAfter not pausing acquisiti"
date: "2026-06-19"
track: bug
category: runtime-errors
module: src/ParleyAI/RateLimiting/AimdRateController.cs
tags: [dotnet, rate-limiting, token-bucket, aimd, timeprovider, cancellation, retry-after]
problem_type: runtime-error
symptoms: Callers stall forever at rate<1; RetryAfter ignored for request pacing; pre-canceled token still charges a permit
root_cause: Burst cap = rate (no 1.0 floor); RetryAfter only suppressed ramp not acquisition; no cancellation check before granting the seeded permit
resolution_type: fix
related_to: [bug/runtime-errors/transport-timeout-vs-caller-2026-06-19]
---

## Problem
A custom manual-replenish AIMD token-bucket pacer (TimeProvider-driven, used as an
IAiChatClient decorator) shipped with three latent correctness gaps that impl-review
caught: (1) the burst cap was `= currentRate`, so a configured rate < 1 req/s capped
the bucket below the 1.0 a single acquire needs → every caller stalled forever after
the seeded permit; (2) a provider `RetryAfter` only suppressed the AIMD ramp via the
cooldown timestamp — `AcquireAsync` still granted permits during the advised wait, so
RetryAfter was not actually honored as a request pause; (3) `AcquireAsync` granted the
seeded permit even when the CancellationToken was already canceled (no
ThrowIfCancellationRequested before consuming a token) → a permit leak charging the
bucket for a request that must not acquire.

## What Didn't Work
Treating "honor RetryAfter" as "suppress the ramp during a cooldown window" — the
ramp-suppression and the request-pause are DISTINCT concerns. A bare category cooldown
should only suppress the ramp; a RetryAfter must additionally block acquisition.

## Solution
- Floor the burst cap at one whole permit: `burstCap = Math.Max(1.0, currentRate)`
  (in both Replenish and the OnBackoff surplus clamp).
- Add a separate `_blockUntilTimestamp` set ONLY from a non-null RetryAfter; AcquireAsync
  waits on it (via Task.Delay(span, TimeProvider, ct)) before granting any permit.
- `cancellationToken.ThrowIfCancellationRequested()` at the TOP of each AcquireAsync loop
  iteration, before the seeded-permit fast path.
See src/ParleyAI/RateLimiting/AimdRateController.cs.

## Prevention
For any custom rate limiter / token bucket: explicitly test (a) sub-1 rates do not
deadlock, (b) a provider-advised pause actually blocks acquisition (not just internal
state), (c) a pre-canceled token throws WITHOUT consuming a permit. Use an injected
TimeProvider (FakeTimeProvider) + a zero-jitter source so all three are deterministic
with no real sleeps.

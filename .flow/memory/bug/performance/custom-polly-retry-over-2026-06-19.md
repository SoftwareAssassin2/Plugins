---
title: Custom Polly retry over HttpResponseMessage leaks undisposed failed responses
date: "2026-06-19"
track: bug
category: performance
module: src/ParleyAI/DependencyInjection/ParleyAiResilienceOptions.cs
tags: [dotnet, polly, resilience, httpclient, retry, disposal]
problem_type: performance
symptoms: Retried 5xx responses' content buffers/sockets held until GC during downstream outage
root_cause: A generic Polly AddRetry over HttpResponseMessage does not dispose handled outcomes between attempts (unlike AddStandardResilienceHandler)
resolution_type: fix
---

## Problem
A custom Polly v8 resilience pipeline built with `AddRetry(new RetryStrategyOptions<HttpResponseMessage> {...})` over `HttpResponseMessage` does NOT dispose the handled (failed) response between attempts. A retried 5xx (with a body) holds its content buffer / socket until GC — a resource-exhaustion risk during a downstream outage. `AddStandardResilienceHandler` handles this internally, but a hand-rolled `AddResilienceHandler(name, b => b.AddTimeout(...).AddRetry(...).AddTimeout(...))` does not.

## What Didn't Work
The first cut just configured `ShouldHandle` + back-off and returned the discarded response implicitly — no disposal hook. Builds + tests pass (the in-process fake builds a fresh response per attempt so the leak is invisible in unit tests), so it slips past CI.

## Solution
Add an `OnRetry` callback to the retry strategy that disposes the previous outcome:
`OnRetry = static args => { args.Outcome.Result?.Dispose(); return default; }`.
The final (non-retried) outcome flows to the caller pipeline and is disposed there. See src/ParleyAI/DependencyInjection/ParleyAiResilienceOptions.cs ApplyDefaultPipeline.

## Prevention
When building a CUSTOM Polly pipeline over HttpResponseMessage (not AddStandardResilienceHandler), always add an OnRetry that disposes args.Outcome.Result. Also: retry a WHITELIST of transient statuses (408/500/502/503/504), never a blanket `>= 500` — 501/505 are non-transient and 429 must surface to the rate-limiter/AIMD layer, not be retried away.

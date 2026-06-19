---
title: Transport timeout vs caller cancellation must be disambiguated in HttpClient err
date: "2026-06-19"
track: bug
category: runtime-errors
module: src/ParleyAI/Providers/OpenAi/OpenAiChatClient.cs
tags: [dotnet, httpclient, error-mapping, cancellation, timeout, resilience]
problem_type: runtime-error
symptoms: Transport timeout (TaskCanceledException) escapes unmapped instead of being classified Transient
root_cause: "catch (OperationCanceledException) rethrows unconditionally, conflating caller cancellation with HttpClient timeout"
resolution_type: fix
---

## Problem
In a .NET HttpClient-backed provider client, catching `OperationCanceledException`
and unconditionally rethrowing it conflates two different events: cooperative
caller cancellation (the caller's CancellationToken fired) AND a transport timeout
(HttpClient.Timeout / SocketsHttpHandler surfaces a `TaskCanceledException`, which
derives from `OperationCanceledException`, with the caller token NOT cancelled).
The timeout is a transient failure that must be classified/retried, but the naive
`catch (OperationCanceledException) { throw; }` lets it escape unmapped.

## Solution
Split the catch with a `when` filter on the caller token:
`catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }`
propagates genuine cancellation unwrapped; a following
`catch (OperationCanceledException ex)` maps the transport timeout to the
Transient error category. See src/ParleyAI/Providers/OpenAi/OpenAiChatClient.cs.

## Prevention
When mapping provider/HTTP errors to a neutral category, always disambiguate
caller cancellation from transport timeout via the caller token's
IsCancellationRequested. A unit test that throws TaskCanceledException from the
fake handler with CancellationToken.None asserts the timeout->Transient path.

## Related (separate finding, same review)
429 token-limit detection should match machine `code` variants
(tokens_per_minute / tokens-per-min), not only the exact human message phrase
"tokens per min" — normalize separators (_ and -) to spaces before substring match.

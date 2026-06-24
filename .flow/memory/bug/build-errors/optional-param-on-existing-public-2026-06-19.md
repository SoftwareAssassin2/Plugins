---
title: Optional param on existing public API/ctor breaks NuGet binary compat
date: "2026-06-19"
track: bug
category: build-errors
module: src/ParleyAI/Providers/OpenAi/OpenAiServiceCollectionExtensions.cs
tags: [dotnet, csharp, nuget, binary-compatibility, public-api, optional-parameters, overloads]
problem_type: build-error
symptoms: MissingMethodException at load for callers compiled against the old public signature
root_cause: Optional params are part of the compiled C# signature; mutating a public method/ctor in place changes that signature
resolution_type: fix
---

## Problem
Threading a new optional parameter (`ParleyAiTelemetryOptions? telemetryOptions = null`)
onto existing PUBLIC methods/constructors of a published NuGet package
(`AddOpenAiChatClient`, `AddAnthropicChatClient`, the `OpenAiChatClient(settings, httpClient)`
ctor) is a binary-compatibility break. In C#, optional parameters are baked into the
compiled method signature, so a caller assembly compiled against the old arity binds to
a signature that no longer exists and fails at load with `MissingMethodException` — even
though the source still "looks" call-compatible.

## What Didn't Work
Adding the optional param in place to the single existing public method/ctor. Source +
the in-repo test suite compiled and passed (everything recompiles against the new
signature), which HIDES the break — it only surfaces for a separately-compiled downstream
consumer of the shipped package.

## Solution
Keep the original public signature as a thin overload that delegates to a new overload
carrying the extra parameter as a REQUIRED (non-optional) arg:
`AddOpenAiChatClient(services, config, configureOverride = null)` ->
`AddOpenAiChatClient(services, config, configureOverride, telemetryOptions: null)`.
Same pattern for the ctor (`: this(settings, httpClient, telemetryOptions: null)`).
Internal members / test seams can keep optional params freely — binary compat only
matters across the public package boundary.

## Prevention
For any published library, treat existing public method/ctor signatures as frozen: extend
via NEW overloads, never by mutating an existing signature (optional params included). A
"does it still compile in-repo?" check is insufficient — the regression is only visible to
a downstream assembly compiled against the prior version.

---
title: "DelegatingHandler base-URL override needs DI-owned pipeline, not a public bare-H"
date: "2026-06-19"
track: bug
category: integration
module: src/ParleyAI/Providers/Anthropic/AnthropicChatClient.cs
tags: [dotnet, httpclient, delegatinghandler, keyed-di, base-url, sdk-wrapper]
problem_type: integration
symptoms: Public ctor accepts settings.BaseUrl but it is silently ignored; requests hit the SDK default origin
root_cause: "A pipeline-handler-based override can only be wired in the HttpClient pipeline (DI); a handler cannot be added post-construction, and forwarding through a nested HttpClient reuses the request and throws 'already sent'"
resolution_type: fix
---

## Problem
For a provider whose base-URL override is implemented as a DelegatingHandler
(the SDK emits absolute URIs that ignore HttpClient.BaseAddress, so an
origin-rewrite handler in the transport pipeline is the only way to honor the
override), exposing a PUBLIC (settings, HttpClient) constructor is a trap: the
override handler can only be wired when the HttpClient's pipeline is built (via
AddHttpMessageHandler in DI), and a handler CANNOT be grafted onto an
already-constructed HttpClient. A public bare-HttpClient ctor therefore lets a
caller pass settings.BaseUrl that is then silently ignored — the request goes to
the SDK default origin with no error.

## What Didn't Work
First attempt: have the public ctor "own" the pipeline by wrapping the supplied
HttpClient in a forwarding leaf handler (rewrite handler -> forwarding handler ->
innerHttpClient.SendAsync). This throws InvalidOperationException: "The request
message was already sent. Cannot send the same request message multiple times."
because the outer pipeline's HttpRequestMessage is reused when forwarded into a
second HttpClient.SendAsync. You cannot nest one HttpClient send inside another
with the same request object.

## Solution
Make the (settings, HttpClient) ctor INTERNAL (DI + test seam) and let the DI
building block (Add<Provider>ChatClient) attach the rewrite handler to the named
client's pipeline via AddHttpMessageHandler. The supported PUBLIC construction
path is the DI extension, which guarantees the handler is wired. Prove it with a
DI end-to-end test that swaps the named client's primary handler for an
in-process fake (ConfigurePrimaryHttpMessageHandler(() => fake)) and asserts the
final rewritten URI on the wire. See AnthropicChatClient.cs (internal ctor) +
AnthropicServiceCollectionExtensions.cs (AddHttpMessageHandler) +
AnthropicServiceCollectionExtensionsTests.Di_wired_client_applies_base_url_rewrite_end_to_end.

## Prevention
When an override is enforced by a pipeline handler (not by SDK options), do NOT
expose a public ctor taking a pre-built HttpClient — the public surface must be
the DI extension that owns the pipeline. Also validate the override URL scheme to
http/https (a root-only check alone lets ftp://, ws:// through to a later
transport failure), and preserve non-standard HTTP statuses verbatim (e.g.
Anthropic 529) rather than nulling via Enum.IsDefined(HttpStatusCode).

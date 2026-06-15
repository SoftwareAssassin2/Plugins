---
satisfies: [R3, R4, R5, R10, R11]
---

## Description
Implement the **OpenAI wrapper** over the official OpenAI .NET SDK, implementing `IAiChatClient`. Expose the named DI extensions `AddOpenAiChatClient` (keyed, lazy) + `ValidateOpenAiChatClientOnStart` (opt-in eager hook). Honor `OPENAI_BASE_URL`/`OPENAI_API_KEY` verbatim, make the SDK use the DI transport, map the role enum. Tests cover BOTH override and env-absent default paths via in-process fakes, self-contained.

**Size:** M
**Files:** `src/<OpenAiWrapper>/*`, `src/<OpenAiWrapper>.Tests/*`

## Approach
- PRESENT `OPENAI_BASE_URL` ⇒ `OpenAIClientOptions.Endpoint = new Uri(value)` (verbatim; trailing-slash normalize; `/v1` kept) + `OpenAIClientOptions.Transport` from the DI `HttpClient`. ABSENT ⇒ set neither (SDK default; no `api.openai.com` in shipped code).
- **API key required** from ctor or `IConfiguration["OPENAI_API_KEY"]` (non-empty) — no SDK-default fallback. Base-URL precedence ctor > flat key > SDK default; key precedence ctor > flat key.
- **Named DI contract (from fn-4.1):** `AddOpenAiChatClient(this IServiceCollection, …)` registers a **keyed** `IAiChatClient` (`"openai"`) + typed client via `AddHttpClient<>`, lazy validation, exact flat-key mapping via `IConfiguration[..]` (NOT section binding) + ctor-override overload; `ValidateOpenAiChatClientOnStart(this IServiceCollection)` opts into eager validation. No captive singleton; no caller glue; no unkeyed registration.
- **Base-URL validation:** present `OPENAI_BASE_URL` must be an ABSOLUTE URI (reject relative); path allowed, `/v1` preserved; invalid fails at validation time (eager for the default provider, lazy otherwise).
- **Role mapping:** System→`system`, User→`user`, Assistant→`assistant`; test each. Enforce the single-leading-`System` rule (reject multiple/non-leading with a clear error); test rejection.
- **Tests (in-process fakes, no real network, no fn-3 stack):** (a) override — DI keyed client reaches `/v1/chat/completions` (no double `/v1`) via the configured transport, flat env vars + NO config section; (b) env-absent — capture the SDK-default request URI via a fake transport and assert the correct default path (the test fixture MAY name `api.openai.com`; the production-code grep excludes `*.Tests`, so default-host literals are allowed only in test fixtures); (c) `ValidateOpenAiChatClientOnStart` fails fast on a missing key.

## Investigation targets
**Required:**
- `fn-4-openaianthropic-api-wrapper-nuget.1` — `IAiChatClient`, role enum, named DI/hook contract
- GitHub `openai/openai-dotnet` — `OpenAIClientOptions.Endpoint` + `Transport`
**Optional:**
- MS Learn keyed DI + options `ValidateOnStart`

## Acceptance
- [ ] Implements `IAiChatClient`; `AddOpenAiChatClient` registers a **keyed** (`"openai"`) client (+ typed client), no unkeyed; `ValidateOpenAiChatClientOnStart` exposed
- [ ] `OPENAI_BASE_URL` honored verbatim (`/v1` kept) w/ ctor override; validated ABSOLUTE (relative rejected); SDK uses DI `HttpClient` via `Transport`; env absent ⇒ SDK default; no hardcoded `api.openai.com` in shipped code
- [ ] Single-leading-`System`-message rule enforced (multiple/non-leading rejected; tested)
- [ ] API key required from ctor or flat `OPENAI_API_KEY` (presence-validated, no SDK-default fallback); base-URL falls back to SDK default only
- [ ] DI maps exact flat keys explicitly (no section binding); lazy by default + the named eager hook; no captive singleton; no caller glue
- [ ] Role enum maps correctly (per-role test); BOTH paths tested with in-process fakes (override reaches `/v1/chat/completions`; env-absent SDK-default URI asserted), no real network/fn-3 dependency

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

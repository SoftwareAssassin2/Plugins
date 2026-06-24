---
satisfies: [R2, R3, R4, R5, R10, R11]
---

## Description
Implement the **Anthropic** provider as a CONCRETE `IAiChatClient` over `Anthropic.SDK`: origin-rewrite `DelegatingHandler`, singleton-safe `HttpClient`, keyed concrete registration, role mapping (System→top-level `system`), the error→`ParleyAIErrorCategory` mapping contract, and disabled SDK-native retry. Expose the keyed `IHttpClientBuilder` for .4. Adds `Anthropic.SDK` (R2). Tests against an in-process fake.

**Size:** M
**Files:** `src/ParleyAI/ParleyAI.csproj` (add `Anthropic.SDK`), `src/ParleyAI/Providers/Anthropic/*`, `src/ParleyAI.Tests/Anthropic/*`

## Approach
- `AnthropicChatClient : IAiChatClient`; `new AnthropicClient(APIAuthentication(key), httpClient)`. PRESENT `ANTHROPIC_BASE_URL` ⇒ a `DelegatingHandler` on the keyed `HttpClient` rewrites each request URI's **full origin (scheme+host+port)** preserving path+query. ABSENT ⇒ SDK default. `ANTHROPIC_BASE_URL` validated root-only at construction/resolve (lazy). Key required (ctor > flat `ANTHROPIC_API_KEY`).
- **SDK-native retry — DISABLE (single retry authority):** audit `Anthropic.SDK`'s built-in retry/resilience options and disable them so the standard resilience handler (.4) is the ONLY retry layer (avoid double-retry corrupting AIMD's final-outcome/`RetryAfter`).
- **DI** `AddAnthropicChatClient` (building block): keyed named `HttpClient` (`AddHttpClient("anthropic")` + rewrite handler + `SocketsHttpHandler`/`PooledConnectionLifetime`) and `AddKeyedSingleton<AnthropicChatClient>("anthropic")`. **Expose the keyed `IHttpClientBuilder`** for .4. Explicit flat-key mapping + ctor overload; `ValidateAnthropicChatClientOnStart`. Do NOT register public `IAiChatClient` (.4). Pin `Anthropic.SDK`.
- Role System→top-level `system`; single-leading-`System`.
- **Error→category mapping contract (Anthropic) — exact precedence (first match wins):** (1) 429 `rate_limit_error` with `anthropic-ratelimit-tokens-remaining: 0` (or body/message indicating a token limit) → `TokenLimit`; (2) 429 `rate_limit_error` with `anthropic-ratelimit-requests-remaining: 0` (or any other 429) → `RateLimit`; (3) 401 `authentication_error` → `Authentication`; (4) 400 `invalid_request_error` → `InvalidRequest`; (5) 529 `overloaded_error`/5xx/timeout → `Transient`; else `Unknown`. `RetryAfter` = `retry-after` (seconds). Named test fixtures (status + headers + body): `anthropic-429-tokens`, `anthropic-429-requests`, `anthropic-401`, `anthropic-400`, `anthropic-529`. `OperationCanceledException` passes through.
- **Tests (in-process fakes, no real network/fn-3):** `http://localhost:<port>` base ⇒ `http://localhost:<port>/v1/messages` (scheme+host+port rewrite, no double `/v1`); env-absent ⇒ `https://api.anthropic.com`; base-with-path rejected at construction/resolve; missing-key; role+system; mapping contract via minimal fixtures (429 token vs request, 401, overloaded/5xx) + `RetryAfter`; **one logical call makes exactly ONE HTTP attempt when the fake returns a retryable (429/5xx) response (SDK-native retry disabled; NO resilience handler present at this task — the resilience-on-vs-off integration test lives in fn-4.4)**.

## Investigation targets
**Required:** `fn-4...1`; tghamm/Anthropic.SDK README (`AnthropicClient(auth, HttpClient)`; retry options)
**Optional:** MS `DelegatingHandler`/keyed DI; Anthropic error/`anthropic-ratelimit-*` shapes

## Acceptance
- [ ] `Anthropic.SDK` PackageReference (pinned). `AnthropicChatClient : IAiChatClient` keyed concrete (`"anthropic"`); keyed `HttpClient` singleton-safe; keyed `IHttpClientBuilder` exposed for .4; public keyed `IAiChatClient` deferred to .4
- [ ] Anthropic SDK-native retry DISABLED via the SDK's resilience/retry options at the pipeline level (pin the SDK version; `Anthropic.SDK` exposes HTTP-resilience/retry config — set retries to 0; NOT via HttpClient if retries live in its pipeline). FALLBACK: if the pinned version exposes NO native retry switch, verify (via source/docs) that it adds NO retry layer of its own and prove single-attempt behavior with the test — either way the single-attempt test is the contract; a note records the SDK version + the exact mechanism (native off-switch OR "no retry layer present")
- [ ] PRESENT `ANTHROPIC_BASE_URL` ⇒ handler rewrites full origin (proven w/ `http://localhost`); ABSENT ⇒ SDK default; validated root-only at construction/resolve (lazy); no hardcoded host; key required; flat-key mapping explicit
- [ ] Error→`ParleyAIErrorCategory` mapping contract (token vs request 429, 401, invalid-request, overloaded/5xx) + `RetryAfter`; role + single-leading-`System` (→ top-level `system`); cancellation passes through
- [ ] Tests cover both base-URL paths + path-rejection + validation + the mapping contract via named fixtures + the single-HTTP-attempt assertion + **a ctor-override precedence test (a ctor-supplied base URL/key beats a populated flat `ANTHROPIC_*` config) via `AddAnthropicChatClient` / the concrete client** (the `AddParleyAi`-path precedence test lives in fn-4.4), in-process fakes only

## Done summary
Implemented the Anthropic provider for ParleyAI: AnthropicChatClient : IAiChatClient over Anthropic.SDK 5.10.0 with an origin-rewrite DelegatingHandler (ANTHROPIC_BASE_URL root-only override; SDK default when absent), the keyed singleton-safe HttpClient + AddAnthropicChatClient DI building block (explicit flat-key mapping, ctor-override precedence, lazy validation, exposed keyed IHttpClientBuilder for fn-4.4), System->top-level-system role mapping with the single-leading-System rule, the full error->ParleyAIErrorCategory mapping contract (429 token vs request, 401, 400, 529/5xx, RetryAfter, non-standard 529 preserved) sourced from handler-captured response detail, multi-text-block response aggregation, transport-timeout-vs-cancellation disambiguation, and proof that Anthropic.SDK ships no native retry layer (single-attempt). 38 new Anthropic tests (65 total green). Codex review reached SHIP.
## Evidence
- Commits: 15f6da3, bed6fe3, 7de8d41, 32c5f8e, 9f0e38a, 9d5f407
- Tests: dotnet test src/ParleyAI.sln, dotnet pack src/ParleyAI/ParleyAI.csproj -c Release -o ./artifacts
- PRs:
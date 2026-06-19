---
satisfies: [R2, R3, R4, R5, R10, R11]
---

## Description
Implement the **OpenAI** provider as a CONCRETE `IAiChatClient` over the official OpenAI SDK: keyed concrete registration, singleton-safe `HttpClient`, base-URL/key override, role mapping, a defined error→`ParleyAIErrorCategory` mapping contract, and disabled SDK-native retry. Expose the keyed `IHttpClientBuilder` for .4. Adds the OpenAI SDK (R2). Tests against an in-process fake.

**Size:** M
**Files:** `src/ParleyAI/ParleyAI.csproj` (add `OpenAI`), `src/ParleyAI/Providers/OpenAi/*`, `src/ParleyAI.Tests/OpenAi/*`

## Approach
- `OpenAiChatClient : IAiChatClient`; inject the keyed `HttpClient` via `OpenAIClientOptions.Transport = new HttpClientPipelineTransport(httpClient)`. `Endpoint = OPENAI_BASE_URL` when present (verbatim, `/v1` kept, absolute-validated AT CONSTRUCTION), else SDK default. Key via `ApiKeyCredential` from `OPENAI_API_KEY` (required: ctor > flat key).
- **SDK-native retry — DISABLE (single retry authority):** disable the OpenAI SDK's built-in retry at the PIPELINE level (the SDK retries 408/429/5xx by default — this lives in its `ClientPipeline`, NOT the transport, so an `HttpClient`/transport tweak will NOT stop it): set `OpenAIClientOptions.RetryPolicy = new ClientRetryPolicy(maxRetries: 0)` (System.ClientModel). Pin the OpenAI SDK version and confirm this API on it. So the resilience handler (.4) is the ONLY retry layer — otherwise the SDK retries a 429 internally before AIMD sees the final mapped error, corrupting `RetryAfter`/back-off.
- **DI** `AddOpenAiChatClient` (a documented building block; `AddParleyAi` is the public API): keyed named `HttpClient` (`AddHttpClient("openai")` + `SocketsHttpHandler`/`PooledConnectionLifetime` singleton-safe) and `AddKeyedSingleton<OpenAiChatClient>("openai")`. **Expose the keyed `IHttpClientBuilder`** for .4 to attach resilience once. Explicit flat `IConfiguration["OPENAI_BASE_URL"|"OPENAI_API_KEY"]` mapping (no section binding) + ctor overload. `ValidateOpenAiChatClientOnStart` opt-in; validation lazy (construction/resolve or hook). Do NOT register public `IAiChatClient` (.4).
- Role mapping + single-leading-`System`.
- **Error→category mapping contract (OpenAI) — exact precedence (first match wins):** (1) 429 with `x-ratelimit-remaining-tokens: 0` OR an error message/`code` indicating tokens-per-minute (message contains `tokens per min`) → `TokenLimit`; (2) any other 429 (incl. `x-ratelimit-remaining-requests: 0`) → `RateLimit`; (3) 401/403 → `Authentication`; (4) 400/422 → `InvalidRequest`; (5) 408/5xx/timeout/`HttpRequestException` → `Transient`; else `Unknown`. `RetryAfter` = `Retry-After` (seconds) else `retry-after-ms` (ms). Named test fixtures (status + headers + body): `openai-429-tpm`, `openai-429-rpm`, `openai-401`, `openai-400`, `openai-500`. `OperationCanceledException` passes through.
- **Tests (in-process fakes, no real network/fn-3):** override → `/v1/chat/completions` (no double `/v1`) via the transport, flat env + no config section; env-absent → SDK default URI (fixture may name `api.openai.com`; grep excludes `*.Tests`); missing-key validation at resolve; role + single-leading-`System`; mapping contract via minimal fixtures (429 token-limit → `TokenLimit`, 429 request-limit → `RateLimit`, 401, 5xx) + `RetryAfter`; **one logical call makes exactly ONE HTTP attempt when the fake returns a retryable (429/5xx) response (SDK-native retry disabled; NO resilience handler present at this task — the resilience-on-vs-off integration test lives in fn-4.4)**.

## Investigation targets
**Required:** `fn-4...1` (abstraction/exception/options); `openai/openai-dotnet` (`Endpoint`+`Transport`; retry/`ClientPipelineOptions`)
**Optional:** MS keyed DI + `IHttpClientFactory`; OpenAI rate-limit error shapes

## Acceptance
- [ ] `OpenAI` PackageReference (pinned). `OpenAiChatClient : IAiChatClient` keyed concrete (`"openai"`); keyed `HttpClient` singleton-safe; keyed `IHttpClientBuilder` exposed for .4; public keyed `IAiChatClient` deferred to .4
- [ ] OpenAI SDK-native retry DISABLED at the pipeline level via `OpenAIClientOptions.RetryPolicy = new ClientRetryPolicy(maxRetries: 0)` (pinned SDK version, API confirmed; NOT via HttpClient — retries live in the pipeline) — proven by the single-attempt test; a note records the SDK version + the exact no-retry API
- [ ] `OPENAI_BASE_URL` via `Endpoint`+`Transport`, absolute-validated at construction/resolve (lazy); env-absent ⇒ SDK default; key required; flat-key mapping explicit; no hardcoded `api.openai.com`
- [ ] Error→`ParleyAIErrorCategory` mapping contract (token vs request 429, 401, 4xx, 5xx) + `RetryAfter`; role + single-leading-`System`; cancellation passes through
- [ ] Tests cover both base-URL paths + validation + the mapping contract via named fixtures + a single-HTTP-attempt assertion + **a ctor-override precedence test (a ctor-supplied base URL/key beats a populated flat `OPENAI_*` config) via `AddOpenAiChatClient` / the concrete client** (the `AddParleyAi`-path precedence test lives in fn-4.4), in-process fakes only

## Done summary
Implemented the OpenAI provider for ParleyAI: OpenAiChatClient : IAiChatClient over the official OpenAI SDK (2.11.0) with a keyed singleton-safe HttpClient injected as the SDK pipeline Transport, OPENAI_BASE_URL via Endpoint (verbatim /v1, absolute-validated at construction) with SDK-default fallback, SDK-native retry disabled via ClientRetryPolicy(maxRetries: 0), a full error->ParleyAIErrorCategory mapping contract (+ RetryAfter), role mapping with the single-leading-System rule, transport-timeout-vs-cancellation disambiguation, and the AddOpenAiChatClient DI building block (keyed concrete client, explicit flat-config mapping with ctor-override precedence, lazy validation, exposed keyed IHttpClientBuilder for fn-4.4). 27 in-process-fake tests pass.
## Evidence
- Commits: 3eebaef, 128d905, 604b7623e10ec5f5973d255471384b8604e4642c
- Tests: dotnet test src/ParleyAI.sln, dotnet pack src/ParleyAI/ParleyAI.csproj -c Release -o ./artifacts
- PRs:
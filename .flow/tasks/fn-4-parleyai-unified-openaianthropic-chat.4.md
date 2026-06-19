---
satisfies: [R4, R11]
---

## Description
Assemble the cross-provider composition (completable + testable standalone, no AIMD): register the PUBLIC keyed `IAiChatClient` per provider via a composition factory wrapping the keyed concrete provider (.2/.3), applying an OPTIONAL registered decorator when present+enabled; the `IAiChatClientFactory`; and attach the standard resilience handler to each provider's keyed `HttpClient` via the builder hook .2/.3 expose. `AddParleyAi` is the public no-glue API. NO unkeyed default.

**Size:** M
**Files:** `src/ParleyAI/ParleyAI.csproj` (add `Microsoft.Extensions.Http.Resilience`), `src/ParleyAI/DependencyInjection/*` (`AddParleyAi`, composition factory, decoration hook, `AiChatClientFactory`), `src/ParleyAI.Tests/DependencyInjection/*`

## Approach
- **Composition factory + decoration hook (no .4/.5 cycle):** register the public `IAiChatClient` per provider as `AddKeyedSingleton<IAiChatClient>(key, (sp,k) => Compose(sp, k, sp.GetRequiredKeyedService<TConcreteProvider>(k)))`; the **decoration hook is a concrete optional singleton delegate `Func<IServiceProvider, string /*providerKey*/, IAiChatClient /*inner*/, IAiChatClient>`** (one optional decorator in v1 — no chaining). `Compose` does `sp.GetService<that-delegate>()`: if present, invoke it `(sp, key, bareInner)` and return its result; if absent, return the bare provider. Lifetime: the composed keyed `IAiChatClient` is singleton (matching the singleton concrete provider). `.4` registers NO delegate (bare); `.5` registers it (and gates enabled/off inside its own options). No descriptor surgery.
- **Resilience attach point (no stacking):** `.2/.3` expose each provider's keyed `IHttpClientBuilder`; `.4` attaches a resilience pipeline to that builder EXACTLY ONCE (the single place resilience is added — `.2/.3` add none). Use a **custom `AddResilienceHandler("parleyai-<provider>", b => b.AddTimeout(total).AddRetry(...).AddTimeout(attempt))` containing ONLY timeout + retry strategies — NO rate-limiter strategy** (cleaner than `AddStandardResilienceHandler` then trying to disable its built-in rate-limiter; AIMD is the sole pacer). Retry handles ONLY true transient transport/server failures — timeouts/`408`/selected `5xx`/`HttpRequestException`/`TimeoutRejectedException` — and **explicitly does NOT retry `429`**: a 429 must surface (as a mapped `ParleyAIException`) to the AIMD decorator, because retrying it here would let a retry-success hide the rate-limit signal and make AIMD ramp UP instead of backing off. Overridable.
- **Public API (exact signature):** `AddParleyAi(this IServiceCollection services, IConfiguration configuration, Action<ParleyAiOptions>? configure = null)` (`IConfiguration` passed explicitly so the flat `IConfiguration[KEY]` reads are unambiguous — not resolved from DI) plus ctor-override overloads for callers supplying base-URL/key directly. It calls the per-provider building-block helpers, registers the public keyed `IAiChatClient` via the composition factory, attaches resilience, registers `AiChatClientFactory`. NO unkeyed default.
- `AiChatClientFactory` resolves the public keyed `IAiChatClient` by `ProviderKeys`.

## Investigation targets
**Required:** `fn-4...2`/`.3` (keyed concrete registrations + exposed `IHttpClientBuilder`); MS Learn `Microsoft.Extensions.Http.Resilience`
**Optional:** `.5` (the AIMD decorator the hook applies); Polly v8

## Acceptance
- [ ] `Microsoft.Extensions.Http.Resilience` PackageReference (pinned)
- [ ] Public keyed `IAiChatClient` via composition factory + optional decoration hook; with no decorator registered (`.4` state) returns the bare provider — `.4` builds + tests pass with NO AIMD
- [ ] A custom resilience pipeline (timeout + retry ONLY, NO rate-limiter strategy) attached EXACTLY ONCE per provider via the `.2/.3`-exposed `IHttpClientBuilder` (no stacking/duplication), with a concrete **`ParleyAiResilienceOptions`** override surface: per-provider enable/disable, retry-count + timeout knobs, and a builder-callback to replace the pipeline (precedence: explicit options > defaults; lifetime singleton-with-options)
- [ ] A ctor-override precedence test through the **`AddParleyAi`** public path (ctor-supplied base URL/key beats populated flat config) for both providers (the per-provider-helper precedence tests live in .2/.3)
- [ ] The decoration hook is the concrete optional singleton `Func<IServiceProvider,string,IAiChatClient,IAiChatClient>`; `Compose` applies it when present (one decorator, v1) else returns bare — defined so .5 needs no descriptor surgery
- [ ] `AddParleyAi` public no-glue API; NO unkeyed default (unkeyed resolution throws); both injectable in one scope; `AiChatClientFactory` resolves by key
- [ ] Tests (no AIMD): keyed resolution returns a working bare client; unkeyed throws; resilience present once; **a no-double-retry integration test — one logical call hitting a retryable TRANSIENT response (`5xx`/timeout, NOT 429) yields the resilience handler's expected attempt count (and exactly one when resilience is off), proving SDK-native retry (.2/.3) does not stack with the resilience retry; plus a test that a `429` is NOT retried by resilience (surfaces immediately to mapping/AIMD)**

## Done summary
Implemented the unified AddParleyAi DI composition: a public no-glue API (IConfiguration + ctor-override overloads, NO unkeyed default) that registers each provider's public keyed IAiChatClient via a composition factory wrapping the keyed concrete provider (.2/.3) and applying an OPTIONAL singleton Func<IServiceProvider,string,IAiChatClient,IAiChatClient> decoration hook when present (bare otherwise — no .4/.5 cycle), an IAiChatClientFactory resolving the public keyed client by ProviderKeys, and a custom Microsoft.Extensions.Http.Resilience pipeline (timeout + retry only, NO rate-limiter; retries a whitelist of transient statuses 408/500/502/503/504, never 429) attached EXACTLY ONCE per provider via the .2/.3-exposed IHttpClientBuilder, with a ParleyAiResilienceOptions override surface (enable/disable, retry/timeout knobs, full-pipeline replacement, and OnRetry disposal of discarded responses). 14 new DI tests (keyed resolution + unkeyed-throws, factory, decorator-hook applied/bare, ctor-override precedence through AddParleyAi for both providers, no-double-retry attempt counts, 429/non-transient-5xx not retried, both providers).
## Evidence
- Commits: 0573293, ea9d647, da51513, 233090a, e5ecb9d, 17b381a, b3c95a7
- Tests: dotnet test src/ParleyAI.sln (79 passed), dotnet build src/ParleyAI.sln -c Release (0 warnings), dotnet pack src/ParleyAI/ParleyAI.csproj -c Release (valid .nupkg + .snupkg)
- PRs:
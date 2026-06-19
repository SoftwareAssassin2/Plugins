---
satisfies: [R12]
---

## Description
Implement the **adaptive AIMD rate optimizer** as an `IAiChatClient` decorator and register it into .4's decoration hook so it is ON by default (off switch → bare). Per-provider request-rate token bucket; additive-increase on success; multiplicative back-off on a mapped `ParleyAIException` (`RateLimit`/`TokenLimit`) with distinct per-category factor/cooldown; honors `RetryAfter`.

**Size:** M
**Files:** `src/ParleyAI/ParleyAI.csproj` (pin `System.Threading.RateLimiting` explicitly if it is not already provided by the net10 framework reference — verify), `src/ParleyAI/RateLimiting/*` (decorator + AIMD controller), `src/ParleyAI/DependencyInjection/*` (wire the AIMD hook delegate into the `AddParleyAi` path so it is on by default — `AddParleyAi` alone yields AIMD-decorated clients, preserving the no-glue API), `src/ParleyAI.Tests/RateLimiting/*`

## Approach
- **Wiring (on-by-default via the public API; no .4/.5 cycle):** .4 ships the composition factory + an optional decoration hook with NO delegate; **.5 modifies the `AddParleyAi` DI path (in `DependencyInjection/*`) to register the AIMD hook delegate by default** — so `services.AddParleyAi(...)` ALONE returns AIMD-decorated keyed clients with no extra opt-in call (no-glue API preserved). The per-provider off switch makes the delegate return `inner` for disabled providers. .5 depends on .4.
- **Control model (v1, fixed):** ONE per-provider request-rate token bucket; `RateLimit` and `TokenLimit` back off THAT pacer with distinct configurable factor + cooldown (from .1's AIMD options). Per-token (TPM) budgeting is a documented v1 non-goal.
- **Decorator:** wraps the bare concrete `IAiChatClient`; acquire a permit before delegating; success → additive increase; `ParleyAIException{RateLimit|TokenLimit}` → the category's decrease; honor `RetryAfter`. Reacts to the FINAL mapped outcome.
- **Limiter mutability:** immutable options ⇒ thread-safe limiter-swap or custom manual-replenish controller. Per-provider isolation; cooldown (one decrease/window); jitter on increase.
- **Deterministic testability:** the AIMD controller takes an injected `TimeProvider` (clock) and an injectable jitter/random source — tests use deterministic fakes (a fake `TimeProvider` + seeded/zero jitter) so cooldown/`RetryAfter`/swap behavior is asserted WITHOUT real sleeps (no flaky timing).
- **Dependency hygiene:** do NOT rely on `System.Threading.RateLimiting` arriving transitively (e.g. via resilience). If the net10 framework reference does not already include it, add a pinned `<PackageReference Include="System.Threading.RateLimiting" ... />`; verify it resolves at build.
- **Tests:** reuse the provider error fixtures' mapped exceptions from .2/.3 — a `ParleyAIException{RateLimit}` vs `{TokenLimit}` drive DIFFERENT factor/cooldown on the same pacer; `RetryAfter` honored; success → ramp; off switch → bare client (no decorator); per-provider isolation; concurrent limit-hits → one decrease/window; limiter-swap thread-safe.

## Investigation targets
**Required:** `fn-4...4` (composition-factory decoration hook); `.1` (`ParleyAIException`/category/`RetryAfter` + AIMD per-category options); `.2`/`.3` (the mapped exceptions the tests exercise)
**Optional:** MS `System.Threading.RateLimiter`; `gadget-inc/aimd-bucket`

## Acceptance
- [ ] `services.AddParleyAi(...)` ALONE returns AIMD-decorated keyed clients by default (test) — the AIMD registration is wired into the `AddParleyAi` path, not a separate opt-in call
- [ ] AIMD registered as .4's hook delegate `Func<IServiceProvider,string,IAiChatClient,IAiChatClient>` (returns the AIMD decorator wrapping `inner`), ON by default. The off switch is **per-provider**: the delegate inspects `providerKey` and returns `inner` (bare) for a disabled provider while keeping others decorated (a global-off is just both providers disabled)
- [ ] One per-provider request-rate pacer; `RateLimit` vs `TokenLimit` use DISTINCT factor/cooldown (TPM dimension a documented non-goal); honors `RetryAfter`
- [ ] Rate adjusted via thread-safe limiter-swap or manual-replenish controller (no in-place option mutation); per-provider isolation; one decrease/cooldown window; jitter on increase; AIMD controller takes an injected `TimeProvider` + jitter source so tests are deterministic (no real sleeps)
- [ ] `System.Threading.RateLimiting` availability verified (pinned PackageReference added if not framework-provided) — not relied on transitively
- [ ] Tests: RateLimit vs TokenLimit differ; RetryAfter honored; success → ramp; off → no decorator; isolation; concurrent single-decrease; swap thread-safety

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

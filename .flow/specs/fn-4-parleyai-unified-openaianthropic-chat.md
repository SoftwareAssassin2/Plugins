# ParleyAI — unified OpenAI/Anthropic chat client NuGet package + /init-project integration


## Overview

Build a single publishable **.NET NuGet package, `ParleyAI`** (author `SoftwareAssassin`, **Apache-2.0**), that provides a unified, provider-agnostic chat client over the **OpenAI** and **Anthropic** APIs, then wire **/init-project** so a scaffolded project consumes it (`<PackageReference>` + DI + OpenTelemetry) pre-connected to fn-3's config/env model.

One package contains everything: the provider-neutral abstraction (`IAiChatClient`), the OpenAI and Anthropic implementations, the DI extensions, the OpenTelemetry instrumentation, and the adaptive rate optimizer. It depends on the official OpenAI .NET SDK and the `Anthropic.SDK` — consumers pull both transitively (accepted trade-off for a single cohesive package).

Value over the raw SDKs: (1) one provider-agnostic interface, (2) base-URL/key override so the same code hits a local mock (fn-3), real local Ollama, or real cloud, (3) scaffold-native DI with explicit per-provider selection, (4) OpenTelemetry GenAI telemetry, (5) an adaptive AIMD rate optimizer that self-tunes throughput to the caller's token/rate plan.

**Linchpin + base-URL contract.** Both providers honor base-URL + key override from the flat env vars fn-3 emits, with construction-time override. Path semantics follow fn-3 verbatim: `OPENAI_BASE_URL` includes `/v1`; `ANTHROPIC_BASE_URL` is the host root. When a base-URL env var is ABSENT the SDK default applies — shipped code never hardcodes `api.openai.com`/`api.anthropic.com`. **API keys are required** (ctor or exact flat key; never an SDK default). OpenAI override = `OpenAIClientOptions.Endpoint` + `Transport` (DI `HttpClient`); **Anthropic override = a `DelegatingHandler` rewriting the full request ORIGIN (scheme+host+port)** preserving path (the SDK emits absolute `https://api.anthropic.com` URIs ignoring `HttpClient.BaseAddress`).

**No default provider.** ParleyAI registers each provider as a **keyed** `IAiChatClient` (`"openai"` / `"anthropic"`) — there is NO unkeyed default. A consumer must name the provider and may inject/use both concurrently in the same method (`[FromKeyedServices("openai")] IAiChatClient`, `[FromKeyedServices("anthropic")] IAiChatClient`); a small `IAiChatClientFactory.Create(provider)` supports runtime selection.

## Quick commands
```bash
# ParleyAI builds + packs locally (single package + symbols) — early proof point (fn-4.1)
dotnet pack src/ParleyAI/ParleyAI.csproj -c Release -o ./artifacts && ls ./artifacts/ParleyAI.*.nupkg ./artifacts/ParleyAI.*.snupkg

# No hardcoded provider hosts in SHIPPED code (tests/bin/obj excluded; defaults live in the SDKs)
! grep -rEn 'api\.(openai|anthropic)\.com' src --include=*.cs | grep -vE '/(bin|obj)/|\.Tests/' | grep -v '//'

# Tests: ai-mock-shaped in-process fakes; final scheme+path correct; roles; both override + SDK-default paths; AIMD ramp/back-off
dotnet test src/ParleyAI.sln

# Package identity
grep -nE '<PackageId>ParleyAI</PackageId>|Apache-2.0|<Authors>SoftwareAssassin' src/ParleyAI/ParleyAI.csproj
# Scaffold references ParleyAI (single package) and targets net10.0
grep -nE 'PackageReference .*ParleyAI|net10\.0' plugins/init-project/templates/src/Api/Api.csproj
```

## Boundaries / non-goals
- **NOT a runtime/deployed component.** A library consumed via NuGet; the scaffold references the **published** version.
- **Does NOT modify fn-3** (env contract + LiteLLM mock); fn-4 consumes them.
- **fn-4.1–.8 carry NO fn-3 runtime dependency** — tests mimic the ai-mock surface with in-process fakes/local fixtures, never fn-3's container/stack. Only **fn-4.9/.10** depend on fn-3 landed (the scaffold integration + live restore consume the env contract and the `--profile ai-mock` surface).
- **Single package, not three.** No separately-published Abstractions package; no cross-package shared-version machinery. (Trade-off: consumers get both provider SDKs transitively — accepted.)
- **v1 is non-streaming chat only** (`/v1/chat/completions` + unified `/v1/messages`); roles System/User/Assistant. Streaming, embeddings, batch, files, tool-calling fidelity beyond chat, assistants — out of scope.
- **No private feed.** Public nuget.org only.

## Decision context
- **Name + identity (interview):** single package `ParleyAI` (verified free on nuget.org — flat-container 404, 0 search hits), no owner prefix; `Authors = SoftwareAssassin`; **Apache-2.0** (chosen for its explicit patent grant + retaliation given commercial/client use; ship `LICENSE` + `NOTICE`).
- **Single package over three (interview):** one csproj, one publish, one version — deletes the Abstractions-as-its-own-package + shared-version-across-three complexity. The abstraction still has a provider-SDK-free public surface (design rule), it's just not a separate package boundary.
- **Custom `IAiChatClient` (interview):** no Microsoft.Extensions.AI dependency; ParleyAI owns its minimal interface (R10 shape).
- **No default provider (interview):** keyed-only registration; consumers select explicitly and can use both providers at once. This removes the prior "scaffold designates a default" + default-eager/non-default-lazy machinery entirely. Validation is lazy per keyed provider (relies on fn-3 always emitting both keys non-empty); an optional `IAiChatClientFactory` covers runtime selection.
- **Error model (interview):** provider/SDK errors are wrapped in a provider-agnostic `ParleyAI` exception (status/category + inner) so callers catch one type regardless of provider.
- **Adaptive AIMD rate optimizer (interview, NEW):** an **`IAiChatClient` decorator** (NOT a raw HTTP handler — a `DelegatingHandler` can't see the mapped `ParleyAIException`/category, which is produced above the HTTP layer) wrapping each keyed provider client. It paces logical calls via a per-provider token bucket: additive-increase on success, multiplicative decrease on a `ParleyAIException` with `Category==RateLimit` (request rate) / `TokenLimit` (token budget), honoring `RetryAfter`. It sits ABOVE the HttpClient/resilience pipeline and reacts to the FINAL mapped outcome — so there's no inside/outside-retry ambiguity (resilience retries transient blips at the HTTP layer; the standard resilience rate-limiter stays disabled so they don't fight). ON by default, fully configurable incl. a hard off switch.
- **Resilience (interview):** built-in retry-on-transient + timeout via the standard `Microsoft.Extensions.Http.Resilience` handler, applied by default, overridable. SDK-native retry (OpenAI + Anthropic) is audited and DISABLED so the resilience handler is the single HTTP retry authority. The resilience retry covers ONLY true transient failures (timeout/408/5xx/`HttpRequestException`) and **never `429`** — a 429 surfaces to the AIMD decorator (retrying it would hide the rate-limit signal and make AIMD ramp on a retry-success).
- **TFM net10.0 + scaffold bump (interview):** ParleyAI targets **net10.0** (latest LTS). Because a net10-only package can't be referenced by the scaffold's net9.0 projects, fn-4 **re-targets the scaffolded .NET projects (Api + libraries + tests) to net10.0** and updates the scaffold toolchain (dev-container SDK, CI `setup-dotnet`) accordingly. net9 is STS/near-EOL, so the bump is the forward-looking call.
- **Publish-before-reference** still holds: **fn-4.8**'s `verify-package-restorable` job polls `ParleyAI@<version>` restorable on the flat-container index; **fn-4.10** (a `verify-scaffold-restore` CI job that `needs:` the .8 gate) does the live fresh-scaffold restore+build. `scaffold_test.sh` stays offline (static assertions only).
- **OTel both sides + package refs:** ParleyAI emits on a named `ActivitySource`/`Meter` (and takes no OTLP-exporter dependency itself); the scaffolded `Api` registers them + an OTLP exporter via the standard `OTEL_EXPORTER_OTLP_ENDPOINT` (SDK default `http://localhost:4317` = the host-run collector's loopback; container-run overrides to `otel-collector:4317`) and gains the OpenTelemetry package refs. Content capture opt-in/OFF; semconv pinned, mapping isolated.
- **Single version from the tag:** `/p:Version=${TAG#nuget-v}`; the scaffold pins it via a scoped `$(LlmWrapperVersion)` MSBuild property (NOT CPM), asserted == tag at publish.
- **fn-3 not yet landed**; only **fn-4.9/.10** are gated on fn-3 (fn-3.1/.2/.3) — the scaffold integration + live restore. fn-4.1–.8 are independent of fn-3.

## Acceptance Criteria
- **R1:** `dotnet pack -c Release` produces a valid `ParleyAI` `.nupkg` + `.snupkg` with: `PackageId=ParleyAI`, `Authors=SoftwareAssassin`, `PackageLicenseExpression=Apache-2.0`, **`LICENSE` + `NOTICE` packed as content files** (alongside the SPDX expression; no `PackageLicenseFile`), a real `PackageReadmeFile`, `RepositoryUrl`, SourceLink, deterministic build (CI-only `ContinuousIntegrationBuild`), targeting **net10.0**.
- **R2:** ParleyAI is a SINGLE package containing the abstraction + OpenAI + Anthropic implementations + DI + telemetry + the adaptive optimizer; it declares NuGet dependencies on the official OpenAI .NET SDK and `Anthropic.SDK` (consumers receive both transitively). No separate Abstractions package.
- **R3:** Both providers honor base-URL + key override from the flat env vars, VERBATIM per fn-3. Base-URL env ABSENT ⇒ SDK default ⇒ no hardcoded host in SHIPPED code; **API key required (ctor or flat key), never SDK-default**. OpenAI via `Endpoint`+`Transport`; Anthropic via a `DelegatingHandler` rewriting the full origin (scheme+host+port) preserving path; `ANTHROPIC_BASE_URL` structurally validated as root. Tests assert the FINAL scheme+path for BOTH override AND env-absent default paths, both providers, via in-process fakes (the Anthropic override test uses `http://localhost:<port>` to prove scheme rewrite).
- **R4:** **`AddParleyAi(...)` is the public, no-glue consumer API** (it registers both providers keyed + composition + factory). The per-provider helpers (`AddOpenAiChatClient`/`AddAnthropicChatClient`) are documented building blocks. The DI maps the EXACT flat config keys explicitly via `IConfiguration[KEY]` (not section binding) + a ctor-override overload; key precedence ctor > flat key (required); base-URL precedence ctor > flat key > SDK default; structural-presence validation, lazy (at construction/resolve, not at registration); no captive singleton (keyed `HttpClient` is singleton-safe via `PooledConnectionLifetime`). A test proves the flat keys work with NO config section and NO caller glue.
- **R5:** Test suites pass against an in-process fake mirroring the LiteLLM ai-mock surface (`/v1/chat/completions` + unified `/v1/messages`), self-contained — NO fn-3 runtime/container dependency.
- **R6:** ParleyAI emits OpenTelemetry GenAI telemetry (named `ActivitySource`/`Meter`, `gen_ai.*` span attrs + the pinned metric instruments `gen_ai.client.operation.duration`/`token.usage`) AND the scaffolded `Api` registers them + an OTLP exporter on BOTH the tracing and metrics builders with NO explicit endpoint — the OTel SDK default `http://localhost:4317` is correct: the `Api` process and the compose stacks run in the same place (host, or inside the dev container via docker-in-docker), and the collector publishes its gRPC port to that loopback — so a dev-container-run Api reaches it at `localhost:4317` too; no env emission is required and `build-config`/`config.json` is NOT touched. (A code comment notes the standard `OTEL_EXPORTER_OTLP_ENDPOINT` override to `http://otel-collector:4317` IF the Api is ever containerized — out of fn-4 scope.) The required OpenTelemetry package refs are added to `Api.csproj` (pinned). Content capture gated, default OFF; semconv version + attribute names in one constants source.
- **R7:** Plugin-repo NuGet publish workflow (repo's first `.github/`): build/test job path-scoped to `src/**`; publish job gated on `nuget-v*` tags that asserts the scaffold `$(LlmWrapperVersion)` equals `${GITHUB_REF_NAME#nuget-v}`, packs `ParleyAI` at that version, publishes via a deterministic auth selector (`vars.NUGET_TRUSTED_PUBLISHING=='true'` ⇒ OIDC, else `NUGET_API_KEY`, never both) with `--skip-duplicate` + symbols, pinned actions, and polls `ParleyAI@version` restorable before signalling success. Committed `src/` fixtures survive `.gitignore`.
- **R8:** /init-project references the published `ParleyAI` via a scoped `$(LlmWrapperVersion)` property (NOT CPM) and DI-registers BOTH providers (keyed, no default) in the scaffolded `Api` via the ParleyAI extensions (no caller glue), with example usage showing explicit per-provider selection. `scaffold_test.sh` asserts STATIC generated artifacts only (offline); the live published restore+build is fn-4.10 (CI job `needs:` .8's verify-package-restorable gate).
- **R9:** Docs updated: scaffolded `docs/config-management.md` (services/env rows + ParleyAI consumer), `_CLAUDE.md` (local-LLM exception row + Standards-index trigger naming the pre-wired ParleyAI client), `README.md`, OTel note; the skill orchestration doc `plugins/init-project/SKILL.md` (this plugin has no `main.md` — `SKILL.md` is the orchestration doc) + `marketplace.json` description; a repo-root `README.md` documenting `./src/` + the release procedure; and `LICENSE`/`NOTICE` (packed in the nupkg per R1).
- **R10:** ParleyAI's `IAiChatClient` defines the provider-neutral v1 chat shape — request/response DTOs, token usage, finish reason, `CancellationToken`, a pinned role enum (`System`/`User`/`Assistant`) with the single-leading-`System`-message rule (multiple/non-leading rejected) — and its PUBLIC surface carries no provider-SDK types. Provider errors surface as a provider-agnostic `ParleyAIException` carrying a public `ParleyAIErrorCategory` enum (`RateLimit`/`TokenLimit`/`Authentication`/`InvalidRequest`/`Transient`/`Unknown`), a nullable HTTP status, and the originating provider key; `OperationCanceledException` passes through un-wrapped. The category drives the AIMD back-off (R12).
- **R11:** DI resolution is keyed-only: each provider registers a **keyed** `IAiChatClient` (`"openai"`/`"anthropic"`) — NO unkeyed default anywhere; consumers resolve explicitly (and may inject/use both at once), with an `IAiChatClientFactory` for runtime selection. Per-provider validation is lazy; a fresh scaffold never fails at boot for an unused provider.
- **R12 (NEW):** ParleyAI ships an **adaptive AIMD rate optimizer as an `IAiChatClient` decorator** (per provider) — additive throughput increase on sustained success, multiplicative back-off on a mapped `ParleyAIException` with `Category==RateLimit`/`TokenLimit` (honoring `RetryAfter`), self-tuning to the caller's plan via a per-provider token bucket (rate adjusted by a thread-safe limiter-swap / manual-replenish controller, not in-place option mutation). It decorates each keyed provider client and reacts to the FINAL mapped outcome (above the resilience pipeline; the standard resilience rate-limiter stays disabled). **Enabled by default; fully configurable** (tunable step/factor/floor/ceiling + a hard off switch → bare client). Tested: RateLimit vs TokenLimit drive different decreases; `RetryAfter` honored; sustained success ramps; disabled bypasses (no decorator).
- **R13 (NEW):** ParleyAI targets **net10.0**, and fn-4 re-targets the scaffolded .NET projects (Api + libraries + tests) from net9.0 to **net10.0** so they can reference it, updating the scaffold toolchain (dev-container .NET SDK pin, CI `setup-dotnet` version, any `global.json`). The scaffold builds + tests green on net10.0.

## Early proof point
Task **fn-4.1** validates packaging + the abstraction contract for the single `ParleyAI` package (build, `dotnet pack` → valid `.nupkg`/`.snupkg` with correct metadata + Apache-2.0 + net10.0, provider-SDK-free abstraction surface incl. the pinned role enum). The other make-or-break validation is the **Anthropic origin-rewrite `DelegatingHandler`** reaching `/v1/messages` over `http://localhost` (proves scheme rewrite).

## Open questions
- **AIMD default tuning (for `/flow-next:work`):** the control model is now FIXED — one per-provider **request-rate** token bucket, `RateLimit`/`TokenLimit` driving distinct per-category back-off factor/cooldown (true per-token/TPM budgeting is a v1 non-goal; no token-cost estimate in the DTO). The provider error→category mapping (which 429 body/header maps to `RateLimit` vs `TokenLimit`, etc.) is now a defined contract in fn-4.2/.3 with required fixtures. What's left to the implementer is only the default NUMERIC tuning: additive-step / per-category multiplicative-factor / cooldown / floor-ceiling values. The observable contract (ramp on success, category-specific back-off, on-by-default, off-switch) is fixed.

## Resolved via Codebase
- Scaffold .NET TFM is `net9.0` (`plugins/init-project/templates/src/Api/Api.csproj`) → drives the R13 bump-to-net10.0 reconciliation.
- Repo/marketplace owner is `SoftwareAssassin2` (git remote + `.claude-plugin/marketplace.json`); the package **author** chosen in interview is `SoftwareAssassin` (no company prefix in the package ID).
- No `LICENSE` file exists at the repo root → Apache-2.0 `LICENSE`/`NOTICE` are net-new (R9).
- nuget.org availability verified for `ParleyAI` (flat-container 404, 0 exact/loose search hits).

## Requirement coverage

| Req | Description | Task(s) |
|-----|-------------|---------|
| R1  | Single ParleyAI package packs valid .nupkg/.snupkg w/ metadata + Apache-2.0 + net10.0 | fn-4.1 |
| R2  | One package: abstraction + both provider impls (+ SDK deps) | fn-4.1, fn-4.2, fn-4.3 |
| R3  | Base-URL/key override (OpenAI Endpoint+Transport; Anthropic origin-rewrite handler), both paths tested | fn-4.2, fn-4.3 |
| R4  | Public `AddParleyAi` no-glue API (+ per-provider building blocks): explicit flat-key mapping, key required, lazy validation, no glue | fn-4.2, fn-4.3, fn-4.4 |
| R5  | Tests vs in-process fake ai-mock surface (no fn-3 dep) | fn-4.2, fn-4.3 |
| R6  | OTel library emission + scaffold Api registration + pkg refs | fn-4.6, fn-4.9 |
| R7  | Publish CI (PR/branch build-test path-filtered to src/**; nuget-v* tag runs release UNconditionally; pin==tag, tag-derived version, two mutually-exclusive publish jobs w/ explicit NuGet/login OIDC step, restorability gate, net10 SDK per job) | fn-4.8 |
| R8  | Scaffold scoped-property pin + keyed DI (no default) wiring; static scaffold_test; live restore | fn-4.9, fn-4.10 |
| R9  | Docs + repo-root README + LICENSE/NOTICE | fn-4.1, fn-4.8, fn-4.9 |
| R10 | Custom IAiChatClient shape + role enum + single-leading-System rule + ParleyAI exception | fn-4.1, fn-4.2, fn-4.3 |
| R11 | Keyed-only DI (no default) + IAiChatClientFactory; lazy per-provider validation | fn-4.2, fn-4.3, fn-4.4 |
| R12 | Adaptive AIMD rate optimizer, on by default, configurable | fn-4.5 |
| R13 | net10.0 target + scaffold re-target to net10.0 + toolchain bump | fn-4.1, fn-4.7 |

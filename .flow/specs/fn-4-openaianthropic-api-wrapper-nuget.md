# ParleyAI — unified OpenAI/Anthropic chat client NuGet package + /init-project integration

> **Interview update (supersedes the original three-package plan).** This spec was refined via `/flow-next:interview`. The package is now a SINGLE package named **`ParleyAI`** (author `SoftwareAssassin`, Apache-2.0), not three. The 7 existing tasks were authored against the three-package design and are now stale — run `/flow-next:sync` (or re-plan) to realign them before `/flow-next:work`.

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
- **fn-4.1–.5 carry NO fn-3 runtime dependency** — tests mimic the ai-mock surface with in-process fakes/local fixtures, never fn-3's container/stack. Only fn-4.6/.7 depend on fn-3 landed.
- **Single package, not three.** No separately-published Abstractions package; no cross-package shared-version machinery. (Trade-off: consumers get both provider SDKs transitively — accepted.)
- **v1 is non-streaming chat only** (`/v1/chat/completions` + unified `/v1/messages`); roles System/User/Assistant. Streaming, embeddings, batch, files, tool-calling fidelity beyond chat, assistants — out of scope.
- **No private feed.** Public nuget.org only.

## Decision context
- **Name + identity (interview):** single package `ParleyAI` (verified free on nuget.org — flat-container 404, 0 search hits), no owner prefix; `Authors = SoftwareAssassin`; **Apache-2.0** (chosen for its explicit patent grant + retaliation given commercial/client use; ship `LICENSE` + `NOTICE`).
- **Single package over three (interview):** one csproj, one publish, one version — deletes the Abstractions-as-its-own-package + shared-version-across-three complexity. The abstraction still has a provider-SDK-free public surface (design rule), it's just not a separate package boundary.
- **Custom `IAiChatClient` (interview):** no Microsoft.Extensions.AI dependency; ParleyAI owns its minimal interface (R10 shape).
- **No default provider (interview):** keyed-only registration; consumers select explicitly and can use both providers at once. This removes the prior "scaffold designates a default" + default-eager/non-default-lazy machinery entirely. Validation is lazy per keyed provider (relies on fn-3 always emitting both keys non-empty); an optional `IAiChatClientFactory` covers runtime selection.
- **Error model (interview):** provider/SDK errors are wrapped in a provider-agnostic `ParleyAI` exception (status/category + inner) so callers catch one type regardless of provider.
- **Adaptive AIMD rate optimizer (interview, NEW):** additive-increase on sustained success, multiplicative (exponential) decrease on rate/token-limit signals — self-tuning throughput to the caller's plan. ON by default, fully configurable incl. a hard off switch. Layers ABOVE the standard transient-retry resilience (they're distinct concerns: retry handles blips; the pacer shapes sustained throughput).
- **Resilience (interview):** built-in retry-on-transient + timeout via the standard `Microsoft.Extensions.Http.Resilience` handler, applied by default, overridable.
- **TFM net10.0 + scaffold bump (interview):** ParleyAI targets **net10.0** (latest LTS). Because a net10-only package can't be referenced by the scaffold's net9.0 projects, fn-4 **re-targets the scaffolded .NET projects (Api + libraries + tests) to net10.0** and updates the scaffold toolchain (dev-container SDK, CI `setup-dotnet`) accordingly. net9 is STS/near-EOL, so the bump is the forward-looking call.
- **Publish-before-reference** still holds: fn-4.5's CI polls `ParleyAI@<version>` restorable; fn-4.7 (an explicit CI job `needs:` publish) does the live fresh-scaffold restore+build. `scaffold_test.sh` stays offline (static assertions only).
- **OTel both sides + package refs:** ParleyAI emits on a named `ActivitySource`/`Meter`; the scaffolded `Api` registers them + an OTLP exporter (`OTEL_EXPORTER_OTLP_ENDPOINT`, default `http://localhost:4317`) and gains the OpenTelemetry package refs. Content capture opt-in/OFF; semconv pinned, mapping isolated.
- **Single version from the tag:** `/p:Version=${TAG#nuget-v}`; the scaffold pins it via a scoped `$(LlmWrapperVersion)` MSBuild property (NOT CPM), asserted == tag at publish.
- **fn-3 not yet landed**; fn-4.6/.7 gated on fn-3.2 + fn-3.1.

## Acceptance Criteria
- **R1:** `dotnet pack -c Release` produces a valid `ParleyAI` `.nupkg` + `.snupkg` with: `PackageId=ParleyAI`, `Authors=SoftwareAssassin`, `PackageLicenseExpression=Apache-2.0` (+ shipped `LICENSE`/`NOTICE`), a real `PackageReadmeFile`, `RepositoryUrl`, SourceLink, deterministic build (CI-only `ContinuousIntegrationBuild`), targeting **net10.0**.
- **R2:** ParleyAI is a SINGLE package containing the abstraction + OpenAI + Anthropic implementations + DI + telemetry + the adaptive optimizer; it declares NuGet dependencies on the official OpenAI .NET SDK and `Anthropic.SDK` (consumers receive both transitively). No separate Abstractions package.
- **R3:** Both providers honor base-URL + key override from the flat env vars, VERBATIM per fn-3. Base-URL env ABSENT ⇒ SDK default ⇒ no hardcoded host in SHIPPED code; **API key required (ctor or flat key), never SDK-default**. OpenAI via `Endpoint`+`Transport`; Anthropic via a `DelegatingHandler` rewriting the full origin (scheme+host+port) preserving path; `ANTHROPIC_BASE_URL` structurally validated as root. Tests assert the FINAL scheme+path for BOTH override AND env-absent default paths, both providers, via in-process fakes (the Anthropic override test uses `http://localhost:<port>` to prove scheme rewrite).
- **R4:** DI extensions (`AddOpenAiChatClient` / `AddAnthropicChatClient`) map the EXACT flat config keys explicitly via `IConfiguration[KEY]` (not section binding) + a ctor-override overload; key precedence ctor > flat key (required); base-URL precedence ctor > flat key > SDK default; structural-presence validation, lazy; no captive singleton. A test proves the flat keys work with NO config section and NO caller glue.
- **R5:** Test suites pass against an in-process fake mirroring the LiteLLM ai-mock surface (`/v1/chat/completions` + unified `/v1/messages`), self-contained — NO fn-3 runtime/container dependency.
- **R6:** ParleyAI emits OpenTelemetry GenAI telemetry (named `ActivitySource`/`Meter`, `gen_ai.*` span attrs + pinned metric instruments) AND the scaffolded `Api` registers them + an OTLP exporter (`OTEL_EXPORTER_OTLP_ENDPOINT`, default `http://localhost:4317`) WITH the required OpenTelemetry package refs in `Api.csproj` (pinned). Content capture gated, default OFF; semconv version + attribute names in one constants source.
- **R7:** Plugin-repo NuGet publish workflow (repo's first `.github/`): build/test job path-scoped to `src/**`; publish job gated on `nuget-v*` tags that asserts the scaffold `$(LlmWrapperVersion)` equals `${GITHUB_REF_NAME#nuget-v}`, packs `ParleyAI` at that version, publishes via a deterministic auth selector (`vars.NUGET_TRUSTED_PUBLISHING=='true'` ⇒ OIDC, else `NUGET_API_KEY`, never both) with `--skip-duplicate` + symbols, pinned actions, and polls `ParleyAI@version` restorable before signalling success. Committed `src/` fixtures survive `.gitignore`.
- **R8:** /init-project references the published `ParleyAI` via a scoped `$(LlmWrapperVersion)` property (NOT CPM) and DI-registers BOTH providers (keyed, no default) in the scaffolded `Api` via the ParleyAI extensions (no caller glue), with example usage showing explicit per-provider selection. `scaffold_test.sh` asserts STATIC generated artifacts only (offline); the live published restore+build is fn-4.7 (CI job `needs:` publish).
- **R9:** Docs updated: scaffolded `docs/config-management.md` (services/env rows + ParleyAI consumer), `_CLAUDE.md`, `README.md`, OTel note; skill `main.md`/`SKILL.md` + `marketplace.json` description; a repo-root `README.md` documenting `./src/` + the release procedure; and the shipped `LICENSE`/`NOTICE`.
- **R10:** ParleyAI's `IAiChatClient` defines the provider-neutral v1 chat shape — request/response DTOs, token usage, finish reason, `CancellationToken`, a pinned role enum (`System`/`User`/`Assistant`) with the single-leading-`System`-message rule (multiple/non-leading rejected) — and its PUBLIC surface carries no provider-SDK types. Provider errors surface as a provider-agnostic `ParleyAI` exception.
- **R11:** DI resolution is keyed-only: each provider registers a **keyed** `IAiChatClient` (`"openai"`/`"anthropic"`) — NO unkeyed default anywhere; consumers resolve explicitly (and may inject/use both at once), with an `IAiChatClientFactory` for runtime selection. Per-provider validation is lazy; a fresh scaffold never fails at boot for an unused provider.
- **R12 (NEW):** ParleyAI ships an **adaptive AIMD rate optimizer** — additive throughput increase on sustained success, multiplicative/exponential back-off on rate/token-limit signals (HTTP 429, `Retry-After`, provider rate-limit headers, token-limit error responses) — self-tuning to the caller's plan. **Enabled by default; fully configurable** (tunable parameters + a hard off switch). Layers above the R-resilience retry. Tested: simulated 429/limit responses drive back-off; sustained success drives ramp-up; disabled config bypasses it.
- **R13 (NEW):** ParleyAI targets **net10.0**, and fn-4 re-targets the scaffolded .NET projects (Api + libraries + tests) from net9.0 to **net10.0** so they can reference it, updating the scaffold toolchain (dev-container .NET SDK pin, CI `setup-dotnet` version, any `global.json`). The scaffold builds + tests green on net10.0.

## Early proof point
Task **fn-4.1** validates packaging + the abstraction contract for the single `ParleyAI` package (build, `dotnet pack` → valid `.nupkg`/`.snupkg` with correct metadata + Apache-2.0 + net10.0, provider-SDK-free abstraction surface incl. the pinned role enum). The other make-or-break validation is the **Anthropic origin-rewrite `DelegatingHandler`** reaching `/v1/messages` over `http://localhost` (proves scheme rewrite).

## Open questions
- **AIMD optimizer mechanics (for `/flow-next:work`):** which lever the pacer adjusts (max in-flight concurrency vs request-rate/inter-request delay), the exact per-provider limit signals (429 + `Retry-After` + `x-ratelimit-*` / `anthropic-ratelimit-*` headers + token-limit error bodies), and the default additive-step / multiplicative-factor / floor-ceiling parameters. The observable contract (ramp on success, exp back-off on limit, on-by-default, off-switch) is fixed; the tuning is an implementation decision.

## Resolved via Codebase
- Scaffold .NET TFM is `net9.0` (`plugins/init-project/templates/src/Api/Api.csproj`) → drives the R13 bump-to-net10.0 reconciliation.
- Repo/marketplace owner is `SoftwareAssassin2` (git remote + `.claude-plugin/marketplace.json`); the package **author** chosen in interview is `SoftwareAssassin` (no company prefix in the package ID).
- No `LICENSE` file exists at the repo root → Apache-2.0 `LICENSE`/`NOTICE` are net-new (R9).
- nuget.org availability verified for `ParleyAI` (flat-container 404, 0 exact/loose search hits).

## Requirement coverage
> Task mappings below are the PRE-interview 7-task structure. The single-package pivot + R12/R13 mean the task graph must be re-derived via `/flow-next:sync` (or re-plan); treat this table as intent, not the final task split.

| Req | Description | Task(s) (pending re-sync) |
|-----|-------------|---------------------------|
| R1  | Single ParleyAI package packs valid .nupkg/.snupkg w/ metadata + Apache-2.0 + net10.0 | fn-4.1 |
| R2  | One package: abstraction + both providers + DI + telemetry + optimizer; SDK deps | fn-4.1 |
| R3  | Base-URL/key override (OpenAI transport; Anthropic origin rewrite), both paths tested | fn-4.2, fn-4.3 |
| R4  | DI extensions: explicit flat-key mapping, key required, lazy validation, no glue | fn-4.2, fn-4.3 |
| R5  | Tests vs in-process fake ai-mock surface (no fn-3 dep) | fn-4.2, fn-4.3 |
| R6  | OTel emission + scaffold Api registration + pkg refs | fn-4.4, fn-4.6 |
| R7  | Publish CI (path-scoped, pin==tag, tag-derived version, OIDC selector, restorability poll) | fn-4.5 |
| R8  | Scaffold scoped-property pin + keyed DI (no default) wiring; static scaffold_test; live restore fn-4.7 | fn-4.6, fn-4.7 |
| R9  | Docs + repo-root README + LICENSE/NOTICE | fn-4.6, fn-4.5 |
| R10 | Custom IAiChatClient shape + role enum + single-leading-System rule + ParleyAI exception | fn-4.1, fn-4.2, fn-4.3 |
| R11 | Keyed-only DI (no default) + IAiChatClientFactory; lazy per-provider validation | fn-4.2, fn-4.3, fn-4.6 |
| R12 | Adaptive AIMD rate optimizer, on by default, configurable | (new task — re-sync) |
| R13 | net10.0 target + scaffold re-target to net10.0 + toolchain bump | (new task — re-sync) |

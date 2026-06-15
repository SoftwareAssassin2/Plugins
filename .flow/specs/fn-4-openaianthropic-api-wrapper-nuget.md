# OpenAI/Anthropic API wrapper NuGet packages + /init-project integration

## Overview

Build my own publishable **.NET NuGet wrapper packages** for the OpenAI and Anthropic APIs under a new top-level **`./src/`** (the .NET home, sibling to `plugins/`), publish them to **nuget.org**, then add **/init-project** scaffold wiring so a generated project pulls them in (`<PackageReference>` + DI + OpenTelemetry registration) pre-connected to the existing config/env model.

**Three packages ship**, all sharing one version: an **Abstractions** package (provider-neutral interface + DTOs, zero provider-SDK deps), an **OpenAI** wrapper, and an **Anthropic** wrapper. The provider packages take a NuGet dependency on the published Abstractions package.

The packages are an **additive value layer** (fn-3 works with the official SDKs alone): a provider-agnostic abstraction, scaffold-native DI + config (no caller glue), and OpenTelemetry GenAI telemetry into the fn-2 observability stack.

**Linchpin + base-URL contract.** Both wrappers honor base-URL + key override from the flat env vars fn-3 emits, with construction-time override, so one code path runs across deterministic mock (CI), real local Ollama, and real cloud. **Path semantics follow fn-3 verbatim:** `OPENAI_BASE_URL` includes `/v1`; `ANTHROPIC_BASE_URL` is the host root (validated absolute, no path/query/fragment beyond `/`; SDK appends `/v1/messages`). When a base-URL env var is ABSENT the wrapper applies no override and the SDK uses its own default — shipped code never contains `api.openai.com`/`api.anthropic.com`. **API keys are required** (ctor override or exact flat config key; never an SDK default). OpenAI override = `OpenAIClientOptions.Endpoint` + `Transport` (DI `HttpClient`); **Anthropic override = a `DelegatingHandler` that rewrites the full request ORIGIN (scheme + host + port)** from `ANTHROPIC_BASE_URL` while preserving path + query (the SDK emits absolute `https://api.anthropic.com` URIs that ignore `HttpClient.BaseAddress`; rewriting only host/port would keep `https` and break an `http://localhost` mock — so the SCHEME must be rewritten too).

## Quick commands
```bash
dotnet pack src/<Solution>.sln -c Release -o ./artifacts && ls ./artifacts/*.nupkg ./artifacts/*.snupkg   # 3 + 3
# No hardcoded provider hosts in SHIPPED code (tests/bin/obj excluded)
! grep -rEn 'api\.(openai|anthropic)\.com' src --include=*.cs | grep -vE '/(bin|obj)/|\.Tests/' | grep -v '//'
dotnet test src/<Solution>.sln   # ai-mock-shaped in-process fakes; final paths (no double /v1); roles; both override + default paths
grep -RnE 'LlmWrapperVersion' plugins/init-project/templates/ && grep -nE 'OpenTelemetry' plugins/init-project/templates/src/Api/Api.csproj
```

## Boundaries / non-goals
- **NOT a runtime/deployed component.** Libraries consumed via NuGet; the scaffold references the **published** versions.
- **Does NOT modify fn-3** (env contract + LiteLLM mock); fn-4 consumes them.
- **Does NOT block fn-3, and fn-4.1–.5 carry NO fn-3 runtime dependency** — their tests mimic the ai-mock surface with in-process fakes/local fixtures, never fn-3's container/stack. Only fn-4.6/.7 depend on fn-3 landed.
- **Does NOT convert the scaffold to CPM.** Scaffold keeps inline pins; fn-4 adds only a scoped MSBuild property.
- **v1 is non-streaming chat only** (`/v1/chat/completions` + unified `/v1/messages`); roles System/User/Assistant. Streaming, embeddings, batch, files, tool-calling fidelity beyond chat, assistants — out of scope.
- **No private feed.** Public nuget.org only.

## Decision context
- **`./src/` for the .NET home (user directive)**, sibling to `plugins/`; `marketplace.json` still points only at `./plugins/*`.
- **Custom wrappers justified** — the Anthropic absolute-URI/no-override gap makes a wrapper (DelegatingHandler retarget) the clean way to satisfy fn-3's mock interception.
- **v1 abstraction shape.** Provider-neutral DTOs: chat request (model id; ordered messages with a fixed **role enum `System`/`User`/`Assistant`**; optional max-tokens/temperature), chat response (content; token usage in/out; finish reason), `CancellationToken`; **non-streaming**; **zero provider-SDK deps** in the public surface. Role mapping is provider-specific + tested: OpenAI System→`system`; Anthropic System→top-level `system` request param.
- **DI extension API (named contract, fixed here so .2/.3/.6 stay compatible).** Each provider package exposes: `AddOpenAiChatClient(this IServiceCollection, …)` / `AddAnthropicChatClient(…)` — register a **keyed** `IAiChatClient` (`"openai"`/`"anthropic"`) + concrete typed client, **lazy** validation; and `ValidateOpenAiChatClientOnStart(this IServiceCollection)` / `ValidateAnthropicChatClientOnStart(…)` — the **opt-in eager-validation hook**. No unkeyed registration inside provider packages. The scaffold (fn-4.6) registers the default unkeyed `IAiChatClient` (default OpenAI; one-line switch) and calls ONLY the default provider's `Validate…OnStart`. Consumers inject unkeyed (default) or `[FromKeyedServices("anthropic")]` — no `IEnumerable` glue.
- **Validation scope.** Structural-presence only (never key validity). **API key required** from ctor or exact flat key (non-empty); only the **base URL** falls back to the SDK default. Default provider validates eagerly via its `Validate…OnStart` (called by the scaffold); non-default keyed providers validate lazily on first resolve. Relies on fn-3 always emitting both keys non-empty (`sk-local-mock`/`REPLACE_ME`).
- **Base-URL structural validation per provider.** `ANTHROPIC_BASE_URL`: absolute URI, no query/fragment, path empty or `/` (reject `/v1` — SDK owns the path, fail fast). `OPENAI_BASE_URL`: absolute URI (reject relative), path ALLOWED and `/v1` preserved. Invalid values fail at validation time for the resolved/default provider (lazy for non-default).
- **Release version invariant (single-source through the release).** The published version is `${TAG#nuget-v}`. The scaffold pin `$(LlmWrapperVersion)` MUST equal it; **fn-4.5 asserts `LlmWrapperVersion == ${GITHUB_REF_NAME#nuget-v}` and fails the release on mismatch** — so the tag, the published packages, and the scaffold pin can never drift. **No release-order deadlock:** the pin file `plugins/init-project/templates/Directory.Build.props` is CREATED (with the initial `<LlmWrapperVersion>`) by **fn-4.5**, so it exists before the first publish; **fn-4.6** only CONSUMES it, and its static wiring needs no published packages (publish-before-reference is enforced solely by fn-4.7's live restore).
- **Two version-pin mechanisms:** wrapper REPO `./src/` uses CPM; the SCAFFOLD uses the scoped `$(LlmWrapperVersion)` property.
- **Three published packages, one shared version** from the tag; providers depend on the Abstractions package (ProjectReference without `PrivateAssets`).
- **Publish-before-reference, owned by an explicit CI job.** fn-4.5's publish job polls each package ID@version restorable. **fn-4.7 is a CI job with `needs:` the publish job** (NOT a manual step) that scaffolds a fresh project and `restore`+`build`s it against the published packages. `scaffold_test.sh` stays OFFLINE (static assertions only).
- **OTel both sides + package refs:** wrappers emit on named `ActivitySource`/`Meter` (fn-4.4); the scaffolded `Api` registers them + an OTLP exporter AND gains the OpenTelemetry package refs in `Api.csproj` (fn-4.6). Content capture opt-in/OFF; semconv pinned, mapping isolated.
- **Trusted Publishing (OIDC) preferred**; `--skip-duplicate`; `.snupkg` + SourceLink + deterministic builds.
- **Prefix reservation = MANUAL release prerequisite** (evidence in release notes); workflow non-blocking on unique IDs.
- **fn-3 not yet landed**; fn-4.6/.7 gated on fn-3.2 + fn-3.1.

## Acceptance Criteria
- **R1:** `dotnet pack -c Release` produces valid `.nupkg` + `.snupkg` for all three packages, each with a unique owner-namespaced `PackageId`, SPDX `PackageLicenseExpression`, per-package `PackageReadmeFile` (real README via `<None Pack="true">`), `RepositoryUrl`, SourceLink, deterministic build (CI-only `ContinuousIntegrationBuild`).
- **R2:** Abstractions is its own published package; provider packages declare a NuGet package dependency on it (shared version), not a bundled project.
- **R3:** Both wrappers honor base-URL + key override from the flat env vars, VERBATIM per fn-3 (`OPENAI_BASE_URL` incl `/v1`; `ANTHROPIC_BASE_URL` root, structurally validated). Base-URL env ABSENT ⇒ SDK default ⇒ no hardcoded host in SHIPPED code; **API key required (ctor or flat key), never SDK-default**. OpenAI via `Endpoint`+`Transport`; Anthropic via a `DelegatingHandler` rewriting the full origin (scheme+host+port) preserving path. Tests assert the FINAL scheme+path (no double `/v1`) for **BOTH** override AND env-absent SDK-default paths, **for both providers**, via in-process fake transport/handler (the Anthropic override test uses an `http://localhost:<port>` base to prove the scheme is rewritten); no real network, no fn-3 stack.
- **R4:** Each wrapper's DI extension maps the EXACT flat config keys via `IConfiguration[KEY]` (not section binding) + a ctor-override overload; key precedence ctor > flat key (required); base-URL precedence ctor > flat key > SDK default; lazy validation + the named opt-in eager hook; no captive singleton. A test proves the flat keys work with NO config section and NO caller glue.
- **R5:** Wrapper test suites pass against an **in-process fake** mirroring the LiteLLM ai-mock surface (`/v1/chat/completions` + unified `/v1/messages`) — self-contained, NO fn-3 runtime/container dependency.
- **R6:** Wrappers emit OTel GenAI telemetry (named `ActivitySource`/`Meter`, `gen_ai.*`) AND the scaffolded `Api` registers them (`AddSource`/`AddMeter` + OTLP exporter) WITH the required OpenTelemetry package refs in `Api.csproj` (pinned). The exporter target is the **standard `OTEL_EXPORTER_OTLP_ENDPOINT`** env var, defaulting to the fn-2 collector's gRPC endpoint `http://localhost:4317` (the loopback port the collector publishes); a static test asserts the registration uses that env var (not a silent SDK default). Content capture is gated by a named options flag, default OFF; the semconv version + attribute names live in a single constants source.
- **R7:** Plugin-repo NuGet publish workflow (repo's first `.github/`): build/test job path-scoped to `src/**`; publish job gated on `nuget-v*` tags that **asserts the scaffold `$(LlmWrapperVersion)` equals `${GITHUB_REF_NAME#nuget-v}` (fails on mismatch)**, derives the single shared version from the tag, publishes all three via a **deterministic auth selector — `vars.NUGET_TRUSTED_PUBLISHING == 'true'` selects OIDC Trusted Publishing (fail if its login fails), otherwise require `NUGET_API_KEY` (fail if absent); never attempt both** — with `--skip-duplicate` + symbols, pinned actions, and polls each package ID@version restorable before signalling success. Committed `src/` fixtures survive `.gitignore`.
- **R8:** /init-project references the published packages via a scoped `$(LlmWrapperVersion)` property (NOT CPM) and DI-registers them in the scaffolded `Api` via the wrapper extensions, designating + eager-validating the default provider in the composition root (no caller glue). `scaffold_test.sh` asserts STATIC generated artifacts only (offline); the live published-`restore`+`build` is an explicit CI job (fn-4.7) with `needs:` the publish job, after the restorability poll.
- **R9:** Docs updated: scaffolded `docs/config-management.md` (services/env rows + consumers), `_CLAUDE.md`, `README.md`, OTel note, skill `main.md`/`SKILL.md` + `marketplace.json` description, and a repo-root `README.md` documenting `./src/` + the release procedure (bump `LlmWrapperVersion`, tag `nuget-v<ver>`).
- **R10:** The Abstractions package defines the provider-neutral v1 chat shape — request/response DTOs, token usage, finish reason, `CancellationToken`, pinned role enum (`System`/`User`/`Assistant`) — with no provider-SDK dependencies in its public surface. **System-message rule (v1):** at most ONE `System` message, and it must be the FIRST in the ordered list; multiple or non-leading `System` messages are rejected with a clear error (this maps deterministically to Anthropic's top-level `system` param and OpenAI's leading system message — no silent ordering loss). Tested in both wrappers.
- **R11:** DI resolution is unambiguous: each provider registers a **keyed** `IAiChatClient` via the named `Add…ChatClient` extension; the scaffold designates a single default unkeyed `IAiChatClient` and calls the matching named `Validate…OnStart` hook for the default only — no order-dependent collisions, no `IEnumerable` glue, never a boot failure for an unused provider. Non-default provider validation — INCLUDING base-URL structural validation — is lazy and never runs at startup unless that provider is resolved or is the designated default.

## Early proof point
**fn-4.1** validates packaging + the abstraction contract (build, `dotnet pack` ×3, abstractions-as-package-dependency graph, provider-SDK-free surface incl. the pinned role enum + the named DI/hook contract). The other make-or-break validation is **fn-4.3** (Anthropic origin-rewrite handler reaching `/v1/messages` over `http://localhost`, plus the env-absent default path).

## Open questions
- **Package-ID owner prefix.** Concrete `<Owner>` chosen in fn-4.1; nuget.org prefix reservation is a MANUAL release prerequisite (evidence at fn-4.5); unique namespaced IDs suffice if reservation isn't ready.

## Requirement coverage

| Req | Description | Task(s) | Gap justification |
|-----|-------------|---------|-------------------|
| R1  | Three packages pack valid .nupkg/.snupkg w/ README + metadata + SourceLink | fn-4.1 | — |
| R2  | Abstractions published; providers depend on it (shared version) | fn-4.1, fn-4.5 | — |
| R3  | Override + env-absent default tested both providers (in-process fakes); verbatim paths; Anthropic root validated; key required | fn-4.2, fn-4.3 | — |
| R4  | DI: explicit flat-key mapping, key required, base-URL default fallback, lazy + named eager hook, no glue | fn-4.2, fn-4.3 | — |
| R5  | Tests pass vs in-process fake ai-mock surface (no fn-3 dep) | fn-4.2, fn-4.3 | — |
| R6  | OTel wrapper emission + scaffold Api registration + pkg refs | fn-4.4, fn-4.6 | — |
| R7  | Publish CI: path-scoped, pin==tag assert, tag-derived version, OIDC, restorability poll | fn-4.5 | — |
| R8  | Scaffold scoped-property pin + DI wiring + default designation/eager-validate; static scaffold_test; live restore CI job fn-4.7 | fn-4.6, fn-4.7 | — |
| R9  | Docs + repo-root README (incl release procedure) | fn-4.6, fn-4.5 | — |
| R10 | Provider-neutral abstraction shape + pinned role enum + single-leading-System rule, no provider-SDK deps (shape in .1; provider enforcement/tests in .2/.3) | fn-4.1, fn-4.2, fn-4.3 | — |
| R11 | Keyed DI per provider (named extensions) + scaffold default + named eager hook | fn-4.1, fn-4.2, fn-4.3, fn-4.6 | — |

---
satisfies: [R1, R2, R10, R11]
---

## Description
Stand up the .NET home under a NEW top-level `./src/` (sibling to `plugins/`). Three packable projects: **Abstractions** (provider-neutral interface + DTOs + the pinned role enum), **OpenAI** wrapper skeleton, **Anthropic** wrapper skeleton. Publishable metadata + per-package README on all three; providers declare a NuGet dependency on the Abstractions package (shared version). Build + `dotnet pack` emit valid `.nupkg`+`.snupkg` for all three. **Epic early proof point.**

**Size:** M
**Files:** `src/<Solution>.sln`, `src/<Abstractions>/` (csproj + interface + DTOs + role enum + README), `src/<OpenAiWrapper>/`, `src/<AnthropicWrapper>/` (csproj + stub + README each), `src/Directory.Packages.props`, `src/Directory.Build.props` (optional), `.gitignore`.

## Approach
- **v1 abstraction (signatures only):** a provider-neutral chat interface `IAiChatClient` — request (model id; ordered messages with the **role enum `System` / `User` / `Assistant`**; optional max-tokens/temperature), response (content; token usage in/out; finish reason), `CancellationToken`. **Non-streaming v1.** **Zero provider-SDK dependencies** in the public surface. **System-message rule (document it on the request type):** at most ONE `System` message and it must be FIRST; the providers (.2/.3) reject multiple or non-leading `System` messages with a clear error — so the mapping to Anthropic's top-level `system` param is deterministic and loses no ordering.
- **DI consumption contract (documented here for .2/.3/.6 to honor):** providers register a **keyed** `IAiChatClient` (`"openai"`/`"anthropic"`); the scaffold designates the default unkeyed client. No unkeyed registration inside the provider packages (avoids order-dependence). No `IEnumerable` glue.
- **Three published packages, one shared version.** Owner-namespaced IDs `<Owner>.Ai.Abstractions`/`.OpenAI`/`.Anthropic` (choose `<Owner>` here). Providers `<ProjectReference>` Abstractions WITHOUT `PrivateAssets` → pack emits a package dependency.
- **Metadata (all three):** SPDX license; `PackageReadmeFile`→real per-package `README.md` via `<None Pack="true">`; `RepositoryUrl`; `IncludeSymbols`+snupkg; SourceLink; `Deterministic`; CI-only `ContinuousIntegrationBuild`.
- **CPM scoped to `./src/` only.**

## Investigation targets
**Required:**
- `plugins/init-project/templates/src/Api/Api.csproj:13-17` — metadata/PackageReference convention
- `plugins/init-project/templates/src/DataAccess/DataAccess.csproj:13-19` — PrivateAssets pattern (AVOID for abstractions ref)
**Optional:**
- MS Learn: `dotnet pack`, .snupkg, CPM; SourceLink (devblogs)

## Key context
- CPM is new (scope to `./src/`). Memory `template-gitignore-silently-drops`: verify committed fixtures via `git ls-files --error-unmatch`; test from clean `git checkout-index`.

## Acceptance
- [ ] `./src/` solution (Abstractions + OpenAI + Anthropic, `net9.0`) builds clean
- [ ] Abstractions defines the v1 chat shape + **pinned role enum `System`/`User`/`Assistant`** + the documented **single-leading-`System`-message rule**, non-streaming, with NO provider-SDK dependency in its public surface
- [ ] `dotnet pack -c Release` emits `.nupkg`+`.snupkg` for all three with unique owner-namespaced `PackageId`, SPDX license, real per-package README, `RepositoryUrl`, SourceLink, deterministic (CI-only `ContinuousIntegrationBuild`)
- [ ] Provider packages declare a NuGet package dependency on the Abstractions package (verified in `.nuspec`)
- [ ] The keyed-DI consumption contract (keyed per provider + scaffold default; no unkeyed in provider packages) is documented for .2/.3/.6; `<Owner>` chosen; `src/Directory.Packages.props` scoped to `./src/`; committed fixtures survive `.gitignore`

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

---
satisfies: [R1, R2, R10, R13]
---

## Description
Stand up the `./src/` .NET home, the test project, and the abstraction for the single package **ParleyAI** (net10.0). Metadata, Apache-2.0 `LICENSE`+`NOTICE` (both packed), the provider-neutral abstraction (no provider-SDK types in its public surface). Builds, `dotnet test src/ParleyAI.sln` runs, `dotnet pack` emits `ParleyAI.nupkg` + `.snupkg`. **Epic early proof point.**

**Size:** M
**Files:** `src/ParleyAI.sln`, `src/ParleyAI/ParleyAI.csproj`, `src/ParleyAI/Abstractions/*.cs`, `src/ParleyAI/README.md`, `src/ParleyAI.Tests/ParleyAI.Tests.csproj` (xUnit + coverlet, net10.0), `LICENSE`, `NOTICE` (repo root).

## Approach
- **csproj/metadata** (net10.0, `Microsoft.NET.Sdk`): `PackageId=ParleyAI`, `Authors=SoftwareAssassin`, `Copyright`, `PackageLicenseExpression=Apache-2.0`. **Pack BOTH `LICENSE` and `NOTICE` at the nupkg ROOT as files** (`PackagePath=""` — NOT under NuGet's `contentFiles/` convention; alongside the SPDX expression — that is allowed; only `PackageLicenseExpression` + `PackageLicenseFile` together is not). Both live at repo root; pack with explicit relative paths from the csproj (two levels down): `<None Include="..\..\LICENSE" Pack="true" PackagePath="" />` and `<None Include="..\..\NOTICE" Pack="true" PackagePath="" />`. `PackageReadmeFile=README.md` with `<None Include="README.md" Pack="true" PackagePath="" />` (README sits beside the csproj). `RepositoryUrl`, `IncludeSymbols`+`SymbolPackageFormat=snupkg`, SourceLink, `Deterministic`, CI-only `ContinuousIntegrationBuild`. (Do NOT set `IsAotCompatible` — the provider SDKs are not validated AOT-clean and the epic does not require AOT.) Mirror the inline-pin convention at `plugins/init-project/templates/src/Api/Api.csproj:1-24`. Set `<Copyright>`.
- **Solution + test project:** `src/ParleyAI.sln` contains `ParleyAI` + `ParleyAI.Tests` (net10.0, xUnit + `coverlet.collector`, `ProjectReference` to ParleyAI, `IsPackable=false`) so `dotnet test src/ParleyAI.sln` works.
- **Abstraction (signatures only):** `IAiChatClient` (async chat + `CancellationToken`); `ChatRequest` (model id; ordered messages w/ `Role` enum `System`/`User`/`Assistant`; optional max-tokens/temperature) + documented single-leading-`System` rule; `ChatResponse` (content; token usage in/out; finish reason); **`ParleyAIException`** with a public **`ParleyAIErrorCategory` enum** (`RateLimit`, `TokenLimit`, `Authentication`, `InvalidRequest`, `Transient`, `Unknown`), nullable HTTP status, nullable `RetryAfter` (`TimeSpan?`), originating provider key, inner exception; `OperationCanceledException` NOT wrapped. `IAiChatClientFactory.Create(providerKey)`; `ProviderKeys`; options types (base-URL/key, content-capture flag default false, AIMD options — incl. per-category back-off factor/cooldown — resilience toggle). NO provider-SDK types in the public surface.

## Investigation targets
**Required:** `plugins/init-project/templates/src/Api/Api.csproj:1-24`; `plugins/init-project/templates/tests/Api.Tests/Api.Tests.csproj`
**Optional:** MS Learn `dotnet pack`/.snupkg/NuGet license MSBuild/SourceLink

## Key context
- You MAY pack a `LICENSE` content file while using `PackageLicenseExpression` — only `PackageLicenseExpression` + `PackageLicenseFile` is mutually exclusive. Pack paths are RELATIVE to the csproj (LICENSE/NOTICE are two dirs up). Memory `template-gitignore-silently-drops`: verify committed fixtures via `git ls-files --error-unmatch`.

## Acceptance
- [ ] `src/ParleyAI.sln` (`ParleyAI` + `ParleyAI.Tests`, net10.0) builds; `dotnet test src/ParleyAI.sln` runs
- [ ] `dotnet pack src/ParleyAI/ParleyAI.csproj -c Release -o ./artifacts` → `.nupkg` + `.snupkg` with `PackageId=ParleyAI`, `Authors=SoftwareAssassin`, `Copyright`, `Apache-2.0`; **LICENSE + NOTICE + README all packed at the nupkg ROOT** (explicit `<None Pack="true" PackagePath="">`, NOT `contentFiles/`); `RepositoryUrl`; SourceLink; deterministic; `ParleyAI.Tests` `IsPackable=false`; no `PackageLicenseFile`
- [ ] Abstraction defined incl. `ParleyAIException` + `ParleyAIErrorCategory`, nullable status + `RetryAfter`, provider key, cancellation pass-through; AIMD options include per-category back-off fields; public surface carries NO provider-SDK types
- [ ] Committed `src/` fixtures survive `.gitignore`

## Done summary
Stood up the single ParleyAI package (net10.0): solution + test project, the provider-neutral abstraction (IAiChatClient, chat DTOs, Role/FinishReason enums, ParleyAIException + ParleyAIErrorCategory, factory, ProviderKeys, options with per-category AIMD back-off), Apache-2.0 LICENSE/NOTICE, and csproj metadata that packs valid .nupkg + .snupkg (LICENSE/NOTICE/README at the nupkg root, SourceLink, deterministic). Verified build/test/pack from a clean git export; codex review SHIP.
## Evidence
- Commits: 6749b25d967bcf0696822a18040788101c5ec505, f7fda41fe6605e43bd9290b55481cff159324926
- Tests: dotnet test src/ParleyAI.sln, dotnet pack src/ParleyAI/ParleyAI.csproj -c Release -o ./artifacts
- PRs:
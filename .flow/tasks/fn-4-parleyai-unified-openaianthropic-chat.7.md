---
satisfies: [R13]
---

## Description
Re-target the scaffolded .NET projects + toolchain from **net9.0 to net10.0** so they can reference ParleyAI. Mechanical sweep; a fresh scaffold builds + tests green on net10. Independent of the ParleyAI package build. Touches fn-2-authored templates — fn-4 owns the bump.

**Size:** M
**Files:** the 9 scaffold csproj, `.config/dotnet-tools.json`, `.devcontainer/devcontainer.json`, `.github/workflows/ci.yml`, scaffold tests.

## Approach (exact edit sites)
- **TFM `net9.0`→`net10.0`** in: `plugins/init-project/templates/src/{Api,Framework,DataAccess,BusinessLogic,SampleApp}/*.csproj` + `templates/tests/{Api,Framework,BusinessLogic,DataAccess}.Tests/*.csproj`.
- **SDK-major package pins + ".NET 9" comments → net10, as ONE consistent version set:** use EXACT pins everywhere (no wildcards/ranges) sharing the same `10.0` major.minor. The **Microsoft-owned** packages — `Microsoft.AspNetCore.Authentication.JwtBearer` (`Api.csproj:13-14`), `Microsoft.EntityFrameworkCore*` (`Api.csproj:17`), `Microsoft.EntityFrameworkCore.Design` (`DataAccess.csproj:16`) — and the `dotnet-ef` tool (`.config/dotnet-tools.json:6`) share ONE concrete `10.0.x` patch chosen once. `Npgsql.EntityFrameworkCore.PostgreSQL` (`DataAccess.csproj:13-14`) is independently versioned by Npgsql, so it uses the nearest available exact `10.0.x` (same major.minor, patch may differ). Bump the prose comments too.
- `templates/.config/dotnet-tools.json:6` `dotnet-ef` → the same exact net10 version (`rollForward:false`).
- `templates/.devcontainer/devcontainer.json:4` comment + `:7` image `dotnet:1-9.0`→`1-10.0`.
- `templates/.github/workflows/ci.yml:34-39` comment, step name, `dotnet-version: "9.0.x"`→`"10.0.x"`.
- Add a `net10.0` TFM assertion + a "no floating/range versions, shared platform major.minor" check in `plugins/init-project/tests/scaffold_test.sh`; fix any net9 assertion.

## Investigation targets
**Required:** the edit sites above; `plugins/init-project/tests/scaffold_test.sh` assertion style
**Optional:** .NET 10 what's-new; fn-2.9/.4/.13

## Acceptance
- [ ] All 9 scaffold `.csproj` target `net10.0`; Microsoft-owned ASP.NET/EF packages + `dotnet-ef` share ONE exact `10.0.x` patch; `Npgsql.EntityFrameworkCore.PostgreSQL` uses the nearest exact `10.0.x`; all share `10.0` major.minor; no wildcards/ranges; ".NET 9" comments bumped
- [ ] devcontainer image `dotnet:1-10.0`; `ci.yml` `setup-dotnet` `10.0.x` (+ comment/step-name)
- [ ] A freshly scaffolded project `dotnet build` + `dotnet test` green on net10.0
- [ ] `scaffold_test.sh` asserts `net10.0` + no floating/range versions + consistent platform major.minor; no stale `net9`/".NET 9" strings remain

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

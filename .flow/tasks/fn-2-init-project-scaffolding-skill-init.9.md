---
satisfies: [R10, R26]
---

## Description
Scaffold the **.NET solution**: `src/system.sln` referencing each per-component `.csproj`, layered, with `DataAccess` holding the EF Core `DbContext` (migrations + RLS land in fn-2….11). Each .NET project is its own `src/<component>/` + `systems[]` entry.

**Size:** M
**Files:** `templates/src/system.sln`; `templates/.config/dotnet-tools.json` (pinned `dotnet-ef`); `templates/src/{Framework,DataAccess,BusinessLogic,Api,SampleApp}/<Project>.csproj` (+ minimal source); per-project test projects at `templates/tests/<Component>.Tests/` (xUnit + `coverlet.msbuild`, referenced by the .sln); `DataAccess` `DbContext` stub

## Approach (from docs-scout)
- Single solution **`src/system.sln`** referencing each `src/<component>/` `.csproj`; layering `Api → BusinessLogic → DataAccess → Framework` (project references only down the stack). `SampleApp` (console) = clearly-marked removable demo referencing the layers.
- **DataAccess**: add `Npgsql.EntityFrameworkCore.PostgreSQL` + `Microsoft.EntityFrameworkCore.Design` (pin provider major == TFM major, .NET 9); a `DbContext` configured `UseNpgsql(<conn from env>)`. Migrations themselves are fn-2….11.
- **Api**: HTTP API project skeleton (JWT/Keycloak wiring is fn-2….11).
- **Test projects + coverage:** scaffold a test project per testable .NET project at **`tests/<Component>.Tests/`** (top-level `tests/`, NOT `src/` — so they are not mistaken for `src/<component>` systems components), xUnit, wired with **`coverlet.msbuild`** so the CI gate (fn-2….13, `dotnet test /p:CollectCoverage=true /p:Threshold=100 ...`) has real tests to measure; keep pure logic testable (Humble-Object) per the tdd standard. The `tests/` exception is documented in `_CLAUDE.md` (fn-2….2).
- Keep each project minimal but buildable (`dotnet build src/system.sln` succeeds).

## Investigation targets
**Required:**
- `.flow/specs/fn-2-...md` — R10 component list + R26 solution layering
- `src/init-project/templates/docs/tdd.md` (fn-2….8) — coverage expectations for .NET (coverlet)

## Acceptance
- [ ] `src/system.sln` references Framework, DataAccess, BusinessLogic, Api, SampleApp (each `src/<component>/`)
- [ ] Layered project refs Api→BusinessLogic→DataAccess→Framework; SampleApp marked removable
- [ ] DataAccess references Npgsql EF Core provider + Design; has a `DbContext` using `UseNpgsql`
- [ ] `.config/dotnet-tools.json` pins `dotnet-ef`; DataAccess ships an `IDesignTimeDbContextFactory` that reads an exported migrator connection string (so `dotnet ef` works without app startup/auth, using the `migrator` role)
- [ ] `dotnet build src/system.sln` succeeds on a freshly scaffolded project (smoke)
- [ ] Per-project test projects scaffolded under `tests/<Component>.Tests/` (NOT `src/`) + `coverlet.msbuild` wired; `dotnet test` runs and coverage is measurable (so fn-2….13's 100% gate is meaningful)

## Done summary
Authored the build-time-complete .NET starter solution as scaffold templates: a single `src/system.sln` referencing five layered `src/<component>/` projects (Framework, DataAccess, BusinessLogic, Api, removable SampleApp) plus four `tests/<Component>.Tests/` xUnit projects wired with coverlet.msbuild. DataAccess ships `PlatformDbContext` (UseNpgsql) + Npgsql/EF-Design package refs + an `IDesignTimeDbContextFactory` reading `MIGRATOR_CONNECTION_STRING`, with `dotnet-ef` pinned in `.config/dotnet-tools.json`. Verified end-to-end on the host (SDK 10, net9.0 roll-forward): `dotnet build` succeeds, `dotnet test` passes 8/8 with measurable coverage, and `dotnet ef migrations list` exercises the design-time factory. scaffold_test.sh gained 27 structural assertions (90/90 green); Codex impl-review verdict SHIP.
## Evidence
- Commits: 461e19f11d898c7d220b5cf36dd95134639cfbee
- Tests: bash src/init-project/tests/scaffold_test.sh (90 passed, 0 failed), dotnet build src/system.sln (9/9 projects, 0 errors), DOTNET_ROLL_FORWARD=Major dotnet test src/system.sln (8/8 passed, coverlet coverage measurable), dotnet tool restore + dotnet ef migrations list (design-time factory exercised: reads MIGRATOR_CONNECTION_STRING, builds PlatformDbContext, fail-fast verified when unset)
- PRs:
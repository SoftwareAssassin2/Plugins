---
satisfies: [R6, R8, R9]
---

## Description
Wire the published `ParleyAI` into the (net10) scaffold: `Api.csproj` PackageReference + OpenTelemetry package refs; `Program.cs` keyed DI (both providers, no default, example usage) + OTel registration; scaffolded docs; static `scaffold_test`. **Preconditions:** fn-4.4 (`AddParleyAi`/composition/factory) + fn-4.5 (default AIMD) + fn-4.6 (source/meter names) + fn-4.7 (net10) + fn-4.8 (`Directory.Build.props` + published) + fn-3.1/.2/.3 (env contract + ai-mock) DONE. Does NOT touch `build-config.sh`/`config.json` services.

**Size:** M
**Files:** `plugins/init-project/templates/src/Api/Api.csproj`, `templates/src/Api/Program.cs`, `plugins/init-project/tests/scaffold_test.sh`, `templates/docs/config-management.md`, `templates/README.md`, `plugins/init-project/main.md`, `plugins/init-project/SKILL.md`, `.claude-plugin/marketplace.json`.
## Approach
- **Api.csproj:** `<PackageReference Include="ParleyAI" Version="$(LlmWrapperVersion)" />` (property from `Directory.Build.props` created in .8); add `OpenTelemetry.Extensions.Hosting` + `OpenTelemetry.Exporter.OpenTelemetryProtocol` (pinned inline). TFM net10 (from .7).
- **Program.cs** (~`:16-66`): `AddParleyAi(...)` (the public no-glue API; keyed, NO default) + an example-usage comment showing both providers in one method (`[FromKeyedServices("openai")]` + `[FromKeyedServices("anthropic")]` or the factory). Register `AddOpenTelemetry().WithTracing(..).WithMetrics(..)` adding ParleyAI's `ActivitySource`/`Meter` names (from .6 — both literally `"ParleyAI"`, surfaced as the public constants `ParleyAI.Telemetry.ParleyAiTelemetry.ActivitySourceName` + `ParleyAiTelemetry.MeterName`; reference the constants, do NOT hardcode the literal — a name mismatch silently no-ops all telemetry) + an OTLP exporter registered on BOTH the tracing AND metrics builders (`WithTracing(t => t.AddSource(ParleyAiTelemetry.ActivitySourceName).AddOtlpExporter())` AND `WithMetrics(m => m.AddMeter(ParleyAiTelemetry.MeterName).AddOtlpExporter())`, or the cross-signal `UseOtlpExporter()`) <!-- Updated by plan-sync: fn-4...6 surfaced source/meter names as ParleyAiTelemetry.ActivitySourceName/.MeterName (namespace ParleyAI.Telemetry), both "ParleyAI" --> with **NO explicit endpoint** — the OTel SDK default `http://localhost:4317` is correct: fn-2's `Api` runs as a process (`dotnet run`) in the SAME place the compose stacks run — host, or inside the dev container via docker-in-docker — and the collector publishes its gRPC port to that same loopback (`127.0.0.1:4317`), so the dev-container-run Api reaches it at `localhost:4317` too (document this topology in the code comment). IF a deployment instead puts the Api in a SEPARATE container from the collector, set `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317` — but **containerizing the Api is OUT OF fn-4 scope and requires no env emission / no `build-config` change here** (the standard env var is the override mechanism if/when needed). Wrappers read fn-3's flat env vars (no manual glue); content capture default OFF.
- build-config ALREADY emits the four LLM env vars (fn-3.2) — consume; do NOT edit `build-config.sh`/`config.json` services.
- **Coverage:** 100% gate — glue tested or `[ExcludeFromCodeCoverage]` (Program.cs already excluded).
- **`scaffold_test.sh` (STATIC/offline):** assert `PackageReference Include="ParleyAI" Version="$(LlmWrapperVersion)"` + `Directory.Build.props` present + OTel pkg refs land + `Program.cs` registers `AddParleyAi` + `AddOpenTelemetry` with the ParleyAI source on tracing + meter on metrics + an OTLP exporter on BOTH signals + net10 TFM. Live restore is .10.
- **Docs:** `config-management.md` §4 names `ParleyAI` as the LLM-env consumer (do NOT add openai/anthropic `config.json` service entries — fn-3 owns the services model); light `README.md` note; `SKILL.md` + `marketplace.json` descriptions gain "pre-wired ParleyAI AI client (OpenAI/Anthropic), net10"; `main.md` note.

## Investigation targets
**Required:** `templates/src/Api/Api.csproj` + `Program.cs:16-66`; `plugins/init-project/tests/scaffold_test.sh`; `fn-4...6` (source/meter names) + `.8` (`$(LlmWrapperVersion)`); fn-3 `.1`/`.2`/`.3` (precondition)
**Optional:** `templates/docs/config-management.md:205-208`; `templates/src/otel-collector/otel-collector-config.yaml`

## Acceptance
- [ ] **Preconditions verified:** fn-4.4 + fn-4.5 + fn-4.6 + fn-4.7 + fn-4.8 + fn-3.1/.2/.3 DONE
- [ ] `Api.csproj` references `ParleyAI` via `Version="$(LlmWrapperVersion)"` + OTel pkg refs (pinned); net10
- [ ] `Program.cs` uses `AddParleyAi` (keyed, NO default; example shows both in one method) + `AddOpenTelemetry` registering the ParleyAI `ActivitySource` (`ParleyAiTelemetry.ActivitySourceName`) on tracing AND `Meter` (`ParleyAiTelemetry.MeterName`) on metrics — both via the public constants, not hardcoded literals — with an OTLP exporter on BOTH signals at the SDK default (host-run collector loopback `:4317`); container override documented as out-of-scope note (no env emission / no build-config touch); glue covered or bootstrap-excluded
- [ ] `scaffold_test.sh` asserts STATIC artifacts only; live restore deferred to .10
- [ ] Docs updated: `config-management.md`, `README.md`, `SKILL.md`/`main.md`/`marketplace.json`; does NOT modify `build-config.sh`/`config.json` services

## Done summary
Wired the published ParleyAI NuGet package into the net10 /init-project scaffold: Api.csproj PackageReference via $(LlmWrapperVersion) + pinned OpenTelemetry pkg refs, Program.cs keyed-DI AddParleyAi (no default) + AddOpenTelemetry registering ParleyAI's ActivitySource/Meter (via public constants) with an OTLP exporter on both signals at the SDK-default loopback, plus static scaffold_test assertions and docs (config-management.md, README, SKILL.md, marketplace.json).
## Evidence
- Commits: bb7554c801de31be8f27fa61e76c2dd087e3efbe
- Tests: bash plugins/init-project/tests/scaffold_test.sh (static offline scaffold assertions)
- PRs:
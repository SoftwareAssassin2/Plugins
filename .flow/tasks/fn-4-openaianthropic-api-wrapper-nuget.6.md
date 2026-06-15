---
satisfies: [R6, R8, R9, R11]
---

## Description
Wire the **published** wrapper packages into the /init-project scaffold, designate the default LLM provider in the composition root (invoking the default provider's eager-validation hook), register the wrappers' OpenTelemetry sources in the scaffolded `Api` (with the required OTel package refs), and update docs. **CONSTRAINTS:** (a) this task is STATIC/offline and does NOT require the packages to be published — publish-before-reference is enforced solely by fn-4.7's live restore; (b) **precondition gate** — fn-3.2 + fn-3.1 DONE before start (for the env contract the DI wiring reads). Must NOT re-author `build-config.sh`, the services model, or the mock stack.

**Size:** M (split docs out if it grows past one iteration)
**Files:** `plugins/init-project/templates/src/Api/Api.csproj`, `plugins/init-project/templates/src/Api/Program.cs`, `plugins/init-project/tests/scaffold_test.sh`, `plugins/init-project/templates/docs/config-management.md`, `plugins/init-project/templates/_CLAUDE.md`, `plugins/init-project/templates/README.md`, `plugins/init-project/main.md`, `plugins/init-project/SKILL.md`, `.claude-plugin/marketplace.json`, repo-root `README.md` (cross-ref). NOTE: `plugins/init-project/templates/Directory.Build.props` is CREATED by fn-4.5 — this task CONSUMES it, does not author it.

## Approach
- **Version pin (NOT CPM):** the scoped `<LlmWrapperVersion>` lives in `plugins/init-project/templates/Directory.Build.props` (created by fn-4.5); here, `Api.csproj` references both wrapper packages with `Version="$(LlmWrapperVersion)"`. Do NOT add `Directory.Packages.props`/CPM to the scaffold.
- **DI + default provider (R11):** call `AddOpenAiChatClient`/`AddAnthropicChatClient` in `templates/src/Api/Program.cs` (each registers its keyed `IAiChatClient`; wrappers read fn-3's flat env vars — NO manual env glue). Then **designate the default**: register the unkeyed `IAiChatClient` bound to the chosen default (default OpenAI; one-line switch comment) AND **call only that provider's `Validate…ChatClientOnStart` hook** so the default validates eagerly. Non-default keyed providers stay lazy — their validation, INCLUDING base-URL structural validation, must NOT run at startup unless resolved.
- **OTel package refs (R6 — required to compile):** add `OpenTelemetry.Extensions.Hosting` + `OpenTelemetry.Exporter.OpenTelemetryProtocol` (+ any used instrumentation) to `templates/src/Api/Api.csproj`, pinned inline (convention `Api.csproj:13-17`).
- **OTel registration:** `AddOpenTelemetry().WithTracing(..).WithMetrics(..)` adding the wrappers' `ActivitySource`/`Meter` names (fn-4.4) + an OTLP exporter whose endpoint is the **standard `OTEL_EXPORTER_OTLP_ENDPOINT`** env var, defaulting to the fn-2 collector's gRPC `http://localhost:4317` (the loopback port the collector publishes per `templates/src/otel-collector/otel-collector-config.yaml`). Leave content capture at its default-OFF flag (fn-4.4).
- build-config ALREADY emits the env vars (fn-3.2) — consume; do NOT touch `build-config.sh`.
- **Coverage:** 100% line+branch; DI/OTel glue tested or `[ExcludeFromCodeCoverage]` (Program.cs already excluded).
- **Tests OFFLINE:** `scaffold_test.sh` asserts STATIC artifacts only — `Version="$(LlmWrapperVersion)"` refs present, `Api.csproj` OTel pkg refs land, `Program.cs` registers keyed clients + default (+ eager-validation call) + OTel with the `OTEL_EXPORTER_OTLP_ENDPOINT`-based exporter (assert the endpoint env var/value is used, not a silent SDK default). NO network restore here (fn-4.7 owns it).
- **Docs:** services/env rows in `config-management.md` (~`:94-208`); `_CLAUDE.md`; scaffolded `README.md`; OTel note; skill `main.md`/`SKILL.md` + `marketplace.json` description; cross-ref repo-root README.

## Investigation targets
**Required:**
- `plugins/init-project/templates/src/Api/Api.csproj` + `Program.cs:21-22,32-37` — PackageReference + DI/config pattern
- `plugins/init-project/tests/scaffold_test.sh` — static landed-file assertion style
- `plugins/init-project/templates/docs/config-management.md:94-208` — services schema table
- fn-3 tasks `.2`/`.1` (precondition); `fn-4-openaianthropic-api-wrapper-nuget.4` — ActivitySource/Meter names; `.2`/`.3` — the eager-validation hook
**Optional:**
- `plugins/init-project/scaffold.sh:93-97,154-162` — copy + config-merge

## Acceptance
- [ ] **Precondition verified before start:** fn-3.2 + fn-3.1 DONE
- [ ] `Api.csproj` refs both wrapper packages with `Version="$(LlmWrapperVersion)"`, consuming the `plugins/init-project/templates/Directory.Build.props` created by fn-4.5 (no `Directory.Packages.props` in the scaffold)
- [ ] `Api.csproj` gains the required OpenTelemetry package refs (pinned inline) so OTel registration compiles
- [ ] `Program.cs` registers both keyed clients (no manual env glue), designates the default unkeyed `IAiChatClient` + invokes ONLY the default provider's `Validate…ChatClientOnStart` hook (non-default providers — incl their base-URL validation — stay lazy, never validated at startup), and registers `AddOpenTelemetry` with the wrappers' source/meter names + OTLP exporter; glue covered or bootstrap-excluded
- [ ] `scaffold_test.sh` asserts STATIC generated props/refs/registration only (offline); live restore deferred to fn-4.7
- [ ] Docs updated: `config-management.md` services rows, `_CLAUDE.md`, scaffolded `README.md`, OTel note, `main.md`/`SKILL.md` + `marketplace.json` description, repo-root `README.md`
- [ ] Does NOT modify `build-config.sh`/services model/mock stack

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

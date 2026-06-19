---
satisfies: [R6]
---

## Description
Instrument both providers with OpenTelemetry GenAI telemetry on a named `ActivitySource`/`Meter` — `gen_ai.*` spans + the pinned metric instruments. Content capture gated by a named options flag, default OFF. Library side only; the scaffolded `Api`'s OTel registration is .9.

**Size:** M
**Files:** `src/ParleyAI/ParleyAI.csproj` (add `System.Diagnostics.DiagnosticSource` if a ref is needed for `Meter`/`ActivitySource`; OTLP exporter packages are the scaffold's, registered in .9), `src/ParleyAI/Telemetry/*`, `src/ParleyAI.Tests/Telemetry/*`

## Approach
- Telemetry is instrumented **INSIDE the provider client classes** (`OpenAiChatClient`/`AnthropicChatClient`, on the `.2`/`.3` call paths) — NOT as a decorator, so it never competes with AIMD's single decoration hook (.4/.5); the two are independent layers.
- A `static readonly ActivitySource` + `Meter` with **stable, documented public names** (.9 registers them by exact name — a mismatch silently no-ops). Span: name `chat {model}`, attrs `gen_ai.operation.name=chat`, `gen_ai.provider.name` (`openai`/`anthropic`; note older `gen_ai.system`), `gen_ai.request.model`, response finish reasons.
- **Pinned metric instruments:** `gen_ai.client.operation.duration` (Histogram, unit `s`) + `gen_ai.client.token.usage` (Histogram, unit `{token}`, attr `gen_ai.token.type` input/output). Tests assert the EXACT instrument names + units.
- Content capture gated by the named options flag (from .1), default `false`. GenAI semconv is **experimental** — keep the pinned semconv version + all `gen_ai.*` attribute-name constants in ONE constants source (note `OTEL_SEMCONV_STABILITY_OPT_IN`). The ParleyAI library only DEFINES + emits on the source/meter; the OTLP exporter wiring is the scaffold's (.9) — ParleyAI takes no OTLP exporter dependency itself.

## Investigation targets
**Required:**
- `fn-4-parleyai-unified-openaianthropic-chat.2` + `.3` — provider call paths; content-capture option from `.1`
- OTel semconv: gen-ai spans + metrics (names/units/attrs); OTel .NET `ActivitySource`/`Meter`
**Optional:**
- `templates/src/otel-collector/otel-collector-config.yaml` — the OTLP endpoint .9 exports to

## Acceptance
- [ ] Both providers emit spans on a named, publicly-documented `ActivitySource` with `gen_ai.*` attrs — instrumentation lives INSIDE the provider classes (not a decorator; the AIMD hook stays free)
- [ ] Pinned metric instruments on a named `Meter`: `gen_ai.client.operation.duration` (Histogram, `s`) + `gen_ai.client.token.usage` (Histogram, `{token}`, `gen_ai.token.type`) — tests assert exact names/units
- [ ] Content capture gated by a named options flag, default OFF; ParleyAI takes no OTLP-exporter dependency (that's .9)
- [ ] Pinned semconv version + `gen_ai.*` constants in ONE source; `ActivitySource`/`Meter` names documented for .9

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

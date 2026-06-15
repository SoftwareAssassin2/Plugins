---
satisfies: [R6]
---

## Description
Instrument the **wrapper libraries** with OpenTelemetry GenAI telemetry: emit on the wrapper's own named `ActivitySource`/`Meter` using GenAI semantic-convention attributes, so any consumer that registers those sources sees traced/metered LLM calls. Prompt/completion **content capture is opt-in and OFF by default** (PII/secret hazard). **Scope note:** this task ships the library-side emission + a documented, stable public name for the `ActivitySource`/`Meter`; the SCAFFOLD-side registration (`AddOpenTelemetry`/`AddSource`/`AddMeter` + OTLP exporter in the generated `Api`) is fn-4.6.

**Size:** M
**Files:** `src/<Abstractions>/` (telemetry helper) and/or each wrapper's call path, `src/*.Tests/*`

## Approach
- Define a `static readonly ActivitySource` + `Meter` with **stable, documented public names** (fn-4.6 registers them by exact name — a mismatch silently no-ops). Span attrs: `gen_ai.system`, `gen_ai.request.model`, `gen_ai.usage.input_tokens`/`output_tokens`, `gen_ai.response.finish_reasons`.
- **Pin the v1 metric contract** (don't leave "some metric exists"): name the instruments, types, and units per the GenAI semconv — e.g. `gen_ai.client.token.usage` (Histogram, unit `{token}`, with `gen_ai.token.type` in/out) and `gen_ai.client.operation.duration` (Histogram, unit `s`), each carrying `gen_ai.system` + `gen_ai.request.model`. Tests assert these exact instrument names/units, not merely that a metric was emitted.
- GenAI semconv is **experimental** — keep the pinned semconv version string + all `gen_ai.*` attribute-name constants in ONE constants source (e.g. a single internal static class), so a convention bump is a one-file change.
- Content capture (prompts/completions/tool args) is gated by a **named public options flag** (e.g. `CaptureMessageContent`/`CaptureContent`) that **defaults to `false`**; document the exact property name (fn-4.6 leaves it at the default).

## Investigation targets
**Required:**
- `fn-4-openaianthropic-api-wrapper-nuget.2` + `.3` — the wrapper call paths to instrument
- OTel semconv: gen-ai spans/metrics (attribute names); OTel .NET (ActivitySource/Meter)
**Optional:**
- `plugins/init-project/templates/src/otel-collector/otel-collector-config.yaml:11-48` — the OTLP endpoints fn-4.6 will export to

## Acceptance
- [ ] Both wrappers emit traces on a **named, publicly documented** `ActivitySource` with `gen_ai.*` span attributes, AND the pinned metric instruments (`gen_ai.client.token.usage` Histogram `{token}`, `gen_ai.client.operation.duration` Histogram `s`) on a named `Meter` — tests assert the exact instrument names/units
- [ ] Prompt/completion content capture is gated by a named public options flag (documented name) that defaults to `false`
- [ ] Pinned semconv version string + `gen_ai.*` attribute-name constants live in ONE constants source
- [ ] Emission verified with an in-process listener/exporter in tests (spans + metrics asserted); the source/meter names are documented for fn-4.6 to register

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

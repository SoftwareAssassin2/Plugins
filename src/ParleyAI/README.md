# ParleyAI

A single .NET (net10.0) NuGet package providing a unified, provider-agnostic
non-streaming chat client over the **OpenAI** and **Anthropic** APIs.

One package contains everything: the provider-neutral abstraction
(`IAiChatClient`), the OpenAI and Anthropic implementations, keyed DI extensions,
OpenTelemetry GenAI instrumentation, and an adaptive AIMD rate optimizer. It depends
on the official OpenAI .NET SDK and `Anthropic.SDK`; consumers receive both
transitively.

## Why

- One provider-agnostic interface across OpenAI and Anthropic.
- Base-URL / key override so the same code targets a local mock, local Ollama, or
  real cloud.
- Keyed DI registration with explicit per-provider selection — no default provider.
- OpenTelemetry GenAI telemetry.
- An adaptive AIMD rate optimizer that self-tunes throughput to your token/rate plan.

## Status

`v1` is **non-streaming chat only** (roles System / User / Assistant). Streaming,
embeddings, batch, files, and tool-calling are out of scope.

## License

Apache-2.0. See `LICENSE` and `NOTICE` (both packed in the NuGet package).

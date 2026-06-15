---
satisfies: [R3, R4, R5, R10, R11]
---

## Description
Implement the **Anthropic wrapper** over `Anthropic.SDK` (tghamm), implementing `IAiChatClient`. Expose `AddAnthropicChatClient` (keyed, lazy) + `ValidateAnthropicChatClientOnStart` (opt-in eager hook). Retarget the SDK's absolute `api.anthropic.com` URIs via a **`DelegatingHandler` that rewrites the full request ORIGIN (scheme + host + port)** from `ANTHROPIC_BASE_URL` (validated host root) preserving the path. Map the role enum (System→top-level `system` param). Tests cover BOTH override and env-absent paths via in-process fakes, self-contained. Make-or-break validation.

**Size:** M
**Files:** `src/<AnthropicWrapper>/*`, `src/<AnthropicWrapper>.Tests/*`

## Approach
- PRESENT `ANTHROPIC_BASE_URL` ⇒ a `DelegatingHandler` on the DI `HttpClient` rewrites each request URI's full ORIGIN — **scheme + host + port** (NOT just host/port: the SDK defaults to `https`, so an `http://localhost` mock needs the scheme rewritten too) — to the configured base, preserving path + query; `new AnthropicClient(apiKey, client: httpClient)`. ABSENT ⇒ no rewrite handler ⇒ SDK default `api.anthropic.com` (no host hardcoded in shipped code). Wrapper OWNS the `HttpClient` via the typed-client factory; never per-call `new`.
- **`ANTHROPIC_BASE_URL` structural validation:** absolute URI, no query/fragment, path empty or `/` (reject `/v1` — SDK owns the path; fail fast with a clear message).
- **API key required** from ctor or `IConfiguration["ANTHROPIC_API_KEY"]` (non-empty) — no SDK-default fallback.
- **Named DI contract (from fn-4.1):** `AddAnthropicChatClient(…)` registers a **keyed** `IAiChatClient` (`"anthropic"`) + typed client, lazy validation, exact flat-key mapping (NOT section binding) + ctor overload; `ValidateAnthropicChatClientOnStart(…)` opts into eager validation. No captive singleton; no caller glue; no unkeyed registration.
- **Role mapping:** System→top-level `system` param (NOT a message); User→user; Assistant→assistant; test each. Enforce the single-leading-`System` rule (at most one `System`, must be first) — reject multiple/non-leading with a clear error; test both the valid mapping and the rejection (deterministic, no ordering loss).
- Pin `Anthropic.SDK` centrally in `src/Directory.Packages.props`.
- **Tests (in-process fakes, no real network, no fn-3 stack):** (a) override — with an **`http://localhost:<port>`** base, the DI keyed client's final request is `http://localhost:<port>/v1/messages` (proves scheme+host+port rewritten, path preserved, no double `/v1`); (b) env-absent — request targets `https://api.anthropic.com` asserted at the handler/URI level (test fixture may name the host; production grep excludes `*.Tests`); (c) reject `ANTHROPIC_BASE_URL` with a path/query/fragment; (d) `ValidateAnthropicChatClientOnStart` fails fast on a missing key.

## Investigation targets
**Required:**
- `fn-4-openaianthropic-api-wrapper-nuget.1` — `IAiChatClient`, role enum, named DI/hook contract
- tghamm/Anthropic.SDK README + DeepWiki — absolute-URI behavior; `client:` injection + disposal ownership
**Optional:**
- MS Learn `DelegatingHandler` / keyed DI; LiteLLM unified `/v1/messages` docs

## Acceptance
- [ ] Implements `IAiChatClient`; `AddAnthropicChatClient` registers a **keyed** (`"anthropic"`) client (+ typed client), no unkeyed; `ValidateAnthropicChatClientOnStart` exposed
- [ ] PRESENT `ANTHROPIC_BASE_URL` ⇒ `DelegatingHandler` rewrites the full origin (scheme+host+port), path preserved (proven with an `http://localhost` base); ABSENT ⇒ SDK default; no hardcoded host in shipped code; `ANTHROPIC_BASE_URL` structurally validated as root (reject path/query/fragment)
- [ ] API key required from ctor or flat `ANTHROPIC_API_KEY` (presence-validated, no SDK-default fallback)
- [ ] DI maps exact flat keys explicitly (no section binding); lazy + named eager hook; correct `HttpClient` lifetime (no captive singleton, no per-call `new`); no caller glue
- [ ] Role enum maps correctly incl System→top-level `system` param (per-role test); single-leading-`System` rule enforced (multiple/non-leading rejected; tested); BOTH paths tested with in-process fakes (override reaches `/v1/messages`; env-absent targets `api.anthropic.com` at the URI level), no real network/fn-3 dependency

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

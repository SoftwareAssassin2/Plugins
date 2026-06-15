# Local LLM mock stack (opt-in)

This standard governs the **opt-in, local-dev-only LLM gateway** under
`etc/local-llm/`. It lets the app's outbound LLM calls hit a **local gateway**
instead of the real paid/cloud providers — for fast, free, deterministic tests
and offline development. Read it whenever you touch the local LLM stack, switch
between mock and real inference, choose a model, or remove the stack.

## 1. What it is and why

When a developer runs a scaffolded project locally, the `Api` talks to two
external `services{}` endpoints — `claude-api` (Anthropic-compatible) and
`openai-api` (OpenAI-compatible). By default those point at the real providers.
The local LLM mock stack lets you **repoint them at a local gateway** so the same
app code, with no edits, talks to a local model (or a canned mock) instead.

The stack is two containers behind one gateway:

```
app (OpenAI SDK)    ─┐
                     ├─►  LiteLLM proxy  ──►  Ollama  ──►  model
app (Anthropic SDK) ─┘    127.0.0.1:4000        :11434
                          /v1/chat/completions   (OpenAI surface)
                          /v1/messages           (unified Anthropic surface)
                          /v1/embeddings         (OpenAI surface, opt-in)
```

- **LiteLLM proxy** — the single gateway, published on **loopback only**
  (`127.0.0.1:4000`; a dev-only unauthenticated gateway must never bind all
  interfaces). It hosts both the OpenAI `/v1/chat/completions` surface and the
  **unified Anthropic `/v1/messages`** surface (not the raw `/anthropic`
  passthrough, which would forward to the real `api.anthropic.com`), translating
  both formats to one backend. It runs with **no master key** — `sk-local-mock`
  exists only because SDK clients reject an empty key.
- **Ollama** — the inference engine (real models via GGUF/llama.cpp), reachable
  only by LiteLLM over the shared Docker network. The app never talks to Ollama
  directly. It has **no host port**.

No local engine speaks the Anthropic format natively, so LiteLLM is required for
`/v1/messages`. Ollama is chosen over LM Studio because it is container-native.

**Classification — internal dev tooling, not a system component.** Like the
observability stack (Grafana/Prometheus/OTel), this is compose-managed local dev
tooling brought up by `./system.sh up`. It is **explicitly NOT a `config.json`
`systems[]` component** (nothing deploys it) and **NOT itself a `services{}`
external dependency** — it *backs* the always-present `claude-api`/`openai-api`
services in local dev by repointing their `base_url`. See `docs/config-management.md`
§4 for the config schema and the dev-tooling classification.

## 2. Two profiles: `ai` (real) vs `ai-mock` (deterministic mock)

The stack exposes two operating modes, selected purely by **compose profile** —
no app-code edits, identical base URL across both; only the active profile
differs. The default `./system.sh up` activates **neither** profile, so the stack
starts nothing unless you opt in explicitly.

| Profile | Containers | Config mounted | Use for |
|---|---|---|---|
| `--profile ai-mock` | LiteLLM only (Ollama **not** started) | committed static `litellm/config.mock.yaml` (a canned `mock_response`) | CI / tests — fast, free, deterministic |
| `--profile ai` | LiteLLM + Ollama + a one-shot model-pull | the gitignored, `build-config`-stamped `litellm/config.yaml` | manual dev / demos with real local inference |

Activate a profile through the dispatcher:

```bash
./system.sh up --profile ai-mock   # deterministic mock; LiteLLM only
./system.sh up --profile ai        # real inference; LiteLLM + Ollama + model-pull
./system.sh up                     # NEITHER — the stack starts nothing
```

The profile grammar accepts only `ai` and `ai-mock` (repeatable, `--profile ai`
or `--profile=ai`). Anything else — an unknown profile, an unknown flag, or
**selecting both `ai` and `ai-mock` at once** (both LiteLLM instances publish
`:4000`, a port conflict) — is a usage error (exit 64). An explicit
`--profile ai`/`ai-mock` request when the stack is not installed (a non-opt-in
scaffold) is also a usage error: `local LLM stack not installed — re-scaffold
with --local-llm`.

**`build-config` first for `--profile ai`.** Real inference mounts the
**gitignored** `litellm/config.yaml`, which `build-config` stamps from the
committed `config.yaml.template` using the chosen model. Run it before the first
real bring-up:

```bash
./system.sh build-config     # stamps etc/local-llm/litellm/config.yaml + exports the model
./system.sh up --profile ai
```

`ai-mock` needs no stamping — `config.mock.yaml` is committed and static, so it
works straight from a clone.

## 3. Mock vs real

- **Mock (`ai-mock`)** returns a single canned reply for **any** model name on
  both chat surfaces, short-circuiting the backend (Ollama need not run). It is
  the CI/test path. It is **chat-only** by design — no embeddings mock.
- **Real (`ai`)** runs actual inference through Ollama against the pulled model.
  Slower and heavier (it pulls model weights on first boot), it is for manual
  dev and demos.

### Editing the canned mock response

The mock is **a single editable `mock_response`** in
`etc/local-llm/litellm/config.mock.yaml` (per-model / per-endpoint mocking is a
deliberate v1 non-goal). Edit the string to change the canned reply:

```yaml
model_list:
  - model_name: "*"
    litellm_params:
      model: openai/mock
      mock_response: "This is a canned mock response from the local LLM mock stack ..."
```

Because `mock_response` short-circuits the backend, it **cannot** emit structured
OpenAI `tool_calls` / Anthropic `content[].type == "tool_use"`. A tools-bearing
request to the mock is merely *tolerated* (no 5xx, well-formed response) — it is
not a structured tool-use round-trip. Richer fixtures are a documented power-user
edit; structured tool-use fidelity is a manual real-mode check only.

## 4. Model selection

The chat model is chosen **interactively at scaffold time, only when you opt into
installing the stack**. It is written to `config.json` → `localLlm.model`, the
single source of truth, validated against the Ollama model-name grammar
`^[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?$`. The scaffold menu offers:

- **Lightweight** (e.g. `llama3.2:3b`, `qwen2.5:3b`) — laptop/CPU-friendly default.
- **More powerful** (e.g. `qwen2.5:7b`, `llama3.1:8b`).
- **Abliterated** (e.g. `huihui_ai/llama3.2-abliterate`,
  `huihui_ai/qwen2.5-abliterate:7b-instruct`) — see the caveat below; never a
  default-on.
- **Something else** — any Ollama model name you supply, validated by the same
  grammar.

> **Abliterated-model caveat.** "Abliterated" models have had their refusal
> behavior removed. They carry a **quality-degradation** risk, **no safety
> guardrails**, and their **base-model license** still applies. Choose them
> deliberately and never as a default.

To change the model after scaffold: edit `config.json` → `localLlm.model` and
rerun `./system.sh build-config` (re-stamps `config.yaml`). The next
`up --profile ai` pulls the new model.

### How model routing works (no app-code changes)

LiteLLM only serves models named in its `model_list`, so a base-URL repoint alone
is **not** enough. The stamped `config.yaml` configures a **wildcard chat route**
(`model_name: "*"` → `ollama_chat/<your-model>`) so unmodified app code sending
**any** chat model name — `gpt-4o`, `claude-sonnet-4-6`, … — is transparently
served by the local model on both chat surfaces. An explicit `local` alias to the
same model is also kept. The backend is the native `ollama_chat` provider (not
`openai/` + Ollama's experimental `/v1` surface, which is unreliable for tool
calls); `OLLAMA_API_BASE` is also set on the LiteLLM container because LiteLLM
hits `OLLAMA_API_BASE/api/show` for capability detection regardless of the
per-model `api_base` (a known bug) — without it, function-calling silently
degrades.

### Optional embeddings model (opt-in)

After the chat-model prompt, a **second, separate opt-in prompt** asks whether the
project needs embeddings. If yes, an embedding model is chosen (default
`nomic-embed-text`, or "something else", same grammar) and written to
`config.json` → `localLlm.embeddingModel`. When set:

- The single model-pull step pulls **both** models under the same `ai` profile
  (`ai-mock` stays chat-only — no embeddings mock).
- LiteLLM gains a **`local-embed`** route (`ollama/<embedding-model>`) on the
  **OpenAI `/v1/embeddings`** surface only — Anthropic has no embeddings endpoint.
  Embeddings use an explicit alias because a wildcard is unreliable across the
  embeddings endpoint.
- `build-config` emits `OPENAI_EMBEDDING_MODEL=local-embed` into the `Api`'s `.env`,
  so embedding callers know the model name. Chat callers need no model env var —
  the wildcard route serves any name.

## 5. Anthropic-surface fidelity caveat + pinned versions

The unified `/v1/messages` surface translates Anthropic ↔ OpenAI. That
OpenAI↔Anthropic SSE re-assembly has **documented, version-specific regressions**
(dropped streaming tool_use args, null `stop_reason`, dropped first text delta).
**Real-mode Anthropic-surface tool-use/streaming fidelity is therefore NOT
guaranteed.** The deterministic mock is the right tool only for canned-response /
request-*tolerated* assertions (it short-circuits the backend, so it cannot emit
structured `tool_calls` / `tool_use` — see §3). **Structured tool-use and
streaming-translation fidelity must be checked in real mode (`--profile ai`) or a
dedicated integration fixture, never via the mock.**

Because of these version-specific regressions, the images are pinned and the
**LiteLLM image is pinned by immutable digest** (a bare semver tag is
insufficient — registry tags can be re-pushed). Ollama is pinned to a readable
**version tag** (not a digest): it is the stable inference engine, far less
regression-prone than LiteLLM's translation layer, and a readable tag eases
bumping.

| Container | Pin | Exact tested value |
|---|---|---|
| LiteLLM | image **digest** (R11) | `ghcr.io/berriai/litellm:v1.77.3-stable@sha256:13627afb7b0dd049ce7a7d724c05264fa0acbca1b8e32e85c6241b22c46921be` |
| Ollama | version **tag** (R14) | `ollama/ollama:0.30.8` |

When bumping LiteLLM, update the digest and re-verify both chat surfaces (and any
tool-use/streaming behavior you rely on) before committing — the tag alone is
documentation; the digest is what gets pulled.

## 6. CPU-only default + opt-in GPU override

The stack is **CPU-only by default** (laptop/CI portability; no GPU
auto-detection). To use an NVIDIA GPU, add a compose override file that requests
GPU devices on the `ollama` service — e.g. `etc/local-llm/docker-compose.gpu.yml`:

```yaml
services:
  ollama:
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: ["gpu"]
```

Then layer it onto the bring-up (requires the host NVIDIA Container Toolkit):

```bash
docker compose \
  -f etc/local-llm/docker-compose.yml \
  -f etc/local-llm/docker-compose.gpu.yml \
  --profile ai up -d
```

This is opt-in; the committed stack never enables GPU.

## 7. Offline / pre-pull workflow + loud pull-failure

`--profile ai` runs a one-shot **model-pull** init container that runs
`ollama pull` for the chat model (and the embedding model, if opted in). The real
`litellm` service waits on it (`service_completed_successfully`), so a model is
always present before the first smoke request.

A failed `ollama pull` — **offline, or an unknown model name** — makes the
model-pull container exit non-zero, which **blocks `litellm` and fails
`up --profile ai` loudly** with a clear message, rather than leaving a
half-started stack. (There is no warn-and-continue.)

To work offline, **pre-pull the model(s) into the named volume while you still
have a network**, then bring the stack up offline (the pull becomes a fast no-op
because the model is already present):

```bash
# pre-pull while online (run against the same `ollama` service / volume)
./system.sh up --profile ai          # first online run pulls + caches into ollama-models
# ... later, offline:
./system.sh up --profile ai          # model already cached; pull is a no-op
```

The pulled weights live in the `ollama-models` named volume, so they survive
`down`/`up` cycles. If `LLM_MODEL` is empty (no `localLlm.model`, or
`build-config` not yet run), the pull fails clearly telling you to set the model
and run `build-config`.

## 8. Complete removal

The stack is removable (like `SampleApp`), but removing it fully takes more than
deleting the directory. Deleting **only** `etc/local-llm/` leaves `build-config`
**failing on the orphaned `localLlm.model`** and the app **pointed at a missing
gateway** (the `127.0.0.1:4000` base URLs remain). The `[[ -f ]]` guard in
`up`/`down` only makes the bring-up/teardown a no-op — it does **not** undo the
config changes.

To fully remove the mock stack:

1. **Delete the stack directory:** `rm -rf etc/local-llm/`.
2. **Remove the `localLlm` block** from `config.json` (drop the entire top-level
   `localLlm` object — both `model` and any `embeddingModel`).
3. **Restore the `services.claude-api` / `services.openai-api` `base_url` + `api_key`**
   in `config.json` to real-provider values:
   - `claude-api.base_url` → `https://api.anthropic.com`
   - `openai-api.base_url` → `https://api.openai.com/v1`
   - both `api_key` → your real provider keys (or `REPLACE_ME`)
4. **Rerun** `./system.sh build-config` so the `Api`'s `.env` is regenerated with
   the real-provider base URLs/keys (and `OPENAI_EMBEDDING_MODEL` is dropped).

(The simplest way to *avoid* this entirely is to scaffold without `--local-llm`
in the first place — then no `etc/local-llm/`, no `localLlm` block, and the base
URLs default to the real providers.)

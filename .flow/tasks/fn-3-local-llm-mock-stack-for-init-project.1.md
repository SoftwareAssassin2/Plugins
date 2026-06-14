---
satisfies: [R1, R2, R3, R10, R11]
---

## Description
Author the build-time-complete compose templates for the local LLM mock: `etc/local-llm/docker-compose.yml`, the real + mock LiteLLM configs, and a model-pull init script. Prove (manual/integration) both LiteLLM surfaces answer against Ollama under `--profile ai`, and that `--profile ai-mock` answers via `mock_response` with no Ollama container. This is the epic's early proof point.

**Size:** M
**Files:** `templates/etc/local-llm/docker-compose.yml`, `templates/etc/local-llm/litellm/config.yaml.template` (real, build-config-stamped), `templates/etc/local-llm/litellm/config.mock.yaml` (mock, static), `templates/etc/local-llm/_pull-model.sh` (init), automated tests under `templates/tests/`.

## Approach
- Model the stack on the fn-2 observability stack (`etc/observability/docker-compose.yml`) — same `etc/`-tooling category, compose-managed, outside `.devcontainer/`.
- `ollama` service: official `ollama/ollama`, named volume `/root/.ollama`, CPU-only default, **healthcheck via `ollama list`** (the image has the `ollama` CLI; do NOT assume `curl`), generous `start_period`. Tagged `profiles: ["ai"]`.
- `litellm` service: **PINNED by image digest** (`ghcr.io/berriai/litellm@sha256:…`, optionally with a readable tag alongside — a bare semver tag is re-pushable; capture the exact tested version+digest in this task's Evidence, fn-3….5 documents it), mount config, port 4000, `OLLAMA_API_BASE=http://ollama:11434` env (capability-detection bug). Real instance tagged `profiles: ["ai"]`; a mock instance (mounting `config.mock.yaml`) tagged `profiles: ["ai-mock"]` so it runs WITHOUT Ollama.
- LiteLLM real config: ship committed `litellm/config.yaml.template` whose `model_list` alias `local` → `ollama_chat/@@LLM_MODEL@@` (native provider, NOT `openai/` + Ollama `/v1`); **`build-config` stamps the gitignored runtime `litellm/config.yaml` from it** by replacing `@@LLM_MODEL@@` with the raw model from `config.json` `localLlm.model` (wiring lands in .2/.4) — mirrors the keycloak realm-stamp pattern. `config.mock.yaml`: committed static, same alias with `mock_response` (no model needed).
- Anthropic surface: rely on unified `/v1/messages` (auto for all `model_list` entries). Do NOT use the `/anthropic` passthrough.
- Model-pull init: SAME `ollama/ollama` image with an **`entrypoint:` override** (the official image's default entrypoint is `ollama`, so a bare `command: _pull-model.sh` would run `ollama _pull-model.sh`) — e.g. `entrypoint: ["/bin/sh","/scripts/_pull-model.sh"]`. `OLLAMA_HOST=http://ollama:11434`, `restart: "no"`, gated by `depends_on: ollama condition: service_healthy`. The committed **`_pull-model.sh`** (a real script — kcov-coverable) reads `LLM_MODEL` from its container env (set via compose `${LLM_MODEL:-}` interpolation), runs `ollama pull "$LLM_MODEL"`, and **fails clearly when `LLM_MODEL` is empty**.
- **Real `litellm` waits for the pull:** `depends_on: model-pull condition: service_completed_successfully`, so early smoke requests don't hit a missing model.
- All services on a shared network; **LiteLLM published loopback-only `127.0.0.1:4000:4000`** (dev-only unauthenticated gateway — never bind all interfaces; matches the `127.0.0.1` SDK base URLs), Ollama internal-only (no host port).
- Mock LiteLLM (`config.mock.yaml`) must serve canned output through BOTH `/v1/chat/completions` AND `/v1/messages` (the CI path exercises both surfaces).
- Real bind mount of `litellm/config.yaml` uses `create_host_path: false` so a missing generated file errors clearly (no silent dir creation). `up.sh` preflight for `--profile ai` (in .3) requires both generated files present.
- **No `env_file:` / no generated `.env`** (avoids the `env_file: {required:false}` compose-version dependency): `LLM_MODEL` reaches compose as a `system.sh up`/`down`-exported env var, interpolated as `environment: [LLM_MODEL=${LLM_MODEL:-}]` (.3 owns the export). The real LiteLLM service bind-mounts its generated `litellm/config.yaml` (`volumes:` + `create_host_path: false`), NOT a top-level `configs:` `file:` — so `down` doesn't fail when the generated config is absent. `_pull-model.sh` mounted read-only. `--profile ai` requires `./system.sh build-config` first (stamps `litellm/config.yaml`); document this. Only `config.yaml.template`, `config.mock.yaml`, and `_pull-model.sh` are committed.
- Split evidence: the **unit gate** is generated-file + mocked-shell (no daemon); an **optional Docker-enabled integration job** runs `--profile ai-mock` (no model) and asserts both surfaces; real-inference `--profile ai` smoke is MANUAL.

## Investigation targets
**Required:**
- `.worktrees/init-project/plugins/init-project/templates/etc/observability/docker-compose.yml` — the analog stack to mirror (if authored by fn-2.5; else fn-2 spec R5)
- `.worktrees/init-project/plugins/init-project/templates/tests/system-cli/` — existing shell test harness + kcov + stubbing conventions
- fn-2 spec R5 (`etc/` tooling), R23 (build-time-complete), R6 (kcov 100% line + per-branch)

## Key context
- Ollama's OpenAI `/v1` is officially experimental/unreliable for tool calls — route via `ollama_chat`.
- LiteLLM `/v1/messages` streaming has version-specific regressions — pin the image (R11), prefer `mock_response` for tool-use assertions.
- Profiled service is not auto-started by another's `depends_on` unless its profile is active; keep services on a shared network.

## Acceptance
- [ ] `etc/local-llm/docker-compose.yml` defines `ollama` (`ai`) + real `litellm` (`ai`) + mock `litellm` (`ai-mock`) + model-pull init; shared network; LiteLLM :4000, Ollama internal-only; `ollama list` healthcheck + named volume (R1)
- [ ] model-pull init uses `ollama/ollama` with an `entrypoint:` override running `_pull-model.sh` (not `ollama <script>`) + `OLLAMA_HOST` + `ollama pull "$LLM_MODEL"` (from compose `${LLM_MODEL:-}`), gated by `service_healthy`; fails clearly on empty `LLM_MODEL`; no `curl` reliance (R1)
- [ ] real `litellm` has `depends_on: model-pull condition: service_completed_successfully` (R1, R2)
- [ ] real `config.yaml.template` committed; mock `config.mock.yaml` static (build-config stamps the runtime real config in .2) (R1)
- [ ] `config.yaml.template` shape validated: `model_list` alias `local` → `ollama_chat/@@LLM_MODEL@@` + `api_base: http://ollama:11434`; AND `OLLAMA_API_BASE=http://ollama:11434` set on the litellm **compose service env** (not the YAML). (Runtime stamping + generated `config.yaml` assertions belong to .2.) (R2)
- [ ] MANUAL/integration smoke (documented, not a CI gate; uses a temp/generated config as evidence): both surfaces (`/v1/chat/completions` + unified `/v1/messages`) return a completion under `--profile ai` against the pulled model (R2)
- [ ] `--profile ai-mock` returns canned `mock_response` output through BOTH `/v1/chat/completions` AND `/v1/messages`, with NO Ollama container running (R3)
- [ ] LiteLLM published `127.0.0.1:4000:4000` (loopback only); Ollama has no host port (R1, R5)
- [ ] LiteLLM image pinned by digest (`@sha256:…`); exact tested version+digest captured in this task's Evidence for fn-3….5 to document (R11)
- [ ] automated generated-file assertion: `docker-compose.yml` contains `ghcr.io/berriai/litellm@sha256:` and does NOT use `latest`/`main-latest`/a tag-only LiteLLM image (R11)
- [ ] NO `env_file:`/generated `.env`; `LLM_MODEL` via `environment: [LLM_MODEL=${LLM_MODEL:-}]`; bind-mounts generated `litellm/config.yaml` (`create_host_path: false`, not `configs:`), so `down` works with `config.yaml` absent; `build-config`-first for `--profile ai` documented (R7, R10)
- [ ] optional Docker-enabled integration job: `--profile ai-mock` serves canned responses on BOTH `/v1/chat/completions` + `/v1/messages` (distinct from the no-daemon unit gate) (R3, R10)
- [ ] AUTOMATED CI: generated-file checks + model-pull/any shell at 100% line coverage via kcov, per-branch tests, with ollama/curl/docker stubbed — no daemon/network/model (R10)

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

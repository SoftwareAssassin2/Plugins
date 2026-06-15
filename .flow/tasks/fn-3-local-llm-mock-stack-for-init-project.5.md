---
satisfies: [R3, R8, R9, R11, R12, R13, R15]
---

## Description
Author the docs: a new `docs/local-llm.md` standard (incl. removal instructions), plus updates to `dev-container.md`, `_CLAUDE.md` (Standards index + invariant-exceptions), and `README.md`. Capture `ai` vs `ai-mock` profiles, the Anthropic-surface fidelity caveat, pinned-version rationale, model selection, and the dev-tooling classification.

**Size:** M
**Files:** `templates/docs/local-llm.md` (new), `templates/docs/dev-container.md`, `templates/_CLAUDE.md`, `templates/README.md`.

## Approach
- New `docs/local-llm.md`: what the stack is + why (local mock for `claude-api`/`openai-api`); opt-in install; the `ai` (real: litellm+ollama+pull) vs `ai-mock` (litellm-only, mock_response, no ollama) profiles + activation; mock vs real modes; model selection incl. the abliterated quality/guardrail/license caveat; **the optional embeddings model (R12) — second opt-in, `/v1/embeddings` OpenAI-surface only, default `nomic-embed-text`, surfaced via `OPENAI_EMBEDDING_MODEL=local-embed`**; **how model routing works — the wildcard `"*"` route means unmodified app code can keep sending `gpt-*`/`claude-*` names and they're served locally; only embeddings need the `local-embed` model name (R2)**; **the GPU opt-in compose-override snippet (`deploy.resources.reservations.devices`) — CPU-only by default (R15)**; **the offline / pre-pull workflow + that a failed pull fails `up --profile ai` loudly (R13)**; **how to edit the single canned `mock_response` in `config.mock.yaml`**; the Ollama version-tag vs LiteLLM digest pin rationale (R14/R11); the Anthropic `/v1/messages` tool-use/streaming fidelity caveat + the pinned-LiteLLM-version rationale with the exact tested version (R3, R11); that it is dev tooling, NOT a `systems[]`/`services{}` entry (R9); and **complete removal** — fully removing the mock requires (1) delete `etc/local-llm/`, (2) remove the `localLlm` block from `config.json`, (3) restore `services.claude-api`/`services.openai-api` `base_url`+`api_key` to real-provider values, then rerun `build-config`. Deleting only the directory leaves `build-config` failing on the orphaned `localLlm.model` and the app pointed at a missing gateway; the `[[ -f ]]` guard only covers the `up`/`down` no-op, not full removal. (Removable like `SampleApp`, but with these config steps.)
- `_CLAUDE.md`: add a Standards-index row for `docs/local-llm.md`; add `etc/local-llm/` to the invariant-exceptions table next to `etc/observability/`.
- `dev-container.md`: extend the dep-placement example to include `etc/local-llm/` as a second internal-dev-tooling stack.
- `README.md`: add a "Local LLM mock (opt-in)" section — enabling a profile, which env vars point at it, mock vs real.
- All authored build-time-complete (fn-2 R23); H&G-free.

## Investigation targets
**Required:**
- `plugins/init-project/templates/_CLAUDE.md` — Standards index + invariant-exceptions table format
- `plugins/init-project/templates/docs/dev-container.md` — dep-placement table + services-outside-devcontainer example
- `plugins/init-project/templates/README.md` — "Running the system" section to extend
- `plugins/init-project/templates/docs/config-management.md` — keep the services classification consistent with .2

## Acceptance
- [ ] `docs/local-llm.md` covers what/why, opt-in, `ai`/`ai-mock` profiles, mock vs real, model selection (+ abliterated caveat), optional embeddings model (R12), GPU opt-in override (R15), offline/pre-pull + loud pull-failure (R13), editing the canned `mock_response`, Anthropic fidelity caveat, Ollama-version-tag vs LiteLLM-digest pin rationale + tested version, dev-tooling classification, AND **complete removal** — delete `etc/local-llm/`, remove the `localLlm` block, restore `claude-api`/`openai-api` base URLs+keys to real-provider values, rerun `build-config` (deleting only the dir leaves build-config failing + app pointed at a missing gateway) (R3, R8, R9, R11, R12, R13, R15)
- [ ] `docs/local-llm.md` records the EXACT LiteLLM version+digest captured in fn-3….1's Evidence (no placeholder) — this task cannot complete until .1 has recorded it (R11)
- [ ] `_CLAUDE.md` Standards index links `docs/local-llm.md`; invariant-exceptions table lists `etc/local-llm/` (R8)
- [ ] `dev-container.md` dep-placement example includes `etc/local-llm/` (R8)
- [ ] `README.md` has a "Local LLM mock (opt-in)" section, incl. that `./system.sh build-config` must run before `--profile ai` (stamps the model) (R8)
- [ ] Docs are H&G-free and build-time-complete (R8)

## Done summary
Authored docs/local-llm.md (the local LLM mock-stack standard) and updated _CLAUDE.md (Standards index + invariant-exceptions), dev-container.md (dep-placement table + outside-.devcontainer example), and README.md (Local LLM mock opt-in section). Covers ai vs ai-mock profiles, mock-vs-real, model selection + abliterated caveat, optional embeddings, wildcard routing, the Anthropic-surface fidelity caveat with the exact pinned LiteLLM digest + Ollama tag, CPU-only default + GPU override, offline/pre-pull + loud pull-failure, editing the canned mock_response, dev-tooling classification, and complete-removal steps.
## Evidence
- Commits: 9c01949f687045fd6aa6aa4f7dae8fa33564e2c2, 87408d8bc702264ca05ce9a7eede1cd3a8992b0c
- Tests: bash plugins/init-project/tests/scaffold_test.sh (305 ok, 0 fail), bash plugins/init-project/tests/dispatcher_test.sh (62 ok, 0 fail), scaffold demo project: docs/local-llm.md lands with LiteLLM digest intact
- PRs:
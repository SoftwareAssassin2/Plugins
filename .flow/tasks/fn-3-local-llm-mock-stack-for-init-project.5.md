---
satisfies: [R3, R8, R9, R11]
---

## Description
Author the docs: a new `docs/local-llm.md` standard (incl. removal instructions), plus updates to `dev-container.md`, `_CLAUDE.md` (Standards index + invariant-exceptions), and `README.md`. Capture `ai` vs `ai-mock` profiles, the Anthropic-surface fidelity caveat, pinned-version rationale, model selection, and the dev-tooling classification.

**Size:** M
**Files:** `templates/docs/local-llm.md` (new), `templates/docs/dev-container.md`, `templates/_CLAUDE.md`, `templates/README.md`.

## Approach
- New `docs/local-llm.md`: what the stack is + why (local mock for `claude-api`/`openai-api`); opt-in install; the `ai` (real: litellm+ollama+pull) vs `ai-mock` (litellm-only, mock_response, no ollama) profiles + activation; mock vs real modes; model selection incl. the abliterated quality/guardrail/license caveat; the Anthropic `/v1/messages` tool-use/streaming fidelity caveat + the pinned-LiteLLM-version rationale with the exact tested version (R3, R11); that it is dev tooling, NOT a `systems[]`/`services{}` entry (R9); and **complete removal** — fully removing the mock requires (1) delete `etc/local-llm/`, (2) remove the `localLlm` block from `config.json`, (3) restore `services.claude-api`/`services.openai-api` `base_url`+`api_key` to real-provider values, then rerun `build-config`. Deleting only the directory leaves `build-config` failing on the orphaned `localLlm.model` and the app pointed at a missing gateway; the `[[ -f ]]` guard only covers the `up`/`down` no-op, not full removal. (Removable like `SampleApp`, but with these config steps.)
- `_CLAUDE.md`: add a Standards-index row for `docs/local-llm.md`; add `etc/local-llm/` to the invariant-exceptions table next to `etc/observability/`.
- `dev-container.md`: extend the dep-placement example to include `etc/local-llm/` as a second internal-dev-tooling stack.
- `README.md`: add a "Local LLM mock (opt-in)" section — enabling a profile, which env vars point at it, mock vs real.
- All authored build-time-complete (fn-2 R23); H&G-free.

## Investigation targets
**Required:**
- `.worktrees/init-project/src/init-project/templates/_CLAUDE.md` — Standards index + invariant-exceptions table format
- `.worktrees/init-project/src/init-project/templates/docs/dev-container.md` — dep-placement table + services-outside-devcontainer example
- `.worktrees/init-project/src/init-project/templates/README.md` — "Running the system" section to extend
- `.worktrees/init-project/src/init-project/templates/docs/config-management.md` — keep the services classification consistent with .2

## Acceptance
- [ ] `docs/local-llm.md` covers what/why, opt-in, `ai`/`ai-mock` profiles, mock vs real, model selection (+ abliterated caveat), Anthropic fidelity caveat, pinned-version+digest rationale + tested version, dev-tooling classification, AND **complete removal** — delete `etc/local-llm/`, remove the `localLlm` block, restore `claude-api`/`openai-api` base URLs+keys to real-provider values, rerun `build-config` (deleting only the dir leaves build-config failing + app pointed at a missing gateway) (R3, R8, R9, R11)
- [ ] `_CLAUDE.md` Standards index links `docs/local-llm.md`; invariant-exceptions table lists `etc/local-llm/` (R8)
- [ ] `dev-container.md` dep-placement example includes `etc/local-llm/` (R8)
- [ ] `README.md` has a "Local LLM mock (opt-in)" section, incl. that `./system.sh build-config` must run before `--profile ai` (stamps the model) (R8)
- [ ] Docs are H&G-free and build-time-complete (R8)

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

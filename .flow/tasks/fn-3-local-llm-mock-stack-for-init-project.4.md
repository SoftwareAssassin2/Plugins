---
satisfies: [R4, R5, R10, R12]
---

## Description
Add the scaffold-time opt-in: the `/init-project` skill asks whether to install the local LLM mock stack; on yes, it asks which model (guided menu), writes the choice into `config.json`, repoints the local `claude-api`/`openai-api` base URLs at LiteLLM, and lays down the `etc/local-llm/` templates. (The `services{}` entries themselves are always present — see .2 — so non-opt-in just leaves real-provider defaults.) Update `SKILL.md` prose and the scaffold engine.

**Size:** M
**Files:** `plugins/init-project/SKILL.md`, the scaffold engine (`scaffold.sh` or equivalent). NOTE: the `templates/config.json` template ALWAYS ships real-provider defaults + no `localLlm` block; the engine mutates the GENERATED project's `config.json` (via `jq`) only on opt-in — it never conditionally rewrites the template itself.

## Approach
- **Concrete scaffold contract:** the engine takes explicit flags `--local-llm` (opt-in toggle) + `--local-llm-model <model>` (default off / unset). SKILL.md (assistant-workflow prompt, like fn-2 R15's git phase) prompts "install local LLM mock stack? (y/N)"; on yes presents the model menu — lightweight (`llama3.2:3b`), more powerful (`qwen2.5:7b`), abliterated (`huihui_ai/llama3.2-abliterate`, with the quality/guardrail/license caveat), and "something else" (skill helps pick by size/VRAM/task/license). **Then a second opt-in prompt (R12): "need embeddings? (y/N)"** — on yes, pick an embedding model (default `nomic-embed-text` + "something else", same grammar validation). The skill then invokes `scaffold.sh … --local-llm --local-llm-model <chosen> [--local-llm-embed-model <embed>]`. Non-interactive: absent `--local-llm`, no stack. `--local-llm` REQUIRES `--local-llm-model <model>` (no hardcoded default — the model is the source of truth) → omitting it, or `--local-llm-model`/`--local-llm-embed-model` without `--local-llm`, or an invalid model → usage exit 64. Skill prose, NOT runtime LLM authoring.
- **Scaffold-time `jq` dependency:** the opt-in path uses `jq` on the HOST (scaffolding may run outside the devcontainer, so fn-2's in-project `jq` guarantee doesn't apply). The engine **preflights `jq` only when `--local-llm` is set** and, if absent, exits 64 with a clear "the --local-llm option requires `jq`" message (the non-opt-in scaffold stays `jq`-free). Document the conditional dependency in `SKILL.md`; test the missing-`jq` path.
- Engine: on opt-in, via structured `jq` edits to `config.json`, (a) set `claude-api.base_url=http://127.0.0.1:4000` + `openai-api.base_url=http://127.0.0.1:4000/v1` + both keys `sk-local-mock`, (b) add `localLlm.model=<chosen>` and, when the embeddings prompt was accepted, `localLlm.embeddingModel=<embed>` (R12) — the single source of truth (`build-config` in .2 stamps them into `litellm/config.yaml` ONLY, and `system.sh up`/`down` export `LLM_MODEL`/`LLM_EMBED_MODEL` from `config.json`; there is **no generated `.env`**, and the engine does NOT itself stamp the runtime config), (c) **copy the optional subtree `templates/_optional/local-llm/` → the generated project's `etc/local-llm/`** (it is NOT in the default wholesale copy — see .1; this opt-in copy is the ONLY thing that materializes the stack). No leftover `__SCAFFOLD_*__` tokens post-scaffold (fn-2 R2).
- When NOT opted in: no `etc/local-llm/`, no `localLlm` block, base URLs stay real-provider defaults (`https://api.anthropic.com` / `https://api.openai.com/v1`); the `claude-api`/`openai-api` entries still exist (from .2). Scaffold otherwise identical to today.
- Document the opt-in + conditional inclusion in SKILL.md parallel to the `--force`/`--update` mode prose.

## Investigation targets
**Required:**
- `plugins/init-project/SKILL.md` — skill prose + the git/`--force`/`--update` prompt patterns to parallel
- the fn-2 scaffold engine (`scaffold.sh`) — token substitution + how conditional/optional files are handled today
- `plugins/init-project/templates/config.json` — the `services{}` base-URL fields .2 introduces (the repoint target)
- fn-2 spec R2 (no leftover tokens), R23 (copy + substitute only), R15 (assistant-workflow prompt pattern)

## Acceptance
- [ ] Skill prompts to install the stack; declining yields the non-opt-in scaffold: no `etc/local-llm/`, no `localLlm` block, real-provider base URLs, WITH the always-present `claude-api`/`openai-api` entries from .2 (R5)
- [ ] On opt-in, skill presents the model menu incl. lightweight/powerful/abliterated/"something else" guided selection; the chosen/entered model is validated against `^[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?$` before it's written (re-prompt on invalid) (R4)
- [ ] Chosen model written to `config.json` `localLlm.model` (single source of truth; build-config propagates it — .2) (R4)
- [ ] Second embeddings opt-in prompt (R12): on yes, pick an embedding model (default `nomic-embed-text` + "something else", grammar-validated) written to `localLlm.embeddingModel`; on no, no embeddings field/entry; `--local-llm-embed-model` requires `--local-llm` (else exit 64) (R12)
- [ ] On opt-in, the engine copies `templates/_optional/local-llm/` → `etc/local-llm/` AND sets `claude-api`/`openai-api` base URLs+keys to the LiteLLM values via `jq`; no leftover `__SCAFFOLD_*__` tokens. Non-opt-in: `_optional/` is NOT copied, so the scaffold has zero `etc/local-llm/` files (R4, R5)
- [ ] "Removable" = a non-opt-in project has NO `etc/local-llm/` files, NO `localLlm` config block, and NO runtime/config hard-dependency on the stack; the always-authored docs (`docs/local-llm.md`, README/_CLAUDE sections from .5) MAY still mention the opt-in feature by name — those are documentation, not a dependency. The removal *procedure* is documented in .5 (R5)
- [ ] `--local-llm` preflights `jq` on the host → exit 64 with a clear message when absent; non-opt-in scaffold needs no `jq`; documented in SKILL.md; tested (R4, R10)
- [ ] Engine changes (shell) tested at 100% line coverage + per-branch: opt-in on/off, `--local-llm` without `--local-llm-model` → exit 64, `--local-llm-model`/`--local-llm-embed-model` without `--local-llm` → exit 64, invalid model → exit 64, missing-`jq` → exit 64, config `jq` mutation, conditional `etc/local-llm/` inclusion (R10)
- [ ] SKILL.md documents the opt-in prompt, the `scaffold.sh --local-llm[ --local-llm-model]` contract + conditional inclusion (R5)

## Done summary
Added the scaffold-time `--local-llm` / `--local-llm-model` / `--local-llm-embed-model` opt-in to the init-project engine: prunes the `_optional/` subtree from the default copy, lays down `templates/_optional/local-llm/` → the project's `etc/local-llm/` and jq-mutates the generated config.json (repoint claude-api/openai-api base URLs + sk-local-mock keys + localLlm.model/embeddingModel) only on opt-in, with host-side jq preflight + Ollama model-name validation. Opt-in is non-sticky: a non-opt-in `--update` over a prior opt-in resets it (gated on prior-opt-in evidence so never-opted projects keep operator edits). SKILL.md documents the prompts (install? → chat-model menu incl. abliterated + "something else"; then optional embeddings) and the engine contract; 54 new shell-test assertions cover every branch incl. missing-jq.
## Evidence
- Commits: d62895f, e3e0652, 38de188, 180eca8
- Tests: bash plugins/init-project/tests/scaffold_test.sh (334 passed, 0 failed), bash plugins/init-project/tests/dispatcher_test.sh (62 passed, 0 failed), shellcheck plugins/init-project/scaffold.sh (clean)
- PRs:
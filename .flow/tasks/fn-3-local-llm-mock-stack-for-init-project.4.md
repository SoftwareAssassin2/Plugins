---
satisfies: [R4, R5, R10]
---

## Description
Add the scaffold-time opt-in: the `/init-project` skill asks whether to install the local LLM mock stack; on yes, it asks which model (guided menu), writes the choice into `config.json`, repoints the local `claude-api`/`openai-api` base URLs at LiteLLM, and lays down the `etc/local-llm/` templates. (The `services{}` entries themselves are always present — see .2 — so non-opt-in just leaves real-provider defaults.) Update `SKILL.md` prose and the scaffold engine.

**Size:** M
**Files:** `src/init-project/SKILL.md`, the scaffold engine (`scaffold.sh` or equivalent). NOTE: the `templates/config.json` template ALWAYS ships real-provider defaults + no `localLlm` block; the engine mutates the GENERATED project's `config.json` (via `jq`) only on opt-in — it never conditionally rewrites the template itself.

## Approach
- **Concrete scaffold contract:** the engine takes explicit flags `--local-llm` (opt-in toggle) + `--local-llm-model <model>` (default off / unset). SKILL.md (assistant-workflow prompt, like fn-2 R15's git phase) prompts "install local LLM mock stack? (y/N)"; on yes presents the model menu — lightweight (`llama3.2:3b`), more powerful (`qwen2.5:7b`), abliterated (`huihui_ai/llama3.2-abliterate`, with the quality/guardrail/license caveat), and "something else" (skill helps pick by size/VRAM/task/license) — then invokes `scaffold.sh … --local-llm --local-llm-model <chosen>`. Non-interactive: absent `--local-llm`, no stack. `--local-llm` REQUIRES `--local-llm-model <model>` (no hardcoded default — the model is the source of truth) → omitting it, or `--local-llm-model` without `--local-llm`, or an invalid model → usage exit 64. Skill prose, NOT runtime LLM authoring.
- Engine: on opt-in, via structured `jq` edits to `config.json`, (a) set `claude-api.base_url=http://127.0.0.1:4000` + `openai-api.base_url=http://127.0.0.1:4000/v1` + both keys `sk-local-mock`, (b) add `localLlm.model=<chosen>` (the single source of truth — `build-config` in .2 stamps it into `litellm/config.yaml` ONLY, and `system.sh up`/`down` export `LLM_MODEL` from `config.json`; there is **no generated `.env`**, and the engine does NOT itself stamp the runtime config), (c) include the `etc/local-llm/` templates. No leftover `__SCAFFOLD_*__` tokens post-scaffold (fn-2 R2).
- When NOT opted in: no `etc/local-llm/`, no `localLlm` block, base URLs stay real-provider defaults (`https://api.anthropic.com` / `https://api.openai.com/v1`); the `claude-api`/`openai-api` entries still exist (from .2). Scaffold otherwise identical to today.
- Document the opt-in + conditional inclusion in SKILL.md parallel to the `--force`/`--update` mode prose.

## Investigation targets
**Required:**
- `.worktrees/init-project/src/init-project/SKILL.md` — skill prose + the git/`--force`/`--update` prompt patterns to parallel
- the fn-2 scaffold engine (`scaffold.sh`) — token substitution + how conditional/optional files are handled today
- `.worktrees/init-project/src/init-project/templates/config.json` — the `services{}` base-URL fields .2 introduces (the repoint target)
- fn-2 spec R2 (no leftover tokens), R23 (copy + substitute only), R15 (assistant-workflow prompt pattern)

## Acceptance
- [ ] Skill prompts to install the stack; declining yields the non-opt-in scaffold: no `etc/local-llm/`, no `localLlm` block, real-provider base URLs, WITH the always-present `claude-api`/`openai-api` entries from .2 (R5)
- [ ] On opt-in, skill presents the model menu incl. lightweight/powerful/abliterated/"something else" guided selection; the chosen/entered model is validated against `^[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?$` before it's written (re-prompt on invalid) (R4)
- [ ] Chosen model written to `config.json` `localLlm.model` (single source of truth; build-config propagates it — .2) (R4)
- [ ] On opt-in, `etc/local-llm/` laid down AND `claude-api`/`openai-api` base URLs+keys set to the LiteLLM values via `jq`; no leftover `__SCAFFOLD_*__` tokens (R4, R5)
- [ ] "Removable" = no project artifact hard-depends on the stack (non-opt-in projects contain zero `etc/local-llm`/`localLlm` references); the removal *procedure* is documented in .5 (R5)
- [ ] Engine changes (shell) tested at 100% line coverage + per-branch: opt-in on/off, `--local-llm` without `--local-llm-model` → exit 64, `--local-llm-model` without `--local-llm` → exit 64, invalid model → exit 64, config `jq` mutation, conditional `etc/local-llm/` inclusion (R10)
- [ ] SKILL.md documents the opt-in prompt, the `scaffold.sh --local-llm[ --local-llm-model]` contract + conditional inclusion (R5)

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

---
satisfies: [R5, R7, R10, R12]
---

## Description
Make the dispatcher forward args and orchestrate the `etc/local-llm/` stack behind the opt-in `ai`/`ai-mock` compose profiles — excluded from the default `up`, activated explicitly. The current `up.sh` ignores args, so arg-forwarding through `system.sh` + `--profile` parsing in `up.sh`/`down.sh` is an in-scope change. Cover with shell tests.

**Size:** M
**Files:** `templates/src/system-cli/system.sh`, `templates/src/system-cli/up.sh`, `templates/src/system-cli/down.sh`, `templates/tests/system-cli/system_cli_test.sh`.

## Approach
- Confirm/ensure `system.sh` forwards `"$@"` to the dispatched subcommand; update `up.sh` to parse profiles with an explicit grammar: accept ONLY `ai` and `ai-mock`, via repeatable `--profile <name>` AND `--profile=<name>` forms; reject unknown profiles/flags with usage exit 64; pass only accepted profiles through to the `etc/local-llm/` compose invocation. Default (no `--profile`) = none.
- **`LLM_MODEL` export:** `up`/`down` `export LLM_MODEL="$(jq -r '.localLlm.model // ""' config.json)"` AND `export LLM_EMBED_MODEL="$(jq -r '.localLlm.embeddingModel // ""' config.json)"` (R12) before invoking `docker compose`, so the compose `${LLM_MODEL:-}` / `${LLM_EMBED_MODEL:-}` interpolation (.1) reaches the model-pull container — NO `env_file`/generated `.env` (portable across compose versions). The **guarded `// ""` parse** means absent/invalid `localLlm` yields empty `LLM_MODEL` — harmless for `down` and for `--profile ai-mock` (which needs no model; only the `--profile ai` preflight requires it non-empty). `jq` is a fn-2 devcontainer prerequisite (fn-2 R4); behavior on missing `jq`/invalid `config.json` follows fn-2's existing dispatcher convention.
- Default `up` (no `--profile`) must NOT start the AI services. `--profile ai` → litellm(real)+ollama+model-pull; `--profile ai-mock` → litellm(mock) only. **Reject selecting BOTH `ai` and `ai-mock` on `up` (both LiteLLM instances bind `:4000` — port conflict) with usage exit 64.** Pass the accepted profile through to the `etc/local-llm/` compose invocation only; postgres/keycloak/observability behavior unchanged.
- **`down` is NOT profile-gated (resolved in review):** default `system.sh down` tears down `etc/local-llm/` if its compose file is present — invoke `docker compose -f etc/local-llm/docker-compose.yml --profile ai --profile ai-mock down` so containers started under EITHER profile are removed and nothing is left running. `down` starts nothing. `down` mirrors `up`'s profile grammar (repeatable `--profile <name>` / `--profile=<name>`, only `ai`/`ai-mock` valid; duplicates or both-together allowed since they're no-ops — `down` always tears down both internally) and rejects any OTHER arg with usage exit 64. **`down` must succeed when the generated `litellm/config.yaml` is absent** (relies on .1's exported-env + bind-mounted config + `create_host_path: false`; no `env_file`). This deliberate up/down asymmetry is tested, including the config-absent case.
- **`up --profile ai` preflight:** require the generated `etc/local-llm/litellm/config.yaml` present AND `config.json` `localLlm.model` non-empty; if missing, exit non-zero with a clear "run `build-config` first" message (don't let a bind mount silently create a dir — paired with .1's `create_host_path: false`). `--profile ai-mock` has no such requirement (static config, no model).
- Keep the `[[ -f "$stack" ]]` guard so a not-installed stack is a no-op. Update `# Description:` comments to mention the opt-in local-llm stack.
- Mind gotchas: profiled service not auto-started by another's `depends_on`; shared network; `condition: service_healthy` on model-pull.

## Investigation targets
**Required:**
- `.worktrees/init-project/plugins/init-project/templates/src/system-cli/system.sh` — dispatch + whether it already passes `"$@"`
- `.worktrees/init-project/plugins/init-project/templates/src/system-cli/up.sh` — the hardcoded stacks array + `[[ -f ]]` guard + `# Description:` comment + current (lack of) arg handling
- `.worktrees/init-project/plugins/init-project/templates/src/system-cli/down.sh` — teardown mirror
- fn-2 spec R24 (dispatcher contract), R6 (kcov standard)

## Acceptance
- [ ] `system.sh` forwards `"$@"`; `up.sh` accepts only `ai`/`ai-mock` via repeatable `--profile <name>`/`--profile=<name>`; unknown profile/flag → usage exit 64; selecting BOTH `ai`+`ai-mock` on `up` → usage exit 64 (tested) (R7)
- [ ] Default `system.sh up` starts NO litellm/ollama containers (R5)
- [ ] `system.sh up --profile ai` brings up litellm(real)+ollama+model-pull; `--profile ai-mock` brings up litellm(mock) only (R5, R7)
- [ ] `up`/`down` export `LLM_MODEL` + `LLM_EMBED_MODEL` from `config.json` via guarded `jq // ""` (no `env_file`/generated `.env`); absent `localLlm`/`embeddingModel` → empty (tested: `ai-mock` + `down` tolerate it) (R7, R12)
- [ ] `up --profile ai` preflight fails clearly when generated `config.yaml` absent or `localLlm.model` empty ("run build-config first"); `ai-mock` has no such requirement (R7)
- [ ] Default `system.sh down` (no profile) tears down `etc/local-llm/` if present via `--profile ai --profile ai-mock down`, leaving nothing running, starting nothing; mirrors up's profile grammar as no-ops, rejects other args exit 64; succeeds with generated `litellm/config.yaml` absent; `[[ -f ]]` guard makes a not-installed stack a no-op (R7)
- [ ] `# Description:` comments updated; postgres/keycloak/observability unchanged (R7)
- [ ] up/down/system.sh additions at 100% line coverage + per-branch; docker calls stubbed (R10)

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

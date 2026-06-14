---
satisfies: [R6, R9, R10, R12]
---

## Description
Wire the LLM services into the config model with an explicit build-config contract. Both `claude-api` and `openai-api` are ALWAYS present (no opt-in branch in build-config); only the local base-URL value changes on opt-in. Define exactly which `.env` file gets which env vars, update the schema doc + tests.

**Size:** M
**Files:** `templates/config.json`, `templates/config.deploy.json`, `templates/src/system-cli/build-config.sh`, `templates/docs/config-management.md`, `templates/tests/system-cli/system_cli_test.sh`, `templates/.gitignore` (add the generated `etc/local-llm/litellm/config.yaml` path — owned by fn-2 R22, this task adds the entry).

## Approach
- Add `services.openai-api` beside `services.claude-api` in BOTH `config.json` and `config.deploy.json` (key-set parity), each with explicit `base_url` + `api_key` (never omitted). Non-opt-in local values: `claude-api.base_url=https://api.anthropic.com`, `openai-api.base_url=https://api.openai.com/v1`, keys `REPLACE_ME`. (.4's engine rewrites these to the LiteLLM values `http://127.0.0.1:4000` / `http://127.0.0.1:4000/v1` + `sk-local-mock` on opt-in.) Deploy placeholders: `{{CLAUDE_API_BASE_URL}}`, `{{CLAUDE_API_KEY}}`, `{{OPENAI_API_BASE_URL}}`, `{{OPENAI_API_KEY}}`.
- Extend `build-config.sh` (UNCONDITIONALLY) to read the always-present `base_url`+`api_key` and emit into the consuming backend component's `.env` (the `Api` by default): `ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY`, `OPENAI_BASE_URL`, `OPENAI_API_KEY` (SDK-standard names). Use structured `jq --arg` reads (not string replacement). **Validate each `base_url`** against a concrete grammar with a restrictive host class (`[A-Za-z0-9.-]+` — rejects `?#@[]:` etc. **in the host portion**; an optional path may follow; no IPv6 needed) — `^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[^[:space:]]*)?$` — AND range-check the captured port 1–65535 separately (the `[0-9]{1,5}` class alone accepts `99999`). Stricter than the permissive `v_url`; positive/negative fixtures incl. invalid + non-numeric ports + bad host chars. A malformed URL can't poison `.env`. `api_key` stays semantically opaque (no URL-safe check) but is made **transport-safe** — reject CR/LF/control chars (or dotenv-quote) so it can't corrupt `.env`/inject vars; test a non-URL-safe-but-line-safe key.
- **Model propagation:** when `config.json` `localLlm.model` is present, `build-config` first **validates it against the Ollama model-name grammar `^[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?$`** (reject hostile/whitespace/metachar values — fail clearly), then stamps the gitignored runtime `etc/local-llm/litellm/config.yaml` from `config.yaml.template` by **deterministic replacement of the named token `@@LLM_MODEL@@` with the RAW validated model name** (the template line is already `ollama_chat/@@LLM_MODEL@@` — do NOT re-prefix `ollama_chat/`, which would yield `ollama_chat/ollama_chat/…`). **No `.env` is written** — the model-pull `LLM_MODEL` (+ optional `LLM_EMBED_MODEL`) is exported by `system.sh up`/`down` from `config.json` (.3 owns that), not a build-config file. **Embeddings (R12):** when `config.json` `localLlm.embeddingModel` is ALSO present (validated by the same model-name grammar), `build-config` stamps the conditional `local-embed` → `ollama/<embeddingModel>` `model_list` entry in `config.yaml`; when absent, that entry is omitted. Mirrors the existing keycloak realm-stamp responsibility; absent `localLlm` → no-op. **If `localLlm.model` is present but `config.yaml.template` is missing, fail with a clear error** (opt-in invariant — don't silently skip). The generated `litellm/config.yaml` is gitignored (coordinate the `.gitignore` entry with fn-2 R22).
- `config-management.md`: §4 schema table adds the `openai-api` row + the four emitted env vars + their consumer; §2 prose updated for two canonical `services{}` entries; **document the opt-in-only top-level `localLlm.model` field AND the optional `localLlm.embeddingModel` field** (their validation grammar + that they drive the generated `config.yaml` and the exported `LLM_MODEL`/`LLM_EMBED_MODEL`). Document the stack as dev tooling backing the services, NOT a `services{}` entry (R9).
- Tests: assert each emitted `.env` line; assert raw `config.deploy.json` still fails the unrendered-placeholder guard while a rendered deploy config distributes the vars; parallel `openai-api` opaque-credential fixture.

## Investigation targets
**Required:**
- `.worktrees/init-project/plugins/init-project/templates/config.json` + `config.deploy.json` — current `services.claude-api` shape + `{{VAR-NAME}}` parity + the unrendered-placeholder guard
- `.worktrees/init-project/plugins/init-project/templates/src/system-cli/build-config.sh` — which `.env` files it writes today (Api/DataAccess/SPA public config), the `jq --arg` pattern, the deploy-template guard
- `.worktrees/init-project/plugins/init-project/templates/docs/config-management.md` — §2 prose + §4 schema table format
- `.worktrees/init-project/plugins/init-project/templates/tests/system-cli/system_cli_test.sh` — the `claude-api` opaque-credential fixture to parallel

## Acceptance
- [ ] Both `claude-api` + `openai-api` present in `config.json` AND `config.deploy.json` with key-set parity; build-config does NOT branch on opt-in (R6)
- [ ] `build-config` emits `ANTHROPIC_BASE_URL`/`ANTHROPIC_API_KEY` + `OPENAI_BASE_URL`/`OPENAI_API_KEY` into the consuming component's `.env` (the `Api`); `base_url` validated (malformed rejected), `api_key` stays opaque/unvalidated (R6)
- [ ] `localLlm.model` present + `config.yaml.template` missing → build-config fails with a clear error (tested) (R6)
- [ ] Deploy placeholders `{{CLAUDE_API_BASE_URL}}`/`{{CLAUDE_API_KEY}}`/`{{OPENAI_API_BASE_URL}}`/`{{OPENAI_API_KEY}}` present; raw deploy config still fails fast, rendered distributes (R6)
- [ ] `config-management.md` §4 gains the `openai-api` row + env vars; §2 prose updated (R6)
- [ ] config-management documents the stack as dev tooling backing the services, NOT a `services{}` entry (R9)
- [ ] When `localLlm.model` present, build-config stamps gitignored `litellm/config.yaml` (`@@LLM_MODEL@@`→raw model); writes NO `.env`; absent `localLlm` → no-op (R6)
- [ ] When `localLlm.embeddingModel` present, build-config stamps the `local-embed`→`ollama/<embeddingModel>` entry; absent → entry omitted; `embeddingModel` validated by the model-name grammar — tested both ways (R12)
- [ ] `.gitignore` ignores the generated `etc/local-llm/litellm/config.yaml`; `base_url` grammar (host class `[A-Za-z0-9.-]+`, port range-checked 1–65535) has positive+negative fixtures incl. invalid/non-numeric ports + bad host chars (R6)
- [ ] `config-management.md` documents the opt-in-only `localLlm.model` field (grammar + what it drives) (R6, R9)
- [ ] `localLlm.model` validated against `^[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?$` before stamping (reject hostile; accept valid `/` and `:`); `@@LLM_MODEL@@` replaced with the RAW model name (no `ollama_chat/` re-prefix) — tested (R6)
- [ ] `api_key` made transport-safe (CR/LF/control chars rejected or quoted); tested with a non-URL-safe-but-line-safe key (R6)
- [ ] Tests assert each emitted `.env` line + the stamped model wiring; build-config additions at 100% line coverage + per-branch (R10)

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

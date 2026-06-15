---
name: init-project
description: Scaffold a brand-new opinionated mono-repo project with Chris's preferred defaults (root layout, CLAUDE.md, dev container, standards docs, system.sh dispatcher CLI, a starter .NET solution + Angular SPAs, Postgres + Keycloak). Use when starting a new project / "init project" / "scaffold a new repo". Asks only for a project name + short description, then copies the build-time-complete templates and applies minimal placeholder substitution.
argument-hint: "[optional: project name / description]"
---

# init-project

Stand up a new software project from copy-ready templates. **The templates are authored complete; this skill copies them and substitutes only the project name/description** (+ generates per-project secrets). It never authors content at scaffold time.

## What it does (orchestration)
1. **Ask** for a **project name** (`^[a-z0-9][a-z0-9-]*$`) and a **short description** — nothing else.
2. **Local LLM mock stack (opt-in prompt — before running the engine).** Ask the user whether to install the **local LLM mock stack** (LiteLLM + Ollama) so the scaffolded app's outbound LLM calls hit a local gateway instead of paid providers — see the [Local LLM opt-in](#local-llm-opt-in-before-the-engine-runs) section below for the exact prompts (install? → chat-model menu → optional embeddings). The default is **no** (a plain scaffold). Carry the user's answers into the engine flags in the next step.
3. **Run the bundled engine:** `scaffold.sh <name> "<description>" [--local-llm --local-llm-model <model> [--local-llm-embed-model <model>]]` (see [scaffold.sh](scaffold.sh)). It copies `templates/` into `./<name>/`, substitutes `__SCAFFOLD_PROJECT_NAME__` / `__SCAFFOLD_PROJECT_DESCRIPTION__`, generates a fresh URL-safe value for each `__SCAFFOLD_GEN_URLSAFE__` occurrence, maps `_CLAUDE.md` → `CLAUDE.md`, writes `.init-project-manifest.json`, and fails if any `__SCAFFOLD_*__` token is left behind.
   - Refuses a non-empty target unless `--force` (first scaffold, no collision with unmanaged files) or `--update` (re-scaffold over a prior output; `config.json` preserved).
   - `--dry-run` prints the planned tree without writing.
   - **`--local-llm` (opt-in, off by default):** lays down `templates/_optional/local-llm/` → the project's `etc/local-llm/` (this subtree is **excluded from the default copy**, so a plain scaffold has **zero** `etc/local-llm/` files), and `jq`-mutates the generated `config.json` — repointing `claude-api`/`openai-api` base URLs at the local LiteLLM gateway (`http://127.0.0.1:4000` / `…/v1`) with dummy `sk-local-mock` keys, and adding `localLlm.model` (+ `localLlm.embeddingModel` when embeddings were chosen). `--local-llm` **requires** `--local-llm-model <model>` (the model is the single source of truth — there is no hardcoded default); the model flags without `--local-llm`, or an invalid model name, are usage errors (exit 64).
   - **Conditional `jq` dependency:** the `--local-llm` path uses `jq` **on the host** (scaffolding may run outside the dev container). The engine **preflights `jq` only when `--local-llm` is set** and exits 64 with a clear message if it's missing; a plain (non-opt-in) scaffold needs no `jq`.
   - **Opt-in is NOT sticky on `--update`:** the `--local-llm` flag is the source of truth for each run. A re-scaffold (`--update`) **without** `--local-llm` over a previously opted-in project **resets** it — drops the `localLlm` block, restores the `claude-api`/`openai-api` base URLs + keys to real-provider defaults, and removes the prior `etc/local-llm/` files. Pass `--local-llm` again on the `--update` to keep (or re-choose) the stack. (`--update` already requires `jq` for its `config.json` merge, so this reset adds no new dependency.)
4. **Report** the created tree to the user.
5. **Git/GitHub phase** (below) — `git init` + initial commit, status line, optional repo + `/init`.
6. **Terminal `/dick` hand-off** (below) — the LAST thing the skill does.

**Scaffold-exit handling (gate before the git phase).** `scaffold.sh` exit codes are surfaced verbatim as user-facing errors; a non-zero exit STOPS the skill — do **not** proceed to git/`/dick`:
- **64** — usage/validation error (e.g. the name failed `^[a-z0-9][a-z0-9-]*$`, or a `__SCAFFOLD_*__` token survived). Re-prompt for a valid name/description, or report the validation message.
- **65** — target/collision error (the target dir is non-empty / has a prior manifest / an unmanaged file collides). Report it and tell the user to pick a fresh `./<name>/`, or re-run with `--force`/`--update` per the message — never silently overwrite.
- **0** — success; continue to the git phase.

## Local LLM opt-in (before the engine runs)

The scaffolded project **always** carries `claude-api` + `openai-api` `services{}` entries pointing at the real providers. This opt-in step instead points them at a **local LiteLLM + Ollama mock stack** (under `etc/local-llm/`), so the app's LLM calls run locally — free, offline-capable, and deterministic in CI. It is **off by default** and fully removable; declining leaves a plain scaffold with **no** `etc/local-llm/` and **no** `localLlm` config block. This is **prose-driven prompting only** — the skill chooses the model with the user and passes the names as flags; it never authors model config itself (the engine + `build-config` do the deterministic work).

Ask, in order (each defaults to the safe choice):

1. **"Install the local LLM mock stack (LiteLLM + Ollama)?"** (default: **no**). If **no**, run the engine with no `--local-llm` flag and skip the rest of this section.
2. **If yes — pick the chat model** (guided menu; the chosen name is passed as `--local-llm-model`):
   - **Lightweight** (laptop/CPU-friendly default) — e.g. `llama3.2:3b` or `qwen2.5:3b`.
   - **More powerful** — e.g. `qwen2.5:7b` or `llama3.1:8b`.
   - **Abliterated** — e.g. `huihui_ai/llama3.2-abliterate` — **caveat:** guardrails removed + quality degradation + the **base model's license** still applies. Never offer this as a default; only when the user explicitly wants it.
   - **Something else** — help the user pick by size / VRAM / task / license (any Ollama model name). The engine validates the entered name against `^[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?$` and **re-prompt on rejection** (exit 64).
3. **Then a second prompt — "Does the project need embeddings?"** (default: **no**). If **yes**, pick an embedding model (default **`nomic-embed-text`**, or **"something else"** — same grammar validation) and pass it as `--local-llm-embed-model`. If **no**, omit the flag entirely (no embeddings entry is written).

Then invoke the engine: `scaffold.sh <name> "<description>" --local-llm --local-llm-model <chat-model> [--local-llm-embed-model <embed-model>]`. The engine lays down `etc/local-llm/`, repoints the base URLs + keys, and writes `localLlm.model` (+ `localLlm.embeddingModel`) into `config.json` — the single source of truth that `build-config` and `system.sh up`/`down` later consume. Reminder: the `--local-llm` path needs **`jq` on the host** (preflighted by the engine; a plain scaffold does not).

## Git/GitHub phase (after a successful scaffold)

Run these as **assistant-workflow steps from the scaffold parent directory** (the dir that now contains `./<name>/`) — every command below uses an explicit `git -C ./<name> ...` so the working directory is unambiguous. This skill instructs the agent; it does not itself execute slash commands. All prompts **default to the safe/no-op choice** (declining leaves the freshly scaffolded files on disk untouched, no repo, no commit); a declined repo or an absent tool degrades gracefully (non-fatal) and the skill still reports overall success.

Ask up front (batch the prompts):
- **Create a GitHub repo?** (default: no) — if yes, ask for the **repo name** (default: the project name).
- **Auto-commit after setup?** (default: no) — when accepted, make the repo's user-opted initial commit. (A commit is not a no-op, so the safe default is to leave the scaffold uncommitted.)
- **Run `/init` after setup?** (default: no).

Then, in order:

1. **`git init`** the project on an explicit `main` branch (`git -C ./<name> init -b main`) — pin the branch with `-b main` rather than relying on the host's `init.defaultBranch`, which may still be `master`; the later `push -u origin main` and the commit-on-`main` bootstrap depend on it.
2. **Status line** — the script + its `statusLine` entry already ship in the scaffolded `.claude/` (`templates/.claude/statusline.sh` + `.claude/settings.json`). It is active by virtue of being copied in; this phase only confirms it (`branch | model | % context`) and **must not rewrite `.claude/settings.json`** — the Stop hook (`hooks.Stop`) lives in the same file and must be left intact.
3. **GitHub repo (optional, only if accepted):** `gh repo create <repo-name> --private --source ./<name>` (best-effort). If `gh` is **not installed / not authenticated**, print a clear non-fatal note ("`gh` unavailable — skipping repo creation; create it later with `gh repo create`") and continue. A declined repo is simply skipped.
4. **`/init` (optional, only if accepted):** run `/init` **only when the host can guarantee it will not clobber the scaffolded `CLAUDE.md` / `.claude/`** without explicit confirmation. The scaffold already authored a complete `CLAUDE.md`, so if there's any risk `/init` overwrites it, **do not run it — print the exact command** (`/init`) for the user to run themselves and move on. Never silently clobber scaffolded files.
5. **Initial commit (optional, only if "auto-commit" accepted):** stage everything and commit on `main`:
   ```bash
   git -C ./<name> add -A
   git -C ./<name> commit -m "chore: initial project scaffold"
   ```
   This is the **deliberate bootstrap exception** to the scaffolded project's own git policy (its `CLAUDE.md` "Git and commits" forbids committing to `main` without explicit user instruction): the repo's *very first* commit is the user-opted bootstrap, made before any other branch exists. If a GitHub repo was created, `git -C ./<name> push -u origin main`.

This commit captures the scaffold (and any `/init` output) and **runs before** the terminal `/dick` hand-off, because `/dick` is persona-locked and may not return control. Committing `/dick`'s later doc edits is a **printed follow-up command**, never relied-on auto-continuation.

## Terminal `/dick` hand-off (the LAST step)

After the git phase + optional commit, offer to boot **`/dick`** (the business-architect advisor, fn-1) against the freshly scaffolded project. This is **terminal** — `/dick` is persona-locked until the user says "goodbye" and does **not** reliably return control, so the skill performs no work after handing off.

- **Ask:** "Boot `/dick` now to fill in the business docs (`docs/business.md`, `strategy.md`, `customers.md`, `priorities.md`, `decisions.md`)?" (default: no).
- **If accepted and `/dick` resolves:** hand off by invoking `/dick` (optionally passing the project's short description as the business-context argument, per `/dick`'s hand-off contract). Do this **last**. Before handing off, **print the follow-up command** the user runs after they say "goodbye" to `/dick`, to commit Dick's doc edits:
  ```bash
  git -C ./<name> add -A && git -C ./<name> commit -m "docs: business docs from /dick" && git -C ./<name> push
  ```
  (On `main` this is again user-opted; on a `change/` branch it follows the normal policy.)
- **If `/dick` is unavailable** (not installed in this marketplace / not resolvable): print a clear, **non-fatal** message — "`/dick` isn't available here; install it and run `/dick` to fill in the business docs" — and still report the overall scaffold as a **success**. Do not hard-depend on `/dick` being installed.
- **If declined:** finish; the scaffold (and optional commit) stand on their own.

## Notes
- Deterministic stamping lives in `scaffold.sh` (tested, 100% coverage) — not in this prose.
- The scaffolded project is a mono-repo: every component is `src/<component>/` with a matching `config.json` `systems[]` entry (tooling like `src/system-cli/` and `tests/` are documented exceptions).
- **Ordering is single and unambiguous:** optional local-LLM opt-in prompt → scaffold → `git init` + status line → optional `/init` → optional **initial commit** → **terminal `/dick` hand-off LAST**.
- The local LLM mock stack lives under `etc/local-llm/` (internal dev tooling, like the observability stack) — it is opt-in, profile-gated, and removable; it is **not** a `systems[]` component.

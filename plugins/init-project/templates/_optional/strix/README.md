# Strix — AI penetration-testing agent (opt-in)

This project opted into **[Strix](https://github.com/usestrix/strix)**, an open-source
autonomous AI security-testing agent: it runs your code dynamically, probes endpoints,
finds vulnerabilities, and validates them with real proofs-of-concept.

The presence of this `etc/strix/` folder is the **install signal** — the dev container's
`.devcontainer/setup.sh` installs the pinned `strix` CLI (best-effort) whenever this
folder exists. Delete `etc/strix/` (or re-scaffold without `--strix`) to opt back out;
the tool is never installed on a project that did not opt in.

> **Authorized use only.** Strix acts like a real attacker. Only ever point it at systems
> you own or are explicitly authorized to test. Running it against third-party targets
> without written permission may be illegal. Keep runs scoped to this project (`./src`)
> and your own dev/staging environments.

## What the dev container provides

- **The `strix` CLI**, installed via `uv` in an isolated tool env with its own Python
  3.12 (the .NET base image ships no 3.12), pinned in `.devcontainer/setup.sh`.
- **Docker** (the `docker-in-docker` feature). Strix runs each agent in a Docker sandbox
  and pulls that sandbox image on first run — Docker must be running.

## Per-user setup (secrets — a one-time follow-up)

The install is container-level; the **LLM credentials are yours** and are read from the
environment (never committed). Export them in your shell (or the container's env):

```bash
export STRIX_LLM="anthropic/claude-sonnet-5"   # litellm "provider/model" form
export LLM_API_KEY="your-api-key"
```

Strix saves the rest of its config to `~/.strix/cli-config.json` on first run.

### Using this project's local LLM mock (if enabled)

If you also scaffolded the **local LLM mock stack** (`etc/local-llm/`, LiteLLM + Ollama),
point Strix at the local gateway instead of a paid provider — free, offline, deterministic:

```bash
export STRIX_LLM="openai/<your-local-model>"   # the model you pulled into Ollama
export LLM_API_KEY="sk-local-mock"
export LLM_API_BASE="http://127.0.0.1:4000/v1" # the LiteLLM gateway
```

Bring the stack up first with `./system.sh up --profile ai` (see `docs/local-llm.md`).

## Running it

```bash
strix --target ./src                      # test this repo's code
strix -n --target http://127.0.0.1:5080   # non-interactive (CI), against the running Api
```

Results are written to `strix_runs/<run-name>/`. Optional knobs: `STRIX_REASONING_EFFORT`
(default `high`; `medium` for a quicker scan) and `PERPLEXITY_API_KEY` (adds web search).

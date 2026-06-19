# __SCAFFOLD_PROJECT_NAME__

__SCAFFOLD_PROJECT_DESCRIPTION__

This is a mono-repo containing every component of the software system. Each component lives in its own `src/<component>/` folder and has a matching entry in `config.json`'s `systems[]` array; external dependencies the system connects to are listed under `services{}`.

> Agent-facing conventions, standards, and working agreements live in [`CLAUDE.md`](CLAUDE.md) and the [`docs/`](docs/) standards. This README is the human onboarding guide.

## Getting started (dev container)

This repo ships a **dev container** so everyone develops against the same toolchain (.NET SDK, Node + Angular CLI, the cloud CLIs, `jq`, Docker, Claude Code, and the configured plugins).

1. Open the repo in an editor that supports dev containers (e.g. VS Code with the Dev Containers extension), or in a Codespace.
2. **Reopen in container** when prompted. The container build runs `setup.sh`, which installs the toolchain and best-effort enables the configured Claude plugins and MCP servers.
3. Once the container is up, you have everything needed to build, test, and run the system.

You can develop without the dev container, but you'll need to install the toolchain yourself — the container is the supported path.

## Configuration

`config.json` is the single source of truth for local development:

- `systems[]` — one entry per component under `src/`, including the `postgres` database and `keycloak` identity provider.
- `services{}` — external dependencies the system connects to (their credentials start as `REPLACE_ME` — fill them in locally). Two are always present: `claude-api` (Anthropic-compatible) and `openai-api` (OpenAI-compatible). When scaffolded with `--local-llm`, the opt-in local LLM mock stack (see below) backs these in local dev.

The `Api` ships a pre-wired **[`ParleyAI`](https://www.nuget.org/packages/ParleyAI)** client (a unified OpenAI/Anthropic chat client, net10) that consumes those `claude-api`/`openai-api` env vars with no caller glue — both providers register as keyed clients (`"openai"` / `"anthropic"`, no default) and emit OpenTelemetry GenAI traces/metrics to the local OTel Collector. See [`docs/config-management.md`](docs/config-management.md) §4.

Generated local-dev secrets (Postgres role passwords, Keycloak admin) are created at scaffold time and committed for single-operator local dev — they are **not** production secrets. Real secrets enter only via `config.deploy.json` (`{{VAR-NAME}}` placeholders the CI/CD pipeline renders at deploy). See [`docs/config-management.md`](docs/config-management.md).

To distribute config into per-component `.env` files (and stamp the runtime Keycloak realm file):

```bash
./system.sh build-config
```

## Running the system

Everything is driven by the root **`system.sh`** dispatcher. Run it with no subcommand (or `help`) to list what's available:

```bash
./system.sh help
```

Common commands:

| Command | What it does |
|---|---|
| `./system.sh build-config` | Distribute `config.json` → per-component `.env`, stamp the Keycloak realm-import file. |
| `./system.sh up` | Bring up the compose stacks — the `postgres` database, the `keycloak` identity provider, and the observability stack (`src/otel-collector/`, `src/prometheus/`, `src/grafana/`). |
| `./system.sh down` | Stop the compose stacks. |
| `./system.sh migrate` | Run EF Core database migrations against the `platform` database. |
| `./system.sh status` | Show the state of the running components. |

A typical first run:

```bash
./system.sh build-config   # generate per-component env + realm file
./system.sh up             # start postgres, keycloak, observability
./system.sh migrate        # apply the database schema
```

## Local LLM mock (opt-in)

If this project was scaffolded with `--local-llm`, it ships an **opt-in,
local-dev-only LLM gateway** under `etc/local-llm/` (LiteLLM + Ollama). It lets the
app's outbound LLM calls hit a **local gateway** (`127.0.0.1:4000`) instead of the
real paid/cloud providers — without any app-code changes. The scaffold repoints the
`claude-api` / `openai-api` `services{}` `base_url`s at the local gateway, so the
`Api` reads the same env vars (`ANTHROPIC_BASE_URL` / `ANTHROPIC_API_KEY` /
`OPENAI_BASE_URL` / `OPENAI_API_KEY`) and simply points them locally.

Two modes, selected by compose profile — the default `./system.sh up` starts
neither:

| Command | What it does |
|---|---|
| `./system.sh up --profile ai-mock` | Deterministic **mock** — LiteLLM only (no Ollama), a single canned response. Fast, free, what CI uses. |
| `./system.sh up --profile ai` | **Real** local inference — LiteLLM + Ollama + a one-shot model pull. For manual dev/demos. |

**Run `./system.sh build-config` before `--profile ai`** — it stamps the chosen
model (from `config.json` → `localLlm.model`) into the gitignored LiteLLM runtime
config and exports it for the model pull. (`--profile ai-mock` needs no stamping.)

```bash
./system.sh build-config         # stamps the local-LLM runtime config + model
./system.sh up --profile ai      # real inference (pulls the model on first boot)
```

Full details — model selection, the optional embeddings model, the GPU override,
the offline / pre-pull workflow, editing the canned mock response, and **complete
removal** — are in [`docs/local-llm.md`](docs/local-llm.md).

## Project layout

| Folder | Purpose |
|---|---|
| `src/` | One sub-folder per component (`.NET` projects, Angular SPAs, `postgres`, `keycloak`), plus `src/system-cli/` for the dispatcher subcommands. |
| `tests/` | Test projects (`tests/<Component>.Tests/`). |
| `docs/` | Development standards and business direction. |
| `etc/` | Supporting tooling, including the observability compose stack and the opt-in local LLM mock stack (`etc/local-llm/`, if scaffolded with `--local-llm`). |
| `.devcontainer/` | Dev container definition and setup. |
| `.claude/` | Claude Code configuration (status line, hooks, settings). |

## Testing

The project targets **100% line and branch coverage** (see [`docs/tdd.md`](docs/tdd.md)). CI runs the full .NET + Angular test suites with the coverage gate on every change.

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
- `services{}` — external dependencies the system connects to (their credentials start as `REPLACE_ME` — fill them in locally).

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
| `./system.sh up` | Bring up the compose stacks — the `postgres` database, the `keycloak` identity provider, and the observability tooling (Grafana + OTel) under `etc/observability/`. |
| `./system.sh down` | Stop the compose stacks. |
| `./system.sh migrate` | Run EF Core database migrations against the `platform` database. |
| `./system.sh status` | Show the state of the running components. |

A typical first run:

```bash
./system.sh build-config   # generate per-component env + realm file
./system.sh up             # start postgres, keycloak, observability
./system.sh migrate        # apply the database schema
```

## Project layout

| Folder | Purpose |
|---|---|
| `src/` | One sub-folder per component (`.NET` projects, Angular SPAs, `postgres`, `keycloak`), plus `src/system-cli/` for the dispatcher subcommands. |
| `tests/` | Test projects (`tests/<Component>.Tests/`). |
| `docs/` | Development standards and business direction. |
| `etc/` | Supporting tooling, including the observability compose stack. |
| `.devcontainer/` | Dev container definition and setup. |
| `.claude/` | Claude Code configuration (status line, hooks, settings). |

## Testing

The project targets **100% line and branch coverage** (see [`docs/tdd.md`](docs/tdd.md)). CI runs the full .NET + Angular test suites with the coverage gate on every change.

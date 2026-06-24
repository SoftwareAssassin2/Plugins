# Dev container standards

This standard governs **how to add any dependency the repo needs to operate** —
a system package, a CLI, a language runtime, a Claude Code plugin/marketplace, an
MCP server, or an editor extension. The dev container itself is *built* under
`.devcontainer/`; this doc is the convention for keeping it the single home for
every dependency. Read it whenever you reach for a tool that isn't already in
the container.

## 1. All dependencies live in the dev container

Anything the repo depends on to operate easily and efficiently belongs in
`.devcontainer/` — no exceptions. This includes:

- **System packages** (e.g. `jq`, `shellcheck`, `shfmt`)
- **CLI tools** (e.g. `gh`, `glab`, the cloud CLIs, `claude`)
- **Language runtimes** (e.g. the .NET SDK, Node)
- **Claude Code marketplaces and plugins** — marketplaces declared in
  `.claude/settings.json`, plugins provisioned via `.devcontainer/setup.sh`
- **MCP servers** — declared in `.mcp.json` / settings (not installed as plugins)
- **Editor extensions** declared under `customizations.vscode.extensions`

**Rationale.** A new contributor — human or agent — should be able to clone the
repo, open it in the dev container, and have *every* dependency this project
needs in a working state. No separate setup steps, no tribal knowledge, no "oh
you also have to install X." If a dependency lives only on someone's host
machine, it doesn't exist for anyone else, and a build will break unexpectedly
the first time someone other than the original author tries it.

## 2. Where each kind of dependency lands

| Dependency type | Where to add it |
|---|---|
| System packages (apt) | `.devcontainer/setup.sh` |
| Pre-built CLI / runtime features | `features` block in `.devcontainer/devcontainer.json` |
| Claude Code marketplaces | `extraKnownMarketplaces` in `.claude/settings.json` |
| Claude Code plugins | provisioned in `.devcontainer/setup.sh` (best-effort install) |
| MCP servers | `.mcp.json` / settings — NOT `claude plugin install` |
| VS Code extensions | `customizations.vscode.extensions` in `.devcontainer/devcontainer.json` |
| Claude Code hooks (e.g. the async-collaboration SessionStart hook) | the script under `.claude/hooks/`, registered in `.claude/settings.json` |
| Runtime service containers (compose-managed) | the component's own `src/<component>/` (e.g. `src/postgres/`, `src/keycloak/`) — NOT `.devcontainer/` |
| Observability stack (compose-managed dev tooling) | its own `src/<component>/` (`src/otel-collector/`, `src/prometheus/`, `src/grafana/`) — NOT `.devcontainer/` |
| Opt-in local LLM mock stack (compose-managed dev tooling) | `etc/local-llm/` (LiteLLM + Ollama) — NOT `.devcontainer/`; see `docs/local-llm.md` |

**Best-effort steps.** Plugin installs, MCP registration, and similar
enable-steps are best-effort: each is isolated so a single failure warns but
does not abort, and a fresh container build / `setup.sh` run succeeds regardless.
Steps that require per-user auth or secrets (signing into a CLI, providing an API
key) are documented as a per-user follow-up — the *installation* is
container-level, the *credentials* are the contributor's. The async
collaboration protocol (see [`docs/collaboration.md`](collaboration.md)) is one
such per-user follow-up: it keys identity off `git config --get user.email`, so
each contributor sets their own git identity in the container (a dev container
may have no `.gitconfig` unless one is mounted) — the hook stays silent until an
identity is present, never guessing.

## 3. What deliberately lives OUTSIDE `.devcontainer/`

The dev container's role is to provide the **development environment** — language
runtimes, CLIs, editor support — that a contributor uses to interact with the
project. The compose-managed containers live outside it, each under its own
`src/<component>/` folder:

- **Runtime service containers that are system components.** `postgres` and
  `keycloak` are part of the system's own architecture and have matching
  `systems[]` entries; they live under `src/postgres/` and `src/keycloak/` with
  their own `docker-compose.yml`, init scripts, and config, brought up via
  `./system.sh up`.
- **The observability stack.** Grafana, Prometheus, and an OpenTelemetry Collector
  are local dev tooling (no `systems[]` entry, not an external `services{}`
  dependency), but they are first-class `src/` components — `src/grafana/`,
  `src/prometheus/`, `src/otel-collector/` — each with its own `docker-compose.yml`.
  Being separate compose projects, they resolve one another by service name over a
  shared Docker network named `observability` that `./system.sh up` creates before
  starting them. They are orchestrated by `./system.sh up` / `down` alongside the
  service components.
- **The opt-in local LLM mock stack.** LiteLLM + Ollama are the *same kind* of
  internal dev tooling (no `systems[]` entry, not an external `services{}`
  dependency), but they are an **opt-in** stack and live under `etc/local-llm/`
  rather than `src/` — laid down only when a project is scaffolded with
  `--local-llm`. They sit behind the `ai`/`ai-mock` compose profiles, so the
  default `./system.sh up` starts none of it; `./system.sh up --profile ai`
  (or `ai-mock`) brings them up alongside the other stacks. See `docs/local-llm.md`.

In every case the dev container provides the `docker` CLI + `docker-in-docker`
feature so a contributor can drive those compose stacks from inside the dev
container, but the stack definitions themselves are part of the platform/tooling
layer, not the dev environment.

**Example — the observability stack.** Grafana + Prometheus + OTel are *not* added
to `.devcontainer/`; they are compose stacks under `src/grafana/`, `src/prometheus/`,
and `src/otel-collector/`, wired into the dispatcher:

```bash
# brings up postgres, keycloak, AND the grafana/prometheus/otel-collector stack
./system.sh up
```

The dev container only guarantees the `docker` CLI exists to run it.

## 4. Checklist before adding a tool to the repo

- Is it added in `.devcontainer/devcontainer.json` features OR
  `.devcontainer/setup.sh` (or, for a runtime stack, the right compose location
  per §2)?
- If it requires per-user setup (auth, secrets), is the per-user step clearly
  documented and the dependency installation itself container-level?
- Does a fresh dev-container build produce a working environment without manual
  intervention?

If the answer to any of those is "no," the dependency isn't really part of the
repo — it's part of someone's personal environment, and that's a regression.

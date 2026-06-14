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
- **CLI tools** (e.g. `gh`, the cloud CLIs, `claude`)
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
| Runtime service containers (compose-managed) | the component's own `src/<component>/` (e.g. `src/postgres/`, `src/keycloak/`) — NOT `.devcontainer/` |
| Internal dev-tooling stacks (compose-managed, not a component) | `etc/` (e.g. `etc/observability/`) — NOT `.devcontainer/` |

**Best-effort steps.** Plugin installs, MCP registration, and similar
enable-steps are best-effort: each is isolated so a single failure warns but
does not abort, and a fresh container build / `setup.sh` run succeeds regardless.
Steps that require per-user auth or secrets (signing into a CLI, providing an API
key) are documented as a per-user follow-up — the *installation* is
container-level, the *credentials* are the contributor's.

## 3. What deliberately lives OUTSIDE `.devcontainer/`

The dev container's role is to provide the **development environment** — language
runtimes, CLIs, editor support — that a contributor uses to interact with the
project. Two kinds of compose-managed containers live outside it:

- **Runtime service containers that are system components.** `postgres` and
  `keycloak` are part of the system's own architecture and have matching
  `systems[]` entries; they live under `src/postgres/` and `src/keycloak/` with
  their own `docker-compose.yml`, init scripts, and config, brought up via
  `./system.sh up`.
- **Internal dev-tooling stacks that are NOT components.** The observability
  stack — Grafana + an OpenTelemetry Collector — is dev tooling, not a system
  component and not an external `services{}` dependency. It lives under
  `etc/observability/` (per the catch-all convention) and is orchestrated by
  `./system.sh up` / `down` alongside the service components.

In every case the devcontainer provides the `docker` CLI + `docker-in-docker`
feature so a contributor can drive those compose stacks from inside the dev
container, but the stack definitions themselves are part of the platform/tooling
layer, not the dev environment.

**Example — adding the observability stack as a dependency.** Suppose a
contributor wants Grafana + OTel available locally. It is *not* added to
`.devcontainer/`; it is a compose stack under `etc/observability/` wired into the
dispatcher:

```bash
# brings up postgres, keycloak, AND the etc/observability/ Grafana+OTel stack
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

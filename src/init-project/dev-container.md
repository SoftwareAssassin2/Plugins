# Dev container standards

## 1. All dependencies live in the dev container

Anything the repo depends on to operate easily and efficiently belongs in `.devcontainer/` — no exceptions. This includes:

- **System packages** (e.g. `jq`, `shellcheck`, `shfmt`)
- **CLI tools** (e.g. `gcloud`, `gh`, `claude`)
- **Language runtimes** (e.g. Python, Node)
- **Claude Code marketplaces and plugins** — marketplaces declared in `.claude/settings.json`, plugins provisioned via `.devcontainer/setup.sh`
- **Editor extensions** declared under `customizations.vscode.extensions`

**Rationale.** A new contributor — human or agent — should be able to clone the repo, open it in the dev container, and have *every* dependency this project needs in a working state. No separate setup steps, no tribal knowledge, no "oh you also have to install X." If a dependency lives only on someone's host machine, it doesn't exist for anyone else, and a build will break unexpectedly the first time someone other than the original author tries it.

**Where each kind of dependency lands:**

| Dependency type | Where to add it |
|---|---|
| System packages (apt) | `.devcontainer/setup.sh` |
| Pre-built CLI / runtime features | `features` block in `.devcontainer/devcontainer.json` |
| Claude Code marketplaces | `extraKnownMarketplaces` in `.claude/settings.json` |
| Claude Code plugins | Provisioned in `.devcontainer/setup.sh` (best-effort install) |
| VS Code extensions | `customizations.vscode.extensions` in `.devcontainer/devcontainer.json` |
| Runtime service containers (e.g. Postgres via docker-compose) | `platform/<name>-db/`, `platform/<name>-api/`, etc. — NOT `.devcontainer/` |

**Service containers (compose-managed services like Postgres) deliberately live OUTSIDE `.devcontainer/`.** The devcontainer's role is to provide the *development environment* — language runtimes, CLIs, editor support — that a contributor uses to interact with the project. Runtime services that the project ships as part of its own architecture (the platform-db, future microservices, etc.) are the *substrate the dev env interacts with*, not part of the dev env itself. They live under `platform/<name>-db/`, `platform/<name>-api/`, etc., with their own `docker-compose.yml`, init scripts, and migrations, and are brought up via project dispatchers like `./system.sh start`. The devcontainer provides the `docker` CLI + `docker-in-docker` feature so a contributor can drive those compose stacks from inside the dev container, but the service definitions themselves are part of the platform layer, not the dev environment.

**Checklist before adding a tool to the repo:**

- Is it added in `.devcontainer/devcontainer.json` features OR `.devcontainer/setup.sh`?
- If it requires per-user setup (auth, secrets), is the per-user step clearly documented and the dependency installation itself container-level?
- Does a fresh dev container build produce a working environment without manual intervention?

If the answer to any of those is "no," the dependency isn't really part of the repo — it's part of someone's personal environment, and that's a regression.

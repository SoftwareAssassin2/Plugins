---
satisfies: [R4]
---

## Description
Author the dev container template: `.devcontainer/devcontainer.json` (base image + pinned features) + `.devcontainer/setup.sh` (script-installed tools, Claude Code, Codex CLI, and the 9 enabled plugins). Best-effort optional installs. (Nine integrations = seven marketplace plugins via `claude plugin` + two MCP servers `context7`/`github-mcp-server` via `templates/.mcp.json`.)

**Size:** M
**Files:** `src/init-project/templates/.devcontainer/devcontainer.json`, `src/init-project/templates/.devcontainer/setup.sh`, `src/init-project/templates/.mcp.json`

## Approach (from docs-scout, pin versions)
- **Base image:** `mcr.microsoft.com/devcontainers/dotnet:1-9.0`. **Features** (pin major, commit lockfile): `ghcr.io/devcontainers/features/node:2`, `aws-cli:1`, `azure-cli:1`, `github-cli:1`; gcloud via community `ghcr.io/dhoeric/features/google-cloud-cli:1.0.1` (flag non-first-party, pin exact). Angular CLI via npm in setup.sh, **pinned to the single declared Angular version** (the root `package.json` (canonical, single source) source that .12 + .13 also consume — no independent version). **Also add `docker-in-docker` (or `docker-outside-of-docker`) + `jq`** (pinned) — `system.sh up/down` drives `docker compose` and `build-config` parses `config.json` via `jq`; without them the advertised quickstart fails.
- **setup.sh** (`set -e` required steps; optional wrapped `|| echo warn`): Angular CLI (`npm i -g @angular/cli`), DuckDB CLI (install script, pin), **Atlassian CLI `acli`** (Jira + Confluence), Claude Code (`curl -fsSL https://claude.ai/install.sh | bash`), **Codex CLI** (official install, pin); MCP servers `context7` + `github-mcp-server` are declared in a **build-time `templates/.mcp.json`** (committed, complete — NOT written at runtime by setup.sh; coexists with `.claude/settings.json` from fn-2….2). Then register the marketplace by its **published git remote** (`SoftwareAssassin2/Plugins` — NOT the local `./src/` sources, which a scaffolded project does not contain) + best-effort enable the **seven marketplace plugins** (`dick`, `grill-me`, `handoff`, `tdd`, `ubiquitous-language`, Playwright `preferred-browser-automation-plugin`, flow-next `preferred-ralph-loops-plugin`) via `claude plugin marketplace add <remote>` + `claude plugin install`, AND configure two **MCP servers** — `context7` and GitHub MCP (`github-mcp-server`) — via `.mcp.json`/settings (NOT `claude plugin install`). The committed **`templates/.mcp.json` is the canonical outcome** for the MCP servers (build-time-complete); the `claude plugin`/CLI enable steps are **best-effort/advisory smoke only** (CLI syntax may drift — failures are non-fatal warnings, never blockers).
- VS Code extensions under `customizations.vscode.extensions`. Toolchain stays in `.devcontainer/`; services (postgres/keycloak/observability) are compose stacks outside it.

## Investigation targets
**Required:**
- `src/init-project/templates/docs/dev-container.md` (from fn-2….8) — dep-placement table
- `.claude/settings.json` + `.claude-plugin/marketplace.json` — marketplace/enable shapes

## Acceptance
- [ ] devcontainer.json: base `devcontainers/dotnet:1-9.0` + pinned node/aws-cli/azure-cli/github-cli (official) + gcloud (community `:1.0.1`)
- [ ] setup.sh installs Angular CLI, DuckDB, `acli`, Claude Code (install.sh), Codex CLI
- [ ] setup.sh adds the marketplace by **remote git URL** (not local ./src) + best-effort enables 7 marketplace plugins (`claude plugin`); configures 2 MCP servers (`context7`, GitHub MCP via `.mcp.json`/settings); failures isolated/non-fatal
- [ ] devcontainer adds docker-in-docker (or -outside-of-docker) + `jq` (pinned); Angular CLI pinned by **reading** the single declared version source (owned by .12 — this task depends on .12; does NOT duplicate the version)
- [ ] `templates/.mcp.json` declares `context7` + `github-mcp-server` (build-time-complete; coexists with `.claude/settings.json`)
- [ ] A fresh container build / setup.sh run completes successfully (smoke-tested)

## Done summary
Authored the build-time-complete dev container as template files: .devcontainer/devcontainer.json (dotnet:1-9.0 base + pinned node/aws/azure/github-cli features, community gcloud :1.0.1, docker-in-docker, jq, vscode extensions, onCreate setup.sh hook), a token-free executable .devcontainer/setup.sh (set -euo pipefail, idempotent; installs Angular CLI pinned by reading package.json, dotnet-ef via tool manifest, version-pinned DuckDB + Codex CLI, acli, Claude Code; best-effort enables the SoftwareAssassin2/Plugins marketplace + 7 curated plugins), and a build-time-complete .mcp.json declaring context7 + github-mcp-server. settings.json now declares the marketplace remote. +32 scaffold_test.sh assertions (132 -> 164 passing). Codex impl-review: SHIP (after one NEEDS_WORK -> pinned DuckDB/Codex).
## Evidence
- Commits: ff009eb138fec5a724f1d930ec12a72cec1d152a, 3284139522d9b64e72e1444c5e464010f08755e9, f6c7efc1c92ae00a1fd58ee76295f81934ecf763
- Tests: bash src/init-project/tests/scaffold_test.sh (164 passed, 0 failed), shellcheck src/init-project/templates/.devcontainer/setup.sh (clean), bash -n setup.sh (ok), jq validation of .mcp.json + settings.json + devcontainer.json-after-comment-strip (all valid)
- PRs:
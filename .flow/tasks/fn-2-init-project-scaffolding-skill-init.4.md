---
satisfies: [R4]
---

## Description
Author the scaffolded **dev container** template: `.devcontainer/devcontainer.json` (pinned features) + `.devcontainer/setup.sh` (script-installed tools, Claude Code, and this marketplace's plugins). Optional installs are best-effort so one failure doesn't abort the lifecycle.

**Size:** M
**Files:** `src/init-project/templates/.devcontainer/devcontainer.json`, `src/init-project/templates/.devcontainer/setup.sh`

## Approach (from docs-scout)
- **devcontainer.json `features`** (pin to major, commit lockfile): `ghcr.io/devcontainers/features/dotnet:2`, `aws-cli:1`, `azure-cli:1`, `github-cli:1`; gcloud via community `ghcr.io/dhoeric/features/google-cloud-cli:1` (flag as non-first-party).
- **setup.sh** (`set -e` for required steps; optional steps wrapped `|| echo warn`):
  - DuckDB CLI (install script, pin version)
  - **Atlassian CLI (`acli`)** — covers both Jira and Confluence (no separate Jira CLI)
  - Claude Code via `curl -fsSL https://claude.ai/install.sh | bash` (NOT the deprecated npm package)
  - **Codex CLI** (OpenAI) — install via its official method (npm `@openai/codex` or the published binary/installer; pin the version); best-effort
  - **Register this marketplace and enable its five plugins** — `dick`, `grill-me`, `handoff`, `tdd`, `ubiquitous-language` — via `claude plugin marketplace add` + `claude plugin install <plugin>@<marketplace>` (best-effort; verify subcommand syntax against the installed CLI version).
- VS Code extensions under `customizations.vscode.extensions`.
- Toolchain stays in `.devcontainer/`; observability services go to fn-2….5, NOT here.

## Notes
- The five plugins come from THIS marketplace. `grill-me`/`handoff`/`tdd`/`ubiquitous-language` already exist and are registered; `dick` is delivered by fn-1 (spec dependency) — until fn-1….1 lands, the `dick` enable line should be best-effort like the others.

## Investigation targets
**Required:**
- `src/project-init/dev-container.md` — dep-placement table (where each kind lands)
- `.claude/settings.json` — existing marketplace/plugin enablement shape
- `.claude-plugin/marketplace.json` — this marketplace's name/source for the `marketplace add` line

## Acceptance
- [ ] devcontainer.json installs .NET, AWS, Azure, gh (official features) + gcloud (community feature), versions pinned
- [ ] setup.sh installs DuckDB, Atlassian CLI (`acli`, covering Jira + Confluence), Claude Code (via install.sh), Codex CLI
- [ ] setup.sh registers this marketplace and best-effort-enables `dick`, `grill-me`, `handoff`, `tdd`, `ubiquitous-language`; optional failures are non-fatal
- [ ] A fresh container build / setup.sh run completes successfully (smoke-tested)

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

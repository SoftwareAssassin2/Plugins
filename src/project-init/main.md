# Software System

Mono-repo containing all code in the software system - infrastruction, pipelines, applications, CLIs, and scripts.

Shared infrastructure and tooling for H&G's game catalog. Each subsystem exposes a root-level dispatcher (e.g. `play.sh`, `system.sh`) that delegates to scripts under `platform/<name>-cli/`.

## Root layout

The repo root is intentionally kept small. Only these directories belong at the top level:

| Folder | Purpose |
|---|---|
| `.claude/` | Claude Code configuration (agents, settings, plugins). |
| `.devcontainer/` | Devcontainer image, setup scripts, editor extensions. |
| `.flow/` | flow-next specs, tasks, and memory. |
| `docs/` | Human- and agent-readable development standards and strategy. |
| `src/` | Contains sub-folders for each project in the mono-repo. |
| `etc/` | Catch-all for supporting work that doesn't belong in any of the above (tests, caches, ancillary tooling). |

**Convention:** new directories default to living under `etc/`. Only promote a directory to the root when there's a compelling reason — e.g., it's a peer concept to `src/`, or a tool (git, devcontainer, Claude Code) requires it at the root. If you're unsure, put it under `etc/` and revisit later.

## How development standards are documented

Each development standard lives in its own file under `docs/<topic>.md`. CLAUDE.md is loaded into every agent session, so the **Standards index** below acts as an always-on table of contents — agents see which standards exist and pull the full doc into context only when the current task touches it.

When adding a new standard:

1. Write it in `docs/<topic>.md`.
2. Add a row to the Standards index below with a one-line trigger describing when an agent should reference it.

## How development should be approached

All development should follow a TDD pattern.

## Standards index

| Document | Reference when… |
|---|---|
| `docs/dev-container.md` | Adding any dependency (system package, CLI, runtime, Claude plugin/marketplace, or editor extension) the repo needs to operate. |
| `docs/config-management.md` | Adding, removing, or distributing configuration settings. |
| `docs/tdd.md` | . Writing or modifying tests, adding new code that must hit 100% coverage, or touching CI coverage gates. |

## Strategic references

Documents that capture what we're building and why — load when scope, prioritization, or kill/keep judgment is in play.

| Document | Reference when… |
|---|---|
| `docs/business.md` | Making strategic, scope, prioritization, or kill/keep decisions about the software system. |
| `docs/roadmap.md` | Checking what's planned, in progress, or done in the cross-cutting MVP and subsequent iterations; deciding whether to pick up an item or add a new one. |

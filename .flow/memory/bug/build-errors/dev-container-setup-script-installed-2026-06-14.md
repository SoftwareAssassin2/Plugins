---
title: Dev container setup script installed DuckDB + Codex CLI unpinned
date: "2026-06-14"
track: bug
category: build-errors
module: src/init-project/templates/.devcontainer/setup.sh
tags: [devcontainer, reproducibility, version-pinning, scaffold, setup-script]
problem_type: build-error
symptoms: "Container builds non-reproducible: DuckDB/Codex tracked latest, drifting over time"
root_cause: "Script-only tool installs used floating installers (curl|bash latest, npm global w/o version)"
resolution_type: fix
related_to: [bug/build-errors/template-gitignore-silently-drops-2026-06-14]
---

## Problem
The dev container setup.sh template installed two script-only tools unpinned:
DuckDB via `curl https://install.duckdb.org | bash` (tracks "latest") and Codex
CLI via `npm install -g @openai/codex` (floating). Container builds were not
reproducible — the same Dockerfile/devcontainer could install different tool
versions over time, drifting behavior between contributors and CI.

## Solution
Declared exact-version constants near the top of setup.sh and threaded them
through: `DUCKDB_VERSION` passed via the installer's `DUCKDB_INSTALL_VERSION`
env var, and `CODEX_VERSION` via `@openai/codex@<ver>`. This mirrors the
existing convention where devcontainer FEATURES are pinned in devcontainer.json
and Angular CLI is pinned by reading the root package.json single source.
(src/init-project/templates/.devcontainer/setup.sh)

## Prevention
When authoring container/setup scripts, pin EVERY externally-installed tool to
an exact version (declared constant or single-source read) — never pipe a
"latest" installer or use a floating npm global. Added scaffold_test.sh
assertions that grep for the version-pin pattern so an unpinned regression fails
the suite.

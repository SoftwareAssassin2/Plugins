---
name: init-project
description: Scaffold a brand-new opinionated mono-repo project with Chris's preferred defaults (root layout, CLAUDE.md, dev container, standards docs, system.sh dispatcher CLI, a starter .NET solution + Angular SPAs, Postgres + Keycloak). Use when starting a new project / "init project" / "scaffold a new repo". Asks only for a project name + short description, then copies the build-time-complete templates and applies minimal placeholder substitution.
argument-hint: "[optional: project name / description]"
---

# init-project

Stand up a new software project from copy-ready templates. **The templates are authored complete; this skill copies them and substitutes only the project name/description** (+ generates per-project secrets). It never authors content at scaffold time.

## What it does (orchestration)
1. **Ask** for a **project name** (`^[a-z0-9][a-z0-9-]*$`) and a **short description** — nothing else.
2. **Run the bundled engine:** `scaffold.sh <name> "<description>"` (see [scaffold.sh](scaffold.sh)). It copies `templates/` into `./<name>/`, substitutes `__SCAFFOLD_PROJECT_NAME__` / `__SCAFFOLD_PROJECT_DESCRIPTION__`, generates a fresh URL-safe value for each `__SCAFFOLD_GEN_URLSAFE__` occurrence, maps `_CLAUDE.md` → `CLAUDE.md`, writes `.init-project-manifest.json`, and fails if any `__SCAFFOLD_*__` token is left behind.
   - Refuses a non-empty target unless `--force` (first scaffold, no collision with unmanaged files) or `--update` (re-scaffold over a prior output; `config.json` preserved).
   - `--dry-run` prints the planned tree without writing.
3. **Report** the created tree to the user.
4. **Git/GitHub phase + optional `/dick` hand-off** — *authored separately (fn-2 task .7); appended here when built.*

## Notes
- Deterministic stamping lives in `scaffold.sh` (tested, 100% coverage) — not in this prose.
- The scaffolded project is a mono-repo: every component is `src/<component>/` with a matching `config.json` `systems[]` entry (tooling like `src/system-cli/` and `tests/` are documented exceptions).

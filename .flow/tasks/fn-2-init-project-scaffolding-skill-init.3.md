---
satisfies: [R3, R8]
---

## Description
Produce the generalized **config-management standard** template plus the scaffolded `config.json` shape, encoding the user's defined model. Reduce the existing game-catalog-specific `config-management.md` to the portable kernel + this standard.

**Size:** M
**Files:** `src/init-project/templates/docs/config-management.md`, `src/init-project/templates/config.json`

## The standard (defined)
- **`config.json` at repo root is the single source of truth.**
- Top-level **`systems[]`** — one entry per component, in **1:1 correspondence with `src/<component>/` folders**. Each entry defines that component's own configuration (e.g. a database component → database name, credentials, host, port).
- Top-level **`services{}`** (peer to `systems[]`) — one entry per external service the system connects to (e.g. `claude-api` → API keys/credentials).
- A **build step distributes per-component `.env`** files from `config.json`; runtime components read **environment variables only** (12-factor, factor III).
- `config.json` is never read at runtime by components.

## Approach
- Keep the portable kernel from `config-management.md`: §1 single-source-of-truth and §6 12-factor framing.
- Remove game-specific sections: `config-management.md:18-36` (play.sh telemetry, `games[]`), `:40-62` (platform-db Postgres roles), `:63-82` (platform-api OAuth) — but KEEP a generic worked example (e.g. a database component entry + a `claude-api` service entry) to illustrate the schema.
- Ship a starter `config.json` template with empty `systems: []` and `services: {}` (or minimal illustrative entries with placeholder credentials).

## Investigation targets
**Required:**
- `src/project-init/config-management.md:1-17,96-115` — portable kernel (§1, §6)
- `src/project-init/config-management.md:40-62` — Postgres example to generalize into a neutral "database component" systems entry

## Acceptance
- [ ] config-management.md documents the `systems[]` + `services{}` model with a generic worked example; no Postgres/OAuth/play.sh/games references
- [ ] `systems[]` ↔ `src/<component>/` 1:1 invariant and the build-step `.env`/12-factor contract are stated
- [ ] A starter `config.json` template ships with `systems[]` and `services{}` top-level keys
- [ ] Standard is self-contained and stampable into a new project's `docs/config-management.md`

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

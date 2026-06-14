---
satisfies: [R1, R2, R6, R23]
---

## Description
Establish `/init-project` as a registered, invocable skill AND build the bundled deterministic **scaffold engine** it delegates to. Early proof point: skill → script → skeleton into `./<name>/` with collision-safe placeholder substitution and refuse-non-empty.

**Size:** M
**Files:** rename `src/project-init/` → `src/init-project/` (the raw source docs move with it; later tasks read them post-rename); `src/init-project/SKILL.md`; `src/init-project/.claude-plugin/plugin.json`; `.claude-plugin/marketplace.json`; `src/init-project/scaffold.sh`; `src/init-project/templates/` (dir for stamped assets).

## Approach
- Rename dir so dir + plugin name + skill `name:` read `init-project`. SKILL.md frontmatter per `src/dick/SKILL.md:1-5` (name, description, argument-hint `"[optional: project name / description]"`); body = orchestration skeleton (ask name + description → run scaffold.sh → report tree). The git/GitHub phase + `/dick` hand-off tail are authored in fn-2….7.
- Register in `.claude-plugin/marketplace.json:49-54` shape (`source: "./src/init-project"`); add `plugin.json` mirroring `src/dick/.claude-plugin/plugin.json`.
- `scaffold.sh`: scaffold into `./<project-name>/`; **refuse non-empty target** unless one of two modes: **`--force`** = first-time scaffold into a non-empty dir, proceeds only when template paths don't collide with existing **unmanaged** files (refuses on real collisions); **`--update`** = re-scaffold over a prior init-project output, overwriting only paths listed in `.init-project-manifest.json` (normalized relative paths — no `..`/absolute) that are also in the current template output; never wholesale-deletes. `config.json` is special-cased: `--update` preserves it (merge new non-secret keys, retain generated secrets + operator edits); explicit `--replace-config` required to rotate/replace it. Scaffold writes/refreshes `.init-project-manifest.json` (paths+hashes); tests cover stale/tampered manifests + both modes; validate name `^[a-z0-9][a-z0-9-]*$`; `--dry-run` prints the planned tree, writes nothing; `set -euo pipefail`; source-guarded `main "$@"` (testable by fn-2….6).
- **Collision-safe placeholder grammar (research):** substitution token must NOT collide with Angular `{{ }}` interpolation, Keycloak realm JS, or EF templating — use **namespaced `__SCAFFOLD_PROJECT_NAME__` / `__SCAFFOLD_PROJECT_DESCRIPTION__`** tokens (the `__SCAFFOLD_*__` namespace is collision-proof — it can't match mixed-case identifiers like EF's `__EFMigrationsHistory`). Substitute via **bash parameter-expansion** (NOT sed — anti-injection). After stamping, a **leftover-token gate** `grep -rE '__SCAFFOLD_[A-Z0-9_]+__'` over the output must return nothing.
- **Copy + substitute ONLY (R23):** the engine copies the pre-authored templates verbatim + substitutes tokens; it does not author/LLM-fill content. **Sole generative exception:** replace `__SCAFFOLD_GEN_URLSAFE__` secret sentinels with freshly generated URL-safe passwords (`openssl rand -base64 32 | tr -d '=' | tr '/+' '_-'`) per project. Map `_CLAUDE.md` → the target's `CLAUDE.md` at stamp time.

## Investigation targets
**Required:**
- `src/dick/SKILL.md:1-5` — frontmatter/argument-hint exemplar (fresh)
- `.claude-plugin/marketplace.json:49-54` — local plugin entry shape
- `src/project-init/system-cli/system.sh:13,30` — bash conventions (set -euo pipefail, BASH_SOURCE)
- `src/dick/.claude-plugin/plugin.json` — plugin.json shape

## Acceptance
- [ ] `src/init-project/SKILL.md` valid frontmatter (`name: init-project`, `argument-hint`); registered in marketplace.json (`source: "./src/init-project"`); `/init-project` resolves after reload
- [ ] `scaffold.sh <name> <description>` creates `./<name>/`, substitutes `__SCAFFOLD_PROJECT_NAME__`/`__SCAFFOLD_PROJECT_DESCRIPTION__`, maps `_CLAUDE.md`→`CLAUDE.md`; leftover-token scan returns nothing
- [ ] Refuses non-empty target unless `--force` (first scaffold; proceeds only if no collision with unmanaged files) or `--update` (overwrites only `.init-project-manifest.json`-listed paths); never wholesale-deletes; manifest paths normalized (no `..`/absolute); invalid name exits non-zero; `--dry-run` writes nothing
- [ ] Engine copies + substitutes only (no prose authoring); bash param-expansion (no sed); `set -euo pipefail` + source-guarded `main`
- [ ] each `__SCAFFOLD_GEN_URLSAFE__` occurrence replaced with an **independently generated, distinct, URL-safe** value (test asserts all generated local secrets differ); no committed-static secrets
- [ ] `--update` preserves `config.json` (merges only new non-secret keys, retains secrets + operator edits); `--replace-config` required to rotate/replace it (tested)

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

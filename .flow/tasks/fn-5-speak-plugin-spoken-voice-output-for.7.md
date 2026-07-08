---
satisfies: [R7, R8, R11]
---

## Description

Author the plugin's documentation — `SKILL.md`, a human-facing `README.md` (the doc the unreachable-listener hook notice points to), and a one-line update to the dev-container standards doc for the new `nc` dependency.

**Prerequisite:** fn-5.3's container→host proof is green (or the fallback transport is recorded) before this task starts — the README must document whatever transport actually shipped.

**Size:** M
**Files:** `plugins/speak/SKILL.md`, `plugins/speak/README.md`, `plugins/init-project/templates/docs/dev-container.md`

## Approach

- `SKILL.md`: frontmatter (`name: speak`, `description` starting with an action verb + a "Use when…" trigger, optional `argument-hint`) + prose covering the five commands, host/forward modes, the manual listener, the toggle, and the debounced notice. Mirror the frontmatter style of `plugins/init-project/SKILL.md:1-4` and `plugins/dick/SKILL.md:1-4`.
- `README.md`: one-paragraph "what it does"; host listener setup (**from the workspace root, in a Mac terminal**, run `./plugins/speak/bin/speak --serve` — not a container terminal); a **per-context dependency table** (NOT "everything everywhere"): local CLI → `say` (base64 is wire-transport only, not local); forward client → `base64`/usable `nc`; listener → `say`/`base64`/usable `nc`; Stop hook → `jq` + the CLI — so `jq` is hook-only (incl. on the host) and `base64`/`nc` are forward/listener only — plus what to install if missing (preferred netcat: `netcat-openbsd`); env vars (`SPEAK_PORT`, `SPEAK_MAX_CHARS`, `SPEAK_SESSION`, and `SPEAK_DATA_DIR` — which controls BOTH the listener runtime-state dir AND the authoritative toggle dir, and is required (or `CLAUDE_PLUGIN_DATA`) for terminal `speak on/off` outside Claude, else "toggle unavailable"); the macOS firewall first-bind caveat; the remote/Codespaces out-of-scope note. This must match the workspace-relative command the hook notice emits (R8).
- `dev-container.md` (exact insertion point — the §2 system-packages table/list — to be confirmed against the file at implementation time): note **`netcat-openbsd`** (the preferred, capability-compatible netcat — generic `netcat` may lack connect-timeout/EOF-shutdown/`-z`) as a container-side dependency for the speak plugin (the §2 system-packages guidance currently lists `jq`, `postgresql-client`). The README install guidance names the same package.
- Note the Windows-later OS seam in SKILL.md/README (R11).
- **Provisioning (not auto-installed):** state explicitly that a project using speak from a Dev Container must add `netcat-openbsd` (+ `jq`) to its `.devcontainer/setup.sh` per the dev-container standard — the plugin does not auto-provision (no `.devcontainer` in this plugins repo). README + `dev-container.md` both say this.

## Investigation targets
**Required:**
- `plugins/init-project/SKILL.md:1-4`, `plugins/dick/SKILL.md:1-4` — frontmatter style
- `plugins/init-project/templates/docs/dev-container.md:10-49` — system-packages guidance to extend
**Optional:**
- the fn-5 spec body (command behaviors to document)

## Acceptance
- [ ] `plugins/speak/SKILL.md` present with correct frontmatter + command behaviors, matching existing SKILL.md style
- [ ] `plugins/speak/README.md` documents host listener setup (workspace-relative `speak --serve`), a **per-context dependency table** (local → `say` only; forward → `base64`/`nc`; listener → `say`/`base64`/`nc`; hook → `jq`+CLI), env vars (incl. `SPEAK_DATA_DIR`), firewall caveat, and remote-OOS — matching the hook notice (R8, R7)
- [ ] `dev-container.md` AND README name BOTH `netcat-openbsd` AND `jq` (for hook/transcript parsing) as container deps to add to `.devcontainer/setup.sh` for projects using speak
- [ ] Windows-later OS seam noted in SKILL.md/README (R11)
- [ ] The README's setup steps match the self-contained command the `.4` hook notice emits (`./plugins/speak/bin/speak --serve`); the notice does not hard-depend on the README (R8)

## Done summary
Authored the speak plugin docs: SKILL.md (frontmatter matching repo style; five /speak:* commands, local/forward modes, manual listener, toggle + debounced notice, Windows-later seam) and README.md (host listener setup matching the hook notice's exact `./plugins/speak/bin/speak --serve` command, per-context dependency table, netcat-openbsd/jq install + devcontainer provisioning guidance, env vars incl. SPEAK_DATA_DIR's dual role, doctor/--hook/--listener four-way diagnostics, macOS firewall caveat, remote-OOS). Added the netcat-openbsd + jq speak-plugin note to the init-project dev-container.md system-packages guidance. Review: SHIP (triage_skip — docs-only diff).
## Evidence
- Commits: 94e8b829541d06c11e1f5bdafccb63442c82044d
- Tests: ./plugins/speak/tests/coverage.sh --plain (baseline + post-change: cli_test 0 failed, listener_test 0 failed, hook_test 46 passed 0 failed)
- PRs:
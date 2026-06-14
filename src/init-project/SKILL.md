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
4. **Git/GitHub phase** (below) — `git init` + initial commit, status line, optional repo + `/init`.
5. **Terminal `/dick` hand-off** (below) — the LAST thing the skill does.

**Scaffold-exit handling (gate before step 4).** `scaffold.sh` exit codes are surfaced verbatim as user-facing errors; a non-zero exit STOPS the skill — do **not** proceed to git/`/dick`:
- **64** — usage/validation error (e.g. the name failed `^[a-z0-9][a-z0-9-]*$`, or a `__SCAFFOLD_*__` token survived). Re-prompt for a valid name/description, or report the validation message.
- **65** — target/collision error (the target dir is non-empty / has a prior manifest / an unmanaged file collides). Report it and tell the user to pick a fresh `./<name>/`, or re-run with `--force`/`--update` per the message — never silently overwrite.
- **0** — success; continue to step 4.

## Git/GitHub phase (after a successful scaffold)

Run these as **assistant-workflow steps inside the new project dir (`./<name>/`)** — this skill instructs the agent; it does not itself execute slash commands. All prompts **default to the safe/no-op choice**; a declined repo or an absent tool degrades gracefully (non-fatal) and the skill still reports overall success.

Ask up front (batch the prompts):
- **Create a GitHub repo?** (default: no) — if yes, ask for the **repo name** (default: the project name).
- **Auto-commit after setup?** (default: yes) — make the repo's initial commit.
- **Run `/init` after setup?** (default: no).

Then, in order:

1. **`git init`** the project (`git -C ./<name> init`). This brand-new repo's default branch is `main`.
2. **Status line** — the script + its `statusLine` entry already ship in the scaffolded `.claude/` (`templates/.claude/statusline.sh` + `.claude/settings.json`). It is active by virtue of being copied in; this phase only confirms it (`branch | model | % context`) and **must not rewrite `.claude/settings.json`** — the Stop hook (`hooks.Stop`) lives in the same file and must be left intact.
3. **GitHub repo (optional, only if accepted):** `gh repo create <repo-name> --private --source ./<name>` (best-effort). If `gh` is **not installed / not authenticated**, print a clear non-fatal note ("`gh` unavailable — skipping repo creation; create it later with `gh repo create`") and continue. A declined repo is simply skipped.
4. **`/init` (optional, only if accepted):** run `/init` **only when the host can guarantee it will not clobber the scaffolded `CLAUDE.md` / `.claude/`** without explicit confirmation. The scaffold already authored a complete `CLAUDE.md`, so if there's any risk `/init` overwrites it, **do not run it — print the exact command** (`/init`) for the user to run themselves and move on. Never silently clobber scaffolded files.
5. **Initial commit (optional, only if "auto-commit" accepted):** stage everything and commit on `main`:
   ```bash
   git -C ./<name> add -A
   git -C ./<name> commit -m "chore: initial project scaffold"
   ```
   This is the **deliberate bootstrap exception** to the scaffolded project's own git policy (its `CLAUDE.md` "Git and commits" forbids committing to `main` without explicit user instruction): the repo's *very first* commit is the user-opted bootstrap, made before any other branch exists. If a GitHub repo was created, `git -C ./<name> push -u origin main`.

This commit captures the scaffold (and any `/init` output) and **runs before** the terminal `/dick` hand-off, because `/dick` is persona-locked and may not return control. Committing `/dick`'s later doc edits is a **printed follow-up command**, never relied-on auto-continuation.

## Terminal `/dick` hand-off (the LAST step)

After the git phase + optional commit, offer to boot **`/dick`** (the business-architect advisor, fn-1) against the freshly scaffolded project. This is **terminal** — `/dick` is persona-locked until the user says "goodbye" and does **not** reliably return control, so the skill performs no work after handing off.

- **Ask:** "Boot `/dick` now to fill in the business docs (`docs/business.md`, `strategy.md`, `customers.md`, `priorities.md`, `decisions.md`)?" (default: no).
- **If accepted and `/dick` resolves:** hand off by invoking `/dick` (optionally passing the project's short description as the business-context argument, per `/dick`'s hand-off contract). Do this **last**. Before handing off, **print the follow-up command** the user runs after they say "goodbye" to `/dick`, to commit Dick's doc edits:
  ```bash
  git -C ./<name> add -A && git -C ./<name> commit -m "docs: business docs from /dick" && git -C ./<name> push
  ```
  (On `main` this is again user-opted; on a `change/` branch it follows the normal policy.)
- **If `/dick` is unavailable** (not installed in this marketplace / not resolvable): print a clear, **non-fatal** message — "`/dick` isn't available here; install it and run `/dick` to fill in the business docs" — and still report the overall scaffold as a **success**. Do not hard-depend on `/dick` being installed.
- **If declined:** finish; the scaffold (and optional commit) stand on their own.

## Notes
- Deterministic stamping lives in `scaffold.sh` (tested, 100% coverage) — not in this prose.
- The scaffolded project is a mono-repo: every component is `src/<component>/` with a matching `config.json` `systems[]` entry (tooling like `src/system-cli/` and `tests/` are documented exceptions).
- **Ordering is single and unambiguous:** scaffold → `git init` + status line → optional `/init` → optional **initial commit** → **terminal `/dick` hand-off LAST**.

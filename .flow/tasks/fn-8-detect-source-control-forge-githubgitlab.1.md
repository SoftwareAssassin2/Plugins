---
satisfies: [R1, R2]
---
## Description
Build the `detect-source-control` plugin (its own plugin so it keeps the bare `/detect-source-control` name) and implement the forge-detection ladder plus the parseable stdout contract that the four `merge-request:*` skills consume.

**Size:** M
**Files:** `plugins/detect-source-control/.claude-plugin/plugin.json`, `plugins/detect-source-control/SKILL.md`, `plugins/detect-source-control/scripts/detect.sh`, `plugins/detect-source-control/tests/detect_test.sh`

## Approach
- Mirror the single-skill plugin layout of `plugins/dick/` (plugin.json + SKILL.md at plugin root).
- Reuse the git-remote / host-inference + `glab` JSON handling pattern from the prior-art triage script.
- **Detection algorithm — two phases, precedence-major, stop at first confident match:**
  - **Phase A (remotes):** iterate remotes in precedence order [`origin`, `upstream`, then others by name]. For each remote, test (1) exact host (`github.com`/`gitlab.com`, normalizing SSH + HTTPS) then (2) host substring (`github`/`gitlab`). The first remote that yields a confident forge wins and returns immediately — `origin` is authoritative; a later remote NEVER overrides an earlier confident one.
  - **Phase B (repo-global, only if no remote resolved):** (3) CI-config `.github/` -> github / `.gitlab-ci.yml` -> gitlab, BOTH present -> `unsupported`; (4) repo-scoped read-only CLI probe `gh repo view` -> github / `glab repo view` -> gitlab, BOTH succeed -> `unsupported`; (5) else `unsupported`.
- **CLI probing rules:** forge detection uses only repo-scoped `gh repo view` / `glab repo view` (read-only). `auth status` is NOT a forge signal. Run `auth status` only *after* forge detection, solely to populate `cli_authenticated`.
- All CLI probes MUST be read-only; never run a mutating command.

## Stdout contract (exact)
Emit newline-delimited `key=value` lines, all keys present, in this order, no surrounding prose:
```
forge=github|gitlab|unsupported
host=<hostname>|unknown
cli=gh|glab|none
cli_authenticated=true|false
supported=true|false
```
- `forge=unsupported` is a successful result.
- `cli` = the resolved forge's CLI, only if that CLI is installed: github -> `gh` (else `none`); gitlab -> `glab` (else `none`); an irrelevant installed CLI does not count; forge=unsupported -> always `none`.
- `host=unknown` when no remote host could be parsed.
- `cli_authenticated=false` when `cli=none` or unauthenticated.
- `supported=true` iff `forge` is `github` or `gitlab`.
- **Exit codes:** exit `0` whenever the block is emitted (including `unsupported`); non-zero only for operational errors where the block cannot be produced (not a git repo, git missing).

## Investigation targets
**Required:**
- `~/.claude/skills/gitlab-mr-review/scripts/triage.sh` -- host inference, `glab` JSON parsing, `GITLAB_REPO` fallback
- `plugins/dick/.claude-plugin/plugin.json` -- plugin.json field shape (see inline shape below if unavailable)
- `plugins/dick/SKILL.md` -- SKILL.md frontmatter conventions (name/description/user-invocable)
- `plugins/init-project/tests/scaffold_test.sh` -- bundled-test harness pattern

**Optional:**
- `plugins/init-project/scaffold.sh` -- bundled executable shell-script convention

**plugin.json shape (inline, from `plugins/dick`):**
```json
{
  "name": "detect-source-control",
  "displayName": "Detect Source Control",
  "version": "0.1.0",
  "description": "<one-line>",
  "author": { "name": "Chris Green (Software Assassin)" }
}
```

## Acceptance
- [ ] `plugins/detect-source-control/` exists with `.claude-plugin/plugin.json` (name `detect-source-control`) and a root `SKILL.md` (bare-name skill).
- [ ] Phase A precedence-major remote resolution implemented (origin -> upstream -> others; per remote: exact host then substring; first confident remote wins, no later override), normalizing SSH and HTTPS remotes.
- [ ] Phase B fallbacks implemented only when no remote resolves: CI-config (BOTH present -> unsupported), repo-scoped read-only CLI probe (BOTH succeed -> unsupported), else unsupported.
- [ ] Emits the exact stdout block (ordered `key=value`), with the documented `cli` (resolved-forge-CLI-only), `host=unknown`, and exit-code (0 on success incl. unsupported) semantics.
- [ ] Only read-only `gh`/`glab` commands are used; `auth status` used only to populate `cli_authenticated` after forge detection, never as a forge signal.
- [ ] Skill is directly user-invocable and consumable by other skills.
- [ ] `tests/detect_test.sh` covers: github.com, gitlab.com, self-hosted host-substring (github + gitlab), precedence (origin=gitlab + upstream=github -> gitlab because origin wins), `.github/` CI fallback, `.gitlab-ci.yml` CI fallback, BOTH CI signals -> unsupported, mocked `gh repo view` probe, mocked `glab repo view` probe, BOTH CLI probes succeed -> unsupported, unauthenticated CLI (`cli_authenticated=false`), "auth exists but repo probe fails" (must NOT classify on auth alone), resolved-forge-CLI-absent-but-other-CLI-present -> `cli=none`, no-remote -> Phase B / unsupported, and exit `0` on `unsupported`.

## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:

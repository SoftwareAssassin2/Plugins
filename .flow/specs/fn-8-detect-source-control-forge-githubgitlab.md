## Conversation Evidence

> user: "Let's discusss the Creation of a package of skills to assist in PRs/MRs in Github/GitLab. They should include /detect-source-control, /merge-request, /merge-request-review, and /merge-request-fix."
> user: "It should use git commands to determine if the source control system is GitHub, GitLab, or something else. If it's something else then the other skills will not be supported."
> user: "If host match fails use all those secondary signals you mentioned. Also attempt to use the GitLab CLI and GitHub CLI to determine which one works on the repo, without executing any commands that can have a harmful impact on the repo."
> user (output): "Stdout + invokable".
> user (packaging): "/merge-request:create /merge-request:review /merge-request:fix /merge-request:post-findings ... and leave /detect-source-control with the name we already decided on."

## Goal & Context
<!-- 80% [user], 20% [paraphrase] -->

`detect-source-control` is the foundational, provider-agnostic primitive for a package of PR/MR skills spanning GitHub and GitLab. It determines which forge a repo uses so the other skills can branch on `gh` vs `glab`; when the forge is neither, the dependent skills are unsupported. It is the shared dependency of the four `merge-request:*` skills. [user] [paraphrase]

## Architecture & Data Models
<!-- 60% [user], 40% [paraphrase] -->

Shipped as its **own plugin** with a single skill at the plugin root, invoked bare as `/detect-source-control`. It is deliberately separate from the `merge-request` plugin so it keeps its colon-free name (a plugin-bundled skill would be forced to `merge-request:detect-source-control`). The four `merge-request:*` skills depend on it cross-plugin. Both this plugin and the `merge-request` plugin are registered in `.claude-plugin/marketplace.json`. [user] [paraphrase]

**Detection algorithm** — two phases; stops at the first confident match:

**Phase A — remotes (precedence-major).** Evaluate remotes in precedence order: `origin`, then `upstream`, then remaining remotes by name. For each remote, apply the remote-derived signals in order: (1) exact host (`github.com` -> github, `gitlab.com` -> gitlab; SSH + HTTPS normalized), then (2) host substring (`github` -> github, `gitlab` -> gitlab, covering self-hosted like `github.acme.com` / `gitlab.internal`). The **first remote that yields a confident forge wins** and is returned immediately — `origin` is authoritative, so a later remote never overrides an earlier confident one (no cross-remote conflict override).

**Phase B — repo-global fallbacks (only if no remote resolved).**
  3. **CI-config:** `.github/` -> github, `.gitlab-ci.yml` -> gitlab. If BOTH are present -> `unsupported`.
  4. **Repo-scoped read-only CLI probe:** `gh repo view` succeeding -> github; `glab repo view` succeeding -> gitlab. If BOTH succeed -> `unsupported`. `auth status` alone is NOT a forge signal (it proves global auth, not that this repo belongs to that forge).
  5. Else -> `unsupported`.

## API Contracts
<!-- 70% [user], 30% [paraphrase] -->

Parseable stdout block, emitted as newline-delimited `key=value` lines (one key per line, no surrounding prose, keys always present and in this order):

```
forge=github|gitlab|unsupported
host=<hostname>|unknown
cli=gh|glab|none
cli_authenticated=true|false
supported=true|false
```

- `forge=unsupported` is a **successful detection result**, not an error.
- `cli` is the CLI *for the resolved forge* and only when that CLI is available: forge=github -> `gh` iff `gh` is installed else `none`; forge=gitlab -> `glab` iff `glab` is installed else `none`. An irrelevant installed CLI (e.g. `glab` present but forge=github) does NOT count — `cli=none`. forge=unsupported -> always `cli=none`.
- `host=unknown` when no remote host could be parsed (e.g. no remotes; detection fell through to Phase B).
- `cli_authenticated` is populated via `auth status` for the resolved CLI *after* forge detection; `false` when the CLI is `none` or unauthenticated.
- `supported=true` iff `forge` is `github` or `gitlab`.

**Exit codes:** exit `0` whenever the stdout contract is emitted, **including `forge=unsupported`**. Non-zero only for operational/script failures where the block cannot be produced (e.g. not a git repo, git unavailable). Consumers rely on exit `0` + `supported=false` to trigger the hard-stop, never on a non-zero exit.

Runnable directly by a user; consumed by the four `merge-request:*` skills. [user] [paraphrase]

## Edge Cases & Constraints
<!-- 90% [user], 10% [paraphrase] -->

- CLI probes must be strictly read-only/non-mutating — never anything that can harmfully affect the repo. Forge detection uses repo-scoped `repo view`; `auth status` is used only to fill `cli_authenticated`. [user] [paraphrase]
- Self-hosted / Enterprise hosts (arbitrary domain) resolve via the secondary-signal ladder (host substring, then Phase B), not host-equality alone. [user] [paraphrase]
- SSH and HTTPS remote forms both normalized to extract the host. [paraphrase]
- Multiple / renamed / fork remotes: resolved strictly by precedence — `origin` wins if it confidently classifies (via exact host or substring); only if `origin` is inconclusive do `upstream` then others get a turn. A confident earlier remote is never overridden by a later one. [paraphrase]
- Both CI signals present (`.github/` and `.gitlab-ci.yml`) with no remote resolution: `unsupported`. [paraphrase]
- Both CLI probes succeed (`gh repo view` and `glab repo view`) with no remote/CI resolution: `unsupported`. [paraphrase]
- No remotes at all: host=unknown, detection falls through to Phase B (CI-config / CLI probe), else `unsupported`. [paraphrase]

## Acceptance Criteria

- **R1:** Determines the forge (GitHub / GitLab / unsupported) from git remotes plus secondary signals, applying **precedence-major** remote resolution (origin -> upstream -> others; first confident remote wins) then repo-global CI-config and repo-scoped read-only `gh`/`glab repo view` fallbacks, running no mutating commands. Ambiguous Phase-B cases (both CI signals, or both CLI probes succeeding) resolve to `unsupported`. [user] [paraphrase]
- **R2:** Emits the parseable stdout block exactly as specified in API Contracts (ordered `key=value` lines with the documented `cli`/`host`/exit-code semantics), exits `0` on successful detection including `unsupported`, is directly user-invocable, and is the shared dependency consumed by the four `merge-request:*` skills. [user] [paraphrase]
- **R3:** The `supported=false` hard-stop contract is **documented** as the shared reference the four `merge-request:*` skills follow (each skill will call `detect-source-control` and hard-stop with a clear message when `supported=false`). Enforcement inside each skill is delivered by fn-9..fn-12; fn-8 owns the contract doc only. [user] [paraphrase]
- **R4:** The package ships as two plugins — `detect-source-control` (bare-name, single skill, fully implemented here) and `merge-request` (registered plugin **shell**: `plugin.json` + marketplace entry, structured for the `skills/` subdir; the four namespaced skills themselves are delivered by fn-9..fn-12). Both plugins are registered in `.claude-plugin/marketplace.json`. [paraphrase]

## Boundaries
<!-- 90% [user] -->

- GitHub and GitLab only; any other forge is `unsupported` (Bitbucket/Azure out of scope). [user]
- Does not itself open, review, or modify PRs/MRs — detection only. [paraphrase]

## Decision Context

Kept as a separate plugin purely to preserve the bare `/detect-source-control` name while remaining the shared dependency of the `merge-request` package — mirroring the repo's existing cross-plugin dependency pattern (e.g. init-project → dick). Remote precedence is authoritative (origin first) rather than "highest-confidence rung across all remotes", so mixed-remote repos classify by the canonical remote the user works against, matching the "use secondary signals only when host match fails" intent. [paraphrase]

## Requirement coverage

| R-ID | Task |
|------|------|
| R1, R2 | fn-8.1 |
| R3, R4 | fn-8.2 |

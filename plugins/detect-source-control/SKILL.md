---
name: detect-source-control
description: Detect whether the current git repository's forge is GitHub, GitLab, or unsupported, and emit a parseable key=value block (forge/host/cli/cli_authenticated/supported). Provider-agnostic, strictly read-only. Use when you need to know which forge a repo uses before running gh/glab, or as the shared dependency of the merge-request:* skills.
argument-hint: "(no arguments — run inside a git repo)"
---

# detect-source-control

Determine which source-control forge the **current git repository** belongs to —
GitHub, GitLab, or (anything else) unsupported — and print a small, parseable
block that other skills and humans can branch on. Detection is **strictly
read-only**: it never runs a command that can mutate the repo or the forge.

## How to run

From anywhere inside the target git repository:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect.sh"
```

(Equivalently, invoke `/detect-source-control` and read its stdout.)

## Output contract

Newline-delimited `key=value` lines — all keys always present, in this exact
order, with no surrounding prose:

```
forge=github|gitlab|unsupported
host=<hostname>|unknown
cli=gh|glab|none
cli_authenticated=true|false
supported=true|false
```

- **`forge=unsupported` is a successful result**, not an error.
- **`host`** is the hostname of the remote that resolved the forge (e.g.
  `github.com`, or a self-hosted `gitlab.internal`); `unknown` when no remote
  resolved (detection fell through to the repo-global fallbacks).
- **`cli`** is the CLI *for the resolved forge* and only when that CLI is
  installed: github → `gh` (else `none`), gitlab → `glab` (else `none`). An
  irrelevant installed CLI does not count; `forge=unsupported` → always `none`.
- **`cli_authenticated`** is `true` only when `cli` is set and that CLI reports
  an authenticated session; `false` otherwise.
- **`supported`** is `true` iff `forge` is `github` or `gitlab`.

## Exit codes

- **`0`** whenever the block is emitted — **including `forge=unsupported`**.
- Non-zero **only** for operational failures where the block cannot be produced:
  git not installed (`2`), or not inside a git repository (`3`).

Consumers must key the hard-stop off `supported=false` **and** exit `0`, never
off a non-zero exit.

## Detection algorithm

Two phases, precedence-major, stopping at the first confident match:

1. **Phase A — remotes (authoritative).** Remotes are evaluated in precedence
   order: `origin`, then `upstream`, then the rest by name. For each remote,
   its URL (SSH or HTTPS) is normalized to a host, then classified by **exact
   host** (`github.com`/`gitlab.com`) and, failing that, **host substring**
   (`github`/`gitlab`, covering self-hosted hosts). The **first** remote that
   confidently classifies wins and is returned immediately — a later remote
   never overrides an earlier confident one.
2. **Phase B — repo-global fallbacks (only if no remote resolved).**
   - **CI config:** `.github/` → github, `.gitlab-ci.yml` → gitlab; **both
     present → unsupported**.
   - **Read-only CLI probe:** `gh repo view` succeeding → github, `glab repo
     view` succeeding → gitlab; **both succeed → unsupported**.
   - Otherwise → unsupported.

`auth status` is **never** a forge signal (it proves global auth, not that this
repo belongs to that forge); it runs only *after* forge detection to populate
`cli_authenticated`.

## Consumed by

This skill is the shared, provider-agnostic dependency of the `merge-request:*`
skills. Each of those calls it first and hard-stops with a clear message when
`supported=false`.

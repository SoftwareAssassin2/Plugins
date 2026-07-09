# merge-request

Plugin shell hosting the GitHub/GitLab pull/merge-request workflow skills. The
four namespaced skills are delivered by later tasks and live under `skills/`:

| Skill | Invoked as | Delivered by |
|-------|-----------|--------------|
| create        | `/merge-request:create`         | fn-9  |
| review        | `/merge-request:review`         | fn-11 |
| fix           | `/merge-request:fix`            | fn-10 |
| post-findings | `/merge-request:post-findings`  | fn-12 |

Each `skills/<name>/SKILL.md` is auto-discovered by Claude Code — the manifest
carries no `skills` array. This task creates the plugin **shell only**
(`plugin.json` + marketplace registration + this contract doc); the skills and
their per-skill enforcement land in fn-9..fn-12.

`SOUL.md` in this directory is the hand-authored "Chris" review persona consumed
by `/merge-request:review`. It is authored separately and is not part of this
shell scaffolding.

## The `supported=false` hard-stop contract (shared reference)

Every `merge-request:*` skill is forge-specific — it drives `gh` (GitHub) or
`glab` (GitLab). Before doing any forge work, each skill **MUST** first resolve
the repo's forge via the bare `/detect-source-control` skill (a separate plugin,
depended on cross-plugin) and hard-stop when the repo is not a supported forge.

This is the single contract all four skills follow. It is documented here in
fn-8; the actual per-skill call + hard-stop is wired in fn-9..fn-12.

### Step 1 — run detection

Before any forge work, invoke the `/detect-source-control` skill (separate
plugin, depended on cross-plugin) and capture its stdout block plus exit code.
It is the shared entry point — skills go through it rather than reaching into
another plugin's install path, which is not guaranteed to be a stable sibling
directory. Conceptually:

```
detection = stdout of /detect-source-control
detect_exit = its exit code
```

`detect-source-control` emits an ordered, newline-delimited `key=value` block
(one key per line, keys always present and in this order):

```
forge=github|gitlab|unsupported
host=<hostname>|unknown
cli=gh|glab|none
cli_authenticated=true|false
supported=true|false
```

### Step 2 — parse and hard-stop

Two conditions both trigger an immediate stop, before any `gh`/`glab` work:

1. **Operational failure** — `detect_exit` is non-zero. Detection could not
   produce the block at all (not a git repo, `git` unavailable). Stop and report
   the failure.
2. **Unsupported forge** — `detect_exit` is `0` **and** `supported=false`
   (equivalently `forge=unsupported`). This is a *successful* detection result,
   not an error. Stop immediately.

Critically: consumers key the unsupported hard-stop on **exit `0` +
`supported=false`**, never on a non-zero exit. `forge=unsupported` is a normal,
exit-`0` outcome. Only genuine operational failures are non-zero.

### Step 3 — the stop message

When stopping on `supported=false`, the message MUST be clear and name the
detected forge/host so the user understands why the skill can't help — e.g.:

> This repository's forge is not supported (`forge=unsupported`,
> `host=bitbucket.org`). The `merge-request:*` skills work only with GitHub and
> GitLab. Nothing was changed.

No forge command runs after a hard-stop. Only `forge=github` or `forge=gitlab`
(i.e. `supported=true`) lets a skill proceed, branching on `cli`/`forge` to
choose `gh` vs `glab`.

### Reference contract summary

- Call `/detect-source-control` first, before any forge action.
- Non-zero exit → operational failure → stop.
- Exit `0` + `supported=false` → unsupported forge → stop with a forge/host-named message.
- Exit `0` + `supported=true` → proceed, branching on `forge`/`cli`.
- Detection is strictly read-only; the hard-stop guarantees no mutating forge
  command runs against an unsupported repo.

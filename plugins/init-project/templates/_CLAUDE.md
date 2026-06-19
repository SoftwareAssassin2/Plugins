# __SCAFFOLD_PROJECT_NAME__

__SCAFFOLD_PROJECT_DESCRIPTION__

This is a **mono-repo containing every component of the software system** — infrastructure, pipelines, applications, CLIs, services, and scripts all live here together.

## The component ↔ folder ↔ config invariant

Every component of the system obeys a 1:1 correspondence:

> **Each component is a subfolder `src/<component>/` AND has a matching entry in `config.json`'s top-level `systems[]` array.**

External dependencies the system *connects to* (not part of it) are entries under a peer `services{}` object in the same `config.json` (e.g. a third-party API).

**Exceptions** — these are NOT `systems[]` components:

| Path | Why it's exempt |
|---|---|
| `src/system-cli/` | Repo tooling (the `system.sh` dispatcher's subcommands), not a deployable component. |
| `src/otel-collector/`, `src/prometheus/`, `src/grafana/` | The observability stack — local dev tooling brought up by `system.sh up`. No host/port secrets to distribute, so no `systems[]` entries (they wire together over a shared Docker network, not via `config.json`). |
| `etc/local-llm/` | The opt-in local LLM mock stack (LiteLLM + Ollama) — local dev tooling brought up by `system.sh up --profile ai`/`ai-mock`. It *backs* the `claude-api`/`openai-api` `services{}` entries in local dev; it is not itself a `systems[]` component or a `services{}` entry. `src/Api/` reaches those services through the **pre-wired [ParleyAI](https://www.nuget.org/packages/ParleyAI) client** (a NuGet `<PackageReference>`, not a `src/` component) — a unified OpenAI/Anthropic chat client registered keyed-per-provider (no default) with GenAI OpenTelemetry. See `docs/local-llm.md` and `docs/config-management.md`. |
| `tests/<Component>.Tests/` | Test projects live under the top-level `tests/` directory, not `src/`. |

When you add a new component, add BOTH the `src/<component>/` folder AND the `systems[]` entry — never one without the other.

## Root layout

The repo root is intentionally kept small. Only these directories belong at the top level:

| Folder | Purpose |
|---|---|
| `.claude/` | Claude Code configuration (agents, settings, hooks, status line). |
| `.devcontainer/` | Dev container image, setup scripts, editor extensions. |
| `.flow/` | flow-next specs, tasks, and memory. |
| `docs/` | Human- and agent-readable development standards and business direction. |
| `src/` | One sub-folder per component in the mono-repo (plus `src/system-cli/`). |
| `tests/` | Test projects (`tests/<Component>.Tests/`), separate from `src/`. |
| `etc/` | Catch-all for supporting work that doesn't belong above (caches, ancillary scripts, scratch tooling). |

**Convention:** new directories default to living under `etc/`. Only promote a directory to the root when there's a compelling reason — it's a peer concept to `src/`, or a tool (git, dev container, Claude Code) requires it at the root. If you're unsure, put it under `etc/` and revisit later.

## How development standards are documented

Each development standard lives in its own file under `docs/<topic>.md`. This `CLAUDE.md` is loaded into every agent session, so the **Standards index** below acts as an always-on table of contents — agents see which standards exist and pull the full doc into context only when the current task touches it.

When adding a new standard:

1. Write it in `docs/<topic>.md`.
2. Add a row to the Standards index below with a one-line trigger describing when an agent should reference it.

## Standards index

| Document | Reference when… |
|---|---|
| `docs/ubiquitous-language.md` | Naming domain concepts, modeling entities, or reconciling code terms with business terms (Domain-Driven Design). |
| `docs/architecture.md` | Making design decisions — module boundaries, deep vs. shallow interfaces, layering, where logic belongs. |
| `docs/tdd.md` | Writing or modifying tests, adding code that must hit 100% coverage, or touching CI coverage gates. |
| `docs/config-management.md` | Adding, removing, or distributing configuration settings (`config.json` → per-component `.env`), or calling an LLM provider through the pre-wired ParleyAI client (keyed `IAiChatClient` for `"openai"`/`"anthropic"`, flat env-var overrides, GenAI OpenTelemetry). |
| `docs/dev-container.md` | Adding any dependency (system package, CLI, runtime, Claude plugin/marketplace, MCP server, or editor extension) the repo needs to operate. |
| `docs/local-llm.md` | Working with the opt-in local LLM mock stack — switching between the `ai` (real inference) and `ai-mock` (deterministic mock) profiles, choosing a model, editing the canned mock response, GPU/offline workflows, or removing the stack. |
| `docs/front-end.md` | Building or changing an Angular SPA — routing, build profile, styling, testing. |
| `docs/keycloak.md` | Touching authentication, the Keycloak realm, identity, or database session-context / row-level security. |

## Business direction

Strategic context — what we're building and why — is owned and maintained by the `/dick` advisor under `docs/`. Load these when scope, prioritization, or kill/keep judgment is in play (see the business-consult directive below).

| Document | Reference when… |
|---|---|
| `docs/business.md` | Understanding what the business does and the problem it solves. |
| `docs/strategy.md` | Making strategic, scope, or kill/keep decisions. |
| `docs/customers.md` | Reasoning about who the users are and what they need. |
| `docs/priorities.md` | Checking what's planned, in progress, or done; deciding whether to pick up or add an item. |
| `docs/decisions.md` | Understanding why a past business/product decision was made before revisiting it. |

## How development should be approached

Follow a **test-driven development** pattern (see `docs/tdd.md`). Design deep modules with narrow interfaces — *design the interface, then delegate the implementation* — and keep feedback loops short.

### Simplicity over complexity

Complexity is the enemy. It accumulates incrementally — a special case here, a shortcut there — until the system is hard to change (software entropy). Actively fight it: prefer the simpler design even when it costs more up front, because complexity compounds (Ousterhout, *A Philosophy of Software Design*). When two designs both work, choose the one that hides the most complexity behind the cleanest interface.

### Domain modeling

Use the **ubiquitous language** — the same terms in code, tests, conversation, and docs (Evans, *Domain-Driven Design*). Details and the project's evolving glossary live in `docs/ubiquitous-language.md`.

## Working agreements (always apply)

These are inline directives — they apply to every session, not just when a doc is open.

### Brevity and DRY
- Be brief. Don't restate what's already written. Don't duplicate logic, config, or prose — reference the single source of truth instead.
- **Sacrifice grammar for concision** where it makes the meaning clearer or shorter. Bullet fragments beat padded sentences.

### Brutal honesty
- Tell the truth even when it's unwelcome. If a plan is bad, say so. If an approach won't work, say so before building it.
- No flattery, no hedging to please. Disagree and explain when you think the user is wrong.

### Verify before claiming
- **Never claim something works without verifying it.** Run the test, read the file, check the output — then report.
- Don't assert that a file/function/value exists from memory; confirm it. "I believe" and "should" are signals to go check.

## Business-consult sub-agent (before non-trivial work)

Before starting any non-trivial piece of work, **consult the business direction** so the work is aligned with what the project is actually trying to achieve:

1. **Spawn a sub-agent** to read the project's own business docs — `docs/business.md`, `docs/strategy.md`, `docs/customers.md`, `docs/priorities.md`, `docs/decisions.md` — and report back the relevant direction for the task at hand.
2. The sub-agent acts in a **neutral consult-only role**. It **MUST NOT invoke or adopt the `/dick` persona** — that persona is interactive-only and cannot run in a sub-agent or headless context. It reads the docs and summarizes; it does not interview, opine in-character, or edit the docs.
3. **Never fabricate business direction.** If the docs don't answer the question, surface the gap explicitly and suggest the user run an interactive `/dick` session to fill it — do not invent strategy, priorities, or customer needs.

## Git and commits

- **Never commit to the default branch (`main`) without explicit user instruction.** If a changeset on `main` seems commit-worthy, *ask first*.
- **Commit freely on non-default branches.** No need to ask before committing on a feature/change branch.
- **Always `push` after any commit.**
- **Name new branches `change/<description-of-change>`** — description only, no epic/ticket/spec-id prefix (e.g. `change/add-rate-limiter`, not `change/PROJ-12-add-rate-limiter`).
- **Create worktrees under `.worktrees/`** (which is gitignored).

## How documentation is organized

- **`CLAUDE.md` (this file)** — a thin, always-on index: root layout, the Standards index, and the inline working agreements above. Depth lives in `docs/` and is pulled in on demand. Kept current via the auto-update reminder (below).
- **`README.md`** — human-facing onboarding (what the project is, dev-container quickstart, how to run things). Distinct from this agent-facing file.
- **Sub-agent convention** — delegate read-heavy exploration, research, and independently-parallelizable work to sub-agents. Use them to keep the main thread's context focused on the task, not on raw file-reading.

## Keeping the docs current (auto-update reminder)

A non-blocking **Stop hook** (in `.claude/`) reminds you to refresh `CLAUDE.md` and the `docs/` standards when a session surfaced something worth persisting. It never edits files silently.

**When you surface a doc-worthy update** (a new convention, a corrected fact, a standard that changed), create the marker file so the reminder fires at the end of the session:

```bash
touch .claude/.claude-md-dirty
```

At the next Stop the hook prints the reminder and clears the marker. If you didn't surface anything doc-worthy, do nothing — the hook stays silent.

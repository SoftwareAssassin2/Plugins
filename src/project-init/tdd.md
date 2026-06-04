# Testing standards

## 1. Coverage requirement

All game-level and platform-level code must hit **100% line coverage and 100% branch coverage** under automated tests. CI fails any PR whose coverage drops below 100% on either metric.

If code is too hard to test, restructure it until it is testable — that's the point of the requirement.

## 2. Scope

**In scope (must hit 100%):**

- **Platform CLIs** — every subcommand script under `platform/<name>-cli/` (Python *and* shell), plus their shared helpers (e.g. `_common.py`, `_ads.py`).
- **Platform services** — `platform/platform-api/` and any future service.
- **Unity C# game code** — everything under `games/<name>/` that has **no Unity dependency** (scoring, economy, save/load, state machines, AI decisions, data models, configuration parsing). Push logic into these classes ("Humble Object" pattern) so the exemption below stays narrow.
- **The shared game library** (see `docs/roadmap.md` → "Shared game library") once it exists.

**Out of scope:**

- Unity engine glue — `MonoBehaviour` subclasses, `ScriptableObject` editor scripts, `.unity` scene files, `.prefab` files, asset-import code. Keep these thin; if a glue class grows logic, extract the logic into an in-scope class.
- The root-level dispatcher scripts `play.sh` and `system.sh` *only* — they exist solely to route to subcommand scripts and contain no business logic. The subcommands they dispatch to are in scope above, regardless of language.

**Why these carve-outs.** Unity Play Mode tests are slow, flaky, and hard to parallelize; the industry-standard fix is to separate logic from engine glue and test the logic exhaustively. This standard codifies that pattern — the carve-out is narrow *because the rule forces good architecture*.

## 3. What "covered" means

Both metrics required for every PR:

- **Line coverage** — every executable line is hit by at least one test.
- **Branch coverage** — every `if`/`else`, `switch`/`match`, ternary, and short-circuit boolean is exercised in both directions.

Coverage tooling cannot detect shallow assertions (a test that calls a function and asserts nothing still "covers" it). Reviewers must reject PRs whose tests don't assert the behavior they claim to cover.

## 4. Enforcement

- Every PR runs the full test suite with coverage reporting. CI fails if line or branch coverage falls below 100%.
- Skipped tests (e.g. `requires_creds`, `requires_integration_env`, Docker probes from `etc/tests/conftest.py`) do not count toward coverage. Branches inside them must still be covered — typically by mocking the external dependency in a unit test.
- Generated code (e.g. Flyway migration output, OpenAPI clients) is excluded via the coverage config, not by ignoring the rule.

## 5. Tooling

| Codebase | Coverage tool | How to run |
|---|---|---|
| Platform Python | `pytest-cov` | `pytest --cov --cov-branch --cov-fail-under=100` |
| Platform shell (CLI subcommands) | `kcov` | `kcov --include-path=platform coverage-out/ <test runner>` — branch coverage measured via `--bash-method=DEBUG`. Wired in alongside the Python suite. |
| Games (Unity C#, in-scope pure logic) | `coverlet` via `dotnet test` | Finalized when the first game lands |

CI wiring lands as a separate PR alongside the first commit that satisfies the standard.

## 6. Test location

**Libraries own their tests.** Reusable components — the shared game library, future SDK packages, anything intended to be consumed by more than one project — ship their tests inside the library itself, not in a sibling directory and not duplicated across consumers. One library, one test suite, run from the library's own root.

**Applications and services keep tests under `etc/tests/`.** Platform CLIs (`platform/<name>-cli/`) and services (`platform/platform-api/`) are applications, not libraries — their tests live under `etc/tests/<topic>/` and import the code under test via the `sys.path` convention in `etc/tests/conftest.py`.

The split exists so a library can be lifted out of the repo (or installed by a future external consumer) with its tests intact, while application tests stay co-located with the rest of the platform test infrastructure.

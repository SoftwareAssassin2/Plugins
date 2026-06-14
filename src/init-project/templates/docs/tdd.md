# Testing standards

This is the project's testing **standard** — the coverage rule, what's in scope,
and the tooling. The *practice* of test-driven development (the red-green-refactor
loop, tracer bullets, how to write a good test) is documented by the `/tdd`
skill installed in this repo. Use `/tdd` when writing tests; use this doc to know
what the bar is and which tools enforce it. The two are complementary — this doc
does not restate the loop.

## 1. Coverage requirement

All production code must hit **100% line coverage and 100% branch coverage**
under automated tests. CI fails any PR whose coverage drops below 100% on either
metric.

If code is too hard to test, restructure it until it is testable — that's the
point of the requirement. Testability is a design property; a behavior that
resists testing is usually badly factored, not just badly tested (see
[architecture.md](architecture.md)).

## 2. Scope

**In scope (must hit 100%):**

- **.NET** — `Framework`, `DataAccess`, `BusinessLogic`, `Api`, and any future
  project, tested by their `tests/<Component>.Tests/` suites.
- **Angular SPAs** — `MarketingSite` and `WebApp` component/service logic, via
  their Jest suites.
- **Shell** — the `system.sh` dispatcher's subcommand scripts under
  `src/system-cli/` and their `_`-prefixed shared helpers.

Push logic out of untestable glue and into plain, testable units (the
"**Humble Object**" pattern): keep the engine glue, the framework boilerplate,
and the bootstrap wiring thin, and move every decision into a class or function
you can exercise directly. The exclusions below stay narrow precisely *because*
the rule forces this good architecture.

**Out of scope (excluded from the gate — see §5):** generated code and bootstrap
glue that contains no decisions of its own. These are listed concretely below;
keep them thin, and if one grows logic, extract that logic into an in-scope unit.

## 3. What "covered" means

Both metrics are required for every PR:

- **Line coverage** — every executable line is hit by at least one test.
- **Branch coverage** — every `if`/`else`, `switch`/`match`, ternary, and
  short-circuit boolean is exercised in both directions.

Coverage tooling cannot detect shallow assertions (a test that calls a function
and asserts nothing still "covers" it). Reviewers must reject PRs whose tests
don't assert the behavior they claim to cover. A green coverage number is
necessary, not sufficient.

## 4. Enforcement

- Every PR runs the full test suite with coverage reporting (see
  [the CI workflow](../.github/workflows/) once it lands). CI fails if line or
  branch coverage falls below 100% on any suite.
- Skipped tests (e.g. those gated on integration credentials or a running
  service) do not count toward coverage. Branches inside them must still be
  covered — typically by mocking the external dependency in a unit test.
- Coverage exclusions are declared in the coverage config (§5), never by
  silently ignoring the rule in a PR.

## 5. Coverage-exclusion policy

A small, fixed set of generated and bootstrap files are excluded from the 100%
gate because they contain no production decisions. **Production logic is never
excluded** — if a "bootstrap" file grows a decision, move that decision into an
in-scope unit rather than widening the exclusion list.

| Codebase | Excluded | How it's excluded |
|---|---|---|
| .NET | EF Core migrations, `Program`/startup wiring, generated code (OpenAPI clients, etc.) | `[ExcludeFromCodeCoverage]` on the type, or a coverlet `--exclude`/filter in the test run |
| Angular | `main.ts` bootstrap, `app.config.ts` / `*.config.ts`, generated files | Jest `collectCoverageFrom` excludes (negative globs) |
| Shell | none — dispatcher subcommands and helpers are all in scope | n/a |

Everything not on this list — every domain rule, every use-case, every
subcommand branch — must be covered.

## 6. Tooling

| Codebase | Coverage tool | How to run |
|---|---|---|
| .NET | `coverlet` via `dotnet test` | `dotnet test --collect:"XPlat Code Coverage" /p:Threshold=100 /p:ThresholdType=line,branch` |
| Angular | `jest` | `jest --coverage` with `coverageThreshold` set to 100 (line + branch) |
| Shell (dispatcher subcommands) | `kcov` | `kcov --include-path=src/system-cli coverage-out/ <test runner>` — bash branch metrics aren't portable, so branch completeness is enforced by an explicit test case per branch, not a kcov branch number |

CI wires all three suites with the coverage gate; see
[the CI workflow](../.github/workflows/).

## 7. Test location

- **.NET tests** live in `tests/<Component>.Tests/` — separate from `src/`, one
  test project per component, referencing the component under test.
- **Angular tests** live beside the code they exercise inside each SPA, run by
  that SPA's Jest config.
- **Shell tests** live alongside the dispatcher under `src/system-cli/` (or the
  scaffold's own `tests/`), run from the script's root.

The split keeps each suite runnable from its own root, so a component can be
exercised in isolation without bringing up the whole solution.

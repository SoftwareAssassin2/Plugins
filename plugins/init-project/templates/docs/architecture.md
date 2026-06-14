# Architecture

This is the design-philosophy home for the repo. `CLAUDE.md` carries the
one-line summary and links here; the depth lives below. Read it when you're
making a design decision — drawing a module boundary, choosing where logic
belongs, or deciding between a simple and a clever approach.

## Design the interface, then delegate the implementation

Start every non-trivial piece of work by designing the **interface** the rest of
the system sees — the smallest set of methods, types, and contracts a caller
needs. Only then write the implementation behind it. The interface is a promise;
the implementation is a detail you are free to change later. When the interface
is right, the implementation can be rewritten without anyone noticing.

## Deep modules over shallow ones

A **deep module** has a small interface hiding a large, complex implementation
(Ousterhout, *A Philosophy of Software Design*). It gives callers a lot of
functionality through a narrow door, so the rest of the system stays decoupled
from how the work actually gets done.

A **shallow module** is the opposite — a wide interface that hides almost
nothing. It pushes complexity outward onto every caller and earns its keep only
in trivial passthroughs.

Prefer deep modules. When you find yourself widening an interface to expose
internals, stop and ask whether the complexity belongs *behind* the interface
instead.

| | Interface | Implementation | Effect on callers |
|---|---|---|---|
| **Deep (prefer)** | small, stable | large, hidden | shielded from complexity |
| **Shallow (avoid)** | wide, leaky | thin | complexity leaks outward |

## Simplicity over complexity

Complexity is the enemy. It accumulates incrementally — a special case here, a
shortcut there — until the system is hard to change (software entropy). Actively
fight it: prefer the simpler design even when it costs more up front, because
complexity compounds. When two designs both work, choose the one that hides the
most complexity behind the cleanest interface.

Practical tactics:

- **Pull complexity downward.** It is better for a module's implementation to be
  complex than for its interface to be. The module author pays the cost once; every
  caller pays the cost of a leaky interface forever.
- **Eliminate special cases** by designing them out of existence rather than
  handling them with conditionals. The best special case is the one that can't occur.
- **Define errors out of existence** where you can — pick semantics that make a
  failure mode simply not happen, instead of detecting and reporting it everywhere.
- **Name things well.** A precise name is a tiny, free design document. Use the
  project's [ubiquitous language](ubiquitous-language.md) so code, tests, and
  conversation share one vocabulary.

## Where logic belongs (this repo's layering)

The .NET solution (`src/system.sln`) is layered, and dependencies point one way
only — outer layers depend on inner ones, never the reverse:

```
Api → BusinessLogic → DataAccess → Framework
```

| Layer | Holds | Does NOT hold |
|---|---|---|
| `Framework` | cross-cutting primitives, shared abstractions, base types | domain rules, persistence, transport |
| `DataAccess` | the EF Core `DbContext`, entities, migrations, persistence logic | business rules, HTTP concerns |
| `BusinessLogic` | domain rules, use-cases, the bulk of the system's behavior | HTTP/transport details, raw SQL |
| `Api` | HTTP transport, auth/JWT validation, request/response mapping | domain rules (delegate to `BusinessLogic`) |

**Business logic lives in `BusinessLogic`.** The `Api` layer is a thin transport
shell: validate the request, call into `BusinessLogic`, shape the response. When
a controller starts making decisions, that decision belongs one layer in. Keep
`Api` shallow on purpose so the deep behavior sits in a testable, transport-free
core.

The two Angular SPAs (`MarketingSite`, `WebApp`) are separate front-end
components — see [front-end.md](front-end.md). Identity and database
session-context conventions live in [keycloak.md](keycloak.md).

## Testability is a design property

Code that is hard to test is usually badly factored, not just badly tested. If a
behavior resists testing, restructure it until it's testable — extract the logic
out of the glue, narrow the interface, push the dependency behind a seam. The
100% coverage gate (see [tdd.md](tdd.md)) is as much a design forcing-function as
a quality bar.

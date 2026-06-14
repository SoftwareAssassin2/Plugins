# Front-end standard

This is the authoritative standard for the **Angular SPAs** in this repo. Read it
whenever you build or change a front-end — routing, build profile, styling,
testing, or how an SPA reaches its runtime config. It is a standard, not a
tutorial: it states the rules and points at the single source for each one.

The repo ships two SPAs, each its own component under `src/<component>/` with a
matching `config.json` `systems[]` entry (the repo-wide invariant — see the root
`CLAUDE.md`):

| SPA | Folder | Role |
|---|---|---|
| `MarketingSite` | `src/MarketingSite/` | public marketing front-end |
| `WebApp` | `src/WebApp/` | authenticated application front-end |

Both follow this standard identically; they differ only in their content.

## 1. Build profile: static (SSG), client-side only, S3-hosted

Each SPA is built with the Angular **application builder** (`@angular/build:application`)
in **`"outputMode": "static"`** — fully prerendered / static site generation. The
build emits a static bundle to `dist/<app>/browser/` (`index.html` + hashed JS/CSS
+ assets) that runs **entirely in the browser**. There is **no server-side
runtime**: the output is uploaded to an **S3 bucket** (fronted by CloudFront) and
served as static files. Nothing in `dist/` executes on a server.

```bash
ng build WebApp          # -> dist/WebApp/browser/index.html (static)
ng build MarketingSite   # -> dist/MarketingSite/browser/index.html (static)
npm run build            # both
```

`outputMode: static` is **version-sensitive** — it depends on the pinned Angular
major + `@angular/build` builder version (§3). Do not change the output mode to
`server` or add an SSR entry: these SPAs are client-side only by design.

## 2. Routing: path-based + the S3 / CloudFront fallback

SPAs use **path-based routing** (`provideRouter`, real URL paths — not hash
routing). Because the app is a single static `index.html` that renders routes
client-side, the static host must **rewrite unknown paths back to `index.html`** so
a deep link or refresh on a client route (e.g. `/dashboard`) loads the app instead
of returning 404.

**S3 static website hosting** — set **both** the *Index document* and the
*Error document* to `index.html`. The error-document fallback is what makes a
client-side route deep-linkable: S3 returns `index.html` for any path it can't
resolve to an object, and the Angular router takes over.

**CloudFront caveat** — when the bucket is fronted by CloudFront, the S3
error-document trick alone is not enough (CloudFront caches the S3 error status).
Add a **custom error response** mapping HTTP **403 and 404 → `/index.html` with a
`200` response code**, so client-side routes resolve through the CDN. (S3 returns
403 for missing objects on a private origin, 404 on a public one — map both.)

This fallback is purely a hosting-layer concern; the app itself needs no special
handling beyond using path-based routing.

## 3. Single Angular version — one source of truth

There is **exactly one** Angular version for the whole repo, declared once in the
**root `package.json`** (`@angular/*` runtime deps + `@angular/build` /
`@angular/cli` builder deps). This single source is what the SPAs build against,
what the dev-container Angular CLI install targets, and what CI installs (see
[dev-container.md](dev-container.md) and the CI workflow under
`.github/workflows/`). There is **no per-SPA `package.json`** pinning Angular — the
two SPAs share the root install (one `node_modules`, one `npm install` at the repo
root), so the version cannot drift between them or between app/CLI/CI.

When upgrading Angular, change the versions in the **root `package.json` only**, run
one `npm install`, and rebuild both SPAs. Never introduce a second dependency
manifest that pins Angular.

The two SPAs are configured as two projects in a single root **`angular.json`**;
shared compiler settings live in the root **`tsconfig.json`**, which each SPA's
`tsconfig.app.json` / `tsconfig.spec.json` extends.

## 4. Styling: SCSS

Styling is **SCSS**. Component styles use `.scss`; global styles live in each SPA's
`src/styles.scss`. The component schematic default is set to `scss` in
`angular.json`, so generated components get `.scss` automatically. Prefer scoped
component styles; reach for global styles only for genuinely app-wide rules.

## 5. Lint + format: angular-eslint + Prettier

- **Linting** is **angular-eslint** (with typescript-eslint), configured once in the
  root `eslint.config.js` (flat config) and run per project:
  ```bash
  ng lint MarketingSite
  ng lint WebApp
  npm run lint            # both
  ```
- **Formatting** is **Prettier** (root `.prettierrc`; the Angular HTML parser is
  enabled for templates):
  ```bash
  npm run format          # write
  npm run format:check    # verify (CI)
  ```

Lint and format are required to pass in CI. Fix findings; do not disable rules to
get green without justification.

## 6. Package manager: npm

The package manager is **npm** (pinned via `packageManager` in the root
`package.json`). Install once at the repo root:

```bash
npm install
```

Both SPAs resolve their dependencies from the single root `node_modules`. Do not
add yarn/pnpm lockfiles or a second package manager.

## 7. Testing: Jest at 100% coverage

Unit tests run on **Jest** (via `jest-preset-angular`), one Jest config per SPA
(`src/<SPA>/jest.config.js`). The **100% coverage requirement** (lines, branches,
functions, statements) is enforced by each config's `coverageThreshold` — this is
the front-end half of the repo-wide coverage standard. See
[tdd.md](tdd.md) for the coverage rule, what "covered" means, and the practice of
test-driven development; this doc does not restate it.

```bash
npm run test:webapp            # one SPA
npm run test:coverage          # both, with the 100% gate
```

**Coverage-exclusion policy (front-end).** Bootstrap glue with no decisions of its
own is excluded via each Jest config's `collectCoverageFrom` negative globs:
`main.ts` (bootstrap), `*.config.ts` (`app.config.ts` providers wiring), and
`*.routes.ts` (route table). Everything else — every component, service, and
decision — must hit 100%. This list is intentionally narrow and matches the
exclusion table in [tdd.md](tdd.md); if a "bootstrap" file grows a decision, move
that decision into a tested unit rather than widening the exclusion.

## 8. Runtime config: non-secret, fetched at runtime — never in the bundle

A static client-side bundle **cannot hold secrets** — anything shipped to the
browser is public. Each SPA therefore receives only **non-secret public runtime
config** (its Keycloak realm URL + its public OIDC client id) from a
`src/<SPA>/public/config.json` that the app **fetches at runtime** (see
`src/<SPA>/src/app/core/app-config.ts`), rather than baking values into the build.

That `public/config.json` is **generated by `./system.sh build-config`** (stamped
from the root `config.json`) and is **gitignored** — it is environment-specific.
Per environment, drop a fresh `config.json` beside `dist/` (or regenerate it) — no
rebuild required. The committed sample under `src/<SPA>/public/config.json` exists
only so a fresh scaffold builds and tests before `build-config` runs.

- Public clients carry **no client secret** — see [keycloak.md](keycloak.md) for the
  realm's public-SPA-client model.
- The config field names and how they flow from `config.json` are defined in
  [config-management.md](config-management.md) (the SPA public-config section).

**No secrets ever reach `dist/`.** If an SPA needs a privileged operation, it calls
the `Api` (a confidential client) — it never holds the credential itself.

## 9. Where front-end logic belongs

Keep components thin and push decisions into testable services (the Humble-Object
ethos) — see [architecture.md](architecture.md) for module-boundary guidance and
[tdd.md](tdd.md) for why testability is a design property. A component that resists
a 100%-coverage test is usually doing work that belongs in a service.

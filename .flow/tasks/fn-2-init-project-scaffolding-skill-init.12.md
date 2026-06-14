---
satisfies: [R10, R11]
---

## Description
Scaffold the two **Angular SPA** components (`MarketingSite`, `WebApp`) and author the **`docs/front-end.md`** standard. Static/prerendered, S3-hosted, no server runtime.

**Size:** M
**Files:** `templates/src/MarketingSite/`, `templates/src/WebApp/` (Angular app templates), `templates/docs/front-end.md`, **the single Angular-version source** (root `templates/package.json` (single canonical source)) consumed by .4 (CLI install) + .13 (CI)

## Approach (from docs-scout)
- **Pinned versions (R11):** use the **single declared Angular version** (root `package.json` (canonical, single source) — shared with .4 CLI install + .13 CI; no independent pin) for the Angular major + `@angular/build` builder (outputMode is version-sensitive).
- **Build profile (R11):** Angular application builder with **`"outputMode": "static"`** (prerendered/SSG, no server file; output `dist/<app>/browser/` → S3). Styling **SCSS**; lint/format **angular-eslint + Prettier**; package manager **npm**; unit tests **Jest** via `jest-preset-angular` with `coverageThreshold` global **100** (branches/functions/lines/statements).
- **Routing (R11):** **path-based routing** + document the **S3 static-hosting fallback** (Index + Error document both → `index.html`) and the **CloudFront caveat** (custom error response 403/404 → `/index.html` 200) in `front-end.md`.
- **front-end.md** (already linked from `_CLAUDE.md` Standards index, fn-2….2/.8): capture prerendered/client-side-only/S3-static/no-SSR, SCSS, angular-eslint+Prettier, npm, Jest+100% coverage, path-routing+S3/CloudFront fallback — as standards.
- Each SPA is its own `src/<component>/` + `systems[]` entry. Public runtime config (realm URL, public client-id — **non-secret only**) is delivered via a `build-config`-stamped gitignored `src/<SPA>/public/config.json` (per the .3 schema) that the app **fetches at runtime**; **no secrets in `dist/`**.

## Investigation targets
**Required:**
- `.flow/specs/fn-2-...md` — R11 front-end standard
- the declared Angular version source (root `package.json` (canonical, single source)) — shared with .4/.13
- `plugins/init-project/templates/docs/tdd.md` (fn-2….8) — Jest coverage expectation
- `plugins/init-project/templates/src/keycloak/realm.template.json` (fn-2….10) + config public-client keys — the public SPA client ids the apps use (the `import/*.json` runtime file is generated/gitignored, not committed)

## Acceptance
- [ ] This task **owns** the single declared Angular-version source (root `package.json` (canonical, single source)); .4 (CLI install) + .13 (CI) read the SAME version (verified — no drift)
- [ ] MarketingSite + WebApp Angular templates (pinned major/builder) build static to `dist/<app>/browser/index.html` (smoke build); SCSS; angular-eslint + Prettier; npm
- [ ] Jest configured with `coverageThreshold` global 100; `ng`/jest test runs green on the scaffold
- [ ] `build-config` *code* owned by fn-2….6; this task adds **SPA fixtures + app-consumption tests** for the public-`config.json` stamp (may extend `build-config`)
- [ ] Path routing used; `front-end.md` documents the S3 error-document→index.html fallback + CloudFront caveat
- [ ] Only non-secret public config in the browser bundle (no client secrets)

## Done summary
Authored two build-time-complete Angular SPA templates (MarketingSite + WebApp) as static (outputMode: static / SSG) client-side-only apps in a single root Angular workspace (one pinned Angular version source in templates/package.json, one angular.json), plus the docs/front-end.md standard. SCSS, angular-eslint + Prettier, npm, Jest at 100% coverage, path routing with documented S3 error-document->index.html + CloudFront fallback, and runtime-fetched non-secret public config.json (no secrets in dist/). Verified end-to-end on a fresh scaffold (and a clean git export): npm install + ng build static + jest 100% + lint + prettier all pass. Codex impl-review: SHIP.
## Evidence
- Commits: 591b69b, 969bc1d, 0c66330, e6ca6b9, ccdbe23, c736063, 211ba56
- Tests: bash plugins/init-project/tests/scaffold_test.sh (112 passed, 0 failed), fresh scaffold: npm install + npm run build (both SPAs -> dist/<app>/browser/index.html, outputMode static), fresh scaffold: npm run test:coverage (jest 100% lines/branches/functions/statements, 4 suites/6 tests per SPA), fresh scaffold: npm run lint (angular-eslint, both SPAs pass), fresh scaffold: npm run format:check (prettier clean), clean git export (git checkout-index) scaffold + build/test/lint to prove committed-tree correctness
- PRs:
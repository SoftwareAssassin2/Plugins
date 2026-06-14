---
satisfies: [R3, R14, R16, R17, R22]
---

## Description
Author the remaining `docs/` templates (generalized standards + the keycloak standard + the empty business-doc homes) and the stack-aware `.gitignore`. All H&G-free.

**Size:** M
**Files:** `templates/docs/{tdd,dev-container,architecture,ubiquitous-language,keycloak}.md`; `templates/docs/{business,strategy,customers,priorities,decisions}.md` (TODO stubs); `templates/.gitignore`

## Approach
- **tdd.md** (from source, generalize per P7): keep 100% line+branch coverage rule, "restructure to test" ethos, Humble-Object idea, tooling-table shape (kcov for shell, coverlet for .NET, Jest for Angular); drop Unity/`games/`/`play.sh` carve-outs; reconcile with the `/tdd` plugin (point at it, don't duplicate). Fix the stray `". "` typo (source `tdd.md:41`).
- **dev-container.md** (P2): keep "all deps live in `.devcontainer/`" + dep-placement table; swap the Postgres/platform-db service-container example for the Grafana+OTel observability stack; strip H&G.
- **architecture.md**: hosts the design philosophy (deep modules / "design the interface, delegate the implementation" / simplicity-over-complexity) linked from `_CLAUDE.md` (R17).
- **ubiquitous-language.md**: DDD home (linked from `_CLAUDE.md` R17); a stub the `/ubiquitous-language` skill fills.
- **keycloak.md** (R14): document the IdP conventions — self-hosted compose, realm-import, DB-access-gated-through-Keycloak + session-context RLS (cross-ref fn-2….10/.11). Linked from `_CLAUDE.md` Standards index.
- **business-doc stubs** (R16): `business/strategy/customers/priorities/decisions.md` as empty `## TODO` homes owned/filled by `/dick` (fn-1); NO `roadmap.md`.
- **Coverage-exclusion policy (tdd.md, supports R30):** document which generated/bootstrap files are excluded from the 100% gate — EF migrations, ASP.NET `Program`/startup, Angular `main.ts`/bootstrap/`*.config.ts`, generated code — via coverlet filters / `[ExcludeFromCodeCoverage]` + Jest `collectCoverageFrom` excludes; production logic must be covered.
- **.gitignore** (R22): OS noise; `.worktrees/`; .NET (`bin/`,`obj/`,`.vs/`,`*.user`,`[Tt]est[Rr]esults/`); Node/Angular (`node_modules/`,`dist/`,`.angular/`,`coverage/`,`npm-debug.log*`); generated per-component `.env` (NOT `config.json`); the generated `src/keycloak/import/*-realm.json` runtime realm file; the generated SPA public config `src/*/public/config.json`; `.claude/settings.local.json`. **Does NOT ignore `.flow/bin/`** — flow-next's bundled `flowctl` is a protected artifact that must stay committable.

## Investigation targets
**Required:** (raw `tdd.md`/`dev-container.md` sources move `plugins/project-init/`→`plugins/init-project/` via fn-2….1; paths below post-rename)
- `plugins/init-project/tdd.md`, `dev-container.md` — sources to generalize
- `plugins/tdd/SKILL.md` — reconcile tdd.md against
- `.flow/specs/fn-2-...md` — R14/R17 content + the H&G Removal Decisions table

## Acceptance
- [ ] tdd.md, dev-container.md generalized (no Unity/games/platform-db/play.sh); tdd reconciled with `/tdd`; typo fixed
- [ ] architecture.md + ubiquitous-language.md stubs exist and are linked from `_CLAUDE.md`'s Standards index
- [ ] keycloak.md documents self-hosted compose + realm-import + Keycloak-gated DB-auth/RLS
- [ ] business/strategy/customers/priorities/decisions.md ship as empty TODO stubs (no roadmap.md)
- [ ] `.gitignore` covers the stack incl. `.worktrees/` and the generated `src/keycloak/import/*-realm.json`; `config.json` NOT ignored; `.flow/bin/` NOT ignored (protected)
- [ ] Whole-package H&G scan returns nothing: `grep -rEi 'H&G|play\.sh|MonoBehaviour|games\[|platform-(db|api)|PGS|google[_ ]?oauth|oauth2\.googleapis|com\.hg' plugins/init-project/templates/ plugins/init-project/SKILL.md` (note: bare `coverlet` is allowed — it's the .NET coverage tool per R30; only Unity/games framing is banned)

## Done summary
Authored the remaining generalized standards docs (architecture.md, tdd.md, dev-container.md, keycloak.md, ubiquitous-language.md), the five empty `## TODO` business-doc stubs owned by /dick (business/strategy/customers/priorities/decisions, no roadmap.md), and the stack-aware `templates/.gitignore` — all H&G-free and indexed by `_CLAUDE.md`'s Standards index. Added scaffold-test assertions covering doc presence and the .gitignore keep/ignore rules (63 tests green); Codex impl-review verdict SHIP.
## Evidence
- Commits: 0311b2ecf23f9b8e6dd2881ee459e09e2564547f
- Tests: bash plugins/init-project/tests/scaffold_test.sh (63 passed, 0 failed)
- PRs:
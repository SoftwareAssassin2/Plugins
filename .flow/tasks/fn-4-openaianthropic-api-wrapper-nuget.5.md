---
satisfies: [R2, R7]
---

## Description
Author the **plugin-repo-level** NuGet publish workflow — the repo's FIRST `.github/`. Path-scoped to `src/**`, triggered on `nuget-v*` tags; it **asserts the scaffold pin equals the tag version**, derives the single shared version from the tag, packs + publishes **all three** packages, and confirms each is restorable. Add a **repo-root `README.md`** documenting `./src/` + the release procedure.

**Size:** M
**Files:** `.github/workflows/nuget.yml` (repo root), `README.md` (repo root), `plugins/init-project/templates/Directory.Build.props` (new — owns the initial `<LlmWrapperVersion>` pin)

## Approach
- **Create the version-pin source:** author `plugins/init-project/templates/Directory.Build.props` with the initial `<LlmWrapperVersion>` here (in fn-4.5), so the file exists before the first publish — fn-4.6 then CONSUMES it. This breaks the chicken-and-egg with the assert below.
- PR/push build+test job path-scoped to `src/**`; publish job gated `if: startsWith(github.ref, 'refs/tags/nuget-v')`.
- **Version invariant (anti-drift):** assert `plugins/init-project/templates/Directory.Build.props` `LlmWrapperVersion == ${GITHUB_REF_NAME#nuget-v}` and FAIL the release on mismatch — so the tag, the published packages, and the scaffold pin can't diverge.
- **Single version from the tag:** `/p:Version=${GITHUB_REF_NAME#nuget-v}` packs ALL THREE (so the providers' Abstractions dependency resolves to the same version).
- **Auth — deterministic selector (never both):** branch on an explicit repo variable — `vars.NUGET_TRUSTED_PUBLISHING == 'true'` ⇒ OIDC (`permissions: id-token: write`, `NuGet/login`, store only the nuget.org username; **fail if the OIDC login fails**); else ⇒ `NUGET_API_KEY` (`dotnet nuget push --api-key`; **fail if the secret is absent**). Never attempt both. `dotnet nuget push ./artifacts/*.nupkg --skip-duplicate` (`.snupkg` alongside).
- **Restorability poll:** after push, poll the v3 flat-container index for **each package ID @ published version** before signalling success.
- **Prefix reservation = MANUAL release prerequisite** documented in the repo README with evidence; workflow NON-BLOCKING on unique IDs.
- Pin every action to an exact tag (mirror `plugins/init-project/templates/.github/workflows/ci.yml`); `permissions: contents: read` baseline; concurrency cancel-in-progress.
- **Repo-root README** documents `./src/` (purpose, build/pack, publish, scaffold consumption) AND the release procedure: bump `LlmWrapperVersion` → commit → tag `nuget-v<ver>`.

## Investigation targets
**Required:**
- `plugins/init-project/templates/.github/workflows/ci.yml` — pinned-action/permissions/concurrency conventions
- Andrew Lock "publishing NuGet from GitHub Actions with Trusted Publishing"; `actions/setup-dotnet`; NuGet/login
**Optional:**
- `plugins/init-project/templates/Directory.Build.props` (fn-4.6) — the `LlmWrapperVersion` the assert reads

## Acceptance
- [ ] `plugins/init-project/templates/Directory.Build.props` created here with the initial `<LlmWrapperVersion>` (exists before first publish; consumed by fn-4.6)
- [ ] `.github/workflows/nuget.yml` at repo root: build/test job path-scoped to `src/**`; publish job gated on `nuget-v*` tags
- [ ] Publish job ASSERTS `plugins/init-project/templates/Directory.Build.props` `LlmWrapperVersion == ${GITHUB_REF_NAME#nuget-v}` (fails on mismatch), then derives that version and packs ALL THREE with it
- [ ] Auth selector deterministic: `vars.NUGET_TRUSTED_PUBLISHING=='true'` ⇒ OIDC (fail if login fails), else `NUGET_API_KEY` (fail if absent), never both; `--skip-duplicate` + `.snupkg`; action versions pinned
- [ ] Polls each package ID@version restorable before signalling success; prefix reservation handled as a documented manual prerequisite (non-blocking on unique IDs)
- [ ] Repo-root `README.md` documents `./src/` + the release procedure; `actionlint` clean; committed `src/` fixtures survive `.gitignore`

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

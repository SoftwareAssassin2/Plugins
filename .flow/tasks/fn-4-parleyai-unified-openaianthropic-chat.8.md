---
satisfies: [R7, R9]
---

## Description
Author the **plugin-repo-level** NuGet publish workflow (the repo's first `.github/`), create the scaffold version-pin `Directory.Build.props`, and the repo-root `README.md`. Explicit trigger shape, tests-gate-the-tag-path, mutually-exclusive publish jobs with concrete OIDC steps, an aggregation gate, net10 SDK in every dotnet job.

**Size:** M
**Files:** `.github/workflows/nuget.yml` (repo root), `plugins/init-project/templates/Directory.Build.props` (new — `$(LlmWrapperVersion)`), `README.md` (repo root)

## Approach
- **Create the pin source:** `plugins/init-project/templates/Directory.Build.props` with the initial `<LlmWrapperVersion>`.
- **Trigger shape (path filters vs tags interact non-obviously):** `on.pull_request.paths: ['src/**']` + `on.push` (branches) `paths: ['src/**']` drive `build-test`; `on.push.tags: ['nuget-v*']` drives the release path — **tag pushes do NOT honor `paths`, so a release tag always runs the release jobs.** No `paths` gate on the tag path.
- **net10 SDK in every dotnet job:** pinned `actions/setup-dotnet@<sha/tag>` `dotnet-version: "10.0.x"` in `build-test`, `pack`, and (fn-4.10) `verify-scaffold-restore`.
- Jobs:
  - `build-test` — PR/branch, path-filtered `src/**`; `dotnet test src/ParleyAI.sln`.
  - `pack` — `if: startsWith(github.ref,'refs/tags/nuget-v')`; setup-dotnet; **runs `dotnet test src/ParleyAI.sln` on the tagged commit BEFORE packing** (the path-filtered `build-test` does NOT run on tag pushes, so the tag path must test on its own — never publish on `dotnet pack` alone); asserts `Directory.Build.props` `LlmWrapperVersion == ${GITHUB_REF_NAME#nuget-v}`; packs `ParleyAI` `/p:Version=...`; uploads artifact.
  - `publish-oidc` (`needs: pack`, `if: vars.NUGET_TRUSTED_PUBLISHING == 'true'`, `permissions: id-token: write`): setup-dotnet, download artifact, the concrete step `uses: NuGet/login@<full-commit-SHA>` (pinned to a SHA — record the matching release tag in a comment; NOT a floating `@v1`), `id: login`, `with: user: ${{ vars.NUGET_USER }}` — it exchanges the OIDC token and exposes the temporary key as the step output `NUGET_API_KEY`; then `dotnet nuget push ./artifacts/*.nupkg --source https://api.nuget.org/v3/index.json --api-key ${{ steps.login.outputs.NUGET_API_KEY }} --skip-duplicate` (`id-token: write` alone is insufficient — the login step is required). Push symbols EXPLICITLY: run a separate `dotnet nuget push ./artifacts/*.nupkg ...` and `dotnet nuget push ./artifacts/*.snupkg ...`; **gate on each command's SUCCESS EXIT CODE** (do NOT parse log text for `2xx` — `--skip-duplicate` may not emit a normal success line). The `verify-package-restorable` poll confirms the `.nupkg` actually landed. `publish-apikey` (`needs: pack`, `if: vars.NUGET_TRUSTED_PUBLISHING != 'true'`, no `id-token`): push with `${{ secrets.NUGET_API_KEY }}` (fail if empty). Exactly one runs.
  - `verify-package-restorable` — `needs: [publish-oidc, publish-apikey]`, `if: always() && startsWith(github.ref,'refs/tags/nuget-v')`; asserts exactly one publish succeeded (other skipped, not failed); polls the v3 flat-container index for `ParleyAI@<version>`. The gate fn-4.10 depends on.
- Pin all actions; baseline `permissions: contents: read`; concurrency cancel-in-progress.
- **Repo-root `README.md`:** `./src/` (ParleyAI), build/pack, release procedure (bump `LlmWrapperVersion` → commit → tag `nuget-v<ver>`), scaffold consumption.

## Investigation targets
**Required:** `plugins/init-project/templates/.github/workflows/ci.yml` (conventions); Andrew Lock trusted-publishing (`NuGet/login`); `actions/setup-dotnet`
**Optional:** GitHub Actions docs — `on.push.tags` vs `paths`; job-level `permissions`; `needs` + `if: always()`

## Acceptance
- [ ] `Directory.Build.props` created with initial `<LlmWrapperVersion>`; every dotnet job pins `actions/setup-dotnet` `10.0.x`
- [ ] Trigger shape explicit: `build-test` path-filtered `src/**` on PR/branch; release jobs run on `nuget-v*` tags unconditionally
- [ ] `pack` (tag-gated) **runs `dotnet test src/ParleyAI.sln` before packing** (tests gate the tag release — never publish on `dotnet pack` alone); asserts version==tag; packs `ParleyAI`; uploads artifact
- [ ] Two mutually-exclusive publish jobs: `publish-oidc` (`id-token: write` + a SHA-pinned `NuGet/login@<sha>` step with `user:` input → `NUGET_API_KEY` output, then `dotnet nuget push --api-key ${{ steps.login.outputs.NUGET_API_KEY }}`; `.snupkg` pushed + asserted) vs `publish-apikey` (`NUGET_API_KEY`, no id-token, fail if empty); exactly one runs; `--skip-duplicate`; **`.nupkg` AND `.snupkg` pushed via separate explicit commands, each gated on a success exit code (not log text)**; actions pinned
- [ ] `verify-package-restorable` gated `if: always() && startsWith(...nuget-v)`, asserts exactly-one-succeeded, polls `ParleyAI@version`
- [ ] Repo-root `README.md` documents `./src/` + release procedure; `actionlint` clean

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

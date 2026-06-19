---
satisfies: [R8]
---

## Description
The **release-gated `verify-scaffold-restore`** CI job: `needs:` the `verify-package-restorable` gate from .8, sets up the net10 SDK + `jq`, scaffolds a fresh project and `dotnet restore` + `dotnet build`s it against the PUBLISHED `ParleyAI` from nuget.org. Distinct from .8's package-restorability poll. Tag-gated; not a manual step. **Implementation preconditions: fn-4.7 (net10 scaffold) + fn-4.8 (publish + props) + fn-4.9 (scaffold ParleyAI wiring) DONE.**

**Size:** S
**Files:** `.github/workflows/nuget.yml` (add the `verify-scaffold-restore` job) — no scaffold-template changes.

## Approach
- `verify-scaffold-restore` job `needs: verify-package-restorable` (the .8 gate — NOT a publish job directly), gated `if: needs.verify-package-restorable.result == 'success' && startsWith(github.ref,'refs/tags/nuget-v')` — runs only when the package-restorability gate SUCCEEDED on a release tag (the `always()` belongs on .8's aggregation job, not here). Pinned `actions/setup-dotnet@<sha/tag>` `dotnet-version: "10.0.x"`. **Install `jq`** before `./system.sh build-config` (the scaffold's `build-config`/dispatcher path needs `jq`, mirroring the scaffold CI's config job). Scaffold a throwaway project via `plugins/init-project/scaffold.sh`, run `./system.sh build-config`, then `dotnet restore` + `dotnet build` the scaffolded solution (net10) so the pinned `$(LlmWrapperVersion)` resolves the published `ParleyAI`.
- Network-enabled; never in the offline `scaffold_test` path. On failure (unindexed / version mismatch) fail — the release is NOT complete until it passes.
- **Gate naming:** `.8` = `verify-package-restorable` (flat-container availability); `.10` = `verify-scaffold-restore` (fresh-scaffold build); `.10` depends on `.8`'s job AND requires `.7`/`.9` implemented (the net10 scaffold + the ParleyAI wiring it builds).

## Investigation targets
**Required:** `fn-4...8` (`verify-package-restorable`); `.9` (`$(LlmWrapperVersion)` + ParleyAI scaffold wiring) + `.7` (net10 scaffold); `plugins/init-project/scaffold.sh`; the scaffold CI `jq` install step in `plugins/init-project/templates/.github/workflows/ci.yml`

## Acceptance
- [ ] **Preconditions:** fn-4.7 + fn-4.8 + fn-4.9 DONE
- [ ] `verify-scaffold-restore` job `needs: verify-package-restorable`, gated `if: needs.verify-package-restorable.result == 'success' && startsWith(...nuget-v)`; pins `actions/setup-dotnet` `10.0.x`; **installs `jq`** before `./system.sh build-config`
- [ ] Scaffolds fresh + `dotnet restore`+`build` succeeds against the PUBLISHED `ParleyAI` (pinned `$(LlmWrapperVersion)`); runs only on a release tag, never in the offline `scaffold_test` path; failure fails the release
- [ ] No changes to the offline `scaffold_test.sh`

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

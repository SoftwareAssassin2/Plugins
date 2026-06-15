---
satisfies: [R8]
---

## Description
Own the **release-gated CI job** that closes the publish-before-reference loop: an explicit workflow job with `needs:` the publish job (fn-4.5), running AFTER the restorability poll, that scaffolds a fresh project and proves it `dotnet restore`s + builds against the **published** packages from nuget.org. Deliberately SEPARATE from the offline `scaffold_test.sh`. Not a manual step.

**Size:** S
**Files:** `.github/workflows/nuget.yml` (add a `verify-scaffold-restore` job; or a dedicated release workflow) — no scaffold-template changes.

## Approach
- A CI job `needs: <publish-job>` (so it runs only after a successful publish + restorability poll): scaffold a throwaway project via `plugins/init-project/scaffold.sh`, then `dotnet restore` + `dotnet build` it so the pinned `$(LlmWrapperVersion)` resolves the real published packages (Abstractions + both providers) from nuget.org.
- Network-enabled by design; it never runs in the offline PR/`scaffold_test` path.
- On failure (unindexed / version mismatch), fail the job — the release is NOT complete until this passes (no manual-only fallback).

## Investigation targets
**Required:**
- `fn-4-openaianthropic-api-wrapper-nuget.5` — the publish job + restorability poll this `needs:`
- `fn-4-openaianthropic-api-wrapper-nuget.6` — the scaffold pin (`$(LlmWrapperVersion)`) being validated
- `plugins/init-project/scaffold.sh` — engine to scaffold the throwaway project

## Acceptance
- [ ] An explicit CI job with `needs:` the publish job scaffolds a fresh project and `dotnet restore` + `dotnet build` succeeds against the PUBLISHED packages (pinned `$(LlmWrapperVersion)`) from nuget.org
- [ ] Runs only after fn-4.5 publish + restorability poll; never in the offline PR/`scaffold_test` path; failure fails the release (no manual-only fallback)
- [ ] No changes to the offline deterministic `scaffold_test.sh`

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

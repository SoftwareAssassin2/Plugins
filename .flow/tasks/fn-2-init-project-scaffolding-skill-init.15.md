---
satisfies: [R32]
---

## Description
Extend the `/init-project` git/GitHub phase (`SKILL.md`) so that creating a GitHub repo protects `main` against force-push and deletion — matching the marketplace repo's protections. Orchestration prose only (no scaffolded template file; `scaffold_test.sh` does not cover `SKILL.md`).

**Size:** S
**Files:** `plugins/init-project/SKILL.md`

## Approach
- Couple repo creation with bootstrap commit + push: creating a repo always implies the initial commit + `push -u origin main` (a protected remote `main` requires a pushed commit), regardless of the optional auto-commit answer; the auto-commit prompt governs only the no-repo case.
- After the push, apply branch protection via `gh api --method PUT repos/{owner}/{repo}/branches/main/protection`: `enforce_admins: true`, `allow_force_pushes: false`, `allow_deletions: false`, with `required_pull_request_reviews`/`required_status_checks` null (so commit-on-`main` keeps working).
- Best-effort / non-fatal: skip when no repo / no remote `main`; a `403` (private repo on a free plan — classic protection needs Pro/Team/Enterprise) degrades to a printed note (paid plan / make public / re-run later); scaffold still reports success.

## Acceptance
- [ ] Creating a GitHub repo always makes the bootstrap commit + `push -u origin main` (decoupled from the optional auto-commit prompt)
- [ ] Branch protection applied after the push: `enforce_admins` true, `allow_force_pushes` false, `allow_deletions` false, PR/status-check requirements null
- [ ] Skipped when no repo / no remote `main`; `403` (private + free plan) degrades to a clear non-fatal note; scaffold still reports success
- [ ] Single ordering note in SKILL.md updated to include the protect-`main` step

## Done summary
Branch-protection git-phase step; see SKILL.md + commit 9ae692c
## Evidence
- Commits:
- Tests:
- PRs:
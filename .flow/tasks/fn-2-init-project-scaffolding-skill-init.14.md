---
satisfies: [R31]
---

## Description
Scaffold **CI-based AI code review on pull/merge requests**, on by default. Ship two inert-cross-platform CI files: a GitHub Actions job that runs a **Codex/GPT** reviewer on each PR, and a GitLab MR-pipeline job that runs **GitLab Duo** code review on each MR. Best-effort / non-fatal; secrets referenced via CI variables, never committed.

**Size:** M
**Files:** `plugins/init-project/templates/.github/workflows/ai-review.yml`, `plugins/init-project/templates/.gitlab-ci.yml` (AI-review MR job — or a `.gitlab/` include if cleaner), `plugins/init-project/tests/scaffold_test.sh` (+ assertions), `plugins/init-project/templates/docs/dev-container.md` or `README.md` (one-line note + the required secret/CI-variable names)

## Approach
- **GitHub (Codex, default backend):** a workflow triggered on `pull_request` that runs an AI review over the PR diff using **Codex/GPT** (reuse the Codex CLI already installed in the dev container, or a pinned review action), authed via a repo **secret** (e.g. `OPENAI_API_KEY`/Codex token) referenced — never committed. Posts review feedback on the PR. **Non-fatal:** a missing secret WARNS and the job exits success (never blocks merges). Pin actions to SHAs (repo convention, mirrors fn-2.13 / the marketplace pinning).
- **GitLab (Duo):** a `.gitlab-ci.yml` job scoped to **merge-request pipelines** (`rules: - if: $CI_PIPELINE_SOURCE == "merge_request_event"`) that invokes **GitLab Duo** code review on the MR. Same best-effort/non-fatal posture; auth via GitLab CI variables.
- **No platform detection:** ship both files. A `.github/workflows/` file is inert on GitLab and a `.gitlab-ci.yml` AI-review job is inert on GitHub, so whichever host the project lands on runs its own — consistent with the build-time-complete template model (no scaffold-time branching).
- **Scope:** review runs on PRs/MRs only, not on every push.
- Document the required secret / CI-variable names (e.g. the Codex/OpenAI token, GitLab Duo enablement) in `dev-container.md` / `README.md`, alongside the existing per-user-auth follow-up notes.

## Investigation targets
**Required:**
- `plugins/init-project/templates/.github/workflows/` (from fn-2.13) — existing CI workflow conventions + pinning style
- `plugins/init-project/tests/scaffold_test.sh:375-419` — devcontainer/CI assertion patterns to extend
**Optional:**
- `.claude-plugin/marketplace.json` / repo workflows — SHA-pinning convention reference
- `plugins/init-project/templates/docs/dev-container.md` — where per-user-auth/secret notes live

## Key context
- This is the scaffolded *project's* CI (turning AI review ON for projects init-project creates) — distinct from this marketplace repo's own flow-next/Codex plan-review.
- Both review jobs MUST be non-fatal: a fork/PR without the secret, or a project not using GitLab Duo, must not break the pipeline.
- Secrets are referenced via CI variables only — never written into the scaffolded tree (R25 secret boundary).

## Acceptance
- [ ] `.github/workflows/ai-review.yml` present: triggers on `pull_request`, runs a Codex/GPT review over the PR, references a CI secret (not committed), posts feedback, and is **non-fatal** when the secret is absent
- [ ] `.gitlab-ci.yml` AI-review job present: scoped to merge-request pipelines, runs **GitLab Duo** code review on MRs, non-fatal, auth via CI variables
- [ ] Both files are scaffolded and each is inert on the other platform (no scaffold-time platform detection)
- [ ] Review runs only on PRs/MRs (not every push); actions/images pinned per repo convention
- [ ] Required secret / CI-variable names documented in `dev-container.md` / `README.md`; no secrets committed
- [ ] `scaffold_test.sh` asserts both files land with the expected triggers + non-fatal posture; `shellcheck` clean where applicable

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_

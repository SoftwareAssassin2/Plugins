---
title: "Per-request RLS unit-of-work: transaction lifecycle + Keycloak role pitfalls"
date: "2026-06-14"
track: bug
category: integration
module: plugins/init-project/templates/src/DataAccess/Rls
tags: [rls, postgres, unit-of-work, ef-core, keycloak, jwt, transaction, cancellation, aspnetcore]
problem_type: integration
symptoms: RLS app.roles empty; pooled api connection left with open txn / leaked session settings; double-rollback; authz runs outside session context; commit failure not rolled back
root_cause: UoW relied on caller/DI for cleanup instead of being lifecycle-safe; SET LOCAL/set_config context + RoleClaimType semantics misunderstood; middleware ordering + cancellation-token misuse
resolution_type: fix
---

## Problem
A per-request DB unit-of-work that opens a transaction then issues `SET LOCAL`
(via `set_config(..., true)`) for RLS session context had several transaction-
lifecycle holes that review caught in sequence:
1. RoleClaimType alone does NOT flatten Keycloak's `realm_access.roles` JSON array
   into role claims — `app.roles` was always empty.
2. No rollback on the exception path (request work threw) → pooled connection
   returned with an open txn + lingering RLS session settings.
3. Mid-begin failure (apply session context throws after BEGIN succeeds) leaked
   the txn because the "begun" flag wasn't set until after apply.
4. Internal rollback left the flag set → middleware's catch-all rollback double-
   rolled-back the same txn.
5. Rollback used the request-aborted CancellationToken → a client disconnect
   cancels the cleanup itself.
6. Middleware ordered `UseAuthorization()` before the UoW middleware → DB-backed
   authz ran OUTSIDE the session-context transaction.
7. Commit-failure path cleared the "open" flag before committing → middleware
   rollback no-oped, so a failed commit was never deterministically rolled back.

## Solution
- Flatten `realm_access.roles` in a testable unit + `OnTokenValidated` event.
- Wrap the authenticated path in try/catch; roll back on ANY failure (begin,
  request work, commit) and rethrow.
- Track `_everBegun` (single-use) + `_open` (txn live); set `_open` the instant
  BEGIN succeeds (before apply); clear it only after a SUCCESSFUL commit/rollback.
- On apply-failure AND commit-failure, the UoW itself rolls back + clears `_open`
  + rethrows, so the caller's catch-all rollback becomes a safe no-op.
- Roll back with `CancellationToken.None` on every cleanup path.
- Order: `UseAuthentication()` → UoW middleware → `UseAuthorization()` → endpoints.

## Prevention
- For any transaction-scoped session/RLS context: the UoW must be lifecycle-safe
  on its OWN, not rely on the caller or DI disposal. Test every transition
  explicitly (begin-fails, apply-fails, commit-fails, double-commit/rollback,
  commit-after-rollback) — these are exactly the branches a coverage gate forces.
- Cleanup/rollback paths must use `CancellationToken.None`, never the request token.
- Session-context middleware belongs BETWEEN authentication and authorization.

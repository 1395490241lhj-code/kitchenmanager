# Account Deletion Runbook (Phase 2D-2)

Status: **reference runbook for a feature that has been implemented and
locally validated, not yet exercised against a real hosted/production
environment or a real incident.**

## 1. Normal flow (nothing to do)

1. iOS requests a preview (`POST /api/account/delete/preview`).
2. If blocked, the user resolves the blocker (ownership transfer) via
   `POST /api/account/transfer-ownership`.
3. iOS performs provider-native password reauthentication, receives a
   server-verified one-use proof, then requests confirm with the preview's
   `confirmationVersion` + `reauthenticationProof`.
4. Backend runs `request_account_deletion` (business-data cleanup), then
   calls the Auth Admin API, then `mark_account_deletion_finalized`.
5. iOS clears local sync state + domain data + signs out.

No operator action needed for the normal path.

## 2. Stuck at `auth_deletion_pending`

**Symptom**: `account_deletion_requests.status = 'auth_deletion_pending'`
for a user, and the client has stopped retrying (e.g. the user closed the
app after seeing "删除仍在处理中，请稍后重试确认。" and never reopened it).

**What this means**: business data is already gone/anonymized
(`business_data_cleaned_at` is set); only the Auth user row itself still
exists.

**Recovery options**:
- **Preferred**: have the user reopen the app and retry the delete-account
  confirmation screen once more — `request_account_deletion` will detect
  the existing `business_data_cleaned`/`auth_deletion_pending` status with
  the same `idempotencyKey` and return immediately without re-running
  cleanup, then the backend re-attempts the Auth Admin API call.
- **If the user cannot/will not return** (e.g. lost access to the
  associated email/device): this phase has **no background retry worker** —
  an operator must manually re-invoke the finalize path, e.g. by directly
  calling the Supabase Auth Admin API for that user id and then calling
  `mark_account_deletion_finalized` with the stored `idempotency_key` (via
  `psql`/the Supabase SQL editor, using the service-role credential — a
  privileged, backend-only operation, never performed from a developer's
  personal machine against a real project without going through the same
  service-role-key handling discipline as the backend itself).
- **This is a real, currently-manual gap** — not fabricated as
  "automatically resolves." Building a scheduled retry sweep would require
  a background worker, which this Stage-1 architecture doesn't have.

## 3. `STALE_DELETION_PREVIEW` on confirm

**Symptom**: confirm returns `409 STALE_DELETION_PREVIEW`.

**Cause**: the live blocking state (household ownership, mutation-ledger
bucket) changed between the last preview fetch and the confirm call — the
`confirmationVersion` fingerprint no longer matches.

**Resolution**: client-side only — fetch a fresh preview and retry. No
operator action.

## 4. `ACCOUNT_DELETION_IN_PROGRESS` on a second confirm attempt

**Symptom**: a second confirm call (different `idempotencyKey`) while a
first is still `business_data_cleaned`/`auth_deletion_pending`.

**Resolution**: this is the correct, expected fail-closed response —
retry with the **same** idempotency key as the original attempt (the
client should already be doing this; if a second, independent client
session somehow triggered a second attempt, direct it to wait/retry
rather than starting a competing deletion).

## 5. `/api/sync/*` returning `423 ACCOUNT_DELETION_IN_PROGRESS` for a user who says they didn't request deletion

**Symptom**: a user reports sync stopped working with this specific error
code.

**Diagnosis**: check `account_deletion_requests` for that user's row and
its `status`. If a row exists and status is one of `requested`/
`business_data_cleaned`/`auth_deletion_pending`, a deletion genuinely was
requested (possibly by the user, possibly — if this looks anomalous —
worth investigating whether the account was compromised, since request
requires a valid JWT).

**This should never happen without the user having requested it** — there
is no endpoint that lets any other party initiate a deletion on someone
else's behalf (verified in `supabase/tests/account_deletion_test.sql` and
`test/account-deletion-phase2d2.test.mjs`).

## 6. Rolling back the feature entirely (if a serious bug is found)

Since the account-deletion routes are additive (new Express routes, new
SQL functions, no changes to `apply_sync_mutation`/`pull_sync_changes`/
`get_sync_bootstrap`), the fastest safe mitigation is:

1. Stop registering the new routes (`registerAccountDeletionRoutes`) in
   `server.js` — a one-line comment-out, redeployed. Existing
   `/api/sync/*` and `/api/me` are entirely unaffected (they don't import
   or depend on anything in `src/server/account/`).
2. The `accountDeletionGuard` middleware becomes a no-op automatically if
   `registerSyncRoutes` isn't passed one (it defaults to a passthrough) —
   no separate rollback step needed there if step 1 is done via
   redeploying without the account routes wired up; if it's already
   wired and needs disabling independently, pass
   `accountDeletionGuard: (req, res, next) => next()` explicitly.
3. iOS: hide the "删除账号" entry point (a single `NavigationLink` in
   `AccountViews.swift`) via a future build if a client-side rollback is
   also needed — no server-side flag exists to remotely disable it this
   phase (matches this project's existing pattern of build-time, not
   remote, feature flags).
4. The database migration is **additive only** (new table, new/relaxed
   FKs, new functions) — nothing needs reverting there for a rollback;
   the relaxed FKs (`ON DELETE SET NULL` instead of `RESTRICT`) are
   strictly safer than before and don't need reverting even if the
   feature itself is disabled.

## 7. Who approves what

Matches this project's existing posture
(`docs/PRODUCTION_ROLLBACK_RUNBOOK.md`): any engineer observing a genuine
safety problem may disable the feature per §6 without waiting for
sign-off; provisioning real credentials (a production Supabase project,
a real `SUPABASE_SERVICE_ROLE_KEY` for a hosted environment) requires the
same explicit approval this project already requires for any production
change.

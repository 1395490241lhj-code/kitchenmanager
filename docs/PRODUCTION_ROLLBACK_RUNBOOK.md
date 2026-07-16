# Production Rollback / Disaster-Recovery Runbook (Inventory Sync / Guest Merge)

This is a design/reference document. It has not been rehearsed against a
real production incident (none has occurred — no production cohort exists
yet). It consolidates and extends `docs/INVENTORY_SYNC_ROLLBACK_PLAYBOOK.md`
with the specific procedures a real incident would require.

> **Phase 2C-1 update**: two new server-side env vars now exist,
> `SYNC_VERSION_ENFORCEMENT_ENABLED` and the `/api/sync/*` rate limiter
> (always active — it has no separate on/off flag, only its thresholds are
> configured). If the version gate or rate limiter itself needs to be
> disabled during an incident (e.g. a misconfigured minimum version
> accidentally locking out every real client), that is a **backend
> environment-variable change and restart**, not a client-side rollback —
> set `SYNC_VERSION_ENFORCEMENT_ENABLED=false` (or correct the
> `MIN_IOS_*` values) and restart the Express process. This is a different
> action from the client-side flag rollback below, and — like the rest of
> this document's "how to roll back the backend" gap — has no documented
> deploy-and-restart procedure in this repo yet, since Render deployment is
> managed entirely outside it (see `docs/PRODUCTION_ENABLEMENT_READINESS.md`).

## Who approves a rollback

A rollback decision (disabling a flag for a cohort, or halting a rollout
stage) may be made by any engineer who observes a Stop condition from
`docs/PRODUCTION_ROLLOUT_PLAN.md` — rollback is a **safe default action**,
not one that requires waiting for sign-off. Re-enabling after a rollback,
and any decision to run destructive-adjacent recovery (physical delete,
service-role access, migration change) does require a second person's
explicit approval — no such action should ever be taken unilaterally, and
in this codebase's current design **none of those actions should ever be
necessary** (see "Forbidden actions" below).

## How to turn sync off (fastest safe action)

Every gate is an independent, client-side-only `xcconfig` flag, all
defaulting `NO`. To fully roll back a device or a cohort:

1. Set `INVENTORY_SYNC_ENABLED=NO`, `INVENTORY_MERGE_UI_ENABLED=NO`,
   `INVENTORY_SYNC_DOGFOOD_ENABLED=NO`, `INVENTORY_SYNC_DIAGNOSTICS_ENABLED=NO`
   in the build configuration used for that cohort.
2. Rebuild and redistribute (sideload today; TestFlight once that pipeline
   exists — see `docs/PRODUCTION_ENABLEMENT_READINESS.md`).
3. **No server-side action is required.** The backend does not need to be
   touched, paused, or reconfigured to stop a cohort's sync traffic — the
   client simply stops offering the merge UI, the manual sync button, and
   the diagnostics screen.

If only new merge *starts* need to stop (letting already-in-flight sessions
finish), disable `INVENTORY_MERGE_UI_ENABLED` alone first; disable
`INVENTORY_SYNC_ENABLED` too only if a full stop (including manual sync
retries) is needed.

## How to stop new sync without losing in-flight state

Disabling the flags above is itself sufficient — there is no separate
"pause" mechanism to invoke, and none is needed. Already-staged
`PendingMutation` rows and `SyncMetadata` are left exactly as they are; they
are neither cleared nor auto-retried once the flag is off, since
`SyncCoordinator.runOnce` is never called automatically anywhere in this
codebase (every call site is a manual user action — `confirmMerge`,
`rollback`, `syncNow`). Turning the flag off simply removes the user's
ability to trigger one of those manual call sites.

## How to preserve pending mutations (never lose retry state)

Do nothing — this is the default behavior, not an action to take. A
`PendingMutation` is only ever removed by `resolvePending`'s `applied`/
`duplicate` case (i.e., a genuinely successful or already-done apply). A
rollback of the feature flag does not touch this table at all. If a device
is later re-enabled, its pending mutations are exactly where they were.

## How to avoid duplicate replay on re-enable

This is already guaranteed by the existing idempotency ledger
(`sync_mutations`, primary key `(user_id, mutation_id)`) — a mutation ID
generated once is reused verbatim by the client on every retry
(`PendingMutationRecord` is keyed by `mutationId`, never regenerated for an
existing pending row), so re-enabling a flag and letting a device resume
sync cannot replay an already-applied mutation as a new one; the server
returns the original result (`status: duplicate`) instead of re-applying.
No manual action is needed to prevent this — it is exercised by existing
tests (`testTenRapidSyncTapsOnlyEverAttemptSendMutationsOnce`,
`testAppKillBeforePendingCleanupIsRecoveredAndDuplicateSafeOnNextLaunch`).

## How to handle a partial rollout (some devices rolled back, some not)

This is a normal, expected intermediate state, not an error condition —
since every stage in `docs/PRODUCTION_ROLLOUT_PLAN.md` is a per-device
build-configuration difference, "some devices ahead of others" is the
default shape of any rollout, not something requiring special recovery
action. No cross-device coordination exists or is needed: each device's
sync state is independent, scoped by its own `(userId, householdId)` key
server-side (RLS-enforced) and its own local SwiftData otherwise.

## How to recover to local-only (full opt-out for one account)

Set the same four flags to `NO` for that account's device. The account's
already-synced data remains on the server (soft-deletable, never
auto-cleared) and the account's local Guest data is never touched by a
flag change — `KitchenStore`'s inventory persistence has no dependency on
any sync flag. There is no "detach this account from the server and
forget it happened" operation, and building one is explicitly out of scope
(see "Forbidden actions").

## How to handle already-synced data

Already-synced data (both content and its tombstone history) is left
exactly as-is by any rollback action. It is real household data at that
point, subject to the same data-retention expectations as any other
household inventory record — a flag rollback is a *client capability*
change, never a data-deletion event.

## How to handle tombstones

Tombstones (`deleted_at` set, row retained) are never physically removed
by any documented procedure in this codebase, rollback or otherwise. If an
entity was genuinely meant to be permanently gone, its tombstone already
represents that correctly — there is no "purge tombstones" operation, and
one should not be built without a dedicated, separately-reviewed data-
retention policy decision (out of scope here).

## How to roll back the backend

There is currently no backend rollback procedure documented in this repo,
because there is no backend deploy configuration in this repo at all (see
`docs/PRODUCTION_ENABLEMENT_READINESS.md` §1 — Render deployment is managed
entirely through Render's own dashboard/git-connect). **This is a real gap**:
before any production cohort exists, a decision is needed on how a bad
backend deploy would be rolled back (e.g., Render's own rollback-to-previous-
deploy feature, pinned to a specific git commit) — this runbook cannot
specify a procedure for infrastructure this repository does not describe.

## How to pause a migration

No migration is currently mid-flight, and none should ever be applied
directly to a live cohort without the existing review discipline (a new
`supabase/migrations/*.sql` file, reviewed like any other change). If a
migration were ever found to be problematic after applying: **do not**
attempt an automatic down-migration — write and review a new forward
migration that corrects the issue, consistent with this project's existing
practice of never modifying an already-applied migration file.

## Forbidden under any rollback/recovery flow

Carried forward unchanged from `docs/INVENTORY_SYNC_ROLLBACK_PLAYBOOK.md`,
and re-affirmed by this review:

- Clearing all local data, or all remote data, as a "fix."
- Forcing `remoteVersion` to bypass a conflict.
- Discard-conflict-then-overwrite.
- Deleting the mutation ledger or change feed (partially or fully).
- Using a service-role key to bypass RLS/permissions for any recovery
  action.
- Auto-fixing unknown corruption without a human reviewing it first.
- Any prefix-based or business-name-based bulk delete — cleanup is always
  by exact, individually-confirmed entity ID.

None of these exist in the codebase today (verified by the existing Node
semantic-guard suite's "no service-role", "no physical delete" assertions),
and none should ever be introduced as a rollback shortcut.

## Named drill scenarios

See `docs/INVENTORY_SYNC_ROLLBACK_PLAYBOOK.md`'s existing scenario table
(A–F) for the drills already exercised by automated tests. No new drill was
run as part of this review — this document only consolidates the
procedure; it does not claim a new rehearsal was performed.

# Inventory Sync Rollback Playbook (Phase 2B-5)

## Turning dogfood/sync off

Every gate is an independent xcconfig flag, all defaulting `NO`. To fully
roll back a device or a cohort: set `INVENTORY_SYNC_DOGFOOD_ENABLED=NO`,
`INVENTORY_SYNC_DIAGNOSTICS_ENABLED=NO`, `INVENTORY_MERGE_UI_ENABLED=NO`,
`INVENTORY_SYNC_ENABLED=NO` and rebuild/redistribute. No server-side state
needs to change — the client simply stops offering the merge UI, the manual
sync button, and the diagnostics screen; already-staged `PendingMutation`
rows and `SyncMetadata` are left exactly as they are (never physically
deleted by a rollback).

## Recovery actions allowed at any time (never destructive)

Retry pending, re-pull, re-read diagnostics, continue after re-login,
regenerate an invalidated merge preview, return to the conflict decision UI.
All of these already exist as ordinary controller methods
(`syncNow`, `preparePreview`, `resolveConflict`) — Phase 2B-5 added no new
mutating recovery method. A "rebuild local sync index" tool was
deliberately **not** built this phase: the existing manual retry/re-pull
path already satisfies every allowed recovery action without it, and
building one un-requested would have been scope creep beyond a Blocker/High
fix.

## Forbidden under any rollback/recovery flow

Clearing all local data, clearing all remote data, forcing `remoteVersion`,
discard-conflict-then-overwrite, deleting the mutation ledger or change
feed, using a service-role key to bypass permissions, auto-fixing unknown
corruption. None of these exist in the codebase after this phase — verified
by the Node semantic-guard suite's existing "no service-role", "no physical
delete" assertions (extended, not weakened, this phase).

## Named drill scenarios (section 十六)

| Scenario | Expected behavior | Verified |
|----------|--------------------|-----------------------|
| A. Local pending retained, server applied | Retry returns a duplicate-safe result; local cleans up correctly | **Phase 2B-6**: `testPushAppliedThenClientTimeoutIsDuplicateSafeOnRetry` — a real fault-injected timeout after genuine server-side apply, retry resolves the same mutationId, no duplicate |
| B. Local save failed, server applied | Next retry doesn't duplicate; metadata recoverable | **Phase 2B-6**: `testPullSucceedsButLocalSaveFailureNeverAdvancesCursor` covers the pull-side analogue (cursor never advances on local save failure); the push-side analogue is scenario A above |
| C. Conflict | Never auto-overwrites; user can re-choose | Covered by existing `resolveConflict` tests (Phase 2B-1 through 2B-3), not re-run fresh this phase |
| D. Logout | Pending retained; no next batch sent | **Phase 2B-6**: `testLogoutBeforeSyncNeverStartsARun`, plus existing Phase 2B-3 sign-out tests |
| E. App-kill | `mutationId`/fork id persist (both are SwiftData-backed, not in-memory) | **Phase 2B-6**: `testAppKillBeforePendingCleanupIsRecoveredAndDuplicateSafeOnNextLaunch` — a mutation left `.inFlight` by a simulated kill is picked up and resolved by a fresh persistence actor over the same container, without duplicating |
| F. Rollback | Only this session's own created records are removed; originals untouched | Covered by existing `GuestMergeController.rollback` tests, not re-run fresh this phase |

Scenarios A, B, and E — the ones Phase 2B-5 flagged as only structurally
implied — now have dedicated Phase 2B-6 tests. C and F still rely on their
existing Phase 2B-1 through 2B-3 coverage (unmodified and still passing),
not a freshly-added test this phase.

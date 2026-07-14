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

| Scenario | Expected behavior | Verified this phase |
|----------|--------------------|-----------------------|
| A. Local pending retained, server applied | Retry returns a duplicate-safe result; local cleans up correctly | Covered indirectly by existing Phase 2B-3/4 transport-failure tests; no new dedicated drill test added this phase |
| B. Local save failed, server applied | Next retry doesn't duplicate; metadata recoverable | Same as above — not newly re-verified this phase |
| C. Conflict | Never auto-overwrites; user can re-choose | Covered by existing `resolveConflict` tests |
| D. Logout | Pending retained; no next batch sent | Covered by existing sign-out tests |
| E. App-kill | `mutationId`/fork id persist (both are SwiftData-backed, not in-memory) | Structural guarantee from Phase 2B-1 through 2B-4; not re-run as a literal process-kill test this phase |
| F. Rollback | Only this session's own created records are removed; originals untouched | Covered by existing `GuestMergeController.rollback` tests |

Scenarios A, B, and E are **not** independently re-verified with a new
targeted test this phase — they rely on structural guarantees already
established and tested in Phases 2B-3/2B-4. Closing this gap (a dedicated
app-kill/duplicate-retry drill test) is listed as an open item in
[`INVENTORY_SYNC_GO_NO_GO.md`](INVENTORY_SYNC_GO_NO_GO.md).

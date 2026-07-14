# Inventory Sync Diagnostics (Phase 2B-5)

## Purpose

A read-only, fully redacted view into Inventory Sync state for developers
and dogfood participants — visible only when both
`INVENTORY_SYNC_DOGFOOD_ENABLED` and `INVENTORY_SYNC_DIAGNOSTICS_ENABLED`
are `YES` (both default `NO`; never true in a shipped Release build unless a
future phase explicitly changes that default with sign-off).

## Snapshot fields (`InventorySyncDiagnosticsSnapshot`)

`environment`, `isFeatureEnabled`, `isDogfoodEnabled`, `isEnrolled`,
`currentUserPresent`, `householdPresent`, `pendingCount`, `conflictCount`,
`failedCount`, `oldestPendingAge`, `lastSyncStartedAt`, `lastSyncCompletedAt`,
`lastSyncResult`, `lastSuccessfulCursor`, `activeMergeSessionState`,
`enrollmentState`, `localSyncedItemCount`, `localGuestOnlyItemCount`,
`localTombstoneCount`, `appBuild`, `schemaVersion`.

## Explicitly never included

Email, password, JWT, refresh token, `Authorization` header value, full
UUID (user/household/entity/mutation id), payload body, inventory item
names, or a raw HTTP response body. `lastSuccessfulCursor` is a plain
monotonic sequence number the server already returns in every pull
response — not a secret — but it is never combined with any entity
identifier.

Enforced by `testDiagnosticsSnapshotRedactedJSONNeverContainsSensitiveFields`
(`KitchenManagerTests/GuestMergeTests.swift`), which asserts the exported
JSON never contains the current test user/household's raw UUID string, an
`@`, or the substrings `token`/`password`/`Authorization`.

## Export

`InventorySyncDiagnosticsSnapshot.redactedJSON()` returns the same field set
as pretty-printed, sorted JSON. The diagnostics screen's "导出脱敏诊断摘要"
action shares this text via the system `ShareLink` — nothing is written to
a file in the repo or left on disk by the export action itself.

## Screen

`InventorySyncDiagnosticsView.swift` — entry point "库存同步诊断" at the
bottom of the account page (`AccountView`), gated by
`GuestMergeController.showsDiagnosticsScreen`. Allowed actions: refresh,
export, retry manual sync (reuses `syncNow`, subject to the same
single-flight/eligibility rules as the ordinary sync button), help. No
delete-database, clear-pending, force-overwrite, remoteVersion edit, cursor
forge, or physical-delete action exists anywhere on this screen.

## Consistency checker

`InventorySyncConsistencyChecker.check(...)` — a pure function, never
auto-fixes, returns `[InventorySyncConsistencyIssue]` (a redacted `code` plus
an optional short, irreversible, unstable 8-character id fragment, never a
full UUID or entity name). Covers 14 checks: orphan metadata, scope/enrollment
mismatch, orphan pending mutation, pending scope mismatch, non-zero
baseVersion on a pending create, missing remoteVersion on a pending
update/delete, conflicted metadata with no pending mutation, a tombstone
still visible locally, more than one active pending mutation for the same
entity, duplicate fork id, a merge session missing its plan, an
enrollment/user/household mismatch, cursor regression, and a Guest-only item
wrongly bound to a household. Covered by `GuestMergeTests` (queue/consistency
section).

# Inventory Merge Contract (Phase 2B-1)

This is the local-only contract between `GuestMergeController`,
`InventoryMergePlanner`, and the existing Phase 2A sync boundary
(`SyncCoordinator` / `InventorySyncAdapter` / `ExpressSyncTransport`). It adds
no new backend endpoints or schema — every network call it makes reuses
`docs/SYNC_API_CONTRACT.md`'s existing `bootstrap` / `changes` / `mutations`
routes, scoped to `inventory_item` only.

## Session key

```
GuestMergeSession.uniqueKey = "\(userId):\(householdId):inventory_item"
```

At most one *active* (non-terminal) session may exist per key. Terminal
sessions (`completed` / `cancelled` / `rolledBack`) remain queryable by `id`
as history but are not returned by `activeGuestMergeSession`.

## States

```
detected → previewReady → awaitingConfirmation → preparing → uploading
  → completed → rollbackPending → rolledBack
  → conflict (partial commit: unresolved candidates stay pending)
  → failed
  → cancelled (only before upload starts)
```

## Matching key

```
normalizedKey(item) = lowercased(trim(item.name)) + "|" + lowercased(trim(item.unit))
```

Compared fields for conflict detection: `quantity` (exact), `expiryDate`
(exact, including nil vs non-nil). No `location`/`category`/`opened` fields
exist on `InventoryRecord` today, so they are not part of this contract.

## Candidate resolution

| Local vs. remote | Result |
| --- | --- |
| Same id, same values | `skip` (no-op) |
| Same id, different `quantity` | `conflict: quantityMismatch` |
| Same id, different `expiryDate` | `conflict: expiryMismatch` |
| No remote match for key | `create` |
| One remote match, different id | `conflict: ambiguousDuplicate` |
| 2+ remote matches for key | `conflict: multipleRemoteCandidates` |

A conflict only becomes upload-eligible after an explicit
`InventoryMergeConflictChoice`:

| Choice | Resulting action |
| --- | --- |
| `keepLocal` | `update` if same id, else `create` (never takes over a different id's remote record) |
| `keepRemote` | `keepRemote` (never uploaded) |
| `keepBoth` | `create` (always a new remote record) |

## Plan hash

```
planHash = sha256(
  sessionId + householdId +
  join(sorted_by_id(localItems).map(item => "\(id):\(quantity):\(unit):\(expiry ?? "nil")"))
)
```

Recomputed and compared before resuming a persisted session; a mismatch means
local inventory changed since the plan was generated and the plan must be
regenerated, never silently reused or uploaded stale.

## Upload

1. For each candidate in `plan.readyToUpload`, call
   `InventorySyncAdapter.stageUpsert(item:scope:)` (existing Phase 2A-3 path;
   `baseVersion` is the item's last known `SyncMetadata.remoteVersion`, or
   `0` for a first-time create).
2. Run one `SyncCoordinator.runOnce(authentication:, scopes: [householdScope])`
   with a locally-scoped `SyncConfiguration(isEnabled: true)` — this instance
   is never the global `SyncConfiguration.load()` and never toggles the
   `SYNC_ENABLED` flag file.
3. Read back `SyncMetadata` per candidate: `.synced` → uploaded (and, for a
   `create`, appended to `createdEntityIds`); `.conflicted` → conflict
   retained; `.failed` → failed. Session status becomes `completed` only when
   there are zero unresolved conflicts and zero failures; otherwise
   `conflict` or `failed`.

Duplicate-safe: `PendingMutation.mutationId` is stable per candidate for the
lifetime of the session, and the server's existing idempotency ledger
(`docs/SYNC_API_CONTRACT.md`) already answers a repeated identical mutation
with `duplicate`, not a second row.

## Rollback

Only `GuestMergeSession.createdEntityIds` (records this session itself
created) are eligible. Each is soft-deleted via
`InventorySyncAdapter.stageDelete(entityId:scope:)` +
`SyncCoordinator.runOnce`, using the record's current `baseVersion` — never a
hardcoded or stale version. Idempotent: rolling back an already-`rolledBack`
session is a no-op; a partially-failed rollback may be retried and will only
re-attempt ids not yet confirmed deleted. Never a physical delete of the
change feed, idempotency ledger, or local Guest data.

## Error mapping (client-side; server contract unchanged)

| Condition | Session outcome |
| --- | --- |
| `401` / missing token | `confirmMerge`/`rollback` return early with a login prompt; session state unchanged |
| Transport/network failure | `failed`, `lastErrorCode` set; retryable by re-confirming |
| Server `conflict` result | Candidate/session `conflict`, retained, never auto-resolved |
| Non-`.completed` `SyncRunOutcome` | Session `failed` with the outcome recorded, not silently treated as success |

No error message surfaced to the UI includes a JWT, `Authorization` header,
publishable key, or raw SQL detail — the existing `SyncError.errorDescription`
messages are reused as-is.

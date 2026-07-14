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

**`quantity` is never part of the identity/matching key.** It is a mutable
business value, compared only *after* a candidate's identity has already been
resolved (by stable id, or by `normalizedKey` when no id match exists) — a
quantity difference is always surfaced as a conflict, never a reason to treat
two items as unrelated or to let a candidate escape into `create`.

Identity/expiry semantics (`ExpiryIdentity`, `InventoryMergePlanner.swift`):
two expiry dates are **compatible** when both are absent, or both present and
equal; they are **incompatible** in every other case (one absent/one present,
or both present and different). An incompatible expiry is never silently
resolved — same id ⇒ `expiryMismatch`; different id, same key ⇒
`ambiguousDuplicate` (looks like a different batch under a new id, so the
match is not narrowed to "just an expiry issue").

`isStaple` / `stapleCategory` / `lowStockThreshold` / `defaultRestockQuantity`
/ `autoSuggestRestock` / `stapleTrackingMode` / `stapleAvailabilityStatus` are
"metadata" fields: tracked so a same-id difference is surfaced as an explicit
`metadataMismatch` conflict, but — like `quantity` — never part of the
matching key itself, and never silently overwritten by an upload.

## Candidate resolution

Classification order (same id is a certain identity; different id + same key
is only a possible duplicate, so its identity itself stays uncertain no
matter how many fields happen to match):

| Local vs. remote | Result |
| --- | --- |
| Same id, same quantity/expiry/metadata | `skip` (no-op) |
| Same id, incompatible expiry | `conflict: expiryMismatch` |
| Same id, compatible expiry, different `quantity` | `conflict: quantityMismatch` |
| Same id, compatible expiry/quantity, different metadata field | `conflict: metadataMismatch` |
| No remote match for key | `create` |
| One remote match, different id, incompatible expiry | `conflict: ambiguousDuplicate` |
| One remote match, different id, compatible expiry | `conflict: ambiguousDuplicate` (identity is still uncertain even when values line up) |
| 2+ remote matches for key | `conflict: multipleRemoteCandidates` |

A conflict only becomes upload-eligible after an explicit
`InventoryMergeConflictChoice`:

| Choice | Resulting action |
| --- | --- |
| `keepLocal` | `update` if same id, else `create` (never takes over a different id's remote record) |
| `keepRemote` | `keepRemote` (never uploaded) |
| `keepBoth` | `create` — using `candidate.localItemId` if the match was different-id (already distinct); using a freshly allocated `forkedLocalItemId` if the match was same-id (Phase 2B-2.5 — see below), never the original id |
| `skip` (Phase 2B-3) | `skip` — behaviorally identical to leaving the conflict unresolved (never uploaded), except `userChoice` is recorded so it drops out of the "still needs a decision" list |

### Same-id `keepBoth` identity fork (Phase 2B-2.5)

A same-id match means the remote entity's identity is certain, so `keepBoth`
cannot mean "create using that same id" — it already exists remotely at a
real, non-zero version, and a create attempt against it would (correctly)
be rejected as a stale-version conflict, never producing an actual second
record. `InventoryMergeCandidate.forkedLocalItemId: UUID?` — part of the
already-persisted `plan`, no separate SwiftData model — holds a fresh id,
allocated once by `applyingChoice(.keepBoth)` (`forkedLocalItemId ?? UUID()`)
and reused verbatim on every later call (repeated choice, repeated confirm,
or after an App restart re-decodes the same persisted candidate).

`confirmMerge`'s staging loop checks `forkedLocalItemId` first: when set, it
copies the local item's values under the forked id and stages that as a
plain create at `baseVersion` 0 (guarded on the forked id's own local
`SyncMetadata` being absent, so a retry never re-stages an already-created
fork) — `candidate.localItemId` (the original, certain entity) is never
touched by this candidate at all, a true no-op exactly like `keepRemote`.
`createdEntityIds` (and therefore `rollback`) key off the forked id, not the
original, so rollback only ever soft-deletes the fork. The local inventory
ends up with two independent `InventoryRecord`s: the original (its id never
mutated, still mapped to the original remote entity) and the fork (mapped to
the newly created one). Different-id ambiguous-duplicate `keepBoth` is
unaffected — its own id is already distinct, so `forkedLocalItemId` stays
`nil` there and it keeps using `candidate.localItemId` as before.

## Plan hash

```
planHash = sha256(
  sessionId + householdId +
  join(sorted_by_id(localItems).map(item => "\(id):\(quantity):\(unit):\(expiry ?? "nil")"))
)
```

Recomputed and compared before resuming a persisted session; a mismatch means
local inventory changed since the plan was generated and the plan must be
regenerated, never silently reused or uploaded stale. The hash is built from
a manually sorted-and-joined string (not a JSON serialization), so key
ordering is not a source of instability by construction; input ordering of
`localItems` also does not affect the result, since items are sorted by id
before hashing.

`GuestMergeSession.localSnapshot` (used only for this drift check, not for
matching) is capped at `GuestMergeSession.maxSnapshotItems` (500) to bound the
persisted blob size — but this cap only bounds the snapshot; it never
truncates the merge plan itself, which always covers every local item.
`GuestMergeSessionRecord.value` decodes `localSnapshotData`/`planData`
defensively: a decode failure yields an empty snapshot / `nil` plan rather
than crashing or fabricating data, and a `nil` plan makes `confirmMerge`
refuse to upload anything (it guards on `let plan = current.plan else {
return }`).

## Pre-merge remote read (Phase 2B-2)

`GuestMergeController.preparePreview(userId:householdId:kitchenStore:remoteTransport:)`
takes an optional `remoteTransport` (default `nil`). Ordinary in-app preview
never supplies one, so `knownRemoteItems` stays empty and behavior is
unchanged from Phase 2B-1. When supplied (only by the Debug-only hosted smoke
harness today), a private `fetchKnownRemoteItems` performs one read-only
`SyncTransport.fetchChanges` pull for the household's `inventory_item`
entities (a GET; no `sync_mutations`/`sync_changes` write; no persisted pull
cursor advance), decodes each into a `RemoteInventorySnapshotItem` (via
`InventorySyncAdapter.decodeRemoteInventorySnapshot`, including the entity's
real `remoteVersion`), and passes the result to `InventoryMergePlanner.makePlan`.
This is a read, not a write, so it does not violate "preview performs zero
network writes."

`RemoteInventorySnapshotItem` and `InventoryMergeCandidate` both carry this
`remoteVersion`. `confirmMerge` uses it to seed local `SyncMetadata`
(`state: .synced`) before staging a same-id `.update` candidate whose
existence this device only just learned about — without this, a Guest
device merging into an already-populated household would send `baseVersion
0` for an entity that already exists remotely at a later version, and the
server would correctly (but unhelpfully) reject it as a stale-version
conflict. The seed only fills in a previously-unknown local value: if this
device already has its own local `SyncMetadata` for that entity, it is never
overwritten with a possibly-stale snapshot-time version.

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

## Access token handling

`confirmMerge(authStore:)` and `rollback(authStore:)` take the live `AuthStore`
reference the caller (always a `View`) already holds — never a raw access
token string. Internally, a private `AuthStoreCredentialProvider` (a
`SyncAccessTokenProviding`) holds only a `weak var authStore: AuthStore?` and
re-queries `authStore?.currentAccessToken()` fresh on every single network
call, rather than freezing a token value up front. Consequences:

- No `View`, `@Published` property, `Codable`/`Sendable` model, SwiftData
  record, or `UserDefaults` value ever holds a token; `AuthStore.swift`'s
  `currentAccessToken()` accessor is documented as callable only from this one
  provider, and `test/ios-native-guest-merge-phase2b1.test.mjs` enforces (by
  source inspection) that no View file calls it directly.
- A sign-out that happens mid-upload/mid-rollback immediately and permanently
  starves any further request in that same run: the next `accessToken()` call
  returns `nil`, and `ExpressSyncTransport` throws `.notAuthenticated` instead
  of sending anything.
- `confirmMerge`/`rollback` themselves guard on `authStore.currentUserID` up
  front; if the caller is already signed out when the call starts, both
  return immediately with a login-prompt error message and leave the session
  status unchanged.

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

## Manual sync (Phase 2B-3)

`GuestMergeController.syncNow(authStore:householdId:)` is the only production
call site of `SyncCoordinator.runOnce` besides `confirmMerge`/`rollback` —
always in direct response to a user tapping "立即同步库存", never automatic.
Same guard clauses (`isFeatureEnabled`, `authStore.currentUserID`), same
`.inventoryItem`-only scope, same locally-scoped
`SyncConfiguration(isEnabled: true)`. Errors are mapped through
`userFacingSyncError(_:)` to plain copy, never the raw `SyncError`.
`pendingInventoryCount(householdId:)` is a read-only count used only for a
status label, never to decide whether to sync automatically. Full detail:
`docs/INVENTORY_SYNC_PHASE2B3.md`.

## Ordinary CRUD mutation staging (Phase 2B-4)

Once a `(userId, householdId)` workspace is `.enrolled` (a Guest merge
completed — see `docs/INVENTORY_CRUD_SYNC_PHASE2B4.md`), ordinary Inventory
create/update/delete outside the merge flow also stage `PendingMutation`s,
through the exact same `SyncMetadataRecord`/`PendingMutationRecord` schema
and the exact same `syncNow` transport path described above — no new
network capability, no new entity type. `InventorySyncEligibility` is the
single centralized gate (feature flag, signed-in, household match,
enrollment, existing metadata scope/state); coalescing rules (at most one
pending mutation per entity) are in `docs/INVENTORY_MUTATION_COALESCING.md`.

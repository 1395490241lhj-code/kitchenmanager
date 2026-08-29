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

`kind` (the full classification) / `stapleCategory` / `lowStockThreshold` /
`defaultRestockQuantity` / `autoSuggestRestock` / `stapleTrackingMode` /
`stapleAvailabilityStatus` are "metadata" fields: tracked so a same-id
difference is surfaced as an explicit `metadataMismatch` conflict, but — like
`quantity` — never part of the matching key itself, and never silently
overwritten by an upload.

**Classification is compared as the whole `InventoryItemKind`, not as its
`isStaple` projection** (sync P3). `.ordinary` and `.readyToCook` both project
to `isStaple == false`, so comparing the projection reported a genuine
ready-to-cook difference as a clean no-op — the candidate landed in
`exactMatches`, was shown to the user as 无需处理, and was never staged, so the
local ready-to-cook state was lost with no user-visible trace.
`RemoteInventorySnapshotItem` therefore stores `kind` and exposes `isStaple` as
a computed projection, exactly as `InventoryItem` does; the wire's orthogonal
`isStaple` + `preparationKind` pair is resolved into that one axis once, in
`InventorySyncAdapter`, with precedence `staple > readyToCook > ordinary`
(`SYNC_API_CONTRACT.md` §4.2).

An unrecognised `preparationKind` (an out-of-vocabulary future value, a wrong
JSON type, an explicit null) decodes to `.ordinary` and never throws:
`SyncCoordinator.pull` abandons the page and leaves the cursor unadvanced if
`applyRemote` throws, so a fail-closed decode would wedge every later change
behind one record, permanently and with no way to self-heal. The accepted cost:
because every inventory upsert this client sends is a full snapshot, the next
local edit of that row — an unrelated quantity or expiry change just as much as
a classification change — normalises the unknown value to `none` server-side.
The P2 Express enum and the database CHECK make an out-of-vocabulary value
unreachable under the current protocol, so this is a forward-compatibility
trade-off, not a live hosted-data risk.

The same full-snapshot mechanism also collapses the **legal**
`is_staple=true` + `preparation_kind='readyToCook'` combination, with no
unknown value involved: such a row decodes to `.staple` by precedence, and this
client's next upsert of it — again, an unrelated quantity edit is enough —
writes back `isStaple=true, preparationKind=none`, erasing the preparation half
it never represented locally. That is exactly what §4.2's normalisation map
asks a client with a single local classification axis to do, so it is
contract-sanctioned rather than a defect; it is recorded here because a second
sync client that writes the combination would see this client flatten it. Not
reachable today — the PWA has no sync path that writes `is_staple`.

Classification remains **metadata, never identity**: it is compared only after
a candidate's identity has been settled, and `normalizedKey` is still name +
unit alone. Two remote rows differing only by classification therefore stay a
single ambiguous bucket (`multipleRemoteCandidates`) rather than becoming two
separately matchable identities. The PWA's own `inventory_items.kind` identity
semantics are deliberately not imported here.

Both fingerprints cover classification, so drift on either side invalidates a
plan rather than slipping through: `remoteSnapshotHash` folds in
`item.kind.rawValue` (a remote `.ordinary ⇄ .readyToCook` flip leaves
`isStaple` false on both sides, so hashing the projection would let it pass
`confirmMerge`'s pre-write re-verification unnoticed), and `planHash` folds it
in for local items too (a purely local `.ordinary → .readyToCook` edit turns a
clean `skip` into a `metadataMismatch`, so a plan generated before that edit
must be regenerated, not reused). Adding classification changed both hash
inputs; any plan persisted before sync P3 is simply regenerated on its next
validation, which is the intended safe behaviour.

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
  join(sorted_by_id(localItems).map(item => "\(id):\(quantity):\(unit):\(expiry ?? "nil")")) +
  "remote:" + (remoteSnapshotHash ?? "none")
)
```

Recomputed and compared before resuming a persisted session; a mismatch means
local inventory (or, since Phase 2B-8, remote inventory) changed since the
plan was generated and the plan must be regenerated, never silently reused
or uploaded stale. The hash is built from a manually sorted-and-joined
string (not a JSON serialization), so key ordering is not a source of
instability by construction; input ordering of `localItems` also does not
affect the result, since items are sorted by id before hashing.

**Remote snapshot fingerprint (Phase 2B-8).** `InventoryMergePlan` carries
`remoteSnapshotHash: String?`/`remoteSnapshotFetchedAt: Date?`, populated
only when a real remote read happened (`nil` for the offline/no-transport
path, preserving prior behavior exactly).
`InventoryMergePlanner.remoteSnapshotHash(_:)` computes a canonical,
order-independent SHA256 digest over every `RemoteInventorySnapshotItem`
field relevant to matching/conflict detection, including `remoteVersion` —
sorted by entity id so fetch/page order never affects the result. This is
folded into `planHash` above, so `isPlanStillValid(_:against:currentRemoteItems:)`
detects remote drift (a version bump, a create, a delete) through the exact
same mechanism that already detected local drift — no second code path to
keep in sync. `confirmMerge` re-fetches and re-hashes the remote snapshot
immediately before staging any mutation and rejects the confirm (reverting
the session to `previewReady`) if the fingerprint no longer matches what
preview saw.

`GuestMergeSession.localSnapshot` (used only for this drift check, not for
matching) is capped at `GuestMergeSession.maxSnapshotItems` (500) to bound the
persisted blob size — but this cap only bounds the snapshot; it never
truncates the merge plan itself, which always covers every local item.
`GuestMergeSessionRecord.value` decodes `localSnapshotData`/`planData`
defensively: a decode failure yields an empty snapshot / `nil` plan rather
than crashing or fabricating data, and a `nil` plan makes `confirmMerge`
refuse to upload anything (it guards on `let plan = current.plan else {
return }`).

## Pre-merge remote read (Phase 2B-2; wired into production in Phase 2B-8)

`GuestMergeController.preparePreview(userId:householdId:kitchenStore:remoteTransport:)`
takes an optional `remoteTransport` (default `nil`, still zero-network when
omitted). Since Phase 2B-8, the production call site
(`GuestMergePromptView`'s `.task`) calls a second overload,
`preparePreview(userId:householdId:kitchenStore:authStore:)`, which builds a
real transport via the existing `AuthStoreCredentialProvider`/
`transportFactory` pattern and always supplies it — so `knownRemoteItems`
now reflects real household state in the shipped app, not just in the
Debug-only hosted smoke harness. A private `fetchKnownRemoteItems` performs
one read-only `SyncTransport.fetchChanges` pull for the household's
`inventory_item` entities (a GET; no `sync_mutations`/`sync_changes` write;
no persisted pull cursor advance), decodes each into a
`RemoteInventorySnapshotItem` (via
`InventorySyncAdapter.decodeRemoteInventorySnapshot`, including the entity's
real `remoteVersion`), and passes the result to `InventoryMergePlanner.makePlan`.
This is a read, not a write, so it does not violate "preview performs zero
network writes." A scope mismatch or exceeding the hardcoded `maxPages` (50)
cap while more data remains now `throw`s rather than silently returning a
partial/wrong snapshot; any thrown error surfaces as
`GuestMergeController.previewFetchFailureMessage` and blocks preview
entirely — it can never be displayed as "0 known remote items."

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

Only `GuestMergeSession.createdEntityIds` are eligible. That field means
**entities this session created remotely** — never "objects this session
created locally". For a plain `.create` candidate the recorded id is the local
Guest item's *own* id, because a merge deliberately publishes a local row under
the UUID it already has; the same UUID therefore names both a remote entity the
merge created and a local row the user has owned all along.

**Rollback withdraws what the merge published to the household. It never
removes a local durable `InventoryRecord` from the store.** Concretely:

| Merge path | Remote effect of rollback | Local effect of rollback |
| --- | --- | --- |
| `create` | the created entity is soft-deleted | none — the Guest row is preserved |
| `update` | none — never entered `createdEntityIds` | none |
| `keepRemote` / `skip` | none | none |
| same-id `keepBoth` (fork) | only the fork's remote entity is soft-deleted; the pre-existing remote row is untouched | none — **both** the user's original row and the session-created fork row are preserved |

Restoring the exact pre-merge *local* state is a different feature: it needs a
provenance model and its own product semantics, and is explicitly not what
rollback does.

Two delete helpers, separated by name rather than by a boolean flag:

- `InventorySyncAdapter.stageRemoteDeletePreservingLocal(entityId:scope:)` —
  remote-only. Writes `SyncMetadata` and a `PendingMutation` through
  `stageInventoryMutation` (the same primitive ordinary CRUD deletions use) and
  never touches `InventoryRecord`. **This is what rollback uses.**
- `InventorySyncAdapter.stageDeleteRemovingLocalRecord(entityId:scope:)` —
  destructive: stages the remote delete *and* removes the local row in one
  transaction. Smoke/marker cleanup only; it has no production consumer.

Ordinary user deletion uses neither: `KitchenStore` removes the durable row and
`GuestMergeController.handleInventoryDidChange` stages the remote delete
separately. A rollback fix must never turn that into a preserve-local.

Rollback stages against each record's current `baseVersion` — never a hardcoded
or stale version — then runs `SyncCoordinator.runOnce` and only reports
`rolledBack` once every id staged in that attempt reached `.synced` with a
`deletedAt`. Idempotent: rolling back an already-`rolledBack` session is a
no-op; a partially-failed rollback may be retried and will only re-attempt ids
not yet confirmed deleted. Never a physical delete of the change feed,
idempotency ledger, or local Guest data.

### Retrying a failed delete keeps its `mutationId`

A failed push is **ambiguous**: the delete may have reached the server,
tombstoned the entity, and had only its *response* lost. So a retry re-sends the
original mutation rather than staging a replacement — same `mutationId`, same
`baseVersion`, same payload, with only the attempt bookkeeping reset.

That is what makes the retry converge. The server's idempotency ledger is keyed
on `mutationId`, so the resend is answered `duplicate` carrying the original
version, which `resolvePending` settles exactly like an `applied` — the entity
reaches `.synced` with its `deletedAt`, verification passes, and the session
reaches `rolledBack`. A freshly minted id would be invisible to that ledger and
judged on its `baseVersion` alone; that version is stale precisely because the
bump was in the lost response, so the server answers `conflict`, the entity's
metadata sticks at `.conflicted`, and no number of retries can ever complete the
rollback.

The attempt reset is required as well as the id: `stageInventoryMutation`'s
`(.delete, .delete)` branch reuses the queued mutation verbatim, so without it
the spent `attemptCount` would keep the mutation invisible to
`pendingMutations(scope:maxAttempts:)` and rollback would report
`rollback_delete_not_applied` until the window expired.

If staging ever collapses to `.cancelled` (the create+delete case, which also
removes the entity's metadata and with it the tombstone shield), rollback fails
with `rollback_staging_cancelled` and stays retryable — it never verifies, or
reports success for, an entity nothing was staged for.

### After a rollback: the preserved row is local-only

A rolled-back entity keeps its `SyncMetadata` — `.synced`, with a `deletedAt`
and the tombstone's own `remoteVersion`. That metadata is load-bearing in both
directions and must not be cleared:

- **Outbound.** `InventorySyncEligibility` returns
  `.localOnly(reason: .remotelyDeleted)` for any `.update` or `.delete` intent
  on such a row. Without it, an ordinary later edit would be eligible at exactly
  the tombstone's version — which `SYNC_API_CONTRACT.md` defines as the
  *resurrect* upsert — so an unrelated quantity edit would silently undo the
  user's rollback and republish the row to the household.
- **Inbound.** It is also what makes a later pull of *that same tombstone*
  resolve as `duplicate` in `InventorySyncAdapter.applyRemote` (the
  `remoteVersion >= change.version` check runs before the delete branch) instead
  of deleting the preserved local row. Clearing the metadata to "make the row
  Guest-local again" would reintroduce the same data loss through the pull path.

  The inbound protection is scoped precisely to that: it absorbs replays of the
  tombstone the rollback itself produced. It is **not** a general shield. A
  later remote change at a *higher* version still applies normally — if another
  household member resurrects the entity and deletes it again, that newer
  tombstone removes the local row, which is the correct propagation of someone
  else's deletion rather than a rollback defect.

Ordinary deletion is unaffected by this rule: it removes the local row, so no
later intent for that id can arise, and a genuinely new item carries a new UUID
with no metadata at all. The rule covers `.create` as well as `.update` and
`.delete`: intent is derived from "this id was absent before", so a create for
an id that already carries scoped metadata is never a genuinely new item, and it
is the one intent whose staging path would both resurrect the entity and clear
the `deletedAt` shield.

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

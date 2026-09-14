# Research: Safe backup restore

**Feature**: 005 | **Date**: 2026-09-14 | **Evidence base**: `dbb7bce`

Every finding below was read from current code at `dbb7bce`, not from prior reports. Where a
decision had plausible alternatives they are recorded with the reason the alternative lost.

## R1 - What validation must actually check

**Read**: `KitchenBackupPayload` and its custom `init(from:)`; `restoreBackupData`;
`KitchenBackupDocument`; `BackupRestoreView`'s `fileImporter` handler.

The payload declares `format` and `version`. A repository-wide search finds their only
occurrences are the declaration, the `CodingKeys` list and the decoder assignments. **No code
reads either value.** The decoder resolves every field with `decodeIfPresent ?? []`, and both
identity fields have defaults, so absence is indistinguishable from correctness.

Consequences that validation has to close:

| Input | Today | Required |
|---|---|---|
| `{}` | decodes to seven empty domains, restores, reports success | refused, zero mutation |
| unrelated JSON object | same as above | refused, zero mutation |
| `format` of another product | ignored, restores | refused, zero mutation |
| `version: 2` | ignored, restores whatever v1 keys happen to match | refused, zero mutation |
| top-level array or scalar | `container(keyedBy:)` throws, surfaces `invalidFile` | unchanged; already safe |

The last row is the only currently-safe case, and it is safe by accident of `Codable` rather than
by design.

**Decision**: validation is an identity-and-compatibility gate that runs on the decoded object and
is separate from decoding. "Decoded" and "is a Kitchen Manager backup" are different results and
the feature keeps them distinct (spec Key Entities).

**Rejected**: tightening the decoder itself by making fields non-optional. It would turn every
forward-compatibility case into an opaque `DecodingError`, losing the ability to tell the member
"this backup is from a newer version" (FR-006), and it would change how already-written v1 files
that legitimately omit an empty domain are read.

## R2 - Version acceptance policy

**Read**: `KitchenBackupPayload.version` default and initialiser; git history of the payload.

Only `version = 1` has ever been produced. `preparedComponents` and `specialPlans` were added to
the payload after it shipped, and both were introduced as `decodeIfPresent`-tolerant fields
**without** a version bump -- so a v1 file may legitimately lack them.

**Decision**: accept exactly `format == kitchen-manager-native-backup` and `version == 1`. Reject
every other version, higher or lower, before mutation. Within v1, keep tolerating absent domain
keys, because real shipped v1 files do omit them.

This is deliberately strict rather than range-based. There is no historical version to migrate,
so inventing tolerance now would be speculative forward compatibility -- exactly what the request
prohibits. A future v2 will have to state its own acceptance rule, which is the correct place for
that decision.

**Consequence to state honestly**: an older build will refuse a future v2 backup. That is the
intended trade and is reported as "from a newer version of the app", not as corruption.

## R3 - Recovery strategy (the decision the request asked to research, not assume)

**Read**: `exportBackupData()`; `restoreBackupData`'s compensation block; the seven persistence
implementations; `SharedImportQueue.appGroupQueue`; the app's plists for file-sharing keys.

### Options evaluated

| | A. Durable pre-restore copy | B. In-memory snapshot + compensation (today) | C. Both | D. Existing repo mechanism |
|---|---|---|---|---|
| Survives app termination | yes | **no** | yes | App Group container: yes |
| Survives rollback failure | yes | **no** | yes | yes |
| Survives a dirty-context failure | yes | **no** (R5) | yes | yes |
| Member can invoke it | only with an affordance | n/a | only with an affordance | only with an affordance |
| Testable | yes, with an injectable location | partly | yes | yes |
| New data-at-rest | **yes** | no | **yes** | yes |

Option B is what exists and it is exactly what the archaeology disproved: it is held only in
local variables, it is applied with `try?`, and R5 shows the contexts it writes through can be
poisoned by the very failure it is compensating for. It cannot carry the word "safe" alone.

Option D is real: `SharedImportQueue` already writes JSON files into the App Group container, so
the repository has a supported durable-file pattern. But the App Group exists to share with the
Share Extension, which has no interest in a kitchen snapshot, and putting user data there widens
its reach for no benefit.

**Decision: C, with A implemented in app-private storage and B retained unchanged.**

The durable copy is produced by the existing `exportBackupData()` -- the same bytes the member
could have exported by hand -- so it introduces no new serialisation format and no new payload.
The in-memory compensation is kept because when it works it is faster and leaves nothing behind;
it simply stops being the only line of defence, and stops being silent (FR-020).

### Contract for the durable copy

- **Where**: app-private application-support storage, one reserved slot. Not the App Group.
- **When created**: after the member confirms and before the first persistent write. Its success
  is a precondition of the point of no return (FR-013, FR-014).
- **When removed**: when the attempt it belongs to ends in success or in proven recovery. It is
  retained while an unproven outcome is unresolved, and a new attempt replaces the single slot
  rather than accumulating (FR-017).
- **Member-visible**: not browsable. The app declares no file-sharing entitlement, so the
  container cannot be reached from Files. This is precisely why FR-016 requires an in-app action
  **and** an export -- without them the copy would be a promise the member cannot cash.
- **If creation fails**: the restore does not begin. `PREPARATION_FAILED`, zero mutation.

**What this contract must not claim**: it is not a backup service, not versioned history, and not
a guarantee that recovery will succeed. It guarantees that a copy existed before the first write
and that the member can reach it. Recovery runs through the same restore pipeline, so a
sufficiently broken persistence layer can fail it too -- which is why `RESTORE_FAILED_UNSAFE`
remains a real reportable state rather than being designed away.

## R4 - In-memory and persistence consistency after failure

**Read**: `KitchenStore.init`'s per-domain load block; `reconcileInventoryFromPersistence()`;
`endInventorySyncConsistencyWindow()`; `isInventoryLockedForSync`; `publishDurableInventory`.

The repository already has the right shape for one domain: `reconcileInventoryFromPersistence()`
re-hydrates the in-memory array from durable storage, never writes back, never stages an outbound
mutation, and returns whether the read succeeded. `endInventorySyncConsistencyWindow` uses that
return value to decide whether to release the edit gate, and deliberately stays locked when
reconciliation fails.

**There is no equivalent for the other six domains.** Their only load path is `KitchenStore.init`,
where each domain loads independently with its own `catch` and its own notice string.

**Decision**: after an outcome without proven recovery, re-establish every backup-scoped domain
from persistence, following the existing reconcile shape rather than inventing a new one. If a
domain's re-read fails, do not silently keep the stale in-memory value: surface it and keep the
recovery path available, mirroring how the inventory window stays locked on a failed reconcile.

**Rejected**: requiring an app restart. It is unverifiable, cannot be asserted in a test, and
leaves the untrustworthy state on screen until the member happens to comply.

**Rejected**: disabling affected operations wholesale. It is a larger behavioural change than the
problem needs, and the existing precedent locks one domain under a specific sync condition rather
than broadly disabling the app.

## R5 - Why four persistences need a narrow repair

**Read**: all seven persistence implementations.

| Domain | Context lifetime | On save failure |
|---|---|---|
| Inventory | fresh per operation | discarded with the context -- safe by construction |
| Today plan | long-lived | explicit rollback, with a comment explaining why |
| Weekly plan | long-lived | explicit rollback |
| User recipes | long-lived | explicit rollback |
| **Shopping list** | long-lived | **none** |
| **Consumption** | long-lived | **none** |
| **Prepared components** | long-lived | **none** |
| **Special plans** | long-lived | **none** |

The today-plan implementation states the hazard in its own words: a failed save leaves the context
holding that attempt's deletes and inserts, and the next call re-fetches and re-inserts the same
`id`, colliding with the record's unique attribute. Every affected record type here declares
`@Attribute(.unique) id`.

This matters to this feature specifically because the compensating restore runs **immediately
after** the failed write, on that same context. So the repair is not opportunistic cleanup: it is
a precondition for the recovery contract being meaningful for four of the seven domains.

**Decision**: specify the behaviour (FR-025), not the mechanism. Matching the existing rollback
pattern is the obvious implementation, but the acceptance criterion is that a compensating write
immediately after a failed write succeeds -- not that a particular API is called.

**Bounded**: four implementations, no protocol change, no shared-context redesign. Anything wider
is the deferred atomicity work.

## R6 - File-picker cancellation

**Read**: `BackupRestoreView`'s `fileImporter` completion handler.

The handler funnels everything through one `catch` that assigns `error.localizedDescription` to
the alert. Whether SwiftUI delivers a cancellation as `.failure` varies by iOS version, which is
why the archaeology classified this UNKNOWN rather than asserting it.

**Decision**: stop depending on the platform's answer. Normalise at the UI boundary -- a
cancellation, however it arrives, produces no mutation and no failure surface (FR-028). This is
correct on every iOS version and removes the need to verify the platform behaviour at all.

## R7 - Deterministic failure seams

**Read**: `KitchenPersistenceBundle`; the `Failing*Persistence` types; `KitchenStoreTests`.

The repository already has what this feature's tests need. Every domain is injected through
`KitchenPersistenceBundle`, and each protocol already has a `Failing*Persistence` implementation
that throws on every call. `todayPlan` is already `var` specifically so a DEBUG fixture can wrap
it for a failure-path UI test -- an existing precedent for exactly this technique.

**Decision**: build failure injection from the existing bundle and `Failing*` types, extended to
fail on a chosen call rather than always. No new test framework, and no reliance on provoking real
persistence faults.

**Existing coverage checked**: the only pinned restore behaviour today is the sync-lock refusal in
`KitchenStoreTests`. Nothing pins validation or partial failure, so this feature's tests are
additive rather than a rewrite. The Settings UI tests touch the backup screen only to assert its
entry points exist and deliberately trigger neither export nor import.

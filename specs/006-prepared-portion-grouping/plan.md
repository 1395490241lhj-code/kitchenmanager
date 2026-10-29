# PR2 Prepared Portion Grouping — Design and Implementation Plan

**Date:** 2026-10-28

**Status:** Proposed; stop for owner approval. No implementation performed.

**Spec:** [spec.md](spec.md)

**Goal:** Represent one measured Prepared source as linked, consumable groups.

**Architecture:** Extend existing Prepared values/rows with optional source and
per-portion mass metadata; reuse the one Prepared collection and transaction.
There is no new source table, repository, inventory adapter or sync path.

**Stack:** Existing native Swift/SwiftUI/SwiftData/XCTest, iOS 26 deployment floor.

## 1. Verified baseline and authority

All code facts below were inspected with `git show` / `git grep` at
`cdcae1424fafba7ffbe82ccdb6c339a6d695f599`. Its tree is
`eb7b4a7b6e55c8fb4f9a4e9e14f5c18e318634f7`, identical to accepted PR1 head
`bccc30656855e831b72a1d54efb57ebdf71b8402`.

The primary checkout is dirty local `main` at `5b6d2b0`; local `origin/main` is
also older (`207ca09`). The vault's `head_commit: cdcae14` is absent from their
ancestry. **The normal working-checkout freshness gate fails:** do not implement
from this checkout or treat its product files as the merged baseline. This
design uses the available exact merged Git object, not a guessed reconciliation.
No branch was moved and no remote/live status was queried. Before implementation,
select an owner-approved suitable checkout at the merged baseline and rerun the
freshness gate; preserve all inherited dirty work and protected PR1 worktrees.

Canonical intake verified project identity and read the relevant Current Status,
Next Actions, Architecture, Product & IA, UI Design System and D-012/D-015–D-020.
The architecture note's historical 13-record count is stale: the actual merged
factory has **18** types. Its one-container/model-separation rule remains valid.
The owner's new instruction supersedes earlier PR2 deferral and operational
follow-up wording; it does not reopen auth, sign-up or infrastructure acceptance.

Paths in this table are relative to `ios-native/Kitchen Manager/`, at the exact
baseline above. They are source evidence, not fresh test results.

| Evidence | Current behavior / implication |
| --- | --- |
| `KitchenManager/PreparedComponent.swift:81–121` | UUID, name, integer 1–50 count, prepped/cooked, refrigerated/frozen, dates; no mass or source identity. Synthesized Codable bypasses initializer clamping. |
| `KitchenManager/KitchenStore.swift:3266–3354` | Explicit Result, stale edit checks, one UUID decrement, zero deletes; replacement persists before one publish. |
| `KitchenManager/Persistence/PreparedComponentPersistence.swift:23–79` | One context/save for whole Prepared replacement; rollback on failure. Duplicate incoming IDs currently coalesce. |
| `KitchenManager/Persistence/PreparedComponentRecord.swift:8–51` | Flat scalar row; all fields explicitly mapped in init/read/update. |
| `KitchenManager/Persistence/KitchenPersistenceFactory.swift:34–77` | Same 18-type production/test factory; no VersionedSchema/SchemaMigrationPlan wiring. |
| `KitchenManager/KitchenBackup.swift:39–99`; `KitchenStore.swift:3393–3447` | Validator requires explicit format and exactly v1. Missing historical Prepared key decodes as `[]`. Group-level semantic validation is new work. |
| `KitchenManager/MainFeatureViews.swift:2390–2451` | Preview decodes then re-encodes candidate before restore: unknown metadata would be lost without model support. |
| `KitchenManager/KitchenStore.swift:2640–2883`; `KitchenRecoverySnapshot.swift:44–124` | Seven-domain sequential restore, durable recovery copy, compensation and complete reread; not a cross-domain crash-atomic transaction. |
| `KitchenManager/KitchenStore.swift:1417–1489` | Clear is compensating, with weaker recovery reporting than restore. Do not claim atomic clear. |
| `KitchenManagerTests/PreparedComponentSchemaUpgradeTests.swift:30–154` | Tests adding the table using current record classes, not upgrading an old Prepared row layout. |
| `KitchenManagerTests/PreparedComponentReliabilityTests.swift:53–254` | Source-inspected save-failure/unreadable/stale/publish-order regressions to retain and extend. |

No accepted grouping or mass-allocation contract was found in the relevant
Decisions or merged feature contracts. The choices below are proposals.

## 2. Minimal representation and identity

Keep `PreparedComponent.id` as the **group UUID** addressed by every existing
usage entry point. Add optional business value `grouping: PreparedPortionGrouping?`.
Nil means an unchanged legacy count-only batch, not missing/corrupt new data.

| Proposed value | Fields / authority |
| --- | --- |
| `PreparedSourceSnapshot` | Immutable `id: UUID`, `name: String` (original name), `initialMassDecigrams: Int64`, `initialPortionCount: Int` |
| `PreparedPortionGrouping` | `version = 1` (metadata format), immutable `source: PreparedSourceSnapshot`, `massPerPortionDecigrams: Int64` |
| Existing `PreparedComponent` | Group UUID, live count, display name, state/storage/dates plus optional grouping |
| `PreparedSourceSummary` | Derived projection by source UUID: live groups, physical count and mass; never separately persisted |

A source snapshot is repeated identically in its groups, avoiding a parent row
that could be consumed before its children. It is grouping provenance, not a
full ingredient catalog or historical ledger. No Inventory UUID or placeholder
link is added. Physical portions have no individual UUID; separate one into a
one-portion group before it needs distinct attributes. Independently added
same-name sources never merge, and split siblings never auto-coalesce.

Example: source S (800g originally, four portions) → group A (UUID A,
`count=4`, `mass=200g`). Split one → A (`3 × 200g`) + B (`1 × 200g`), both S.
Consuming B removes B only; S is still represented by A. Consuming A's final
portion removes A and the last embedded source snapshot. No zero-count row or
empty parent persists. The source header distinguishes **originally recorded**
mass from **remaining** mass; it does not label the difference “consumed”.

### Quantity invariants and rounding

- New measured input is decimal grams, stored as integer **decigrams (0.1g)**.
  Parse decimal text exactly; no Double arithmetic, implicit input rounding,
  free-text unit conversion, ml/kg/count conversion or nutritional meaning.
- Original and current source counts are 1–50; each persisted group count is
  1–50. Input outside the range is rejected in new APIs, not silently clamped.
  Legacy initializer behavior stays intact. All masses are positive; arithmetic
  uses checked Int64 multiplication/addition and rejects overflow.
- For total Q decigrams and N portions, require Q ≥ N. Let q = Q / N and r =
  Q % N. Allocate r portions of q+1 and N−r of q, omitting empty groups. Thus
  there are at most two groups initially and no hidden remainder.
- 800.0g / 4 → `4 × 200g`. 100.0g / 3 → `1 × 33.4g + 2 × 33.3g`.
  0.2g / 3, 800.05g, zero, negative, fractional counts, nonnumbers and overflow
  are rejected. Preview shows actual sizes rather than a rounded average.
- Creation sums exactly to source mass/count. For any current source, identical
  source snapshots, distinct group UUIDs and positive allocations are mandatory;
  sums cannot exceed original mass/count. Splitting conserves both sums;
  consume/delete reduce them. No promise of consumed-vs-discarded accounting.
- Because PR2 never re-portions an existing package, each live group's mass
  must be q or q+1 from its source's original Q/N. The combined count for each
  size cannot exceed its original bucket (N−r or r). This rejects impossible
  imports such as an 800g/four-portion source claiming a 400g package even when
  its total remaining mass is below 800g. PR3 must explicitly evolve this rule
  if a future cooking transition changes mass; no yield assumption is added now.
- A partial-size physical package is representable as a smaller-size group
  (including rounding remainders). Fractional **use of an existing package**,
  arbitrary gram consumption, adding portions to a measured source, unequal
  manual allocation and cutting a package into smaller packages are deferred.
  PR2 split separates whole existing portions; it never re-portions mass.

IDs for a new source, its maximum two allocated groups, or a separated group are
created once with the draft and reused on save retry. If legacy conversion is
approved later, retain its existing row UUID for the first allocation; if r>0,
that is the q+1 group. The second allocation gets a new UUID. New sources use the same deterministic
allocation ordering. No names, array indices or floating values establish identity.
Prepared source sections follow first occurrence in the existing collection;
groups retain collection order. Insert a separated group immediately after its
remainder. Do not change Home/board sorting or recommendation ranking.

## 3. Operations and publication contract

| Operation | PR2 behavior | Rejection / deferred behavior |
| --- | --- | --- |
| Add | Optional total-mass input in current add form; empty means legacy. Mass+count previews and atomically adds the one/two linked groups with the same initial state/storage/dates. | Existing source UUID or group UUID collision fails; no implied Inventory deduction. |
| Convert legacy | Deferred beyond the recommended PR2 slice set; old rows remain unchanged. | If later approved, measure current remaining mass, preserve the existing UUID for the first allocation and require expected-row equality. No historical reconstruction. |
| Edit | Legacy editing unchanged. Measured group permits name/prepared-date/expiry corrections using expected row equality. Source original name stays provenance. | Measured count, source/mass fields and post-create state/storage are read-only in PR2, enforced in store as well as UI. Re-portion/mass corrections require a later decision. |
| Split k portions | Require linked group, n>1 and 1≤k<n. Preserve old UUID for n−k; create new UUID for k. Copy all other fields and source snapshot. One replacement. | Stale/missing row, reused UUID, 0/n/fractional k or legacy row without conversion fails. No transition or thaw semantics. |
| Consume | Existing `consumePreparedPortion(id:)` is the sole decrement. Return pre-mutation group only after save, including mass for truthful feedback. | Unknown UUID fails. No source-level consume, partial-gram API, Inventory write or undo. |
| Delete group | Existing UUID removal discards that group's remaining allocation; explicitly distinguish it from whole-source deletion. | Siblings retained. Do not loop mutations to imply atomic bulk deletion. |
| Delete source | No whole-source shortcut in recommended PR2. A source disappears when its last group is removed. | A future shortcut requires confirmation of exact affected groups/count/mass, expected sibling-set equality and one replacement; no loop masquerading as an atomic action. |

Reuse/generalize `commitPreparedComponents` for different Result payloads; keep
exactly one validate → replacement/save → publish boundary. Validate the proposed
whole collection, reject duplicate UUIDs before dictionary normalization, and
reject attempts to smuggle immutable grouped fields through generic add/update.
All specialized APIs build a value proposal first; no intermediate publication,
separate source save, per-child save loop or didSet write-through.

Save errors roll back the owned persistence context and preserve the draft,
published values and durable pre-attempt collection. Reload validates the entire
collection before publish. A malformed/unsupported grouping payload or
inconsistent siblings fences Prepared through the existing unavailable state;
export/restore/clear remain blocked until a validated reload. Do not fall back to
nil metadata, an empty collection or destructive repair.

### Recommendation identity — proposed D-019 refinement

Merged `QuickMealCandidate.pool` creates one candidate per row; Component Meal
excludes already-taken row sources, and Quick Meal exclusions/deduplication also
use them. Adding a second linked row can therefore make one multi-role food
appear to be two distinct components. Automatic rounding groups have the same
risk. Keeping these files untouched would change behavior accidentally.

Propose `QuickMealSelectionIdentity` and the existing neutral candidate's
`selectionIdentity`: inventory UUID, legacy Prepared UUID, or linked Prepared
**source** UUID (three distinct enum cases). Actual `QuickMealCandidateSource.preparedComponent(id)`
and `componentSources` stay group UUIDs for live usage/consumption. No source UUID
may be sent to the consume API.

Component Meal's taken/exclusion sets and Quick Meal's exclusions/deduplication
use selection identity; `QuickMealSuggestion.selectionIdentities` supplies the
deduplication key alongside its unchanged action `componentSources`. Candidates
remain per group so their expiry/profile can
still be evaluated; do not collapse them globally or make the two policies share
ranking. Their ranking, role inference, effort and template rules stay intact.
Splitting identical-attribute groups must not create a newly complete plate or
duplicate alternatives. Distinct same-name sources remain distinct, as today.
This extends D-019's identity boundary for the new grouping model and requires
an explicit owner decision. It does not redefine ingredients globally.

Prepared/usage labels must distinguish same-name sibling groups by visible group
ordinal within the source, portion mass and current state/storage; speak the
same information. The ordinal is display-only (derived from collection order),
never a persisted identity or mutation target.

PR3 owns storage/thaw/cook transitions, their date/expiry rules and any new enum
cases. Its future `3 frozen + 1 thawing` uses two same-source groups, changing
only the selected group through a separately approved contract. PR4 owns
raw-Inventory linkage, quantity conversion and deduction. Neither is prebuilt.

## 4. SwiftData, backup and rollback strategy

### Additive local schema proposal

Add only `portionGroupingData: Data? = nil` to `PreparedComponentRecord`; its
payload is versioned metadata above. Keep existing columns/types, unique row ID,
sort metadata, factory, container and model list. Add no relationships, table,
default mass, forced backfill or store reset. Codable business values remain
separate from records (D-012).

Update init/read/update mappings. The new record decode is throwing:
`decodePreparedComponent() throws -> PreparedComponent`, so a non-nil bad blob
cannot be silently dropped by today's nonthrowing `preparedComponent` property.
Nil/missing metadata alone is legacy. Validate all decoded siblings together.
Prepared replacement and applicable direct persistence writes must reject invalid
grouping, with no new unchecked save path. Existing clear/delete rollback limits
remain explicit; this is not a rewrite of global cleanup.

An optional column is a *candidate* for inferred lightweight migration, not a
proven migration. Before shipping, create a synthetic old store using the actual
merged PR1 field layout and 18-model configuration in a closed old process,
then open it through the new production factory. Use an old-build-generated
fixture with provenance or a demonstrably identical frozen schema/checksum;
merely reusing the newly compiled class with nil metadata is insufficient.
Verify every unrelated domain, all old Prepared fields/UUIDs/order, write/reopen,
and repeated open. If inferred migration fails or old-layout fidelity cannot be
proved, STOP: return for a versioned migration design. Never reset, reseed, bump
the store URL or add a broad VersionedSchema conversion without approval.

### Backup version boundary

- Default **new exports and new recovery copies to native backup v2**. Read v1
  and v2 explicitly; continue rejecting absent/invalid/future versions before
  mutation. V1 may omit Prepared entirely. V1 rows remain ungrouped; reject
  non-null new grouping under a v1 declaration. V2 grouping is optional per row
  to permit mixed old/new data. JSON missing/null grouping means legacy; a
  present invalid/unknown metadata version fails.
- V2 completeness is explicit: require the existing four mandatory arrays plus
  an array-valued `preparedComponents` key **in the original JSON before decode**.
  Missing/null/non-array Prepared fails before preview or writes; explicit `[]`
  intentionally means empty. Other optional domain rules remain unchanged.
  Apply this to v2 recovery copies too; preview re-encoding must not normalize
  an incomplete v2 into an apparently complete empty domain. Only v1 retains
  historical absent/null Prepared → empty compatibility.
- PR1's real validator accepts exactly v1, so it safely rejects v2. Do not emit
  a v1 compatibility export that strips source linkage. Reading older backups
  is supported; exporting to an older application is intentionally unsupported.
- Add grouping and collection validation before preview **and** before writes.
  Reject duplicate Prepared row IDs, conflicting source snapshots, invalid
  quantities/overflow and excessive source totals; allow depleted sources with
  fewer live rows/counts/mass. Do not normalize corrupt v2 input into validity.
- Preserve every field through decode → preview re-encode → restore, recovery
  copy readback, comparison and compensation. Prepared remains one of the
  existing seven restore domains. Keep its row-count summary as rows/groups;
  supplementary source/physical-portion totals must not relabel rows as sources
  or unknown legacy mass as zero.
- Continue reading outstanding **v1 recovery copies**. Never overwrite an
  unresolved copy. A recovery round-trip must preserve grouping equality as
  well as row fields, including failure after Prepared but before Special Plans.
- Import of a genuine old backup replaces the kitchen under the existing
  preview/confirmation contract. If Prepared was absent, it restores empty;
  do not merge current groups into it or fabricate linkage.

One Prepared save must reopen as the complete old or complete new collection
after interruption. A crash after save but before feedback can leave the new
state without success feedback; restart reads durable truth, not a replay queue.
Do not auto-replay consume or claim durable exactly-once user intent.

Whole-kitchen restore still commits domains sequentially; an interrupted restore
may leave mixed domains and its recovery copy. Clear is also compensating and
does not gain crash recovery here. Test grouped-field survival in both existing
paths, but do not promise cross-domain atomicity, new clear orchestration or
auth/account changes. Application downgrade on an already-upgraded store is
unsupported: an older binary can ignore or strip the new field on editing.
Retain original backups for recovery with a compatible build; a v2 version gate
protects backup import, not old-binary access to the same live store.

## 5. Acceptance matrix — required on the later implementation tree

These are planned checks, not results. Persistence/migration/backup are release
blockers under the acceptance matrix. Start focused; broaden to full native unit
suite for shared Codable/store/backup changes, not unrelated hosted/auth suites.

| ID | Cases and required evidence | Focused owner |
| --- | --- | --- |
| A1 | 800g/4 = 4×200g, fixed IDs, same-name sources independent; full original totals | New `PreparedPortionGroupingTests` |
| A2 | 100g/3 = 33.4+33.3+33.3; 1g/3; 0.2g/3 rejected; exact sum across repeated splits | New grouping tests |
| A3 | Integer-boundary count/mass/overflow rejection in allocation; decimal text excess precision, fractional count/use and nonnumbers rejected at later input/store boundaries with no clamping/write | Grouping tests (algebra), UI/parser + store tests (input) |
| A4 | Split 4→3+1 preserves old UUID/source/mass and copied dates; split 1/0/n rejected; stale snapshot/reused ID fails | New `PreparedPortionGroupingStoreTests` |
| A5 | Add, allowed edit, consume/final delete and group delete: live equality and disk reopen; direct generic edit cannot alter protected grouping; legacy rows stay unchanged | Grouping store tests + durable tests |
| A6 | Inject save failure for each multirow mutation: no event/success, same-context rollback and fresh reopen equal prior; retry once has no duplicate rows and one publish after save | Extend reliability/context-hygiene tests |
| A7 | Actual old-layout disk fixture → new production factory, all 18 model types and seeded unrelated records preserved; repeat open, add linked data, reopen; new/in-memory factory parity | New `PreparedPortionGroupingSchemaUpgradeTests` |
| A8 | V1 Prepared key absent/null, ungrouped old rows, mixed v2 legacy/grouped; UUIDs/dates/counts unchanged; v2 missing/null/non-array Prepared rejected, explicit [] accepted; never infer mass | Backup validation + new grouping backup tests |
| A9 | V2 field-complete export→preview re-encode→confirmed restore→restart; original v1 accepted; PR1 rejects v2; PR2 rejects v3 | `BackupValidationTests`, grouped backup tests, old-reader fixture |
| A10 | Malformed blob/version/source mismatch, duplicate UUID, impossible totals or original-size bucket: reject before all seven domain writes; unavailable load blocks mutation/export/restore/clear; valid reload recovers | Validation spies + reliability tests |
| A11 | Failure after Prepared restore: exact linked-field compensation; compensation/reread failure retains recovery copy and correct unsafe/fenced state | `RestoreOutcomeTests`, `RecoverySnapshotTests` |
| A12 | Clear success removes linked rows; induced later-domain failure restores metadata on same context and fresh reopen. Do not report stronger global-clear guarantees | `SwiftDataConsistencyTests`, context-hygiene tests |
| A13 | Controlled process interruption before save and after commit/before publish: reopen yields complete old/new Prepared collection, no orphan/partial groups, no automatic consume replay | Synthetic-store child-process/test-host harness |
| A14 | Interrupted whole restore retains readable recovery copy (including old v1); restoration is explicit. Distinguish mixed-domain recovery from single-Prepared-save atomicity | Restore/recovery harness |
| A15 | Consume by group UUID in all three surfaces; linked/same-name sources independent. Multi-role sweet potato + chicken before/after split or rounding does not fill two slots; Quick Meal has no split-created duplicates; other policies/Inventory unchanged | Candidate, QuickMeal/ComponentMeal policy + usage/integration suites |
| A16 | Grouped add/preview/split/edit/delete/cancel, real save failure→retry, unavailable vs empty; sibling labels distinguish equal-name/equal-count groups; Light/Dark and normal/AXXXL, 44pt, VoiceOver names and actual listening separate | New focused grouped UI tests + rendered/manual review |

For A13/A14, injected exceptions alone do not prove process interruption. Use
only synthetic local stores in an isolated test host, never a user's live store.
If controlled interruption is unavailable, record that acceptance HOLD instead
of treating save-failure tests as a substitute. Power-loss/fsync durability is
not established by a process-kill test.

Retain `PreparedComponentTests`, `PreparedComponentDurablePersistenceTests`,
`PreparedComponentReliabilityTests`, `PersistenceContextHygieneTests`,
`BackupValidationTests`, `RestoreOutcomeTests`, `RecoverySnapshotTests`,
`SwiftDataConsistencyTests`, `QuickMealPreparedUsageTests`,
`QuickMealPreparedIntegrationTests`, `ComponentMealUsageTests`,
`MealPrepBoardTests`, `PreparedComponentExpiryPolicyTests` and relevant candidate,
Home and safe-restore UI regressions. Existing schema-addition tests remain
useful but do not satisfy A7. Demonstrate targeted negative proof: disabling
metadata persistence, atomic replacement, stale checks or validation must make
the corresponding new regression fail.

Use `km-ios-validation` at implementation time. Xcode is authoritative. Any CLI
simulator test must run its entire foreground flow through
`~/.local/bin/dev-sim-slot run codex -- xcodebuild ...`, target
`platform=iOS Simulator,id=18FAEFC5-3087-48A4-8131-5B97F48D62C6`, and set
`-parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1
-maximum-parallel-testing-workers 1`. Acquire whole-flow occupancy for MCP UI
work and report post-test `dev-sim-slot status`. Reuse the existing suitable
cache; do not create another simulator or touch its data. No suite ran here.

## 6. Exact implementation slices and files

All paths below are under `ios-native/Kitchen Manager/`. No test/source/schema
file listed here has been edited by this design task. These are proposed tasks,
not execution instructions until the owner authorizes a slice.

### Slice 1 — smallest safe first change: pure allocation contract

- [ ] Add only `KitchenManager/PreparedPortionGrouping.swift` and
  `KitchenManagerTests/PreparedPortionGroupingTests.swift` for immutable source,
  allocation/grouping values, checked arithmetic and A1/A2 plus the integer
  boundary part of A3. Text parsing/interaction acceptance remains in Slice 4.
  No property on the
  active Prepared model, persistence/schema/backup change or UI wiring yet.
- [ ] Define `PreparedPortionAllocator.allocate(source: PreparedSourceSnapshot,
  groupIDs: [UUID]) throws -> PreparedAllocationPlan`, where a plan contains the
  source plus one/two groups (`id`, `count`, `massPerPortionDecigrams`). Require
  exactly the IDs needed by the allocation; caller derives that count from Q/N
  and supplies stable draft IDs. Define `split(group: PreparedAllocatedGroup,
  taking: Int, newGroupID: UUID) throws -> (remaining: PreparedAllocatedGroup,
  separated: PreparedAllocatedGroup)`; it never changes per-portion mass.
- [ ] Write focused failing arithmetic/identity tests, implement the pure helper,
  run the focused XCTest and inspect the diff. Stop for review of this slice.

This slice validates the proposed units and grouping algebra while durable data
and current behavior remain unchanged. It does not claim to deliver the feature.

### Slice 2 — durable representation and proven compatibility

- [ ] Modify `KitchenManager/PreparedComponent.swift` (optional grouping/custom
  backward-compatible Codable), `Persistence/PreparedComponentRecord.swift`
  (optional blob/throwing read), and `Persistence/PreparedComponentPersistence.swift`
  (all mapping and collection validation). Keep factory's 18-type list unchanged.
- [ ] Extend the grouping helper with complete-collection validation and typed
  errors. Validate sibling source equality, IDs, positive count/mass, checked
  sums, original bounds and per-size bucket limits. Map failures to sanitized UI
  errors/unavailability.
- [ ] Add the A7 genuine old-layout fixture/test with documented provenance;
  extend durable and context-hygiene tests (A6/A10). No new feature UI yet.
  Stop on failed/unproved lightweight migration rather than inventing a reset.

### Slice 3 — store and backup integration as one protected data contract

- [ ] Modify `KitchenManager/KitchenStore.swift` Prepared section and backup
  payload/default version. Reuse its generic commit boundary; retain existing
  consume signature and implementation. Add `addPreparedSource(draft:)` and
  `splitPreparedComponent(id:taking:newGroupID:expected:)`. New source/split
  return `Result<[PreparedComponent], PreparedComponentMutationError>`; existing
  APIs keep their Result type. Split checks expected-row equality before save.
- [ ] `PreparedSourceDraft` owns immutable source/group draft IDs plus current
  name/mass/count/state/storage/dates; the pure allocator supplies allocation.
- [ ] Modify `QuickMealCandidate.swift`, `QuickMealAssembly.swift` and
  `ComponentMeal.swift` only for the approved selection identity fact and its
  exclusion/deduplication use. Keep action provenance as group UUIDs; add the
  A15 split/rounding multi-role and independent-same-name-source regressions to
  candidate, Quick Meal assembly/integration and Component Meal policy tests.
- [ ] Modify `KitchenManager/KitchenBackup.swift` to validate v1/v2 plus linked
  semantics; preserve `KitchenRestoreOutcome.swift` domain order/equality and
  `KitchenRecoverySnapshot.swift` file lifecycle. Change the latter two only if
  a concrete test shows value propagation/version handling requires it.
- [ ] Add `PreparedPortionGroupingStoreTests.swift` and
  `PreparedPortionGroupingBackupTests.swift`; extend the specific existing suites
  in A5–A15. Prove v1 recovery import, all-domain rejection-before-write and
  field-complete failed-restore/clear compensation. Do not widen account cleanup.

### Slice 4 — bounded native flow and final acceptance

- [ ] Modify `KitchenManager/PreparedComponentViews.swift` for optional mass and
  exact decimal input validation/preview, source sections, split, unambiguous
  sibling labels and read-only grouped quantities. Factor a small
  `PreparedPortionGroupingViews.swift` only for the new form/summary if needed;
  do not restructure unrelated screens.
- [ ] Modify `PreparedPortionUsage.swift` only for optional mass-aware feedback
  or labels; retain shared usage row and UUID resolver. `MainFeatureViews.swift`
  may receive a Prepared-only restore-preview supplement; its restore ownership
  and confirmation sequence stay unchanged. Home, expiry policy and Inventory
  stores require no policy change. No conversion or whole-source-delete flow.
- [ ] Add `KitchenManagerUITests/PreparedPortionGroupingUITests.swift`, using
  keepAlways screenshots for A16; extend safe-restore UI assertions if needed.
  Do not edit the inherited dirty `ScreenshotTourUITests.swift` as a shortcut.
- [ ] Complete A1–A16 and applicable full native unit suite; record actual
  Xcode evidence, diagnostics, tests, rendered evidence and unverified limits.
  Use `km-delivery`; no commit/push/PR, binary release or hosted action is implied.

After approval, generate only the bounded Spec Kit execution tasks needed for
the approved slices, then run consistency analysis before implementation. These
two feature artifacts are the design/plan stage; no `.specify` pointer, hooks,
branch or unrelated feature artifacts were changed. No dependencies, signing,
build settings, migrations, backup data or product source are changed now.

## 7. Decision review and approval gate

| Alternative | Benefit | Cost / disposition |
| --- | --- | --- |
| No change / names in notes | No compatibility risk | Cannot preserve structured origin/mass; fails the requested workflow |
| Only add a shared source UUID | Smallest linkage-only change | Cannot express or conserve 800g/200g; insufficient for this goal |
| Existing homogeneous groups + optional source/mass | Reuses UUID consumers and one atomic domain; supports later subgroup transitions | Needs explicit quantity/edit rules and additive-schema/v2-backup acceptance; recommended for owner consideration |
| Source/group/individual-portion SwiftData tables | Per-package identity immediately | New relationship/deletion/migration machinery without a present per-package requirement; defer |

Top failure modes: (1) inferred mass or permissive edit mints/losses quantity →
exact integer allocation and immutable grouped quantity contract; (2) a split
partially persists or stale editor resurrects portions → one replacement and
expected snapshots, or duplicates meal eligibility → approved selection identity;
(3) migration/old readers/incomplete backups lose grouping → genuine old-store
test, strict v2 completeness and explicit unsupported live-store downgrade.

**Decision Review: OWNER DECISION REQUIRED.** A separate read-only reviewer
identified recommendation identity, v2 completeness and unreachable allocation
risks. This revision addresses them through a proposed D-019 refinement, explicit
required-v2 keys and original-size bucket validation. The reviewer also confirmed
Slice 1 is disconnected from runtime/storage; its input-parsing claim was narrowed.
Legacy conversion and whole-source deletion are deferred to minimize scope.
The separate reviewer's bounded follow-up confirmed those findings were
addressed and found no remaining material contradiction for owner review.
This is design review, not runtime verification or product authorization.

Approve the four choices listed in [spec.md](spec.md), with any amendments, and
explicitly select Slice 1 or a larger implementation scope. Until then stop at
the saved design. If an Active Decision conflict, migration mismatch, requirement
for a new state/Inventory action, hosted/config/credential operation or repeated
same-root-cause failure appears later, stop and return its exact evidence and
smallest proposed resolution. PR3/PR4 work remains separately authorized.

## 8. Design-session validation and output lifecycle

Current evidence is Git-object inspection and a separate read-only backup/schema
audit; no application build, XCTest/XCUITest, Preview, simulator, phone, network,
auth or hosted operation ran. Planned behavior and migration remain unverified.
Relative document links, new-file whitespace checks and repository
`git diff --check` passed. Final status shows only these two task-created feature
documents in addition to the inherited dirty entries. These checks and the
review outcome do not establish runtime acceptance.

Task owner: Codex / Kitchen Manager PR2 design. Task-created paths are this
`spec.md` and `plan.md`, retained as requested review deliverables, not disposable
scratch. No task-created temporary build, cache or probe path exists. Existing
dirty files, worktrees, caches, evidence and device data are preserved. No
canonical Decision or vault anchor is advanced for this unapproved proposal.

# Kitchen Manager PR3 Prepared Group Lifecycle Implementation Plan

> **For future agentic workers:** Read the approved specification and this plan together. After explicit owner authorization of a slice, use the project implementation/acceptance workflow and `superpowers:executing-plans`, or an explicitly selected subagent workflow. Unchecked items below are future work, not permission to execute. Do not commit between steps without separate owner authorization.

**Date:** 2026-10-29

**Status:** Review-ready implementation plan — independent plan review GO, both P2 findings resolved/rechecked; awaiting owner authorization of Slice 1. Implementation is not authorized.

**Branch:** No branch created. Primary checkout remains `main` at `5b6d2b09a4cabd0573135740291972ec996d6744` with all pre-existing dirty/untracked paths preserved.

**Baseline:** Merged PR2 `ef23d688c8e72107b60acff0c2e7755289994bd0`; fresh remote main and canonical vault anchor match. Owning implementation was read from a separate read-only archive of this commit. Do not implement against the older primary source or modify the preserved PR2 worktrees.

**Spec:** [spec.md](spec.md), owner-approved for this planning task. [Specification design review](review.md) and [quality checklist](checklists/requirements.md) remain unchanged. The specification's historical “planning not authorized” exit statement is superseded only by the owner's current plan-only instruction.

**Independent plan review:** [plan-review.md](plan-review.md).

**Goal:** Enable independent thaw/cook transitions for Prepared groups while preserving legacy editing, original allocations, durable publication and lossless Backup v3/recovery.

**Architecture:** Keep prepped/cooked and refrigerated/frozen as independent existing facts; attach optional strictly validated lifecycle metadata to each existing Prepared row. Use a pure proposal engine, then the existing one-save Prepared boundary. Integrate business Codable, store protections and Backup v3 together; apply immediate-meal availability per group and retain a single UUID decrement.

**Tech stack:** Existing Swift/SwiftUI, Foundation Codable, SwiftData, XCTest/XCUITest and the synthetic Python process runner. No new dependency, platform floor or framework.

## 1. Summary and Technical Context

| Context | Verified baseline / planned boundary |
| --- | --- |
| Language / platform | Existing project uses Swift language mode `5.0`, iOS deployment target `26.0`; preserve both. Xcode is authoritative for later builds/tests. |
| Target / discovery | `ios-native/Kitchen Manager/Kitchen Manager.xcodeproj`, shared `KitchenManager` scheme; app/tests use filesystem-synchronized groups. No project-file, signing, capability or entitlement edit is expected for new Swift files. |
| Persistence | Shared production/in-memory 18-model factory; existing Prepared scalar columns plus grouping blob; add only nullable `lifecycleData`. No relationship/entity/store URL change. |
| Existing mutation boundary | Main-actor KitchenStore proposes a complete collection, validates, saves through `PreparedComponentPersistenceProtocol`, then publishes. Persistence uses a fresh context, whole-snapshot stale check, one save and rollback. |
| Existing backup | Root versions 1/2; v2 requires original Prepared array. Preview re-encodes decoded payload. Recovery is seven sequential commits with compensation/readback, not global atomic restore. |
| Existing meal path | Storage-insensitive shared candidate pool; separate Quick/Component policies; source-selection identity and live group UUID actions. UI callbacks currently carry UUID only. |
| Scope / scale | Local Prepared feature, its existing backup/meal/UI consumers and focused tests; original 1–50 portions and checked Int64 decigram allocations. No new performance/timing promise. |
| Research boundary | Accepted architecture is settled. No technology comparison or external research is needed; actual owning code resolves interface placement. Migration/runtime compatibility remains an execution gate, not a researched PASS. |

This plan follows the local Spec Kit template's summary/context/constitution/structure sections and PR2's numbered slice/acceptance convention. Owner scope is **plan plus independent review only**: do not run `setup-plan.sh`, overwrite active-feature metadata, generate extra research/data-model/contracts/quickstart/tasks artifacts, or modify the approved spec/checklist/review. No extension configuration/hooks existed at intake; recheck before final delivery without executing any newly appearing write hook outside owner scope.

## 2. Global Constraints and Constitution Check

- Preserve every approved FR-01–FR-14 contract. Lifecycle payload version stays `1`, grouping payload version stays `1`, new backup root version becomes `3`; these are separate version domains.
- Legacy count-only **and lifecycle nil** retains ordinary name/count/state/storage/date editing. Only a successfully committed explicit lifecycle action opts it in. Every measured group remains state/storage protected even when lifecycle is nil.
- No inferred thaw/cooking history. No automatic completion, refreezing, reverse transition, lifecycle deletion escape, direct-from-frozen cooking, yield/reweighing, fractional use or Inventory deduction.
- Active-thaw measured splits copy exact lifecycle/expiry without resetting event times. State transitions preserve source/group UUIDs, count, source snapshot and decigram allocation.
- Require action-bound expiry review. Default never extends the stored date; completion has no new time allowance. Event time/calendar/review survive unchanged retry; stale recheck requires renewed confirmation.
- Raw original backup JSON is validated before tolerant decode/normalization. Every v3 row explicitly encodes lifecycle null/object; declared v1/v2 rows must lack the key, even null. A new export of an old recovery asset is a separate v3 document, never an overwrite of retained bytes.
- Immediate-meal filtering is Prepared-specific and per group. It does not delete/hide future-use records or change Inventory convenience-food behavior. Live expected-row/eligibility checking feeds the sole decrement inside one serialized mutation boundary.
- Preserve PR2 restore order, process-local outcome, pending-copy limits and unsupported live-store downgrade. No global restore fence/transaction, auth, sync, hosted, release or PR4 expansion.
- Targeted tests during development; **one full native unit-suite gate after shared source stabilizes**, not one per slice. Record actual tree/hash evidence; historical PR2 receipts never satisfy PR3 gates.
- Preserve primary dirty work, original PR2 worktrees, fixtures, evidence, caches and canonical records. No reset/clean/rebase, new branch/commit/PR, push/merge/deploy or native execution during this planning turn.

| Constitution principle | Planning disposition |
| --- | --- |
| Evidence before assumption | Approved documents plus exact merged owning code inspected; no runtime PASS inferred. |
| Bounded change | Five ordered slices below; no opportunistic refactor or unrelated suite/environment repair. |
| Canonical authority | D-012/D-015–D-022 and accepted PR2 refinement preserved; owner revisions govern legacy/v3 behavior. Canonical records/head anchor remain unchanged. |
| Trust / data safety | Two genuine old layouts, rejection-before-write, copy preservation, stale/rollback tests and unsupported downgrade are explicit. |
| Proportional validation | Focused RED→GREEN, boundary reviews, one stabilized full unit gate, affected UI/process evidence only. |
| Authorization | This document proposes work. Stop after the reviewed plan; owner must authorize Slice 1. Later slices also require explicit scope, never inferred automatic continuation. |
| Convergence | Final FR/gate mapping, source-bound receipts and independent final review required; incomplete evidence remains HOLD. |

No constitution exception is requested. The slice staging adjustment below prevents partial activation; it does not alter product behavior.

## 3. Project Structure and Exact Ownership Map

Path aliases below are **repository-relative exact prefixes**: `App = ios-native/Kitchen Manager/KitchenManager`, `Tests = ios-native/Kitchen Manager/KitchenManagerTests`, `UI = ios-native/Kitchen Manager/KitchenManagerUITests`. New paths are proposals, not files created in this planning phase.

| Owner path | Action / responsibility | Slice |
| --- | --- | --- |
| `App/PreparedLifecycle.swift` | New strict metadata value/Codable/phase/error and contextual validity; no active model property initially | 1 |
| `App/PreparedLifecycleTransition.swift` | New action, reviewed-expiry/intent/change values and pure proposal/default-expiry engine | 1 |
| `Tests/PreparedLifecycleTests.swift`, `Tests/PreparedLifecycleTransitionTests.swift` | New pure codec/matrix/time/review tests | 1 |
| `App/Persistence/PreparedComponentRecord.swift` | Nullable column and strict leaf decode first; complete init/read/update mapping when business attachment is activated | 2 → 3 |
| `Tests/PreparedLifecycleSchemaUpgradeTests.swift` | New two-origin upgrade/layout/all-18 preservation proof, then active mapped write/reopen coverage | 2 → 3 |
| `Tests/PreparedPortionGroupingSchemaUpgradeTests.swift` | Adapt the existing old-column comparator only for newly added lifecycle column; retain all 18-table/Prepared/UUID/order assertions and run in Slice 2 | 2 |
| `Tests/Fixtures/PreparedPR2/{README.md,provenance.json,fixture-writer.swift.txt,prepared-pr2.store}` | New **later-authorized** synthetic actual-PR2-layout fixture/provenance; no generation now | 2 |
| `Tests/Fixtures/PreparedPrePR2/{README.md,provenance.json,fixture-writer.swift.txt,prepared-pre-pr2.store}` | Read/reuse frozen original; no overwrite/regeneration | 2, 5 verification only |
| `App/Persistence/KitchenPersistenceFactory.swift` | Verify same 18-model production/in-memory factory; leave code unchanged unless a specific approved mapping issue requires a bounded correction | 2, 3 verification |
| `App/PreparedComponent.swift` | Optional lifecycle, initializer/custom Codable/equality participation; sanitized new mutation errors | 3 |
| `App/PreparedPortionGroupingMetadata.swift` | Extend complete collection validation with lifecycle contextual validity; no allocation/source-version change | 3 |
| `App/Persistence/PreparedComponentPersistence.swift` | Reuse decode, stale snapshot and save boundary; mapping propagation/tests, no new writer protocol | 3; DEBUG hooks verified in 5 |
| `App/KitchenStore.swift` | Dedicated transition API, protected edits, same decrement with contextual preconditions, root payload v3/default and export/restore encoding call sites | 3 |
| `App/KitchenBackup.swift` | Original-byte v1/v2/v3 gate, canonical validated candidate, centralized v3 encoding | 3 |
| `App/MainFeatureViews.swift` | Existing preview confirmation and recovery-export routes use validated canonical v3 bytes; later Prepared-only lifecycle preview detail | 3 → 4 |
| `App/KitchenRecoverySnapshot.swift`, `App/KitchenRestoreOutcome.swift` | Existing byte lifecycle/order/equality should already propagate value changes; verify, do not refactor. Change only for a demonstrated contract failure | 3 verification |
| `App/PreparedPortionGroupingPresentation.swift` | Existing correction draft must copy lifecycle and adopt protected live state correctly; no silent expiry rebase; later display wording | 3 → 4 |
| `Tests/PreparedLifecyclePersistenceTests.swift`, `Tests/PreparedLifecycleStoreTests.swift`, `Tests/PreparedLifecycleBackupTests.swift` | New active mapping/store/backup/failure regressions | 3 |
| `Tests/PreparedLifecycleBackupFixtures.swift`, `Tests/FrozenPR2BackupValidator.swift` | Raw historical shape helpers and frozen baseline v2 root-reader rejection; never production compatibility stripping | 3 |
| `App/SafeRestoreFixture.swift`, `Tests/SafeRestoreFixtureTests.swift` | Qualify actual DEBUG UI-fixture producer with literal historical v1/v2 and explicit v3/malformed shapes; new focused producer tests prevent fixture-induced false results | 3 → 4 |
| `Tests/{BackupValidationTests,PreparedPortionGroupingBackupTests,RecoverySnapshotTests,RestoreOutcomeTests,PreparedComponentReliabilityTests,PreparedPortionGroupingStoreTests,PreparedPortionGroupingPresentationTests}.swift` | Preserve existing coverage while updating owning version fixtures/assertions and adding lifecycle equality/legacy tests where appropriate | 3 |
| `App/PreparedMealAvailability.swift` | New small immediate-meal predicate shared by pool and store meal-use precondition; no global availability flag | 3 foundation → 4 pool |
| `App/QuickMealCandidate.swift` | Filter Prepared before adaptation/source selection; retain independent policy ranking and identity | 4 |
| `App/{PreparedPortionUsage,QuickMealHomeViews,HomeView,ComponentMealViews}.swift` | Carry displayed expected row through meal action callbacks; keep UUID/store decrement ownership | 4 |
| `App/{PreparedComponentViews,PreparedPortionGroupingViews}.swift` | Valid per-group actions, lifecycle status, legacy/protected editor controls, native review/failure flow | 4 |
| `App/PreparedLifecycleFormDraft.swift`, `App/PreparedLifecycleViews.swift` | New focused transition draft and native sheet; no unrelated view/file extraction | 4 |
| `Tests/PreparedLifecycleRecommendationTests.swift`, `Tests/PreparedLifecyclePresentationTests.swift` | New eligibility, captured action, retry/recheck and action-label/presentation regressions | 4 |
| `Tests/{QuickMealCandidateTests,PreparedPortionGroupingRecommendationTests,QuickMealPreparedUsageTests,PreparedPortionGroupingUsageTests,ComponentMealUsageTests,PreparedPortionGroupingPresentationTests}.swift` | Update owned call/fixture changes while preserving ranking, identity, quantity and legacy contracts | 4 |
| `UI/PreparedLifecycleUITests.swift`, `UI/SafeRestoreWorkflowUITests.swift` | New lifecycle journey/screenshots plus existing actual preview/recovery-export flow checks | 4 |
| `App/PreparedPortionGroupingUIFixture.swift`, `App/PreparedReliabilityFixture.swift`, `App/ContentView.swift` | Reuse existing isolated DEBUG fixture composition; add only necessary synthetic lifecycle seeds/faults, no production startup behavior | 4 → 5 |
| `App/PreparedProcessInterruptionFixture.swift`, `Tests/PreparedProcessCheckpointTests.swift`, `scripts/pr2-process-acceptance.py` | Extend existing qualified DEBUG cutpoints/host runner for a named PR3 mode; keep legacy default path and old evidence | 5 |
| `specs/007-prepared-group-lifecycle/acceptance.md` | Future source-bound A01–A14 receipt index/limitations; not created now | 5 |

`QuickMealAssembly.swift`, `ComponentMeal.swift`, `MealPrepBoard.swift` and `HomeDashboardSummary.swift` are **verification consumers**, not ranking/IA/urgency rewrite targets. Existing assembly/policy/home tests are selected when their shared inputs change. Do not edit the dirty `UI/ScreenshotTourUITests.swift`; keepAlways screenshots belong in the feature UI suite. Factory/project files, package locks, capabilities and unrelated data remain outside the write set.

## 4. Dependency Order and Stable Interface Contract

```text
Slice 1: pure value + transition/review algebra (no active attachment)
   ↓
Slice 2: passive nullable disk representation + genuine origins/proof
   ↓
Slice 3: atomic activation of business mapping + store guards + v3/recovery
   ↓
Slice 4: per-group meal wiring + native review UI/accessibility
   ↓
Slice 5: stabilized integration + controlled cuts + one full unit gate
```

**Justified boundary adjustment:** `PreparedComponent` currently has hand-written Codable, old backup versions remain active until Slice 3, and its generic editor reconstructs the row. Adding an active property/encoder in Slice 2 would permit a v2 file with new lifecycle keys or a lossy edit/backup. Therefore Slice 2 adds the nullable column and strict leaf decoder, but normal runtime writes remain nil and production row decoding refuses a non-null lifecycle column until Slice 3 attaches/maps it. Synthetic Slice 2 tests inspect that column through the strict leaf decoder. Slice 3 replaces the passive refusal with complete business mapping and changes all encoding/guard call sites together. No activation flag, extra schema or alternate persistence path is added. Slice 2 is representation evidence, **not** end-to-end lifecycle delivery; no intermediate build is eligible for user kitchens/release.

The immediate-meal predicate and consume precondition land in Slice 3 because the store needs one authoritative check; actual pool/UI availability wiring belongs to Slice 4. Minimal correction-draft metadata preservation also belongs to Slice 3 so an existing editor cannot drop the newly attached value. These are dependency-driven boundaries, not new features.

### 4.1 Slice 1 exported pure interfaces

Names/signatures are planning contracts; bodies are implementation work. All types remain Foundation-only and use the existing preparation/storage enums. Use the existing grouping types' explicit nonisolated pattern for metadata/intent/result values. Keep the transition namespace on the app target's existing MainActor isolation, matching the existing advisory suggestion helper, rather than changing `PreparedComponent.swift` or duplicating its day table in Slice 1. The targeted test classes run on MainActor as existing native model tests do. This isolation is a call-site constraint, not mutable actor state: the engine is deterministic, owns/references no KitchenStore/SwiftData/SwiftUI, and never calls `Date()`.

```swift
enum PreparedThawPhase: String, Codable { case inactive, thawing }
struct PreparedLifecycle: Hashable, Codable {
    static let currentVersion = 1
    let version: Int
    let thawPhase: PreparedThawPhase
    let thawStartedAt: Date?
    let thawCompletedAt: Date?
    let cookedAt: Date?
    func validate(state: PreparedComponentState, storage: PreparedStorage) throws
}
enum PreparedLifecycleAction { case beginThaw, completeThaw, markCooked }
struct PreparedExpiryReview: Equatable {
    let action: PreparedLifecycleAction
    let existingExpiryDate: Date
    let selectedExpiryDate: Date
    let explicitlyEdited: Bool
}
struct PreparedLifecycleIntent: Equatable {
    let action: PreparedLifecycleAction
    let eventAt: Date
    let calendar: Calendar
    let expiryReview: PreparedExpiryReview
}
struct PreparedLifecycleChange: Equatable {
    let state: PreparedComponentState
    let storage: PreparedStorage
    let lifecycle: PreparedLifecycle
    let expiryDate: Date
}
enum PreparedLifecycleTransition {
    static func defaultExpiryDate(action: PreparedLifecycleAction,
        state: PreparedComponentState, existingExpiryDate: Date,
        eventAt: Date, calendar: Calendar) throws -> Date
    static func propose(state: PreparedComponentState, storage: PreparedStorage,
        lifecycle: PreparedLifecycle?, expiryDate: Date,
        intent: PreparedLifecycleIntent) throws -> PreparedLifecycleChange
}
```

Conform action to Equatable for the review/intent values. `PreparedLifecycleError` in `PreparedLifecycle.swift` owns typed invalid-metadata/version/transition/time/review failures. Strict Codable must inspect exactly the five metadata keys and explicitly encode timestamp nulls; contextual validity uses `validate(state:storage:)`. The engine binds review.action/existingExpiryDate to current action/expiry, requires finite times, uses the reviewed selected date, and when `explicitlyEdited == false` requires that date to equal the computed default. Completion's default is exactly stored expiry with no new allowance; explicit date corrections remain deliberate reviewed edits under FR-06. No elapsed-duration or food-safety rule is introduced.

### 4.2 Slice 2/3 persistence and mutation interfaces

```swift
// Existing record, Slice 2 leaf used by Slice 3's complete mapper:
var lifecycleData: Data? = nil
func decodeLifecycle() throws -> PreparedLifecycle?

// Existing business value, attached only in Slice 3:
var lifecycle: PreparedLifecycle?  // initializer default nil

// Existing @MainActor KitchenStore, Slice 3:
func transitionPreparedComponent(id: UUID, expected: PreparedComponent,
    intent: PreparedLifecycleIntent)
    -> Result<PreparedComponent, PreparedComponentMutationError>
enum PreparedConsumptionContext { case manual, immediateMeal }
func consumePreparedPortion(id: UUID, expected: PreparedComponent? = nil,
    context: PreparedConsumptionContext = .manual)
    -> Result<PreparedComponent, PreparedComponentMutationError>

enum PreparedMealAvailability {
    static func isEligible(_ component: PreparedComponent) -> Bool
}
```

`decodeLifecycle()` checks raw enum strings before fallback when a blob exists. Slice 3 init/update must encode the value, decode must attach it, and complete collection validation includes contextual validity. Reuse the persistence protocol without adding a second writer. Preserve existing `consumePreparedPortion(id:)` callers as manual bookkeeping. For `.immediateMeal`, require non-nil expected, exact live equality and the predicate before the same decrement/proposal/save; no suspension. Missing expected/ineligible input fails, never falls back to manual. Generic add cannot inject lifecycle; only explicit transition or validated restore/persistence materialization introduces it. Generic edit may neither introduce nor strip metadata; protected state/storage editing remains forbidden, while opted-in count-only count corrections stay allowed.

Map pure transition/review errors to sanitized `PreparedComponentMutationError.invalidTransition` / `.expiryReviewRequired` added in Slice 3; retain missing/stale/unavailable/save errors. No decoder details or raw database error enters UI. Keep split signature/allocator unchanged; value-copy remainder/sibling inherits lifecycle/expiry automatically and is verified explicitly.

### 4.3 Slice 3 backup/preview interfaces

Keep `KitchenBackupValidator.validateCandidate(_:) throws -> Candidate` and `validate(_:) throws -> KitchenBackupPayload`. `Candidate.version` and `Candidate.exportedAt` retain **original-file provenance**, while `Candidate.payload` becomes canonical version 3 only after raw original validation, decoding and full validation succeed. Missing original export time remains unknown in provenance.

Add `KitchenBackupValidator.encodeV3(_ payload: KitchenBackupPayload) throws -> Data` in the existing file: copy/set root version 3, encode field-complete rows/nulls and validate the generated v3 bytes before returning. Use it in current export, new pre-restore recovery preparation, normal preview confirmation and separate recovery-document export. It is not an import-normalization bypass: original input must first pass `validateCandidate`.

`KitchenRecoverySnapshotStore.outstandingSnapshot()` continues returning original raw bytes and `prepare/resolve` semantics remain unchanged. `BackupRestoreView.exportRecoveryCopy()` in `MainFeatureViews.swift` obtains those bytes, validates the original, then encodes the canonical payload to a **new** document. It never calls prepare/resolve or writes back to the outstanding path. Preview shows recovery-content provenance; a representation-generation time must not masquerade as the old snapshot's original time. No new backup root provenance field is necessary.

### 4.4 Slice 4 UI/captured-consumption interfaces

`PreparedPortionUsage` gains non-optional `expected: PreparedComponent` populated by live UUID resolution. Change `PreparedPortionUsageRow.onUse`, `HomeQuickMealSection.onUsePreparedPortion`, `HomeView.usePreparedPortion` and `ComponentMealView.usePreparedPortion` from UUID-only callbacks to `(PreparedComponent) -> Void`. Each calls the existing decrement with `id: expected.id, expected: expected, context: .immediateMeal`. Do not look up a new expected snapshot at tap time and thereby accept a stale displayed action.

`PreparedLifecycleFormDraft` owns expected row/action, an optional confirmed `PreparedLifecycleIntent`, selected expiry and explicit-edit status. Its `makeReviewedIntent(at:calendar:) throws -> PreparedLifecycleIntent` captures time/calendar on first explicit confirmation and reuses them for an unchanged retry. `recheck(_ current: PreparedComponent)` adopts current protected facts and invalidates the previous confirmation; retained user text/date is not automatically approved for the new state. `PreparedLifecycleEditor` in `PreparedLifecycleViews.swift` submits the store API and dismisses only on success. The draft never writes metadata directly or silently creates history by opening.

## 5. Review Focus: Failure Modes to Pin

| Failure mode | Required pin / owner |
| --- | --- |
| A legacy editor opened before opt-in reconstructs nil metadata or old expiry | `PreparedLifecycleStoreTests.testPreOptInEditorCannotStripCommittedLifecycle`; presentation stale recheck test, Slice 3/4 |
| New encoder creates null keys under a declared old version, or preview repairs missing v3 keys | `PreparedLifecycleBackupTests.testOriginalVersionShapeCheckedBeforeCanonicalPreview`; raw matrix and zero-writer assertions, Slice 3 |
| Retry crosses midnight/DST/calendar change and moves event/expiry | `PreparedLifecycleTransitionTests.testFixedIntentSurvivesCalendarDayBoundary` plus draft retry, Slice 1/4 |
| Frozen/thawing sibling hides the source's usable sibling or stale meal callback adopts a newer row | `PreparedLifecycleRecommendationTests.testEligibleSiblingSurvivesPerGroupFilter` and captured-action equality failure, Slice 4 |
| Exporting old unresolved recovery contents rewrites the sole original or invents its timestamp | `PreparedLifecycleBackupTests.testOldRecoveryExportCreatesV3WithoutChangingOriginalBytes`; actual export UI and process recovery, Slice 3/4/5 |

## 6. Ordered Independently Reviewable Slices

Each slice follows RED → minimal implementation → GREEN on its **named targeted scope**, then diff/evidence review. RED must demonstrate the intended assertion fails on the preceding tree; missing-symbol failures can establish a new API's test scaffold but are not the sole negative proof for persistence/rejection/order gates. Add selective fault/mutation proof where specified. No full native suite per slice. A slice completion grants no next-slice or delivery authorization.

### Slice 1 — Pure lifecycle model, matrix, expiry intent and validation

**Depends on:** Approved spec and this reviewed plan; explicit owner authorization of Slice 1. Select an isolated implementation checkout of the exact approved baseline, preserve primary/PR2 checkouts, and bring the approved documents without using stale primary product source. No branch/worktree is created by this planning turn.

**Owns:** The two new pure app files and two new unit files in §3. Existing enums and `PreparedComponentExpirySuggestion` are inputs, not rewrite targets. Do **not** add a property to active PreparedComponent, a SwiftData column, a backup key, a store API or UI in this slice.

**Test cases / RED→GREEN assertions:**

- `PreparedLifecycleTests.testExactFiveKeyCodecAndExplicitUnknownDates`: raw valid objects round-trip; null timestamps stay explicit; unknown/missing keys, phase/version, wrong type and nonfinite date fail; nil is not replaced by an empty lifecycle object.
- `testContextualValidityAndCookedBeforeThaw`: reject frozen active/history, missing start, completion before start, inactive uncompleted start, cookedAt on prepped and empty inactive marker. Completion exactly equal to start succeeds; completion before start rejects. Mark-cooked exactly equal to recorded completion succeeds; before completion rejects. Accept cooking recorded before a later thaw and cooked state with unknown cookedAt.
- `PreparedLifecycleTransitionTests.testEveryStateStoragePhaseActionCell`: all FR-04 cells, including lifecycle nil versus valid inactive, already-cooked thaw preserving state, no refreeze/reverse/direct-frozen path and no input mutation.
- `testFirstActionRecordsOnlyItsEvent`: begin-thaw from nil records start only; mark-cooked from nil records cook only; complete-thaw from nil rejects.
- `testExpiryDefaultsAndReviewedExtensions`: begin/cook default earlier of stored date and existing 2/3-day refrigerated seed; completion default unchanged; overdue remains overdue; mismatched action/existing date or unedited nondefault date rejects; deliberate edit is distinguished from default.
- `testFixedIntentSurvivesCalendarDayBoundary`: inject event/calendar and rerun the same intent after an external test clock crosses midnight/DST; engine output/event/expiry identical because there is no internal clock read. Also assert independent fixed expected dates, not repeated equality alone: Toronto Gregorian calendar, event 2026-10-31 12:00 EDT (`2026-10-31T16:00:00Z`), later stored expiry → prepped seed `2026-11-02T17:00:00Z`, cooked seed `2026-11-03T17:00:00Z`; the UTC-calendar two-day seed is `2026-11-02T16:00:00Z`. A retained Toronto intent keeps its result even if a later supplied/current calendar would be UTC. Chronology violations fail without clamping.

- [ ] Add fixed-input tests and capture focused RED, including wrong-matrix/default behavior rather than a decorative round trip alone.
- [ ] Implement only §4.1's pure contracts using the existing advisory suggestion helper; run both new test classes to GREEN and inspect diagnostics/diff.
- [ ] Record focused scope and independent focused source review of matrix/expiry/metadata validity. Stop for Slice 1 owner review; active app behavior remains unchanged.

**Acceptance:** A01 pure portion, FR-02/FR-04/FR-06, foundation for A05; A14 evidence discipline. **HOLD:** any new product case/date rule/history inference, dependency on persistence/UI/global time, scope outside four files, unexplained failure, or request to activate the model. No migration/backup/runtime-feature acceptance is claimed.

### Slice 2 — Passive additive SwiftData representation and two genuine old layouts

**Depends on:** Slice 1 focused review accepted and explicit Slice 2 scope. Before modifying the current record layout, qualify the genuine PR2 producer from exact baseline sources in a separate owned synthetic context; no edit to preserved PR2 worktrees/caches/fixtures.

**Owns:** Record column/`decodeLifecycle`, new upgrade suite, existing `PreparedPortionGroupingSchemaUpgradeTests.swift` comparator and new `Fixtures/PreparedPR2` files; preserved pre-PR2 fixture is read-only. Factory/project model list/configuration stay unchanged. Active domain property/serialization stay in Slice 3 under the passive refusal in §4.

**Fixture production contract (later work only):** Use exact baseline owning model/factory sources and a recorded producer process/build; seed all 18 model types, same-name count-only rows, measured chicken siblings and rounded allocation groups. Freeze producer source/checksums/entity-version hashes, old columns (grouping present, lifecycle absent), row counts and expected complete user values. Close the producer before consolidating/copying the synthetic SQLite file. Record original WAL/SHM provenance; never let PR3 classes generate an allegedly old schema. The new writer resource is inert `.swift.txt`, not a production startup/test hook. If a suitable exact old producer cannot be constructed without unapproved configuration/resource changes, HOLD.

**RED→GREEN tests in `PreparedLifecycleSchemaUpgradeTests`:**

- `testPrePR2OriginHasNeitherGroupingNorLifecycleColumn` and `testPR2OriginHasGroupingButNoLifecycleColumn`: prove original layout, source/provenance hashes and 18 populated entity tables before any current-factory open. Copy both originals for migration; immutable originals retain hashes.
- `testBothOriginsUpgradePreservingAll18UserTables`: RED when additive column missing; GREEN current production factory opens same copied file with exactly 18 entities, retains old values/UUIDs/order/grouping, adds nullable lifecycle and leaves every old lifecycle nil. Exclude only newly added columns from old user-column comparison; never filter out the entire Prepared table or existing grouping blobs.
- `testPassiveLifecycleColumnStrictLeafRoundTripAndRepeatOpen`: write controlled valid metadata through a test-only context on the copy, close/reopen and compare exact decoded leaf fields plus all unaffected data. Unknown lifecycle/raw enum combinations fail leaf decode; ordinary production decode refuses a non-null staged column until Slice 3, never silently discards it.
- `testFreshMemoryAndDiskFactoryParity`: separate fresh-store check verifies same 18 entities; cannot replace old-layout upgrade evidence.
- Existing `PreparedPortionGroupingSchemaUpgradeTests.snapshot` currently omits the new PR2 grouping column but would compare an added lifecycle column against an original without it. Demonstrate that comparator mismatch, then exclude only the newly added `ZLIFECYCLEDATA` alongside its existing grouping exclusion. Retain all original 18-table/Prepared-row/UUID/order assertions. The **new PR2-origin comparator must still compare its pre-existing grouping blobs**; it excludes lifecycle only, not grouping. Explicit new-column/null/layout assertions stay in the new suite.

- [ ] Qualify/freeze both origins and capture an honest missing-column RED; preserve original fixtures and source/layout receipts.
- [ ] Add the nullable column/strict leaf decoder and passive fail-closed read; run both `PreparedLifecycleSchemaUpgradeTests` and existing `PreparedPortionGroupingSchemaUpgradeTests` with initial/repeated opens and raw-column write/reopen to GREEN.
- [ ] Independent persistence/schema review checks both producer origins, all-18 comparisons and staging limits. Retain evidence; stop for owner review before active mapping.

**Acceptance:** A06 representation/old-layout portion and A01 disk raw-enum edge; FR-08. A06's **full active business/store lifecycle write/restart remains HOLD until Slice 3**, then is rerun on the final mapping. **HOLD:** missing/uncertain provenance, migration/open/data comparison failure, clearing/moving store, new schema strategy/model count, destructive fallback, non-null column ignored by a runtime read, or attempts to activate v3/store/UI prematurely. No migration fixture is generated now.

### Slice 3 — Coherent business/store activation, Backup v3, preview/recovery and rollback

**Depends on:** Accepted Slice 2 schema proof and explicit Slice 3 scope. This slice is one reviewed data-contract change; do not stop at an interim encoder/version/guard combination and call it accepted.

**Owns:** §3's Slice 3 paths and §4.2/4.3 interfaces, including minimal correction-draft preservation and immediate-meal precondition foundation. Keep persistence protocol, allocation algorithms and seven-domain ordering intact. UI entry/action controls remain Slice 4.

**Dependency order within the slice:** Attach lifecycle to business value/custom Codable/equality → complete record init/read/update mapping and validator → generic edit/add/transition/consume guards → all v3 validator/encoder/export/preview/recovery call sites → field-complete compensation checks. Tests can drive these incrementally, but they are accepted together. New creation still has lifecycle nil.

**RED→GREEN suite and failure pins:**

| Owning test file / proposed test | Assertions that must distinguish RED from GREEN |
| --- | --- |
| `PreparedLifecyclePersistenceTests.testEveryWriterAndReopenKeepsLifecycle` | Active init/read/update, replace/upsert/delete and new context reopen retain exact lifecycle; same-source lifecycle differences valid; no reset of immutable source allocation. |
| `testCorruptMetadataFencesLoadMutationAndExport` | Present malformed/version/raw-enum errors preserve rows, mark unavailable and refuse writes/export placeholder; nil metadata retains prior fallback behavior. |
| `PreparedLifecycleSchemaUpgradeTests.testActiveMappedWriteAfterEachGenuineUpgrade` | On copies of both qualified originals, actual store transition plus fresh-process reopen preserves all 18 original record types and new facts. This completes A06 beyond passive proof. |
| `PreparedLifecycleStoreTests.testLegacyAndMeasuredProtectionMatrix` | Untracked count-only ordinary edits keep nil; failed first action does not opt in; committed first action does. Opted-in count correction remains; state/storage/metadata changes reject; measured nil lifecycle never bypasses protection. |
| `testPreOptInEditorCannotStripCommittedLifecycle` | Exact stale row/reconstructed nil payload cannot remove newer metadata or reapply stale expiry; generic add/edit cannot mint metadata. |
| `testTransitionSavesBeforeSinglePublicationAndRetryKeepsIntent` | Fault-injected save preserves old disk/publication, one subsequent successful write/publication uses same event/calendar/review. Observe publication at durable boundary; no source-wide mutation. |
| `testStaleInMemoryAndDurableWriterNeverCommitProposal` | Same-store mismatch zero persistence calls; separate stale persistence snapshot cannot commit/publish; reload/review required, not row merge. |
| `testActiveThawSplitAndConsumptionKeepExactMetadata` | Count/mass/UUID invariants including rounded buckets; stable split ID retry; copied lifecycle/expiry and independent later action; partial/final consumption, sibling/final-source behavior; Inventory/plans/receipts unchanged. |
| `testImmediateMealRequiresExpectedEligibleLiveRow` | Missing expected or changed/frozen/thawing row rejects inside sole decrement; manual valid-state bookkeeping retains old semantics. Predicate has no suspension/global filter. |
| `PreparedLifecycleBackupTests.testOriginalVersionShapeCheckedBeforeCanonicalPreview` | Complete original-byte v1/v2/v3 matrix, including present-null key in old file and missing key in one v3 row. No successful candidate, recovery preparation or any domain writer on invalid input. |
| `testExplicitNullExportAndMixedLifecycleRoundTrip` | Actual export/new recovery root3; each row lifecycle key present, non-null five keys incl null dates; raw field completeness, UUIDs and all seven domains survive preview→encode→restore→restart. |
| `testHistoricalCandidatesNormalizeOnlyAfterValidation` | Genuine old-shaped v1/v2 accepted with original version/unknown-date provenance; canonical payload/confirmation root3/null keys. Missing v3 row field cannot be repaired. Direct import and actual preview effects match. |
| `testOldRecoveryExportCreatesV3WithoutChangingOriginalBytes` | Retained v1/v2/v3 copies validate first; separate v3 output full facts/nulls; SHA of original unchanged; no prepare/resolve/writeback; failed export leaves asset untouched. |
| `testFrozenPR2ReaderRejectsV3BeforePayloadDecode` | Baseline-frozen v1/v2 root gate refuses3 before row decode/writers. State that this proves root rejection, not historical row-decoder fidelity. |
| `RestoreOutcomeTests` / `RecoverySnapshotTests` lifecycle cases | Failure after Prepared/before special plans, full seven-domain compensation/reread, compensation/reread failure/unavailable protection, unresolved old copies and truthful outcomes. Lifecycle participates in equality, not just counts. |
| `PreparedComponentReliabilityTests` lifecycle clear case | Existing clear failure/compensation restores metadata; no new clear orchestration/crash guarantee. |

**Historical fixture repair is test setup, not version relabeling:** Existing tests and `PreparedProcessInterruptionFixture.seed-v1` currently change `.version` on a newly encoded payload; that produces forbidden lifecycle null keys after the encoder changes. `PreparedLifecycleBackupFixtures.swift` must construct/freeze valid **raw old shapes** (v1 removes grouping as required and both old versions lack lifecycle). Keep positive v1/v2 tests and separately assert the newly malformed relabeling rejects. Update expected default export to3 and future rejection to4; do not merely delete the formerly-future3 assertion or weaken completeness/allocation tests. No production encoder emits old-version files or strips metadata.

Qualify the actual UI producer too: `SafeRestoreFixture.swift`'s current `legacy` case omits Prepared but declares the moving `supportedVersion` (already invalid as v2); its `dated` case follows the current encoder. Preserve existing launch labels while pinning `legacy`/historical `dated` to literal original v1 bytes, add a literal-v2 case with required Prepared array/no lifecycle keys, a mixed-lifecycle current-v3 case and an intentionally missing-lifecycle v3 case. Expose deterministic state selection to `SafeRestoreFixtureTests` (for example `candidateData(state:)` with the existing no-argument call retained through a default). Unit-qualify each producer's original bytes/version/Prepared presence/expected validation result before any UI suite uses it. Historical DEBUG inputs are not production old-version exports. Never pass an intentionally malformed fixture to `recoverySnapshot.prepare()` as a supposedly readable positive copy.

- [ ] Add targeted REDs for attached-field loss, guard bypass, raw-v3 completeness/order, original-copy mutation and after-Prepared compensation. Use independent negative/fault assertions, not current encoder-generated “old” files alone.
- [ ] Implement the coherent activation and run new store/persistence/backup and `SafeRestoreFixtureTests` suites plus affected legacy/version/recovery/draft tests to GREEN; rerun active two-origin upgrade/write coverage now mappings changed. No full suite yet.
- [ ] Obtain an independent data-contract review of original-byte ordering, every encoding call site, current/outstanding recovery separation, strict mapped validity, identity/stale/publication and test evidence. Material findings block Slice 4; stop for owner review.

**Acceptance:** A01–A09 active data portions, A12 store precondition foundation; FR-02–FR-12 as applicable. **HOLD:** any lifecycle loss, encoder old-version mismatch, malformed candidate reaching preview/writer/copy preparation, changed outstanding bytes, stale/failed proposal published, schema drift or proposed global restore fence/order change. UI/pool/captured callbacks remain incomplete until Slice 4; no feature-complete claim at Slice 3.

### Slice 4 — Per-group recommendations, native UI and accessibility

**Depends on:** Accepted Slice 3 data-contract review and explicit Slice 4 scope. Store and wire boundaries must already be safe before a UI can create lifecycle facts.

**Owns:** §3's Slice 4 paths and §4.4 captured-row/draft interfaces. Keep existing navigation, Component Meal entry, ranking/effort/slot rules, source-selection namespaces and UI tokens. Reuse the isolated DEBUG grouping fixture for synthetic data/faults; no real-data or startup behavior change.

**RED→GREEN tests and actual rendering:**

- `PreparedLifecycleRecommendationTests.testEligibilityMatrixAndExistingPolicies`: both policies exclude frozen/active thaw and retain refrigerated nil/inactive prepped/cooked under existing role rules; Inventory frozen-convenience behavior unchanged. Update old frozen **identity/ranking fixture inputs** to eligible refrigerated where that is the test's intent, retaining their original assertions; add explicit frozen-exclusion tests, not empty-result assertions that make identity tests decorative.
- `testEligibleSiblingSurvivesPerGroupFilter`: one source's frozen/thawing siblings cannot shadow a usable sibling; rounding/sweet-potato/corn source cannot occupy two slots or create duplicate Quick alternatives; independent same-name sources stay independent. Keep all groups in Prepared/source totals/board/backup/expiry attention; no global future-planning filter.
- `testDisplayedExpectedRowIsNotReplacedAtTapTime`: construct usage, change selected lifecycle/date/count or ordinary legacy storage before dispatch; callback carries captured row and store rejects. Missing/depleted UUID produces no second action; a newly chosen eligible group remains usable by its own UUID.
- `PreparedLifecyclePresentationTests.testDraftConfirmationRetryAndStaleRecheck`: opening/cancel creates no event; first explicit review captures event/calendar, unchanged retry preserves both; changed live row invalidates confirmation and requires review. Post-opt-in count-only controls and measured nil metadata stay protected; unknown history never displays completion/countdown.
- `testAdvisoryExpiryAndScopedActionCopy`: exact group/count/recorded mass and before/after state shown; expiry default/review rules, accessible group identity and success only after save; no safe/guaranteed/yield claim.
- `UI/PreparedLifecycleUITests`: complete chicken journey/restart; active-thaw split and independent completion; untracked legacy edit→cancel/fail/retry→committed opt-in→protection; stale editor/date review; missing/unavailable/error/retry; Quick and Component live-group use.
- `UI/SafeRestoreWorkflowUITests` owns automated **outstanding-copy recovery** preview/confirmation, original provenance/lifecycle detail and separate v3 export. Its current `openPreview` taps `backup.recovery.restore`; it does not exercise normal file import, and recovery confirmation rereads original copy bytes rather than re-encoding the candidate.
- **Normal file-import evidence is a separate required receipt/HOLD:** after producer qualification, provide known-hash literal v1/v2 and current/malformed v3 synthetic files in a supported isolated document-picker location; use the actual `BackupRestoreView` import button/system `.fileImporter` selection → `handlePickedFile` → normal preview → destructive confirmation → new-process reread. Use a later supported manual/GUI flow if XCUITest cannot drive that picker, as the baseline fixture explicitly documents. Record input original version/hash, canonical v3 confirmation bytes/complete values, original timestamp provenance, relevant screenshots and rejection-before-preview for malformed v3. No private-document browsing, entitlement/security-setting change or alternative production import path is allowed to obtain it. If valid file delivery/selection cannot be demonstrated, A08 normal-route evidence remains HOLD; recovery-preview PNGs or unit re-encoding cannot clear it. The unit candidate/encoder tests still establish their narrower data contract.

- [ ] Add owning unit/UI REDs and implement pool predicate, callback chain, metadata-preserving editor/control changes and focused native sheet/draft. Shared usage remains the one row; manual management consumption keeps its policy.
- [ ] Run named targeted classes and selected affected existing Quick/Component/grouping suites; obtain/inspect keepAlways screenshots: Light/Dark normal and Accessibility XXXL, long/same-name groups, failed/stale/review states. Small-phone Light uses supported rendering on the fixed owner device/configuration; never create a second simulator merely for a screenshot.
- [ ] Obtain independent review of source **and actual rendered PNGs**. Perform actual VoiceOver listening/focus traversal for new controls if supported/owner-scoped; otherwise record HOLD explicitly. Preserve baseline frame warning status and stop speculative unrelated repairs. Stop for owner review.

**Acceptance:** A02/A03/A04/A05 UI portions, A08 actual preview/export, A12/A13; FR-03/FR-05/FR-06/FR-12/FR-13. **HOLD:** captured-row loss/UUID-only bypass, generic protected controls write attempts, hidden future-use data, incorrect group/expiry feedback, visual regression, missing actual renders, or unavailable genuine VoiceOver evidence for an unrestricted acceptance claim. Screenshots/AX queries alone cannot clear spoken/focus HOLD.

### Slice 5 — Final bounded integration and process-interruption acceptance

**Depends on:** Accepted source/data/UI boundary reviews and explicit final-acceptance scope. Stabilize all production and DEBUG acceptance-source changes before reserving the one full native unit gate.

**Owns:** Existing DEBUG process fixture/checkpoint suite/host runner, minimal isolated seed composition and future feature acceptance index. Add a `--suite pr3` runner mode retaining its existing default PR2 path/`--restore-only` behavior. New modes are explicitly named receipts, never rewrites of historical PR2 A13/A14 output. Fix legacy synthetic v1/v2 seed shapes under Slice 3's raw-byte rules before using them; do not weaken the production validator for fixtures.

Retaining the runner's CLI/default operation path does not retain stale file-version assertions: its current new-copy check at baseline `scripts/pr2-process-acceptance.py:150` expects2. New copies made by the PR3 app must assert literal3; qualified outstanding historical inputs retain their explicit1/2 expectations. Fresh case labels/receipts identify actual file versions instead of calling a new v3 import “restore-v2”. Original retained PR2 receipts stay unchanged.

**Interface / expected cut matrix:** `python3 scripts/pr2-process-acceptance.py --suite pr3 --app <exact-current-Debug-app> --evidence <owned-PR3-evidence>` must run its entire foreground flow within the Codex simulator lease. Reuse existing before-save and after-save/before-store-publication callbacks. Seed fixed synthetic rows/event times/reviewed dates through current store APIs; seed genuine old backup shapes as original bytes. No real store, external account or data deletion.

| Acceptance operation | Controlled cuts / expected probes |
| --- | --- |
| Begin thaw; complete thaw; mark cooked; active-thaw split; consume final selected portion | Each before-save and after-commit/before-publication: 10 cases, each with two distinct fresh-process probes; old/new full collections and exact unaffected siblings. Partial consume remains covered by focused store tests. |
| V3 import; explicit v3 recovery; outstanding v1 recovery; outstanding v2 recovery | Each after Prepared commit/before special plans: four cases, each with two fresh-process probes of mixed state, original copy bytes, new-import refusal, then explicit full recovery and two later probes. |

The first set gives 20 restart probes; the second adds mixed-state and recovered-state probes. Compare complete validated backup business scope (seven domains and every lifecycle field), enforce duplicate-ID/key completeness checks and do not normalize missing v3 lifecycle into nil in the host. Raw historical absence may become nil only after its original version/shape is qualified. Keep the runner's PID/session/executable/stopped-state verification and SIGSTOP→SIGKILL handshake; a resumed fixture must exit instead of continuing. No guessed/stale PID, arbitrary process kill, sleep-as-proof or auto-replay. A real kill is required; throwing an error does not satisfy A10/A11.

**RED→GREEN and integration sequence:**

- [ ] Extend `PreparedProcessCheckpointTests` with transition/split/consume checkpoints proving old publication on both sides of save and committed disk after save. Demonstrate a misplaced hook/early publication fails before accepting the harness; keep DEBUG-only hooks/fixture commands out of Release.
- [ ] Finish scoped process cases and targeted source/harness fixes; retain every original failed receipt. Establish actual old/new/mixed states independently of app-generated “PASS” strings. Failure keeps the specific gate HOLD; use bounded retry rules, not broader repeated suites.
- [ ] Inspect final diff and all changed source/configuration, freeze source/fixture/runner hashes, then run **one** `KitchenManagerTests` full unit gate on the stabilized tree. Complete missing/stale affected UI/process and unsigned Release DEBUG-exclusion evidence, not full UI or distribution; retain already accepted receipts whose relevant inputs still match instead of repeating unchanged cases just because the full unit gate finished. A later native Swift/build-input change invalidates that source binding: report why renewed owner-scoped full validation is necessary instead of silently repeating it or claiming the old pass. A host-runner comparator/report-only correction leaves unchanged native-suite evidence valid; rerun only the affected process cases and bind both receipts to their actual producer hashes.
- [ ] Independent final review reconciles FR-01–FR-14 and A01–A14 against exact-source receipts, screenshots, migration producers, interruption copies, Release exclusions and known gaps. Write the future acceptance index with PASS/FAIL/HOLD per gate and preserved limitations; stop for owner decision, with no integration/publish action.

**Acceptance:** A10/A11/A14 plus all earlier gates on the final source. **HOLD:** unverified process identity/boundary, partial Prepared transaction after restart, lost/changed recovery bytes, manufactured historical fixture, replay, unknown source-to-result binding, stale suite receipt, missing actual accessibility or a new regression. Full native pass does not clear VoiceOver, power-loss, old-binary downgrade, real-user restore or global atomicity limitations.

## 7. Complete Requirement → Acceptance → Slice Trace

| Requirement | Owning gates | Implementation/review boundary |
| --- | --- | --- |
| FR-01 scope / authority | A14 and every slice preflight | All; final independent scope audit |
| FR-02 exact value / validity | A01, A05, A06, A07 | 1 pure; 2 raw disk; 3 contextual mapped validation |
| FR-03 legacy/protected editing | A02, A05, A13 | 3 store/draft; 4 actual controls; 5 final evidence |
| FR-04 action matrix | A01, A03, A05, A10 | 1 engine; 3 store; 4 UI; 5 cuts |
| FR-05 UUID/mass/split/consume | A03, A04, A05, A10, A12 | 3 data/sole decrement; 4 actual use; 5 cuts |
| FR-06 expiry review | A01, A03, A05, A13 | 1 intent; 3 API binding; 4 review/retry/stale interaction |
| FR-07 durable publication/stale/retry | A05, A09, A10 | 3 boundary; 4 draft; 5 process proof |
| FR-08 SwiftData/old layouts | A01, A06, A09 | 2 genuine schema; 3 full active mapping; 5 source-bound final audit |
| FR-09 backup versions/completeness | A07, A08 | 3 raw validation/explicit encoding; 4 actual file UI |
| FR-10 preview/old reader/recovery losslessness | A07, A08, A09, A11 | 3 data routes; 4 actual export/preview; 5 old-copy cuts |
| FR-11 rollback limits | A05, A09, A10, A11 | 3 fault-injected compensation; 5 controlled crash proof |
| FR-12 immediate meals/future use | A03, A05, A12, A13 | 3 precondition; 4 per-group filtering and captured UI callback |
| FR-13 native/accessibility | A02, A08, A12, A13 | 4 source/render/listening; 5 final limits retained |
| FR-14 acceptance/evidence integrity | A01–A14 | Targeted gates per slice; 5 single stabilized full unit gate/final audit |

Every A01–A14 gate has an owner in §6. A06 is intentionally staged representation proof then active write/restart; A08 includes **actual** preview/export, not just re-encoding a test object; A10/A11 are real process evidence, not reused PR2 history. No new acceptance-number scheme replaces the specification.

## 8. Later Validation Commands, Review Cadence and HOLD Policy

These are **future commands**, not executed during planning. Read the actual chosen checkout's instructions and verify its baseline first. Record/reuse an appropriate existing Codex/Kitchen Manager DerivedData/package cache; do not create a duplicate per slice or alter lockfiles/signing. Use a unique retained result path per actual RED/GREEN/gate, never overwrite prior evidence. Supply exported `KM_PR3_CHECKOUT`, `KM_PR3_DERIVED_DATA` and `KM_PR3_RESULT` paths from that preflight.

Example Slice 1 focused invocation (all children remain inside the cooperating lease):

```bash
~/.local/bin/dev-sim-slot run codex -- /bin/zsh -c '
  exec xcodebuild \
    -project "$KM_PR3_CHECKOUT/ios-native/Kitchen Manager/Kitchen Manager.xcodeproj" \
    -scheme KitchenManager -configuration Debug \
    -derivedDataPath "$KM_PR3_DERIVED_DATA" \
    -destination "platform=iOS Simulator,id=$DEV_SIM_SLOT_UDID" \
    -parallel-testing-enabled NO \
    -maximum-concurrent-test-simulator-destinations 1 \
    -maximum-parallel-testing-workers 1 \
    -resultBundlePath "$KM_PR3_RESULT" \
    -only-testing:KitchenManagerTests/PreparedLifecycleTests \
    -only-testing:KitchenManagerTests/PreparedLifecycleTransitionTests test
'
```

Replace only the named test filters/result destination for later focused classes. The final full unit invocation uses one `-only-testing:KitchenManagerTests` filter, not the full UI target. Report Xcode MCP versus documented xcodebuild fallback honestly; MCP/UI flows also require whole-flow same-owner occupancy, not a `prepare` claim. The sole simulator is Codex `18FAEFC5-3087-48A4-8131-5B97F48D62C6`; finish actual runs with `dev-sim-slot status`. No additional device/runtime, reset/shutdown, fixed-slot borrowing, clean-as-repair or package/signing change is implied.

Process command uses the same full-flow wrapper and explicit assigned UDID checked by the runner. Small-phone rendering must use supported viewport/render configuration without an extra device; inability to obtain requested evidence remains a named HOLD. Actual VoiceOver may require a separately coordinated supported device/listening pass; labels/screenshots cannot replace it. Relevant existing source guards are run only if the eventual diff affects the source they parse (for example `test/ios-native-kitchen-store-composition.test.mjs` if composition changes); no broad unrelated Node/server/hosted suite is requested.

Independent reviews occur after Slice 1's pure contract, Slice 2's genuine migration evidence, Slice 3's data contract, Slice 4's source+renders, and final source/evidence stabilization. Reviewers receive neutral scope/owning files/spec and actual receipts; do not present a proposing agent's view as independently verified. Each material finding is resolved/rechecked before its dependent slice; a capability gap is reported as HOLD, not hidden by a green suite.

Follow `WORKFLOW.md` retry limits: at most one automatic code fix/rerun for the same failing scope/root cause; environment issues get at most two bounded retries without business changes. Stop with original evidence, attempted fix, excluded hypotheses and smallest missing fact. Never relax a guard, assert, fixture fidelity, scope or test destination to manufacture a pass.

## 9. Recommended First Slice and Current Exit Boundary

**Recommend authorizing Slice 1 only:** two pure Foundation files plus their two focused unit-test files, with no active Prepared property, schema/fixture generation, store, backup, UI, flags or production effects. Its output is a reviewed matrix/metadata/expiry-intent contract and focused RED→GREEN evidence. Resolve the correct isolated baseline checkout and reusable cache at that implementation preflight; preserve all original worktrees. Stop again after this bounded slice unless the owner explicitly expands authorization.

This planning turn creates only `plan.md` and `plan-review.md`. No implementation, tests, schema, fixture, branch, commit, PR, push, merge, deployment or canonical status rewrite is authorized or performed. No runtime gate is marked PASS here. The approved spec/checklist/design review remain byte-for-byte unchanged. Await owner authorization before implementing Slice 1.

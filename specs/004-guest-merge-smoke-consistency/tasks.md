---
description: "Task list for feature 004 — GuestMergeSmoke direct-call consistency window"
---

# Tasks: GuestMergeSmoke direct-call consistency window

**Input**: Design documents from `/specs/004-guest-merge-smoke-consistency/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [quickstart.md](./quickstart.md)

**Tests**: Included. Deterministic regression coverage is an explicit requirement of this feature.

**Organization**: Phases follow the implementation sequence frozen at spec review —
Slice 0 → Slice A → Slice B → Slice C → Slice D. Story labels map tasks back to the user stories
in [spec.md](./spec.md).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel — different files, no dependency on incomplete tasks
- **[Story]**: US1, US2, US3

Most implementation tasks touch the single file `GuestMergeSmoke.swift`, so they are deliberately
**not** marked `[P]`.

## Implementation Sequence Freeze

| Slice | Phase | Content | Separate commit |
|---|---|---|---|
| **0a** | Phase 2 | prerequisite harness-integrity repair: the three baseline fingerprint call sites only, proven by a deterministic test, **no window wiring** | yes — its own first code commit |
| **0b** | Phase 2b | prerequisite harness-integrity repair discovered while implementing 0a: zero rollback window on the three seeding-only baseline controllers | yes — its own commit, after 0a and before Slice A |
| **A** | Phase 3 | boundary plumbing so the windows are expressible | yes |
| **B** | Phase 4 | W1–W4 wiring | yes |
| **C** | Phase 5 | deterministic correctness evidence | yes |
| **D** | Phase 6 | hosted development acceptance and final seal | yes |

**Slices 0a and 0b MUST NOT be collapsed into Slice B.** They repair pre-existing harness defects
and are not part of the consistency-window mechanism. Task IDs are never renumbered: Slice 0b was
discovered after T001–T035 were written, so it carries new IDs T036–T038 even though it executes
between Phase 2 and Phase 3.

---

## Phase 1: Setup

- [ ] T001 Confirm the branch is `codex/004-guest-merge-smoke-consistency` at base `2f436899e8c10cbf1fbb78b98270f5eabb9f2434`, the tree is clean, and `.specify/feature.json` resolves to `specs/004-guest-merge-smoke-consistency`
- [ ] T002 Re-read D-028 and D-029 in the canonical vault `Decisions.md` and confirm this feature modifies neither, recording the confirmation in [research.md](./research.md) if anything has changed since `2f43689`

**Checkpoint**: baseline and governing contract confirmed.

---

## Phase 2: Slice 0a - Prerequisite harness-integrity repair (Priority: P1, blocking) 🎯

**Goal**: the three runners whose baseline seeding currently aborts can reach their intended
checkpoints again. **No consistency-window wiring happens in this slice.**

**Classification**: pre-existing DEBUG-only harness defect. Not a new D-028 semantic, not part of
the window mechanism, not production behavior, not sync enablement.

**Independent Test**: drive the affected runners with a fake transport and observe baseline
seeding reach `.completed` instead of throwing `validationFailed`.

- [x] T003 [US1] Create `ios-native/Kitchen Manager/KitchenManagerTests/GuestMergeSmokeConsistencyTests.swift` with a fake `SyncTransport` and a signed-in `AuthStore` built from a fake auth service, modeled on `SyncSmokeTests.swift` and the `signedInAuthStore(userID:)` helper in `GuestMergeTests.swift`
- [x] T004 [US1] Add a failing test in `ios-native/Kitchen Manager/KitchenManagerTests/GuestMergeSmokeConsistencyTests.swift` asserting baseline seeding reaches `.completed` rather than throwing `validationFailed`, for all three affected runners (FR-011)
- [x] T005 [US1] Repair the three baseline preview call sites in `ios-native/Kitchen Manager/KitchenManager/Synchronization/GuestMergeSmoke.swift` — in `runRemainingPhases`, `runIdentityForkMinimalSmoke` and `runProductionRemotePreviewMinimalSmoke` — so the baseline preview carries the real remote fingerprint that production confirmation semantics require, keeping the change inside the DEBUG smoke file and leaving production merge behavior untouched (FR-011)

**Checkpoint**: previously unreachable baselines now confirm. Commit this slice on its own before any window wiring.

---

## Phase 2b: Slice 0b - Baseline session lifecycle repair (Priority: P1, blocking) 🎯

**Goal**: a seeding-only baseline no longer stays the active rollback-capable session, so the next
preview in the same runner is the fresh scenario preview the smoke needs.

**Classification**: prerequisite harness-integrity repair, discovered while implementing Slice 0a.
Not a D-028 or D-029 behavior change, not production Guest merge behavior, not W1–W4.

**Execution order**: MUST run after Slice 0a (Phase 2) and before Slice A (Phase 3). Task IDs
continue from T035 rather than being renumbered into position.

**Independent Test**: drive each affected runner with a fake transport and observe the preview
after baseline seeding produce a fresh scenario preview instead of resuming the completed baseline
session, with a default-window control proving ordinary rollback availability is unchanged.

- [x] T036 [US1] Construct the three seeding-only baseline controllers in `ios-native/Kitchen Manager/KitchenManager/Synchronization/GuestMergeSmoke.swift` — in `runRemainingPhases`, `runIdentityForkMinimalSmoke` and `runProductionRemotePreviewMinimalSmoke` — with the existing `rollbackWindow` initializer parameter set to zero, leaving its default value, `performConfirmMerge`, `activeGuestMergeSession` and every production caller untouched (FR-014)
- [x] T037 [US1] Replace the temporary Slice 0a expectations in `ios-native/Kitchen Manager/KitchenManagerTests/GuestMergeSmokeConsistencyTests.swift` that assert each runner now fails one checkpoint later, proving positive progress instead: baseline confirms, the completed baseline is not retained as the active session, and the next preview is a fresh scenario preview; document the single-identity simulator boundary for the full Phase 2B-2 runner rather than faking multi-identity support (FR-014, SC-010)
- [x] T038 [US1] Add a default-window control test in `ios-native/Kitchen Manager/KitchenManagerTests/GuestMergeSmokeConsistencyTests.swift` proving an ordinary completed merge is still returned as the active rollback-capable session, so the harness repair cannot hide a production rollback regression (FR-014, SC-010)

**Checkpoint**: every affected runner advances past the baseline session blocker, and production rollback availability is proven unchanged. Commit this slice on its own before any window wiring.

---

## Phase 3: Slice A - Boundary plumbing (Blocking Prerequisites)

**Purpose**: make the existing D-028 window expressible from the runner, including cleanup.

**CRITICAL**: no window wiring begins until this phase is complete.

- [ ] T006 Add a throwing consistency-window helper to `ios-native/Kitchen Manager/KitchenManager/Synchronization/GuestMergeSmoke.swift` that opens the window via `KitchenStore.beginInventorySyncConsistencyWindow()`, closes it on success, error and early return via `endInventorySyncConsistencyWindow()`, and converts a failed reconciliation into `GuestMergeSmokeError.validationFailed` while preserving any original thrown error
- [ ] T007 Change the static `bestEffortCleanup` in `ios-native/Kitchen Manager/KitchenManager/Synchronization/GuestMergeSmoke.swift` to take the run's `KitchenStore` and return whether reconciliation succeeded, keeping its non-throwing contract
- [ ] T008 Hoist `let kitchenStore` above the `do` block in `runIdentityForkMinimalSmoke`, `runInventoryCrudSyncMinimalSmoke`, `runInventoryDogfoodMinimalSmoke` and `runProductionRemotePreviewMinimalSmoke` in `ios-native/Kitchen Manager/KitchenManager/Synchronization/GuestMergeSmoke.swift`, mirroring the existing `persistence` hoist, so each `catch` can reach it
- [ ] T009 Update every `bestEffortCleanup` call site in `ios-native/Kitchen Manager/KitchenManager/Synchronization/GuestMergeSmoke.swift` — success and `catch` paths in all five runners — to pass `kitchenStore`

**Checkpoint**: the window primitive is reachable from every direct path, including cleanup. No runner behavior changed yet.

---

## Phase 4: Slice B - User Story 1: the harness protects its own direct persistence writes (Priority: P1)

**Goal**: every direct persistence-affecting call runs inside a consistency window.

**Independent Test**: drive `GuestMergeSmokeRunner` with an in-memory container and a fake
transport; a conflicting local edit during a protected block is refused, and after the block the
in-memory array equals durable storage.

### Tests for User Story 1

> Write these first and confirm they fail before implementing T012–T016.

- [ ] T010 [US1] Add a failing test in `ios-native/Kitchen Manager/KitchenManagerTests/GuestMergeSmokeConsistencyTests.swift` asserting that a conflicting local inventory edit attempted during the duplicate-retry block is refused, leaving no durable row change and no staged outbound mutation (FR-001, FR-002, SC-003)
- [ ] T011 [US1] Add a failing test in `ios-native/Kitchen Manager/KitchenManagerTests/GuestMergeSmokeConsistencyTests.swift` asserting that after each protected block `KitchenStore.inventory` equals the durable inventory (FR-003, SC-002)

### Implementation for User Story 1

- [ ] T012 [US1] Wrap window W1 in `ios-native/Kitchen Manager/KitchenManager/Synchronization/GuestMergeSmoke.swift`: the duplicate-retry block in `runRemainingPhases`, opening before `duplicateAdapter.stageUpsert` and closing after the marker-cleanup coordinator run, covering the requeued `savePending` and both resends, with no scenario-construction local edit inside the span (FR-001, FR-002, FR-007)
- [ ] T013 [US1] Wrap window W2 in `ios-native/Kitchen Manager/KitchenManager/Synchronization/GuestMergeSmoke.swift`: the final pull `finalCoordinator.runOnce` in `runRemainingPhases`
- [ ] T014 [US1] Wrap window W3 in `ios-native/Kitchen Manager/KitchenManager/Synchronization/GuestMergeSmoke.swift`: the simulated second-device `stageUpsert` plus `updateCoordinator.runOnce` in `runProductionRemotePreviewMinimalSmoke`, closing before the stale-confirm assertions so the stale `remoteSnapshotHash` condition, the rejection, the zero staged mutations and the still-ambiguous fresh preview all remain proven (FR-009)
- [ ] T015 [US1] Wrap window W4 in `ios-native/Kitchen Manager/KitchenManager/Synchronization/GuestMergeSmoke.swift`: the staged soft-delete loop and coordinator run inside `bestEffortCleanup`
- [ ] T016 [US1] Make a failed cleanup reconciliation fail the run on otherwise successful paths in `ios-native/Kitchen Manager/KitchenManager/Synchronization/GuestMergeSmoke.swift`, so a locked store is never reported as a clean cleanup (FR-004, FR-010)

**Checkpoint**: US1 is independently testable — the harness holds the production guarantee.

---

## Phase 5: Slice C - User Story 2: deterministic regression coverage (Priority: P2)

**Goal**: prove the guarantees on failure, overlap and echo paths without network or credentials.

**Independent Test**: run the iOS unit test target offline; these tests pass or fail on their own.

- [ ] T017 [US2] Test in `ios-native/Kitchen Manager/KitchenManagerTests/GuestMergeSmokeConsistencyTests.swift`: an injected staging failure still unwinds the window and reconciles (FR-003, SC-002)
- [ ] T018 [US2] Test in `ios-native/Kitchen Manager/KitchenManagerTests/GuestMergeSmokeConsistencyTests.swift`: an injected `runOnce` failure still unwinds the window and reconciles (FR-003, SC-002)
- [ ] T019 [US2] Test in `ios-native/Kitchen Manager/KitchenManagerTests/GuestMergeSmokeConsistencyTests.swift`: a cleanup failure does not allow the run to report a clean state (FR-010, SC-008)
- [ ] T020 [US2] Test in `ios-native/Kitchen Manager/KitchenManagerTests/GuestMergeSmokeConsistencyTests.swift`: an injected reconciliation failure leaves the store locked and surfaces a validation failure (FR-004, SC-005)
- [ ] T021 [US2] Test in `ios-native/Kitchen Manager/KitchenManagerTests/GuestMergeSmokeConsistencyTests.swift`: nested or overlapping protected operations do not unlock the window at the inner close (FR-006, SC-006)
- [ ] T022 [US2] Test in `ios-native/Kitchen Manager/KitchenManagerTests/GuestMergeSmokeConsistencyTests.swift`: reconciliation stages zero outbound mutations and writes nothing back to persistence (FR-005, SC-004)
- [ ] T023 [US2] Test in `ios-native/Kitchen Manager/KitchenManagerTests/GuestMergeSmokeConsistencyTests.swift`: the duplicate-retry contract is intact — the identical persisted mutation is resent and observed as a duplicate no-op with no remote version bump (FR-008)
- [ ] T024 [US2] Test in `ios-native/Kitchen Manager/KitchenManagerTests/GuestMergeSmokeConsistencyTests.swift`: the simulated second-device scenario still produces a stale-confirm rejection with zero mutations staged, and a fresh preview that still reports the ambiguous duplicate (FR-009)
- [ ] T025 [US2] Test in `ios-native/Kitchen Manager/KitchenManagerTests/GuestMergeSmokeConsistencyTests.swift`: D-029 rollback semantics are unaffected — no local durable inventory row is deleted by a rollback inside a protected block

**Checkpoint**: every protected block has success and failure coverage.

---

## Phase 6: Slice D - User Story 3: hosted acceptance and drift protection (Priority: P3)

**Goal**: confirm against development infrastructure and pin the call-site rule. Starts only after Slice C is green.

**Independent Test**: `npm test` fails when an unprotected call is reintroduced; hosted runners reach their checkpoints when credentials are present.

- [ ] T026 [P] [US3] Extend the guard in `test/ios-native-guest-merge-phase2b1.test.mjs` to fail when a direct persistence-affecting call appears in `GuestMergeSmoke.swift` outside a consistency window, joining the existing `stageDeleteRemovingLocalRecord` call-site rules, and to fail when a scenario-construction `kitchenStore.inventory` assignment appears inside a window (FR-001, FR-007, FR-013, SC-001)
- [ ] T027 [P] [US3] Run `npm test` and confirm the extended guard passes, then temporarily move one protected call outside its window to confirm the guard actually fails, and restore the file (FR-013, SC-001)
- [ ] T028 [US3] Verify every committed `.xcconfig` still defaults sync, merge, smoke, dogfood and diagnostics flags to `NO` (FR-012, SC-009)
- [ ] T029 [US3] Confirm development test-account credentials and gates for `ios-native/Kitchen Manager/KitchenManagerTests/HostedGuestMergeSmokeTests.swift` before any hosted run, enabling flags only in the ignored local configuration
- [ ] T030 [US3] Run the five hosted runners via `HostedGuestMergeSmokeTests` against development infrastructure and confirm each reaches its existing final checkpoint with unchanged checkpoint semantics (SC-007)
- [ ] T031 [US3] Restore every flag to `NO` or its original value, then verify zero marker residue or record the exact residual entity ids (FR-010, SC-008)

**Checkpoint**: hosted evidence collected and the rule is pinned against future drift.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [ ] T032 Run the full `KitchenManagerTests` and `KitchenManagerUITests` targets and classify any red against a clean baseline
- [ ] T033 Run the [quickstart.md](./quickstart.md) validation end to end
- [ ] T034 Produce the required final report per `AGENTS.md` §7, listing unrun tests and their exact next command
- [ ] T035 Reconcile canonical project memory under `AGENTS.md` §2.5, and record a new Decision only if an actual decision was made

---

## Dependencies & Execution Order

- **Phase 1 Setup**: no dependencies.
- **Phase 2 Slice 0a**: depends on Phase 1. Independent of all window work; ships as its own commit.
- **Phase 2b Slice 0b**: depends on Phase 2. Also independent of all window work; ships as its own commit. T036 → T037 → T038.
- **Phase 3 Slice A**: depends on Phase 2b. **Blocks W1–W4.** T006 → T007 → T008 → T009 are sequential, all in one file.
- **Phase 4 Slice B**: depends on Phase 3. Tests T010–T011 precede implementation T012–T016, which are sequential in `GuestMergeSmoke.swift`.
- **Phase 5 Slice C**: depends on Slice B existing; all tasks live in one test file and are sequential.
- **Phase 6 Slice D**: T026 and T027 depend only on Slice B and can run alongside Slice C. T029 → T030 → T031 are strictly ordered and start only after Slice C is green.
- **Phase 7 Polish**: depends on all desired slices.

### Parallel Opportunities

Genuinely parallel work is limited because the implementation is concentrated in one file. The
real opportunity is T026 and T027 in `test/ios-native-guest-merge-phase2b1.test.mjs`, which touch a different file and can proceed
alongside the Slice C tests.

---

## Implementation Strategy

### Order

Slice 0 first and on its own, because it repairs a pre-existing defect that currently prevents
three runners from reaching any checkpoint. Slice A then makes the window expressible, Slice B
wires W1–W4, Slice C proves them, and Slice D confirms the result against development
infrastructure.

### Incremental delivery

Slice 0 makes the harness runnable. Slice B makes it trustworthy. Slice C makes that trust
provable on every change. Slice D makes it durable and confirms it against development
infrastructure.

---

## Notes

- Hosted runs are an additional acceptance layer, never a substitute for the deterministic tests.
- No task in this list authorizes a commit, push, flag enablement, hosted-configuration change or
  production write. That authorization comes only from the user.
- Completion of every task means only that `GuestMergeSmoke` is trustworthy enough to participate
  in the pre-dogfood acceptance gate. It does not mean sync is enabled, Stage 1 or Stage 2 is
  started or approved, production is ready, or production Supabase is provisioned.


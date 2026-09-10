---
description: "Task list for Planner ordinary-meal CRUD — Slice 4: ordinary-meal delete + undo"
---

# Tasks: Planner ordinary-meal CRUD

**Input**: Design documents from `specs/001-planner-meal-crud/`

**Prerequisites**: plan.md (required), spec.md (required), research.md, data-model.md, quickstart.md

**Tests**: Requested by the spec's acceptance scenarios. Store-level delete/undo
tests already exist from Slice 1 in
`ios-native/Kitchen Manager/KitchenManagerTests/PlannerMealCRUDTests.swift` and
are regression-gated, not rewritten.

**Organization**: The only remaining user story is US4 (delete + undo). Slices
1–3 are implemented and reviewed; their tasks are intentionally not represented
here and must not be re-derived retroactively.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to
- Include exact file paths in descriptions

## Path Conventions

- Native iOS paths under `ios-native/Kitchen Manager/`

## Phase 1: Setup

**Purpose**: Confirm the reviewed baseline before any UI mutation.

- [x] T001 Confirm the working tree is clean on the feature branch and the
  existing store-level delete/undo contracts in
  `ios-native/Kitchen Manager/KitchenManagerTests/PlannerMealCRUDTests.swift`
  (remove/restore outcomes, persistence failures, index clamping,
  cooked/consumed linkage) are green as delivered, so US4 starts from the
  reviewed baseline (supports SC-001).

---

## Phase 2: Foundational (blocking prerequisite for US4)

**Purpose**: Shared feedback capability every US4 UI task depends on.

- [x] T002 [P] Extend `FeedbackToast` in
  `ios-native/Kitchen Manager/KitchenManager/AppFeedback.swift` with an
  optional trailing action (label + handler), preserving existing message/style
  rendering, dark high-contrast styling and VoiceOver announcement behavior
  (FR-009, FR-013).

**Checkpoint**: The toast can carry 撤销; US4 UI work may begin.

---

## Phase 3: User Story 4 — Delete an ordinary meal with undo (Priority: P1) 🎯 MVP

**Goal**: Ordinary Planner rows gain native delete (trailing swipe, context
menu, VoiceOver custom action) with immediate, honest, single-token undo.

**Independent Test**: Swipe a row → removal + toast; tap 撤销 → identical meal
at its original day and position; simulate persistence failure → honest error
with no false success.

### Implementation for User Story 4

- [x] T003 [US4] Add the trailing destructive swipe action 移出计划 to ordinary
  meal rows in `ios-native/Kitchen Manager/KitchenManager/PlannerView.swift`,
  keeping the existing leading edit swipe intact; enable full swipe only if
  reliable undo survives it (FR-006).
- [x] T004 [P] [US4] Add 移出计划 to the existing row context menu in
  `ios-native/Kitchen Manager/KitchenManager/PlannerView.swift` (FR-006).
- [x] T005 [US4] Add the VoiceOver accessibility custom action 移出计划 on
  ordinary meal rows in
  `ios-native/Kitchen Manager/KitchenManager/PlannerView.swift` (FR-006,
  FR-013).
- [x] T006 [US4] Route delete through `KitchenStore.removePlan(id:)` and handle
  `.saved` / `.notFound` / `.persistenceFailed` explicitly in
  `ios-native/Kitchen Manager/KitchenManager/PlannerView.swift`; never mutate
  `kitchenStore.plans` directly (FR-008).
- [x] T007 [US4] Hold the captured `PlanRemoval` in a single session-scoped
  undo token; a successful second delete replaces the token and toast in
  `ios-native/Kitchen Manager/KitchenManager/PlannerView.swift` (FR-015).
- [x] T008 [US4] Present the 已移出「<菜名>」 toast with the 撤销 action after a
  successful delete; 撤销 calls only
  `restorePlan(removal.item, at: removal.index)` in
  `ios-native/Kitchen Manager/KitchenManager/PlannerView.swift` (FR-009).
- [x] T009 [US4] Show honest failure states driven by `PlanMutationOutcome` in
  `ios-native/Kitchen Manager/KitchenManager/PlannerView.swift`: failed delete
  keeps the row and shows an error (no success toast, retryable); failed undo
  keeps the row absent and replaces the toast with an error (FR-010, FR-011).
- [x] T010 [P] [US4] Verify stale navigation to a deleted plan renders the
  existing 这一餐不存在 fallback in `plannedMealDestination` in
  `ios-native/Kitchen Manager/KitchenManager/PlannerView.swift`; change nothing
  if it is already safe (FR-014).
- [x] T011 [P] [US4] Add delete/undo coverage in a new
  `ios-native/Kitchen Manager/KitchenManagerUITests/PlannerMealDeleteUITests.swift`:
  swipe delete removes the correct row, success toast appears, undo restores
  identity/day/position/servings/cooked state, context-menu delete,
  single-token replacement on second delete, persistence-failure error path,
  and toast/action accessibility (FR-006–FR-015).
- [x] T012 [US4] Confirm the cooked/consumed delete→undo linkage coverage in
  `ios-native/Kitchen Manager/KitchenManagerTests/PlannerMealCRUDTests.swift`
  remains sufficient for the UI-facing rule; extend only if a gap is found
  (FR-012).

**Checkpoint**: US4 is independently functional: delete, undo, honest
failures, accessibility.

---

## Phase 4: Validation & Convergence

**Purpose**: Close the feature with the repository's own gates.

- [x] T013 Run the focused validation defined in quickstart.md:
  `PlannerMealCRUDTests`, `KitchenStoreTests`, `PlannerProjectionTests`,
  `TodayPlanPersistenceTests`, `PlannedServingsTests`,
  `RecipeCookingSupportTests` (unit); `PlannerMealCreateUITests`,
  `PlannerMealEditUITests`, `PlannerMealDeleteUITests`, `PlannerUITests`,
  `PlannerRegressionUITests` (UI) (SC-005).
- [x] T014 Run `git diff --check origin/main..HEAD` and a Debug build (SC-001,
  SC-005).
- [ ] T015 Produce the final report required by AGENTS.md; reconcile
  spec/plan/tasks against the implementation and record any divergence as a
  known gap or fix it (Constitution VII).

---

## Dependencies & Execution Order

### Phase Dependencies

- Phase 1 (T001) has no dependencies and verifies the baseline.
- Phase 2 (T002) blocks all US4 UI tasks: the toast cannot carry 撤销 before the
  action support exists.
- Phase 3 implements US4: T003–T005 add the delete entry points; T006 routes
  them through the store; T007/T008 depend on T006; T009 depends on T006;
  T010 is an independent verification.
- Phase 4 depends on Phase 3 completion.

### Parallel Opportunities

- T002 (shared feedback component) is parallelizable with T004 and T010.
- T011 (UI tests) and T012 (store-level confirmation) touch different targets
  and can proceed together once implementation lands.

## Implementation Strategy

- MVP = US4 complete: delete + undo with honest failure states, the only
  remaining story.
- Regressions are protected by the existing focused suites; Slice 1–3 work is
  never rewritten.
- Every task above traces to a spec FR/SC: T001→SC-001, T002→FR-009/FR-013,
  T003–T005→FR-006/FR-013, T006→FR-008, T007→FR-015, T008→FR-009,
  T009→FR-010/FR-011, T010→FR-014, T011→FR-006–FR-015, T012→FR-012,
  T013/T014→SC-001/SC-005, T015→Constitution VII.

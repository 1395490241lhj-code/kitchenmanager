---
description: "Task list for Weekly Menu → Canonical Planner Materialization — slices A, R, B, C, D, E"
---

# Tasks: Weekly Menu → Canonical Planner Materialization

**Input**: `specs/003-weekly-menu-materialization/`

**Prerequisites**: spec sealed with OD-1…OD-11 (spec `## Clarifications`). Implementation of any task
still requires explicit user authorization (constitution VI).

**Tests**: requested by the acceptance scenarios; the tests that change by design are listed at the
end so red is expected and attributable.

## Format: `[ID] [P?] [Slice] Description` — paths under `ios-native/Kitchen Manager/`

## Phase 1: Slice A — store contracts

- [x] T001 [A] `KitchenManager/KitchenStore.swift`: add `PlanBatchOutcome` / `PlanBatchRejection` and
  `appendPlans(_ items: [MealPlanItem], calendar:) -> PlanBatchOutcome` (named apart from D-040's
  deduplicating `addPlans(_ additions:)`) — preserve caller ids, normalize
  each item's date via `MealPlanItem.normalizedPlannerDate`, append in order, allow duplicate
  `(recipeID, date)`, reject `empty` / `duplicateIDsInBatch` / `idsAlreadyPresent` before any write,
  commit once through `commitPlans`. Leave `PlanMutationOutcome` untouched. (FR-001, FR-005)
- [x] T002 [P] [A] `KitchenManager/KitchenStore.swift`: add `commitWeeklyPlan(_:) -> Bool`
  (persist-before-publish with suppressed republish, mirroring `commitPlans`). Removing
  `saveWeeklyPlan` stays open until T011 (Slice B) takes away its last caller. (FR-009)
- [x] T003 [P] [A] `KitchenManager/Recipe.swift`: add `RecipeStore.saveUserRecipes(_:)` — one
  `replaceRecipes`; an id already present carrying the same content is reused; in-batch duplicates
  collapse; throws `UserRecipeBatchError.persistenceFailed`, plus `.idConflict(id:)` when a present
  id carries different content (owner implementation constraint §8: refuse rather than overwrite,
  never match by name). (FR-003)
- [x] T004 [P] [A] `KitchenManager/WeeklyMenuPlanner.swift`: add `WeeklyMaterializationState`,
  `WeeklyMaterializationReceipt`, `WeeklyMealPlan.materialization`, and the pure classifier
  `WeeklyMaterializationStatus.resolve(receipt:plans:)` per data-model §2. (FR-008)
- [x] T005 [A] Tests: batch contracts in `PlannerMealCRUDTests` (ids, dates, order, duplicates,
  three rejections, `FailingTodayPlanPersistence` → unchanged `plans`, existing rows and Special Plans
  untouched); `commitWeeklyPlan` failure; receipt round-trip and legacy decode in
  `WeeklyPlanPersistenceTests`; `saveUserRecipes` batch behaviour. (SC-001, SC-002, SC-003)

### Slice A implementation notes (2026-09-10)

- Two audited persistence fixes were required for the receipt to mean anything.
  `SwiftDataWeeklyPlanPersistence.replacePlan` and `SwiftDataUserRecipePersistence.replaceRecipes`
  both mutate live SwiftData records through `update(from:)` on a context they own outright, and
  neither rolled back on a failed `save()` — so a failed write left those objects holding payloads
  the database never took, and the next `loadPlan()` / `loadRecipes()` on that context would return
  them as if stored. Both now roll back, matching the contract
  `SwiftDataTodayPlanPersistence.replacePlans` already had.
- `replaceRecipes` also built its sort-order map with `Dictionary(uniqueKeysWithValues:)`, which
  traps at runtime on a repeated id while the line above it tolerated one. Changed to
  `uniquingKeysWith:` (first position wins), matching the neighbouring dictionary.
- `saveUserRecipes` is narrower than `saveUserRecipe` on purpose: it does not apply the content and
  source duplicate rules across *different* ids. Deciding which recipe a generated dish points at is
  the materializer's job (Slice B).
- FR-003 wording was corrected by the owner after Slice A review: reuse is **safe exact-identity
  reuse**, not unconditional id reuse. spec.md FR-003, research.md R2 and data-model.md now say so,
  and the implementation already matched.

## Phase 2: Slice R — restock migration (parallel with A/B)

- [ ] T006 [P] [R] new `KitchenManager/PlannedMealHorizon.swift`: pure
  `upcoming(plans:from:days:calendar:)` returning pending (not cooked) meals from the reference day
  through `+forwardDays`, date ascending, with `forwardDays = 6` as a named constant. (FR-015)
- [ ] T007 [R] `KitchenManager/InventoryConsumption.swift`: replace the `kitchenStore.weeklyPlan`
  branch of `RestockSuggestionEngine.generate` with `PlannedMealHorizon.upcoming(plans:)` fed to
  `ShoppingGenerationSource.todayPlans`; rename `RestockSuggestionSource.weeklyPlan` →
  `.plannedMeals` and its label; reason string `本周计划需要` → `用餐计划需要`. No
  `ShoppingListGenerator` change. (FR-015)
- [ ] T008 [P] [R] `KitchenManager/KitchenStore.swift`: delete the dead `todaysWeeklyMeals()` (no
  callers; it maps today onto the draft, a second-schedule reading). (FR-016)
- [ ] T009 [R] `KitchenManagerTests/RestockSuggestionEngineTests.swift`: an unmaterialized draft alone
  yields no plan-derived suggestion; canonical pending meals in the horizon do, with reason
  `用餐计划需要`; cooked meals and out-of-horizon meals excluded; the two existing absence assertions
  (`PreparedComponentTests`, `QuickMealPreparedUsageTests`) still pass. (SC-006)

## Phase 3: Slice B — materializer and state machine (after A)

- [x] T010 [B] `KitchenManager/WeeklyMenuPlanner.swift`: `WeeklyMenuMaterializer.prepare(plan:recipeStore:calendar:)`
  — resolve `.local` ids against `RecipeStore` and throw `missingLocalRecipe(dishName:)` on a miss; build
  `.ai` recipes via `domainRecipe` (`baseServings` nil); date from `startOfDay(startDate) + dayIndex`
  then Planner normalization; `plannedServings: nil`; allocate each `MealPlanItem.id` here.
  (FR-004, FR-005, FR-006)
- [x] T011 [B] `WeeklyMenuPlannerStore`: `isMaterializing` + `materialize(kitchenStore:recipeStore:confirmedAppend:calendar:now:)`
  implementing data-model §3 in order — collision detection over `kitchenStore.plans` surfaced to the
  caller for one confirmation; `saveUserRecipes` → `commitWeeklyPlan` (pending receipt +
  `isSavedToLibrary`) → `appendPlans` → `commitWeeklyPlan` (materialized). Retry from `.pending`
  reuses the receipt's exact ids; a pending receipt whose ids are all present finalizes without
  appending. Plus the two recovery primitives `materializeMissingMeals` and `acceptCurrentSchedule`,
  and `WeeklyMaterializationOutcome` covering every distinguishable end state.
  (FR-002, FR-007, FR-008, FR-010)
  Deferred to Slice C: deleting `addRecipeToTodayPlan`, `addDayToTodayPlan` and `savePlan`, which are
  still the UI's only wiring (FR-011).
- [x] T012 [B] Regeneration already yields a receipt-free draft, because `makePlan` builds a fresh
  `WeeklyMealPlan`. `KitchenStore.duplicateWeeklyPlanForNextWeek` did **not**: it copied the receipt,
  so a duplicated menu would have refused to be added at all. It now clears `materialization`.
  (FR-013)
- [x] T013 [B] new `KitchenManagerTests/WeeklyMenuMaterializationTests.swift` — 21 tests covering
  resolution, dates and order, collision, the write order, every failure window, retry and relaunch,
  partial recovery, receipt integrity and the copied-menu case. (SC-001, SC-002, SC-003, SC-005)

### Slice B implementation notes (2026-09-10)

- Two bugs the tests caught. `appendPlans` was being called without the caller's calendar, so an
  already-normalized date was re-normalized in the device timezone and the meal moved a day. And a
  pending receipt whose ids were all present reported `alreadyMaterialized` instead of finalizing,
  which would have stranded the receipt after a failed finalize write.
- Receipt integrity binds days as well as recipes. An earlier revision checked only candidate count
  and the `recipeIDs` sequence, which the owner correctly rejected: the same recipe on two days gives
  an identical id sequence, so a draft whose days had moved would still have passed and the retry
  would have written the approved ids onto the draft's current days. The receipt now carries
  `planDates` parallel to `planIDs` and `recipeIDs`, integrity requires all three to match, and retry
  and partial recovery rebuild each meal from that mapping rather than from the current draft. A
  pending receipt with no recorded dates is stale, not assumed correct.
- `materializedNeedsReceiptRepair` means the member's schedule really did change; only the
  bookkeeping lagged. Reopening finalizes the receipt and never appends again.
- The result screen is untouched, so `savePlan` and the manual add-today actions still exist and the
  materializer has no production caller yet. Slice C wires the CTA and removes them.

## Phase 4: Slice C — result surface truth (after B)

- [ ] T014 [C] `WeeklyMenuResultView`: one prominent CTA (`weekly.result.materialize`) with the five
  presentation states from data-model §3, including the `.partiallyPresent` recovery pair
  (`加入缺少的 N 道`, `标记为已加入`); remove the overview `把今天加入计划` and the per-dish
  `加入今日计划`; remove `保存本周计划` from the ⋯ menu. (FR-010, FR-011, FR-008)
- [ ] T015 [C] Copy per spec §9 across `WeeklyMenuPlanner.swift` and the single
  `ShoppingListGenerator.sourceLabel(.weeklyPlan)` string; state the explicit date range in the
  overview (`weekly.result.range`); regenerate and delete alert bodies; collision confirmation
  wording. (FR-012, FR-013)
- [ ] T016 [C] `WeeklyMenuPlannerView` / `WeeklyMenuResultView`: `onMaterialized` callback and the
  legacy host's `查看用餐计划` affordance; empty draft disables the CTA; add every accessibility
  identifier from data-model §9. (FR-014)
- [ ] T017 [P] [C] `KitchenManager/PlannerRegressionFixture.swift`: DEBUG states for a stubbed result,
  a collision seed, a failing plan persistence, and a pending receipt. (test support)
- [ ] T018 [C] Run the quickstart reference gate → `clean`. (SC-004)

## Phase 5: Slice D — validation (after C and R)

- [ ] T019 [D] new `KitchenManagerUITests/WeeklyMenuMaterializationUITests.swift` covering the
  quickstart manual list. Keep `PlannerUITests` reachability green — `today.plan.weeklyMenu.link` and
  its `HomeView.swift` copy are untouched by 003. (SC-004, SC-005)
- [ ] T020 [D] Full native suite + `npm run ios:release:check`; attribute any red to the documented
  Settings baseline or fix. (SC-007)

## Phase 6: Slice E — reconciliation

- [ ] T021 [E] Re-read `Decisions.md` and take the actual next Decision number (D-041 if nothing
  landed first); never reserve a number. (FR-018)
- [ ] T022 [E] Reconcile artifacts; AGENTS.md §7 report; verify with `git diff --stat main` that no
  Home, `TodayPlanDetailView`, 002 spec, Special Plan or sync file changed (FR-017). VAULT UPDATE
  list: the new Decision, `Current Status.md`, `Next Actions.md` (002's weekly-generator gate flips
  to NO; `TodayPlanDetailView` retirement unblocked; the `.todayPlans` case-name rename and the
  `TodayPlanDetailView` entry-row subtitle recorded as follow-ups), `Product & IA.md`,
  `Architecture.md`. Commit / push / vault writes remain user-authorized.

## Dependencies

A → B → C → D → E; R is independent of A–C and may land in parallel or first; D needs C and R.
T001–T004 are parallel within A; T006 and T008 are parallel within R.

## Tests that change by design

| File | Change |
|---|---|
| PlannerMealCRUDTests | + batch contracts (ids, rejections, atomicity) |
| WeeklyPlanPersistenceTests | + receipt round-trip, + legacy payload without a receipt |
| RestockSuggestionEngineTests | + canonical-plan derivation and horizon cases; draft-alone yields nothing |
| ShoppingScalingTests, PreparedComponentTests, QuickMealPreparedUsageTests | unchanged; verified still valid after the restock migration |
| WeeklyMenuBaseYieldCompatibilityTests, WeeklyMealPlanDerivedCountTests | unchanged (`baseServings` stays nil; derived counts unchanged) |
| PlannerUITests | unchanged (weekly entry link and label remain until 002) |
| new WeeklyMenuMaterializationTests / WeeklyMenuMaterializationUITests | Slices B and D |


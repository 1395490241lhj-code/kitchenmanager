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

- [x] T006 [P] [R] new `KitchenManager/PlannedMealHorizon.swift`: pure
  `upcoming(plans:from:forwardDays:calendar:)` returning pending (not cooked) meals from the
  reference day through `+forwardDays`, in the order `plans` already holds them, with
  `defaultForwardDays = 6` as a named constant. (FR-015)
- [x] T007 [R] `KitchenManager/InventoryConsumption.swift` + `ShoppingListGenerator.swift`: replace
  the `kitchenStore.weeklyPlan` branch of `RestockSuggestionEngine.generate` with
  `PlannedMealHorizon.upcoming(plans:)` fed to a new
  `ShoppingGenerationSource.plannedMeals([MealPlanItem])` case (label `用餐计划`, resolving through
  the existing `.todayPlans` branch body); rename `RestockSuggestionSource.weeklyPlan` →
  `.plannedMeals`; reason string `本周计划需要` → `未来 7 天计划需要`. (FR-015)
- [x] T008 [P] [R] `KitchenManager/KitchenStore.swift`: delete the dead `todaysWeeklyMeals()` (no
  callers; it maps today onto the draft, a second-schedule reading). (FR-016)
- [x] T009 [R] new `KitchenManagerTests/PlannedMealHorizonTests.swift` (window edges, cooked meals,
  order, week crossing, DST) plus `RestockSuggestionEngineTests.swift`: an unmaterialized draft alone
  yields no plan-derived suggestion; canonical pending meals in the horizon do, with reason
  `未来 7 天计划需要`; cooked, deleted and out-of-horizon meals excluded; a missing recipe reference is
  skipped rather than fatal; the two existing absence assertions (`PreparedComponentTests`,
  `QuickMealPreparedUsageTests`) still pass. (SC-006)

### Slice R implementation notes (2026-09-11)

- `.todayPlans` was **not** widened. The sealed plan reused it for the seven-day set; the owner gate
  rejected that, because the name would then be false and every imported row would read `今日计划`.
  A new `.plannedMeals([MealPlanItem])` case resolves through the same branch body and labels its
  imports `用餐计划`; the horizon lives in `PlannedMealHorizon` and the restock caller, never in the
  enum. Cost: one case, one label line, one pattern addition.
- `RestockSuggestionSource.label` was deleted with the rename. It was unreachable (both surfaces
  render `suggestion.reason`, built at the call site), and keeping it would have meant inventing a
  second copy of the reason string in a property nobody reads.
- No new observation: `plans` is already `@Published`, the Inventory section reads restock through a
  computed property, and the cook-confirmation sheet recomputes after applying consumption. Adding,
  removing or cooking a meal moves the suggestions with no polling.
- The horizon filters rather than sorts, so the projection keeps the canonical array order.
  `PlannerProjection`'s presentation sort is not duplicated here, and restock aggregates by
  ingredient anyway.
- Special Plans stay out (spec Out of Scope); `.todayPlans`, its `今日计划` label and Home's shopping
  behaviour are untouched.

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
- [x] T013 [B] new `KitchenManagerTests/WeeklyMenuMaterializationTests.swift` — tests covering
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

- [x] T014 [C] `WeeklyMenuResultView`: one CTA (`weekly.result.materialize`) driving the Slice B
  materializer, with the presentation states from data-model §3 — including the `.partiallyPresent`
  recovery pair `重新加入缺少的 N 道` / `保留当前安排`, whose wording avoids any internal vocabulary.
  The overview `把今天加入计划`, the per-dish `加入今日计划` and the ⋯ `保存本周计划` are gone, along
  with `savePlan`, `addRecipeToTodayPlan` and `addDayToTodayPlan`. (FR-002, FR-008, FR-010, FR-011)
- [x] T015 [C] Copy per spec §9 across `WeeklyMenuPlanner.swift` and the single
  `ShoppingListGenerator.sourceLabel(.weeklyPlan)` string; state the explicit date range in the
  overview (`weekly.result.range`); regenerate and delete alert bodies; collision confirmation
  wording. (FR-012, FR-013)
- [x] T016 [C] `WeeklyMenuPlannerView` / `WeeklyMenuResultView`: `onMaterialized` callback carrying a
  `WeeklyMaterializationSummary` (covered date range only — no ids, because after `保留当前安排`
  some intended meals are absent on purpose), defaulted to `nil` so the existing Home call site is
  untouched; it fires once per member-initiated completion (first append, append whose receipt
  finalization lagged, `重新加入缺少的 N 道`, `保留当前安排`) and never on reopen, passive repair
  (`repairReceiptIfMealsArePresent` returns a `Bool`) or failure/cancel; empty draft disables the
  CTA; accessibility identifiers added.
  The legacy host shows no `查看用餐计划` affordance, because supplying one would mean editing Home,
  which 003 must not do — 002 will pass a callback when it hosts the generator. (FR-014)
- [x] T017 [P] [C] `KitchenManager/PlannerRegressionFixture.swift`: `WeeklyMenuRegressionFixture`
  with DEBUG states `PLANNER_DATA_WEEKLY_PLAIN` / `_COLLISION` / `_ADDED` / `_REPAIR` / `_PARTIAL` /
  `_STALE` / `_MISSING_RECIPE`, all seeding `generatedPlan` directly so no AI call is involved.
  (test support)
- [x] T018 [C] Reference gate run: the weekly flow holds none of the retired wording. Remaining hits
  are outside this slice — `本周计划需要` and `todaysWeeklyMeals` belong to Slice R, the Shopping
  regression fixture seeds a historical `本周菜单` provenance value, and the Recipes tab keeps its own
  unrelated `加入今日计划`. (SC-004)

### Slice C implementation notes (2026-09-10)

- The result screen now has exactly one way to put a menu on the plan, and it runs the Slice B
  materializer. `savePlan`, `addRecipeToTodayPlan` and `addDayToTodayPlan` are gone.
  `KitchenStore.saveWeeklyPlan` stays: `SwiftDataConsistencyTests` still exercises it, so it is not
  dead.
- A menu whose meals are all on the plan but whose receipt never got marked done finishes that
  bookkeeping once per visit, silently. It cannot append — the orchestrator refuses in that state —
  and if the repair write fails the screen still reads `已加入用餐计划`, because the meals really are
  there. The next visit tries again.
- Two SwiftUI compile limits shaped the code rather than the design: the overview rows were split
  into `overviewRows` and the three new alerts moved into a `WeeklyMaterializationAlerts` modifier,
  because the type checker gave up on the combined expression.
- At accessibility sizes the four summary rows fill the first screen, so the CTA is scrolled to
  rather than visible immediately. A lazy List does not build what it does not show, so the
  reachability tests scroll before asserting existence. Reachable, not immediately visible, is the
  requirement.
- No `查看用餐计划` affordance exists on the legacy host: supplying one would mean editing Home.
  `onMaterialized` is in place and defaults to `nil`, so 002 can pass one when it hosts the
  generator from Planner.
- Callback audit (2026-09-10): `WeeklyMaterializationHostNotification.summary(for:of:calendar:)` is
  the single decision point, reached only from `handle`, which only a tap calls. Seven unit tests
  under `// MARK: - Host notification` in `WeeklyMenuMaterializationTests` pin each path: first
  append once; lagging-receipt append once with the later repair silent; passive repair silent even
  when its write fails; reopen silent; re-add once; keep-current once with a dates-only summary; no
  failure or cancel path firing.
- `ShoppingListGenerator.swift` changes in this slice are two strings inside the `.weeklyPlan`
  branch (the empty-draft warning and `sourceLabel`). `.todayPlans` still means today only, and
  `InventoryConsumption.swift` / `todaysWeeklyMeals()` stay untouched until Slice R.
- Draft editing follows the receipt (spec §3 S1/S4): `替换这道`, `移到其他天` and `从计划移除` are
  hidden once the menu is on the plan and disabled while a receipt is pending or partial
  (`isDraftEditable`); `查看菜谱` stays. Found while reconciling the spec against the code — the
  gate had been declared but never wired. Pinned by `testEditingStopsOnceTheMenuIsOnThePlan`.

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
  to NO; `TodayPlanDetailView` retirement unblocked; the `TodayPlanDetailView` entry-row subtitle
  recorded as a follow-up), `Product & IA.md`,
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


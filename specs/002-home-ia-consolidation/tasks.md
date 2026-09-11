---
description: "Task list for Home IA Consolidation — slices A, C, B, D, F (retirement deferred, verdict C)"
---

# Tasks: Home IA Consolidation

**Input**: Design documents from `specs/002-home-ia-consolidation/`

**Prerequisites**: spec.md sealed with the 2026-09-10 clarifications. Implementation of any
task still requires explicit user authorization (constitution VI). Slices B and D additionally
require D-041 recorded in canonical memory (FR-016).

**Tests**: requested by the spec's acceptance scenarios; each slice lists the tests that change
*by design* so red is expected and attributable.

**Organization**: by slice in dependency order. Each task names its FR / SC trace.

## Format: `[ID] [P?] [Slice] Description`

- **[P]**: parallelizable (different files, no dependency)
- Paths under `ios-native/Kitchen Manager/`

## Phase 1: Slice A — Planner parity (blocking for B, D)

- [ ] T001 [A] `KitchenManager/PlannerView.swift`: on pending ordinary rows add `做好了` as the
  first leading swipe action beside `编辑` (id `planner.meal.complete.<id>`), in `.contextMenu`
  (`planner.meal.completeMenu.<id>`) and as `.accessibilityAction(named: "做好了")`; each presents
  `CookConsumptionConfirmationView(title:planIDs:recipeID:recipeName:)` with
  `planIDs: hasConsumedPlan ? [] : [id]` for that exact `MealPlanItem`; on confirm
  `markPlanCooked` + toast `已记录消耗，库存已更新` through the existing toast/token mechanism.
  Hidden for cooked rows. No bare `isCooked` flip. (FR-001, FR-002)
- [ ] T002 [A] Verify the two-action leading edge at standard and AXXXL Dynamic Type and with
  VoiceOver; if native density is inappropriate, **report** in the slice result rather than
  adding custom controls. (FR-001)
- [ ] T003 [P] [A] `KitchenManager/PlannerView.swift`: add `PlannerRoute.shoppingToday` →
  `ShoppingListGenerationView(source: .todayPlans(kitchenStore.todayPlans))`; add trailing
  toolbar `Menu` (`ellipsis.circle`, label `更多`, id `planner.more.menu`) with the single item
  `生成今日购物清单` (`planner.more.shoppingToday`). No shopping management in Planner. (FR-003)
- [ ] T004 [P] [A] `KitchenManager/PlannerView.swift`: `init(initialPath: [PlannerRoute] = [], …)`
  seeding `path`. (FR-011 prerequisite)
- [ ] T005 [P] [A] `KitchenManagerTests/PlannerMealCRUDTests.swift` (or KitchenStoreTests):
  completion-parity unit test — the same plan completed through the confirmation path then
  `markPlanCooked` yields identical `isCooked` and consumption linkage regardless of origin;
  `hasConsumedPlan` prevents double deduction. (SC-003)
- [ ] T006 [A] new `KitchenManagerUITests/PlannerQuickCompleteUITests.swift`: leading-swipe,
  context-menu and VoiceOver-action `做好了` → confirm → `已完成`; cooked row offers none; `更多`
  menu offers only `生成今日购物清单`; it opens the generation screen; empty today shows
  `没有可生成的购物清单`. (US1, US2, SC-002)
- [ ] T007 [A] run quickstart Slice A commands; record results.

**Checkpoint**: Planner owns quick-complete and shopping derivation.

## Phase 2: Slice C — Home reduction (parallel with A)

- [ ] T008 [P] [C] `KitchenManager/HomeView.swift`: delete the toolbar `+`, `HomeSheet.smartImport`,
  `SmartImportSheet`, `SmartImportRow`, `SmartImportRoute`, `SmartImportChildSheet`. (FR-005)
- [ ] T009 [P] [C] `KitchenManager/HomeView.swift`: in `HomeRecommendationSection` remove the
  `AI 换几道` button, `onRefresh`, `isGenerating`; rename `查看全部` → `更多推荐` with id
  `home.recommendation.more`; delete `generateAIRecommendations` if unused. Keep error /
  notice / samples states. (FR-008, FR-009)
- [ ] T010 [P] [C] `KitchenManager/HomeView.swift`: execution-mode `HomeSecondaryLinkRow`
  `想再加一道` → `更多推荐`, id `home.recommendation.more`; same symbol/tint; stays above
  `用餐计划`. (FR-008)
- [ ] T011 [C] Reroute tests that used Home `+` as an entry path to the owning tabs:
  `ClipboardRecipeImportUITests` (Recipes `+ → 从链接导入`), `ManualEntryExpiryUITests`
  (Inventory `inventory.add.button`), `ReceiptCompactListUITests` ×2 (Inventory
  `更多食材操作 → 扫描购物小票`), `RuntimeAccessibilityP1UITests` (~L146, manual entry via
  Inventory), `HomeDashboardUITests.testHeaderImportAndSettingsRemainReachableFromMyTab`
  (assert Home has no `+`; import reachable on Recipes). (SC-004)
- [ ] T012 [C] `HomeDashboardUITests`: delete `testAIRefreshRunsOnHomeWithoutNavigatingAway`;
  update `testAnOrdinaryDayMakesRecipeRecommendationThePrimaryTask`,
  `testAQuickDayMakesQuickMealThePrimaryTask`, `testExecutionModeDemotesRecommendationToALinkWithoutRemovingIt`
  (label `更多推荐`), `testDecisionModeCanOpenTheFullRecommendationExperience` (id
  `home.recommendation.more`); `ComponentMealUITests` ~L72 and `RuntimeAccessibilityP1UITests`
  ~L216–283 (regenerate now only in browser). Add a browser regenerate test if none exists; add
  an order assertion `更多推荐`.minY < `用餐计划`.minY. (US3, FR-008)
- [ ] T013 [C] run quickstart Slice C commands; record results.

## Phase 3: Slice B — plan-link canonicalization + TodayPlanDetail reduction (after C; D-041 recorded)

- [ ] T014 [B] Gate: confirm D-041 is recorded in `Decisions.md` (user-authorized vault write)
  before any B/D code task. (FR-016)
- [ ] T015 [B] `KitchenManager/HomePrimaryTask.swift`: add `otherPlansLine: String?` —
  `今天另有 N 道计划` when pending > 0, `今天另有 N 道计划 · 已完成` when total > 0 and all cooked,
  nil when total == 0 — computed only for `.mealPrepBoard` / `.eatOut` (and `.specialPlanToday` in
  Slice D). Never `今日计划已全部完成`. (FR-007)
- [ ] T016 [P] [B] `KitchenManagerTests/HomePrimaryTaskTests.swift`: cases for pending / all-cooked /
  none across `.mealPrepBoard` and `.eatOut`; assert the exact copy. (FR-007)
- [ ] T017 [B] `KitchenManager/HomeView.swift`: remove `home.plan.secondaryLink`; render
  `otherPlansLine` in `HomeTodayContext` as static `Text` (id `home.context.otherPlans`, no chevron,
  no button trait). (FR-006, FR-007)
- [ ] T018 [B] `KitchenManager/HomeView.swift` — `TodayPlanDetailView`: remove the `全部做完` section
  and `TodayPlanSheet.cookAll`; remove the `生成今日购物清单` section and
  `isShowingShoppingGeneration`; remove the `移出计划` context menu, `planPendingRemoval` and the
  alert. Keep rows, `做好了`, RecipeDetail navigation, the generator link and the title.
  Do not touch `KitchenStore`; the generator link and its copy stay exactly as they are.
  (FR-004, FR-012, FR-013)
- [ ] T019 [B] `PlannerUITests`: delete `testTodayPlanDetailNoLongerCarriesAPlannerRoute`'s
  planner-route assertions or retarget it to “`今天的计划` still reaches the generator; no
  planner link; no `全部做完` / shopping / delete”; rewrite `testTodaySecondaryLinksAreMutuallyExclusive`
  → “exactly one `更多推荐` in execution mode, none in eat-out; `用餐计划` always; no
  `home.plan.secondaryLink`; static `home.context.otherPlans` on eat-out”. `HomeDashboardUITests`:
  rewrite `testAStalePlanUnderAnEatOutDinnerStaysReachableButNeverProminent` to assert the
  context line is not a button and Planner is the route; keep
  `testTodayPlanViewAllStillReachesTheFullPlan` (interim route remains) but assert the reduced
  content and that the generator link is still reachable. (US3, US5, FR-004, SC-001, SC-002)
- [ ] T020 [B] run quickstart Slice B commands + reference gate; record results. (SC-006)

## Phase 4: Slice D — Special Plan today (after B; D-041 recorded)

- [ ] T021 [D] `KitchenManager/HomePrimaryTask.swift`: add `.specialPlanToday`; extend `resolve`
  with today's Special Plans (sorted by `scheduledAt`); branch after `eatOut`, before ordinary
  plan; title = plan title, detail `HH:mm · N 人` / `已完成` / suffix `· 今天还有 N 场`; expose
  primary plan id; `otherPlansLine` applies; suppressed-plan line `今天有聚餐 · HH:mm <title>` for
  `.mealPrepBoard` / `.eatOut`. (FR-010)
- [ ] T022 [P] [D] `KitchenManagerTests/HomePrimaryTaskTests.swift`: cases for all eight §9
  states; extend the exhaustive combination test with the Special Plan dimension and assert all
  prior results unchanged. (SC-005)
- [ ] T023 [D] `KitchenManager/HomeView.swift`: primary section for `.specialPlanToday` using
  `HomePrimaryHeader` + one prominent CTA `查看聚餐` (id `home.specialPlan.open`) →
  `isShowingPlanner` with `initialPath: [.specialPlan(id)]`; render `home.context.specialPlan`
  static line on prep / eat-out days. No new card style; no `更多推荐` in this kind. (FR-011,
  FR-014)
- [ ] T024 [D] `HomeDashboardUITests`: DEBUG seeds for Special Plan today (single, multiple,
  completed, with eat-out, with prep, with ordinary plans pending / all cooked) and assertions
  from §9; section-order test `testHomeRendersTodayContextThenPrimaryTaskThenNeedsAttention`
  still passes with leaf identifiers. (US4, FR-015, SC-001)
- [ ] T025 [D] run quickstart Slice D commands; record results.

## Phase 5: Slice F — Reconciliation

- [ ] T026 [F] Full native suite + `npm run ios:release:check`; attribute any red to the documented
  Settings baseline or fix. (SC-007)
- [ ] T027 [F] Reconcile spec/plan/tasks with the shipped behaviour; record known gaps
  (interim `今天的计划`, generator reachability only in execution mode).
- [ ] T028 [F] AGENTS.md §7 final report; VAULT UPDATE list: `Current Status.md`, `Next Actions.md`
  (materialization feature now owns retirement + dead-code cleanup), `Product & IA.md` (Home
  contract, Planner role), `Decisions.md` (D-041 already recorded at T014). Commit / push / vault
  writes remain user-authorized.

## Dependencies

- A ∥ C → B → D → F. A and C are independent. B follows C only because both edit
  `HomeView.swift`; B's real gate is D-041 (Planner already owns delete under D-040, so no
  Slice A capability is needed first). D requires A (`initialPath`), B (context-line model) and
  D-041.

## Deferred to the weekly-materialization feature (not tasks here)

Delete `TodayPlanDetailView`, `TodayPlanSheet`, `isShowingTodayPlan`, `onViewPlan`,
`home.today.plan.viewAll`, `today.plan.complete.button`, `today.plan.weeklyMenu.link`; remove
`markAllTodayCooked` and `removePlan(_ plan:)` after a zero-reference proof; retire the related
tests; finish OD-1's “exactly one planning-management destination” in execution mode.

## Tests that change by design (summary)

| File | Change |
|---|---|
| HomeDashboardUITests | −testAIRefreshRunsOnHome…; rewrite eat-out stale-plan, import-reachability, recommendation label/id tests; testTodayPlanViewAll… asserts reduced content; + order assertion; + Special Plan seeds |
| PlannerUITests | retarget testTodayPlanDetailNoLongerCarriesAPlannerRoute; rewrite testTodaySecondaryLinksAreMutuallyExclusive |
| RuntimeAccessibilityP1UITests | regenerate assertions to browser; manual-entry path to Inventory; today-plan row/complete test unchanged (interim view keeps 做好了) |
| ClipboardRecipeImportUITests, ManualEntryExpiryUITests, ReceiptCompactListUITests, ComponentMealUITests | entry path reroutes only |
| ProductionDesignLanguageUITests, Phase1DArtDirectionUITests | unchanged (`home.today.plan.start` semantics do not move) |
| HomePrimaryTaskTests | + context-line copy cases; + Special Plan cases; exhaustive test dimension |
| PlannerMealCRUDTests / KitchenStoreTests | + completion parity; legacy API tests untouched (FR-013) |
| new PlannerQuickCompleteUITests | Slice A coverage |


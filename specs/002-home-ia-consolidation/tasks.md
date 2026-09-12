---
description: "Task list for Home IA Consolidation — slices A, C, B, D, E, F; TodayPlanDetailView retired inside this feature"
---

# Tasks: Home IA Consolidation

**Input**: Design documents from `specs/002-home-ia-consolidation/`

**Prerequisites**: spec.md reconciled 2026-09-11 onto `main` = `a7b7d8f`. Implementation of any
task still requires explicit user authorization (constitution VI). Slices B, D and E additionally
require the next available Home IA Decision recorded in canonical memory — currently expected
D-042, but the number is read from `Decisions.md` at write time and is not reserved here
(FR-022).

**Tests**: requested by the spec's acceptance scenarios; each slice lists the tests that change
*by design*, so red is expected and attributable.

**Organization**: by slice in dependency order. Every task names its FR / SC trace. All tasks are
unstarted.

## Format: `[ID] [P?] [Slice] Description`

- **[P]**: parallelizable (different file or independent region, no dependency)
- Paths under `ios-native/Kitchen Manager/`

## Phase 1: Slice A — Planner capability parity (blocking for B, D, E)

- [x] T001 [A] `KitchenManager/PlannerView.swift`: on pending ordinary rows add `做好了` as the
  first leading swipe action beside `编辑`, in `.contextMenu`, and as
  `.accessibilityAction(named: "做好了")` — the same three paths the delete flow already uses.
  Each presents `CookConsumptionConfirmationView` with `planIDs: [id]`, preserving that exact
  `MealPlanItem`. Explicit confirmation is semantic success when consumption is newly persisted
  or already recorded for that valid exact target (no second deduction); invalid targets and
  persistence failures remain failures. On success, `markPlanCooked` plus the existing toast mechanism.
  Hidden for cooked rows. No bare `isCooked` flip. (FR-001, FR-002)
- [x] T002 [A] Verify the two-action leading edge at standard and AXXXL Dynamic Type and with
  VoiceOver; if native density is inappropriate, **report** in the slice result rather than adding
  custom controls. (FR-001)
- [x] T003 [P] [A] `KitchenManager/PlannerView.swift`: add a trailing toolbar `Menu`
  (`ellipsis.circle`, label `更多`) and a `PlannerRoute` value that opens
  `ShoppingListGenerationView(source: .todayPlans(kitchenStore.todayPlans))`. No shopping
  management inside Planner. (FR-003)
- [x] T004 [A] `KitchenManager/PlannerView.swift`: add the weekly-generator entry to the same
  `更多` menu and a route that presents `WeeklyMenuPlannerView(onMaterialized:)`. Pass the
  callback and nothing else: no receipt inspection, no materialization logic, no id inference, no
  second notification channel. `WeeklyMenuPlanner.swift` is not modified. (FR-004)
- [x] T005 [A] `KitchenManager/PlannerView.swift`: in the `onMaterialized` handler set
  `weekStart` to `PlannerProjection.startOfWeek(containing: summary.startDate)` and return the
  member to the week list. Do not assert that any specific meal exists — a recovery choice can
  legitimately leave intended meals absent. (FR-005)
- [x] T006 [P] [A] `KitchenManager/PlannerView.swift`: give the generator entry a subtitle that
  describes an existing draft as generated rather than scheduled; do not carry over
  `已安排 N 天 · M 道菜`. (FR-006)
- [x] T007 [P] [A] `KitchenManager/PlannerView.swift`: add an initial-path seed to
  `PlannerView.init` so a caller can open Planner directly at a `PlannerRoute`. (FR-013
  prerequisite)
- [x] T008 [P] [A] `KitchenManagerTests/PlannerMealCRUDTests.swift` (or `KitchenStoreTests`):
  completion-parity unit test — the same plan completed through the confirmation path then
  `markPlanCooked` yields identical `isCooked` and consumption linkage regardless of origin, and
  `hasConsumedPlan` prevents a second deduction. (SC-010)
- [x] T009 [A] New `KitchenManagerUITests/PlannerQuickCompleteUITests.swift`: leading-swipe,
  context-menu and VoiceOver-action `做好了` → confirm → `已完成`; a cooked row offers none; the
  `更多` menu offers `生成今日购物清单`, which opens the generation screen; empty today shows
  `没有可生成的购物清单`. (US1, US2, SC-005)
- [x] T010 [A] New `KitchenManagerUITests/PlannerWeeklyHostUITests.swift`: the `更多` menu opens
  the generator; `加入用餐计划` returns to Planner showing the week containing the range start; a
  range crossing two weeks reveals the start week and pages normally; cancel changes nothing; the
  entry never describes a draft as scheduled. (US3, SC-006)
- [x] T011 [A] Run the quickstart Slice A commands; record results, including the AXXXL and
  VoiceOver findings from T002. (SC-005, SC-006, SC-010)

**Checkpoint**: Planner owns quick-complete, shopping derivation and weekly-generator hosting.
Nothing may remove a Home route to `TodayPlanDetailView` before this checkpoint passes.

## Phase 2: Slice C — Home reduction (parallel with A)

- [x] T012 [P] [C] `KitchenManager/HomeView.swift`: delete the toolbar `+`,
  `HomeSheet.smartImport`, `SmartImportSheet`, `SmartImportRow`, `SmartImportRoute` and
  `SmartImportChildSheet`. (FR-007)
- [x] T013 [P] [C] `KitchenManager/HomeView.swift`: in the Home recommendation section remove the
  `AI 换几道` button with its `onRefresh` / `isGenerating` plumbing, and rename `查看全部` to
  `更多推荐` with identifier `home.recommendation.more`. Keep the store-level error, notice and
  sample-fallback states, which are not tied to the removed button. (FR-008, FR-009)
- [x] T014 [P] [C] `KitchenManager/HomeView.swift`: execution-mode `HomeSecondaryLinkRow`
  `想再加一道` → `更多推荐`, identifier `home.recommendation.more`; same symbol and tint; stays
  above `用餐计划`. (FR-008)
- [x] T015 [C] Reroute the tests that used Home `+` as an entry path to the owning tabs:
  `ClipboardRecipeImportUITests` (Recipes `+ → 从链接导入`), `ManualEntryExpiryUITests`
  (Inventory `inventory.add.button`), `ReceiptCompactListUITests` (Inventory
  `更多食材操作 → 扫描购物小票`), `RuntimeAccessibilityP1UITests` (manual entry via Inventory), and
  `HomeDashboardUITests` import reachability (assert Home has no `+`; import reachable on
  Recipes). (SC-002)
- [x] T016 [C] `HomeDashboardUITests`: delete the Home AI-refresh test; update the recommendation
  label and identifier cases to `更多推荐` / `home.recommendation.more`; update
  `ComponentMealUITests` and `RuntimeAccessibilityP1UITests` where they assert Home regeneration;
  add a browser regenerate test if none exists; add an order assertion that `更多推荐` sits above
  `用餐计划`. (US4, SC-003, SC-004)
- [x] T017 [C] Run the quickstart Slice C commands; record results. (SC-002, SC-003, SC-004)

## Phase 3: Slice B — canonical routing (after A and C; Decision recorded)

- [x] T018 [B] **Gate**: confirm the next available Home IA Decision is recorded in
  `Decisions.md` by a user-authorized vault write. Read the file at that moment to learn the
  number — expected to be D-042, but do not assume it. No B, D or E code task starts first.
  (FR-022)
- [x] T019 [B] `KitchenManager/HomePrimaryTask.swift`: add `otherPlansLine: String?` —
  `今天另有 N 道计划` when pending > 0, `今天另有 N 道计划 · 已完成` when total > 0 and all are
  cooked, nil when total == 0 — computed for `.mealPrepBoard` and `.eatOut` (and
  `.specialPlanToday` in Slice D). Never `今日计划已全部完成`. (FR-011)
- [x] T020 [P] [B] `KitchenManagerTests/HomePrimaryTaskTests.swift`: pending / all-cooked / none
  cases across `.mealPrepBoard` and `.eatOut`, asserting the exact copy. (FR-011)
- [x] T021 [B] `KitchenManager/HomeView.swift`: remove `home.plan.secondaryLink` and render
  `otherPlansLine` in `HomeTodayContext` as static `Text` (identifier `home.context.otherPlans`,
  no chevron, no button trait). (FR-010, FR-011)
- [x] T022 [B] `KitchenManager/HomeView.swift`: remove both `home.today.plan.viewAll` branches in
  `TodayPlanSummaryCard` (the `HomeActionPair` secondary for the cooked state and the standalone
  row for the pending state) together with the `onViewPlan` wiring at both call sites, leaving
  `用餐计划` as Home's only planning destination. The view itself is still present at this point
  and is deleted in Slice E. (FR-010)
- [x] T023 [B] `PlannerUITests`: retarget `testTodayPlanDetailNoLongerCarriesAPlannerRoute` and
  rewrite `testTodaySecondaryLinksAreMutuallyExclusive` to “exactly one `更多推荐` in execution
  mode, none in eat-out; `用餐计划` always present and the only planning row; no
  `home.plan.secondaryLink`; no `home.today.plan.viewAll`; static `home.context.otherPlans` on
  eat-out”. `HomeDashboardUITests`: rewrite the eat-out stale-plan case to assert the context line
  is not a button and Planner is the route. (US4, SC-001)
- [x] T024 [B] Run the quickstart Slice B commands; record results. (SC-001)

## Phase 4: Slice D — Special Plan today (after B; Decision recorded)

- [x] T025 [D] `KitchenManager/HomePrimaryTask.swift`: add `.specialPlanToday`; extend `resolve`
  with today's Special Plans sorted by `scheduledAt`, branching after the `eatOut` check and
  before the ordinary-plan check. Title = plan title; detail `HH:mm · N 人`, with `· 已完成` as
  a suffix when every dish is cooked (owner copy ruling: no `待开始` — the time communicates
  pending; no same-day count — later events stay reachable through Planner); expose the primary
  plan id; `otherPlansLine` applies; suppressed-plan line `今天有聚餐 · HH:mm <title>`, plus
  ` · 已完成` when the event is completed, for `.mealPrepBoard` / `.eatOut`. Plumb
  `kitchenStore.specialPlans` through to the call site, which does not read them today. (FR-012)
- [x] T026 [P] [D] `KitchenManagerTests/HomePrimaryTaskTests.swift`: the eight §9 states, plus the
  exhaustive combination test extended with the Special Plan dimension, asserting every prior
  result is unchanged. (SC-007)
- [x] T027 [D] `KitchenManager/HomeView.swift`: primary section for `.specialPlanToday` using the
  existing `HomePrimaryHeader` plus one prominent CTA `查看聚餐` (identifier
  `home.specialPlan.open`) that opens the Planner sheet seeded at that plan's detail route; render
  the `home.context.specialPlan` static line on prep / eat-out days. No new card style; no
  `更多推荐` in this kind. (FR-013, FR-020)
- [x] T028 [D] `HomeDashboardUITests`: DEBUG seeds for Special Plan today (single, multiple,
  completed, with eat-out, with prep, with ordinary plans pending and all cooked) and the §9
  assertions; the section-order test still passes on leaf identifiers. Note that the existing
  `UITEST_SEED_SPECIAL_PLAN` fixture also seeds an ordinary meal, so a Special-Plan-only seed is
  needed rather than reuse. (US5, FR-021, SC-001)
- [x] T029 [D] Run the quickstart Slice D commands; record results. (SC-007)

## Phase 5: Slice E — `TodayPlanDetailView` retirement (after A and B; sequenced after D)

- [ ] T030 [E] **Proof before deletion.** Record a zero-reference proof for each symbol proposed
  for removal: `markAllTodayCooked()`, `removePlan(_ plan:)`, `pendingTodayPlans`, and the view's
  private helpers. A symbol that is not proven dead is not deleted, and the proof is recorded in
  the slice result rather than asserted. (FR-017, SC-011)
- [ ] T031 [E] `KitchenManager/HomeView.swift`: delete `TodayPlanDetailView` and its private
  members `TodayPlanSheet`, `planDetailButton`, `completionButton`, `weeklyPlanSubtitle` and
  `showToast`. Deleting the view is what removes `全部做完` and its `.cookAll` sheet from the
  product; the control is not migrated anywhere. (FR-014, FR-016)
- [ ] T032 [E] `KitchenManager/HomeView.swift`: delete the route — `isShowingTodayPlan`, its
  `.navigationDestination`, and `TodayPlanSummaryCard.onViewPlan` with the preview call sites that
  pass it. (FR-016)
- [ ] T033 [E] `KitchenManager/KitchenStore.swift`: delete `markAllTodayCooked()` and
  `removePlan(_ plan:)` per the T030 proof, and retire the remaining test caller in
  `KitchenManagerTests/TodayPlanPersistenceTests.swift`. Do not touch `removePlan(id:)`,
  `restorePlan(_:at:)`, `markPlanCooked` or `hasConsumedPlan`. (FR-014, FR-015, FR-017)
- [ ] T034 [E] `KitchenManager/KitchenStore.swift`: delete `pendingTodayPlans` **only if** T030
  proved it dead once the view and `markAllTodayCooked` are gone; otherwise leave it and say so.
  `ShoppingGenerationSource.todayPlans` is retained — it now serves the Planner entry. (FR-017)
- [ ] T035 [E] Remove or retarget the obsolete identifiers and tests: `home.today.plan.viewAll`,
  `today.plan.complete.button`, `today.plan.weeklyMenu.link`; the `今天的计划` navigation-title
  assertions in `HomeDashboardUITests` and `PlannerUITests`; the today-plan completion layout
  assertions in `RuntimeAccessibilityP1UITests`, which move to the Planner row; and the
  `UITEST_SEED_ACCESSIBILITY_TODAY_PLAN` launch fixture in `ContentView.swift`. Preserve the
  `PlannerMealDeleteUITests` cases that match the shared string `移出计划` against Planner's own
  delete. (FR-018)
- [ ] T036 [E] Confirm Home contains zero `weeklyPlan` references after the deletion, so no Home
  behaviour can treat the draft as schedule truth. (FR-019, SC-009)
- [ ] T037 [E] Run the quickstart Slice E commands and the reference gate; record results and the
  proofs. The gate covers `全部做完`, so a surviving occurrence anywhere fails the slice.
  (FR-014, SC-008, SC-011)

**Checkpoint**: Home has one planning destination, `TodayPlanDetailView` does not exist, and the
weekly generator is reachable only from Planner.

## Phase 6: Slice F — Validation and reconciliation

- [ ] T038 [F] Full native suite with parallel testing disabled, plus `npm run ios:release:check`;
  attribute any red to the documented baseline or fix it. Never infer a pass from an older report.
  (SC-012)
- [ ] T039 [F] Reconcile spec / plan / tasks against the shipped behaviour; record any remaining
  divergence explicitly as a known gap. Verify every FR-001…FR-022 and SC-001…SC-012 is either
  demonstrated or explicitly recorded as unmet. (constitution VII)
- [ ] T040 [F] Produce the AGENTS.md §7 final report and the VAULT UPDATE list: `Current Status.md`,
  `Next Actions.md`, `Product & IA.md` (Home contract, Planner role), `Decisions.md` (the Decision
  recorded at T018). Commit, push and vault writes remain user-authorized. (constitution VI, VII)

## Dependencies

```text
A ──┐
    ├──► B ──► D ──► E ──► F
C ──┘
```

- **A ∥ C**: A edits `PlannerView.swift`, C edits the Home region of `HomeView.swift`.
- **A → B** is a hard gate. B removes Home's only routes into `TodayPlanDetailView`; if the
  generator, `生成今日购物清单` and `做好了` are not already in Planner, they become unreachable.
- **C → B** is file sequencing only; both edit `HomeView.swift`.
- **B → D**: D needs the context-line model and the canonical route. D also needs A's initial-path
  seed.
- **A, B → E** are the real gates; **D → E** is file sequencing.
- **T018 gates B, D and E** on the recorded Decision.
- No task is deferred to another feature. Slice E is inside this feature.

## Tests that change by design

| File | Change |
|---|---|
| `PlannerQuickCompleteUITests` (new) | Slice A quick-complete coverage |
| `PlannerWeeklyHostUITests` (new) | Slice A generator hosting and reveal coverage |
| `PlannerUITests` | retarget the today-plan-detail route case; rewrite the mutually-exclusive secondary-link case; drop the `生成今日购物清单` assertion aimed at the retired view |
| `HomeDashboardUITests` | remove the Home AI-refresh test; rewrite import reachability, eat-out stale-plan, recommendation label/id; remove the today-plan-detail reachability case in E; add `更多推荐` order assertion and Special Plan seeds |
| `RuntimeAccessibilityP1UITests` | regeneration assertions move to the browser; manual entry moves to Inventory; the today-plan completion layout contract moves to the Planner row |
| `ClipboardRecipeImportUITests`, `ManualEntryExpiryUITests`, `ReceiptCompactListUITests`, `ComponentMealUITests` | entry-path reroutes only |
| `HomePrimaryTaskTests` | context-line copy cases; Special Plan cases; exhaustive combination dimension |
| `PlannerMealCRUDTests` / `KitchenStoreTests` | completion parity added |
| `TodayPlanPersistenceTests` | E: retire the `removePlan(_ plan:)` caller |
| `PlannerMealDeleteUITests` | unchanged — must survive the `移出计划` string cleanup |
| `ProductionDesignLanguageUITests`, `Phase1DArtDirectionUITests`, `HomeVisualGateUITests` | unchanged (`home.today.plan.start` semantics do not move) |

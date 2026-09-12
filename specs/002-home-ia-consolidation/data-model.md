# Data Model: Home IA Consolidation

**Feature**: [spec.md](./spec.md) · **Created**: 2026-09-10 · **Reconciled**: 2026-09-11

Presentation-only. This feature adds no schema, no SwiftData model or migration, no sync DTO, no
persistence contract and no new store API for data. Everything below is either an existing type
read as it already is, or a presentation type whose shape changes so Home and Planner can render
the approved IA.

## 1. Existing types read, unchanged

| Type | What this feature reads | Not changed |
|---|---|---|
| `MealPlanItem` | `id`, `recipeID`, `recipeName`, `date`, `plannedServings`, `isCooked` | completion still happens only through the existing consumption confirmation followed by `KitchenStore.markPlanCooked` (FR-002). A bare `isCooked` flip is prohibited |
| `SpecialPlan` | `title`, `scheduledAt`, `peopleCount`, `dishes[].isCooked` | per-dish completion, no inventory consumption |
| `HomeDashboardSummary` | `allPlans`, `totalPlanCount`, `completedPlanCount`, `todayPlanState`, `attentionItems` | attention derivation, caps, ordering |
| `WeeklyMaterializationSummary` | `startDate` and `endDate` only, both start-of-day, `endDate` inclusive | receipt internals are never read by Planner (FR-004) |
| `ShoppingGenerationSource.todayPlans([MealPlanItem])` | reused unchanged as the source of the Planner-initiated generation (FR-003) | **explicitly NOT deleted.** Its only production construction site moves from the retired view to Planner, and several test sites keep using it (FR-017) |
| `KitchenStore.plans` | canonical schedule truth for ordinary meals | ownership unchanged |
| `KitchenStore.weeklyPlan` | resumable generator draft plus its materialization receipt | it is a draft and a receipt, never a second schedule; after retirement Home holds zero references to it (FR-019) |

Derived definitions used by the presentation layer, taken from the data as it already exists:

- **Special Plan today** — `Calendar.current.isDateInToday(scheduledAt)`. No meal slot is inferred
  from the time of day.
- **Special Plan completed** — `!dishes.isEmpty && dishes.allSatisfy(\.isCooked)`. A plan with no
  dishes is pending. A completed plan still holds today's context.
- **Primary Special Plan when several fall on today** — earliest `scheduledAt`, ties broken by
  array order.

## 2. Presentation types changed

### `HomePrimaryTaskKind`

Gains `.specialPlanToday`. Placed in the resolve chain between the dinner `eatOut` branch and
the ordinary-plan branch, so precedence reads `.mealPrep` → dinner `eatOut` →
`.specialPlanToday` → ordinary plan → `.quick` → recommendation (FR-012).

### `HomePrimaryTask`

| Member | Change |
|---|---|
| input | `resolve` gains today's Special Plans. Home does not read `SpecialPlan` anywhere today, so this is new input plumbing rather than a rewiring of existing state |
| primary plan id | the id of the Special Plan that won precedence, so the CTA can open Planner at exactly that plan (FR-013) |
| (none) | A further-same-day-events count was considered for the detail fragment `今天还有 N 场` and dropped by owner copy ruling — Home is not a same-day Special Plan schedule summary; later events stay reachable through Planner |
| `otherPlansLine: String?` | the suppressed-ordinary-plan context line: `今天另有 N 道计划` when any is pending, `今天另有 N 道计划 · 已完成` when all are complete, `nil` when none exist (FR-011). Rendered as static text — no chevron, no button trait, no navigation |
| `secondaryPlanCount` | keeps its meaning as a count; it no longer drives a link, because the link it used to drive is removed (FR-010) |

All existing `HomePrimaryTaskTests` cases carry no Special Plan and keep their results;
`testEveryCombinationProducesExactlyOnePrimaryTask` grows by the new input dimension (SC-007).

### `PlannerRoute`

Today: `specialPlan(UUID)`, `recipe(String)`, `plannedMeal(UUID)` (`PlannerView.swift` L13).
Gains navigation values for the two screens Planner now hosts:

- the shopping-generation screen, opened with `.todayPlans(kitchenStore.todayPlans)` (FR-003);
- the weekly generator, `WeeklyMenuPlannerView` with `onMaterialized` passed (FR-004).

These are navigation values, not data. They carry no plan ids for the weekly generator and Planner
never reconstructs any (FR-004).

### `PlannerView`

Gains an initial-path seed alongside the existing `weekStart` / `now` / `calendar` parameters
(`PlannerView.swift` L128), so Home's `查看聚餐` can present the same Planner sheet with that
plan's own detail already on the path and Home never hosts `SpecialPlanDetailView` (FR-013).

Week reveal after materialization reuses the existing private `reveal` convention: the week
containing the date, anchored by `PlannerProjection.startOfWeek(containing:calendar:)`
(`PlannerView.swift` L511, L60 of `PlannerProjection.swift`). For a materialized range the date is
`summary.startDate` (FR-005). No new week concept is introduced.

## 3. Removed

Production types, members and state removed by this feature:

| Removed | Where | Requirement |
|---|---|---|
| `SmartImportSheet`, `SmartImportRow`, `SmartImportRoute`, `SmartImportChildSheet`, `HomeSheet.smartImport` | `HomeView.swift` | FR-007 |
| `TodayPlanDetailView` in full, with its private members `TodayPlanSheet`, `planDetailButton`, `completionButton`, `weeklyPlanSubtitle`, `showToast` | `HomeView.swift` L2129–2351 | FR-016 |
| `isShowingTodayPlan` and its `.navigationDestination` | `HomeView.swift` L43, L254 | FR-016 |
| `TodayPlanSummaryCard.onViewPlan` and both call sites | `HomeView.swift` L636, L707 | FR-016 |
| `KitchenStore.markAllTodayCooked()` | `KitchenStore.swift` L1374 | FR-014, FR-017 |
| `KitchenStore.removePlan(_ plan:)` and its remaining test caller (`TodayPlanPersistenceTests.swift` L193) | `KitchenStore.swift` L1384 | FR-015, FR-017 |
| `KitchenStore.pendingTodayPlans` | `KitchenStore.swift` L1015 | FR-017 — **only if** the zero-reference proof shows it dead. Its call sites are four inside the retired view plus `markAllTodayCooked`; the proof runs before the deletion, never instead of it |

`KitchenStore.removePlan(id:)` with Undo (D-040) survives as the only ordinary-meal delete
contract (FR-015). `ShoppingGenerationSource.todayPlans` survives (FR-017).

## 4. Identifiers

There is **no central accessibility-identifier enum in this codebase**. Identifiers are inline
string literals at the point of use — Home uses `home.<area>.<element>[.<suffix>]`, Planner uses
`planner.<area>.<element>[.<suffix>]` (`PlannerView.swift` L173, L180, L353, L386, L396, L400,
L406). New identifiers follow the same inline convention; no registry is introduced.

| Removed | Added |
|---|---|
| `home.import.add.button` and every `home.import.*` row | — (capabilities move to the Recipes and Inventory tabs, §7 of the spec) |
| `home.recommendation.refresh` | — (the browser keeps `recommendation.regenerate.button`) |
| `home.recommendation.viewAll`, `home.recommendation.moreLink` | `home.recommendation.more` |
| `home.plan.secondaryLink` | `home.context.otherPlans` (static text) |
| `home.today.plan.viewAll` | — (no replacement; `home.planner.link` is the only planning destination) |
| `today.plan.complete.button` | Planner-side row completion ids |
| `today.plan.weeklyMenu.link` | Planner-side weekly-generator entry id |
| — | `home.context.specialPlan` (static text), `home.primary.specialPlan`, `home.specialPlan.open` |
| — | Planner-side ids for the row `做好了` paths, the `更多` overflow menu, `生成今日购物清单` and the weekly-generator entry, each written as `planner.<area>.<element>[.<suffix>]` with the per-meal `UUID` suffix the existing row actions already use |

Retained unchanged: `home.planner.link`, `home.primary.title` / `.detail`,
`home.today.plan.row.<recipeID>`, `home.today.plan.start`, `home.today.plan.viewRecipe`,
`home.meal.menu.toggle`, `home.recommendation.addToday`, `home.attention.*`,
`home.dayRhythm.row`, `home.clipboard.import.prompt` / `.ignore.button`, and every existing
`planner.*` id (FR-020).

**Hazard.** `planner.day.\(calendar.component(.day, from: group.day))` (`PlannerView.swift` L353)
is the day-of-month only, so it is unique within one displayed week and not across weeks. Any test
that asserts a revealed week after materialization must pin the week first — the identifier alone
cannot distinguish the 8th of one month from the 8th of another.

## 5. Slice map

| Slice | Model surface touched |
|---|---|
| A — Planner capability parity | `PlannerRoute` navigation values, Planner row actions, weekly-generator hosting, `PlannerView` initial-path seed |
| C — Home reduction | `SmartImport*` removal, `HomeSheet.smartImport`, discovery identifiers |
| B — canonical routing | `home.plan.secondaryLink` and `home.today.plan.viewAll` removal, `otherPlansLine` |
| D — Special Plan today | `HomePrimaryTaskKind.specialPlanToday`, Special Plan inputs, `home.specialPlan.open` |
| E — `TodayPlanDetailView` retirement | §3 removals with per-symbol zero-reference proofs |
| F — validation, reconciliation, seal | none |

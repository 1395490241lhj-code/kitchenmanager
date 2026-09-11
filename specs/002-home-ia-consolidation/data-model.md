# Data Model: Home IA Consolidation

No schema, SwiftData, sync or persistence change. Every entity below is presentation-only or an
existing type read as-is.

## Existing types read, unchanged

- **MealPlanItem** — `id`, `recipeID`, `recipeName`, `date`, `plannedServings`, `isCooked`.
  Completion continues through the consumption confirmation and `KitchenStore.markPlanCooked` only.
- **SpecialPlan** — `id`, `title`, `scheduledAt`, `peopleCount`, `dishes[].isCooked`. “Today” is
  `Calendar.current.isDateInToday(scheduledAt)`; “completed” is `!dishes.isEmpty && dishes.allSatisfy(\.isCooked)`.
- **HomeDashboardSummary** — `todayPlanState`, `totalPlanCount`, `completedPlanCount`, `allPlans`.
- **WeeklyMealPlan** / `kitchenStore.weeklyPlan` — untouched (gate = YES).
- **ShoppingGenerationSource.todayPlans([MealPlanItem])** — reused as-is.
- **KitchenStore** — no API added or removed (`markAllTodayCooked`, `removePlan(_:)` left in place, FR-013).

## Presentation types changed

- **HomePrimaryTaskKind** (+ `.specialPlanToday`).
- **HomePrimaryTask** — `resolve` gains today's Special Plans; new derived presentation:
  primary Special Plan id, `additionalSpecialPlanCount`, and `otherPlansLine: String?`
  (`今天另有 N 道计划` / `今天另有 N 道计划 · 已完成` / nil) computed from ordinary plan counts when
  the kind is `.mealPrepBoard`, `.eatOut` or `.specialPlanToday`. `secondaryPlanCount` keeps its
  meaning but no longer drives a link.
- **PlannerRoute** (+ `.shoppingToday`).
- **PlannerView.init** (+ `initialPath: [PlannerRoute] = []`).

## Removed

- `SmartImportSheet`, `SmartImportRow`, `SmartImportRoute`, `SmartImportChildSheet`, `HomeSheet.smartImport`.
- From `TodayPlanDetailView`: `TodayPlanSheet.cookAll`, `isShowingShoppingGeneration`, `planPendingRemoval` + alert.

## Identifiers

| Removed | Added / renamed |
|---|---|
| `home.import.add.button`, `home.import.*` | — |
| `home.recommendation.refresh` | — (browser keeps `recommendation.regenerate.button`) |
| `home.recommendation.viewAll`, `home.recommendation.moreLink` | `home.recommendation.more` |
| `home.plan.secondaryLink` | `home.context.otherPlans` (static text), `home.context.specialPlan` (static text) |
| — (retained, interim) `home.today.plan.viewAll`, `today.plan.complete.button`, `today.plan.weeklyMenu.link` | — |
| — | `planner.meal.complete.<id>` (swipe), `planner.meal.completeMenu.<id>` (context), `planner.more.menu`, `planner.more.shoppingToday` |
| — | `home.primary.specialPlan`, `home.specialPlan.open` |


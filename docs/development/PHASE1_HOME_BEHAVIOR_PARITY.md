# Phase 1A — Home behavior parity checklist

Baseline: `8d47132`, captured from `HomeView.swift` before the Phase 1
presentation change. Every row is something a user can reach on Home today.
The redesign is presentation-only, so each row must still be reachable and
still do the same thing afterwards.

This file is a working checklist for one rollout, not a permanent contract.
Delete it once Phase 1 is sealed and the behavior lives in tests.

## 1. Primary task resolution

`HomePrimaryTask.resolve` decides which single primary region renders.
Precedence must not change:

| Order | Kind | Condition |
| --- | --- | --- |
| 1 | `.mealPrepBoard` | day type is 备餐日 |
| 2 | `.eatOut` | dinner intent is 外食 |
| 3 | `.planExecution` | a Today Plan exists |
| 4 | `.quickMeal` | day type is 快手日 |
| 5 | `.recipeRecommendation` | otherwise |

## 2. Actions reachable from Home

| Action | Identifier | Destination / effect |
| --- | --- | --- |
| Import & add | `home.import.add.button` | `SmartImportSheet` |
| Open day rhythm | `home.dayRhythm.row` | `TodayRhythmSheet` |
| Start / view today's dish | `home.today.plan.start` | `RecipeDetailView(recipe:todayPlan:)` |
| Open a specific planned dish | `home.today.plan.row.<recipeID>` | same detail view |
| Open today's plan | `home.today.plan.viewAll` | `TodayPlanDetailView` |
| Add recommendation to today | `home.recommendation.addToday` | `KitchenStore.addPlan` + toast |
| View recommended recipe | `home.recommendation.viewRecipe` | `RecipeDetailView(recipe:)` |
| Regenerate recommendations | `home.recommendation.refresh` | `HomeRecommendationStore.generateNewRecommendations` |
| Browse all recommendations | `home.recommendation.viewAll` | `RecipeRecommendationBrowserView` |
| Add one more dish (execution mode) | `home.recommendation.moreLink` | `RecipeRecommendationBrowserView` |
| Remaining plans link | `home.plan.secondaryLink` | `TodayPlanDetailView` |
| Meal planner | `home.planner.link` | `PlannerView` sheet |
| Meal-prep board add | `home.mealPrep.add` | `PreparedComponentsView` |
| Quick-meal rotate | quick-meal section | `QuickMealRotation.nextIndex` |
| Use a prepared portion | quick-meal section | `KitchenStore.consumePreparedPortion` |
| Attention row (expired) | `home.attention.expired.<name>` | Inventory filtered to expired |
| Attention row (expiring) | `home.attention.expiring.<name>` | Inventory filtered to expiring |
| Attention row (low stock) | `home.attention.lowStock.<name>` | Inventory filtered to low stock |
| Attention row (prepared) | `home.attention.prepared.<name>` | `PreparedComponentsView` |
| Attention row (awaiting stock-in) | attention list | shopping stock-in |
| Attention row (pending shopping) | attention list | shopping tab |
| Attention overflow | `home.attention.overflow` | Inventory, unfiltered |
| Clipboard import prompt | `home.clipboard.import.prompt` | `ImportRecipeView` |
| Clipboard ignore | `home.clipboard.ignore.button` | dismiss prompt |
| Module issue rows | `home.issue.inventory` / `home.issue.shopping` | inventory / shopping |

## 3. States that must still render

- planned meal (one dish, several dishes, overflow beyond 3)
- recommendation-first empty plan, including loading / empty / error / notice
- sample-recipe fallback notice
- eat-out tonight
- quick-meal day
- meal-prep day
- attention list present, empty (`home.attention.healthy`), and over cap
- outgoing carryover footer
- account restoring
- household name shown / hidden

## 4. Behavior that must not change

- recommendation engine calls and their inputs
- `addPlan` semantics, including the already-added warning path
- clipboard detection lifecycle across scene phase and sheets
- shared-import queue handoff and snooze
- day-rhythm and meal-portion refresh on appear and on becoming active
- toast wording and style
- navigation title `今天`, inline at accessibility sizes

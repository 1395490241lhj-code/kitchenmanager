# Quickstart: Weekly Menu materialization validation

Prefix:

```bash
XB='xcodebuild test -project "ios-native/Kitchen Manager/Kitchen Manager.xcodeproj" -scheme KitchenManager -destination "platform=iOS Simulator,name=iPhone 17 Pro"'
```

## Slice A — store contracts

```bash
$XB -only-testing:KitchenManagerTests/PlannerMealCRUDTests \
    -only-testing:KitchenManagerTests/TodayPlanPersistenceTests \
    -only-testing:KitchenManagerTests/WeeklyPlanPersistenceTests
```

Must include: caller ids preserved; dates normalized; append order; duplicate `(recipeID, date)`
accepted; `duplicateIDsInBatch` / `idsAlreadyPresent` / `empty` rejected with no write;
`FailingTodayPlanPersistence` → `.persistenceFailed` with `plans` unchanged; `commitWeeklyPlan`
returns `false` and publishes nothing on a failing weekly persistence; receipt round-trip and
legacy payload decode.

## Slice B — materializer and state machine

```bash
$XB -only-testing:KitchenManagerTests/WeeklyMenuMaterializationTests \
    -only-testing:KitchenManagerTests/WeeklyMenuBaseYieldCompatibilityTests \
    -only-testing:KitchenManagerTests/PlannerProjectionTests
```

Must include: `dayIndex 0` = today, a Sunday→Monday span, a DST day; `.local` id reuse; `.ai` creates
a user recipe under the draft id with `baseServings == nil`; a vanished `.local` recipe refuses before
any write; `plannedServings == nil`; pending receipt written before the batch; status classification
for all five cases; a materialized receipt is not re-verified after a Planner deletion; retry from
pending reuses ids and creates exactly one set; recipe residue after a plan failure is present and
reused; regeneration clears the receipt.

## Slice R — restock migration

```bash
$XB -only-testing:KitchenManagerTests/RestockSuggestionEngineTests \
    -only-testing:KitchenManagerTests/ShoppingScalingTests \
    -only-testing:KitchenManagerTests/QuickMealPreparedUsageTests \
    -only-testing:KitchenManagerTests/PreparedComponentTests
```

Must include: an unmaterialized draft alone produces no plan-derived suggestion; canonical pending
meals inside the horizon do, with reason `用餐计划需要`; cooked meals and meals outside the horizon are
excluded; `ShoppingScalingTests.testWeeklyHouseholdHeadcountNeverScales` still passes (the in-flow
`.weeklyPlan` source survives).

## Slices C/D — UI

```bash
$XB -only-testing:KitchenManagerUITests/WeeklyMenuMaterializationUITests \
    -only-testing:KitchenManagerUITests/PlannerUITests \
    -only-testing:KitchenManagerUITests/HomeDashboardUITests \
    -only-testing:KitchenManagerUITests/RuntimeAccessibilityP1UITests
```

Manual: materialize → `已加入用餐计划` → Home `用餐计划` shows the dated menu; today's dishes appear on
Home; relaunch keeps both; the reopened result is frozen; a double tap adds nothing; the collision
seed shows one confirmation and existing meals survive; the plan-failure fixture shows no success
copy and retries into exactly one set; the pending-receipt fixture resumes; no manual add-today
action exists; an empty draft disables the CTA.

## Reference gate

```bash
rg -n '本周菜单|本周概览|保存本周计划|已保存本周计划|本周计划需要|生成本周菜单|生成本周购物清单|重新生成整周|把今天加入计划|加入今日计划|查看已保存的本周计划|复制为下一周|删除本周计划|已在今天|本周计划中没有安排菜品|todaysWeeklyMeals' \
   "ios-native/Kitchen Manager/KitchenManager" && echo "STALE" || echo "clean"
```

Expected `clean` once Slice R lands, apart from the by-design residue T018 records: the Recipes
tab's own `加入今日计划` (`RecipeViews.swift`, `AddRecipeViews.swift`) and the Shopping regression
fixture's historical `本周菜单` seed. Note `today.plan.weeklyMenu.link` and its `HomeView.swift` row copy are **not** in
this gate: 003 does not edit Home (FR-017).

## Final gate

```bash
$XB -parallel-testing-enabled NO
npm run ios:release:check
```

Compare against the documented Settings baseline red only.


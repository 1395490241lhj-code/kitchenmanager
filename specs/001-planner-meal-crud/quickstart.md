# Quickstart: Planner ordinary-meal CRUD validation

## Prerequisites

- macOS with Xcode and the iOS simulator used by existing gates.
- Working tree on the feature branch, clean before starting.

## Automated validation

Focused unit suites (store contracts, projection, persistence, servings,
cooking):

```bash
xcodebuild test -project "ios-native/Kitchen Manager/KitchenManager.xcodeproj" \
  -scheme KitchenManager -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KitchenManagerTests/PlannerMealCRUDTests \
  -only-testing:KitchenManagerTests/KitchenStoreTests \
  -only-testing:KitchenManagerTests/PlannerProjectionTests \
  -only-testing:KitchenManagerTests/TodayPlanPersistenceTests \
  -only-testing:KitchenManagerTests/PlannedServingsTests \
  -only-testing:KitchenManagerTests/RecipeCookingSupportTests
```

Focused UI suites (create / edit / delete-undo / Planner regression):

```bash
xcodebuild test -project "ios-native/Kitchen Manager/KitchenManager.xcodeproj" \
  -scheme KitchenManager -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KitchenManagerUITests/PlannerMealCreateUITests \
  -only-testing:KitchenManagerUITests/PlannerMealEditUITests \
  -only-testing:KitchenManagerUITests/PlannerMealDeleteUITests \
  -only-testing:KitchenManagerUITests/PlannerUITests \
  -only-testing:KitchenManagerUITests/PlannerRegressionUITests
```

Whitespace gate and Debug build:

```bash
git diff --check origin/main..HEAD
xcodebuild build -project "ios-native/Kitchen Manager/KitchenManager.xcodeproj" \
  -scheme KitchenManager -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Manual scenarios (behavioral validation, not a design pass)

1. Swipe an ordinary meal row from the trailing edge → destructive `移出计划`
   action → row disappears immediately; toast `已移出「<菜名>」` appears with
   `撤销`.
2. Tap `撤销` → the identical meal is back on its original day and position.
3. Delete a second meal while the first toast is active → toast/token replaced;
   the first deletion stays final.
4. Delete a cooked/consumed meal → allowed; consumption records unchanged;
   undo restores the linkage.
5. Simulate a persistence failure (existing test hooks) → delete keeps the row
   and shows an error, no success toast; undo keeps the row absent and shows an
   error.
6. Delete a meal, then navigate to its stale detail destination →
   `这一餐不存在` fallback, no crash.
7. VoiceOver: `移出计划` discoverable on the row, undo control explicitly
   labeled, announcement survives the toast lifetime.

## Expected outcomes

- All focused suites pass; `git diff --check` clean; Debug build succeeds.
- No visible change beyond the native delete/undo feedback.

# Quickstart: Home IA Consolidation validation

## Prerequisites

- Xcode + iPhone 17 Pro simulator, parallel testing disabled for the full run.
- Working tree on `codex/002-home-ia-consolidation`.
- Slices B/D: D-041 recorded in the vault first (FR-016).

Common prefix:

```bash
XB='xcodebuild test -project "ios-native/Kitchen Manager/Kitchen Manager.xcodeproj" -scheme KitchenManager -destination "platform=iOS Simulator,name=iPhone 17 Pro"'
```

## Slice A — Planner parity

```bash
$XB -only-testing:KitchenManagerTests/PlannerMealCRUDTests \
    -only-testing:KitchenManagerTests/KitchenStoreTests \
    -only-testing:KitchenManagerUITests/PlannerQuickCompleteUITests \
    -only-testing:KitchenManagerUITests/PlannerUITests
```

Manual: Planner today row → leading swipe shows `做好了` + `编辑`; long-press shows `做好了`;
VoiceOver rotor offers `做好了`; confirm → row `已完成`; cooked row offers none. `更多` menu shows
only `生成今日购物清单`; its output matches the retired entry for the same seed. Check the two
leading actions at AXXXL; if they are not usable, report (FR-001) instead of changing the pattern.

## Slice C — Home reduction

```bash
$XB -only-testing:KitchenManagerUITests/HomeDashboardUITests \
    -only-testing:KitchenManagerUITests/ClipboardRecipeImportUITests \
    -only-testing:KitchenManagerUITests/ManualEntryExpiryUITests \
    -only-testing:KitchenManagerUITests/ReceiptCompactListUITests \
    -only-testing:KitchenManagerUITests/RuntimeAccessibilityP1UITests \
    -only-testing:KitchenManagerUITests/ComponentMealUITests \
    -only-testing:KitchenManagerUITests/ProductionDesignLanguageUITests
```

Manual: Home toolbar empty; `更多推荐` in both modes, above `用餐计划` in execution mode; browser
regenerate works.

## Slice B — plan-link canonicalization + TodayPlanDetail reduction

```bash
$XB -only-testing:KitchenManagerUITests/HomeDashboardUITests \
    -only-testing:KitchenManagerUITests/PlannerUITests \
    -only-testing:KitchenManagerUITests/RuntimeAccessibilityP1UITests \
    -only-testing:KitchenManagerTests/HomePrimaryTaskTests
```

Manual: eat-out seed shows the static line `今天另有 N 道计划` (no chevron, not a button) and one
`用餐计划`; `今天的计划` shows rows + `做好了` + generator link only.

## Slice D — Special Plan today

```bash
$XB -only-testing:KitchenManagerTests/HomePrimaryTaskTests \
    -only-testing:KitchenManagerUITests/HomeDashboardUITests
```

## Reference gate (after B, C)

```bash
rg -n 'SmartImportSheet|home\.import\.|home\.recommendation\.(refresh|viewAll|moreLink)|home\.plan\.secondaryLink|全部做完|移出计划？|今日计划已全部完成' \
   "ios-native/Kitchen Manager" && echo "STALE REFERENCES" || echo "clean"
```

Expected: `clean`. (`TodayPlanDetailView`, `today.plan.*`, `markAllTodayCooked` and `removePlan(plan)` are
expected to remain until the materialization feature.)

## Final gate

```bash
$XB -parallel-testing-enabled NO
npm run ios:release:check
```

Compare against the documented Settings baseline red only.


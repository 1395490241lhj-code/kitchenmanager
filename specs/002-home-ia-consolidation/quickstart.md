# Quickstart: Home IA Consolidation validation

**Feature**: [spec.md](./spec.md) · **Created**: 2026-09-10 · **Reconciled**: 2026-09-11

Per-slice commands and manual checks. Slice order is A and C in parallel, then B, then D, then E,
then F.

## Prerequisites

- Xcode with an `iPhone 17 Pro` simulator available.
- Working tree on `codex/002-home-ia-consolidation`.
- **Slices B, D and E require the Home IA Decision to be recorded in canonical memory first**
  (FR-022) — the one that supersedes D-031 decisions 3–4 and narrows decision 5. It was
  assigned and recorded as D-042 after re-reading `Decisions.md`; the unnumbered draft above
  is historical. Slices A and C do not depend on it.
- The full run disables parallel testing; focused runs do not need to.

Common prefix used by every command below:

```bash
XB='xcodebuild test -project "ios-native/Kitchen Manager/Kitchen Manager.xcodeproj" -scheme KitchenManager -destination "platform=iOS Simulator,name=iPhone 17 Pro"'
```

## Slice A — Planner capability parity

New test files this slice adds: `KitchenManagerUITests/PlannerQuickCompleteUITests.swift` and
`KitchenManagerUITests/PlannerWeeklyHostUITests.swift`.

```bash
$XB -only-testing:KitchenManagerTests/PlannerMealCRUDTests \
    -only-testing:KitchenManagerTests/KitchenStoreTests \
    -only-testing:KitchenManagerTests/WeeklyMenuMaterializationTests \
    -only-testing:KitchenManagerTests/PlannerProjectionTests \
    -only-testing:KitchenManagerUITests/PlannerQuickCompleteUITests \
    -only-testing:KitchenManagerUITests/PlannerWeeklyHostUITests \
    -only-testing:KitchenManagerUITests/PlannerUITests \
    -only-testing:KitchenManagerUITests/PlannerMealEditUITests \
    -only-testing:KitchenManagerUITests/PlannerMealDeleteUITests \
    -only-testing:KitchenManagerUITests/WeeklyMenuMaterializationUITests
```

Manual checks:

- Leading swipe on a pending ordinary meal offers `做好了` beside `编辑`; the context menu
  offers `做好了`; VoiceOver exposes `做好了` as a custom action. Confirming runs the existing
  consumption confirmation and leaves the row `已完成` (FR-001, FR-002).
- A cooked row offers `做好了` on none of the three paths.
- A plan already covered by a consumption record deducts nothing a second time.
- **AXXXL density check for FR-001**: set the simulator to accessibility extra-extra-extra-large
  and swipe the leading edge. Two leading actions must remain reachable and distinguishable. If
  they are not, Slice A reports the density finding instead of inventing custom row controls.
- VoiceOver pass over one pending row, one cooked row and the `更多` menu.
- `更多` menu offers `生成今日购物清单` and nothing planning-unrelated; the generated list for a
  given seed matches what the retired entry produced for the same seed (FR-003).
- Weekly generator opens from Planner, `加入用餐计划` materializes, Planner returns to the week
  list revealing the week containing `startDate`, and a cancelled or failed attempt reveals
  nothing (FR-004, FR-005).
- The Planner-hosted generator entry does not describe an unmaterialized draft as scheduled
  (FR-006).

## Slice C — Home reduction

```bash
$XB -only-testing:KitchenManagerUITests/HomeDashboardUITests \
    -only-testing:KitchenManagerUITests/HomeVisualGateUITests \
    -only-testing:KitchenManagerUITests/ClipboardRecipeImportUITests \
    -only-testing:KitchenManagerUITests/ManualEntryExpiryUITests \
    -only-testing:KitchenManagerUITests/ReceiptCompactListUITests \
    -only-testing:KitchenManagerUITests/ComponentMealUITests \
    -only-testing:KitchenManagerUITests/ProductionDesignLanguageUITests \
    -only-testing:KitchenManagerUITests/Phase1DArtDirectionUITests \
    -only-testing:KitchenManagerUITests/RuntimeAccessibilityP1UITests
```

Manual checks:

- Home toolbar carries no `+` (FR-007). Each former row is reachable on its owning tab: Recipes
  `+` → `从链接导入` and `手动添加`; Inventory `添加食材` and
  `更多食材操作` → `扫描购物小票` (SC-002).
- Exactly one discovery control, `更多推荐`, in decision mode (card action) and execution mode
  (link row); `查看全部` and `想再加一道` are gone (FR-008).
- In execution mode `更多推荐` sits above `用餐计划`.
- `AI 换几道` is absent from Home; regeneration still works in the recommendation browser with
  its generating / error / notice states (FR-009).
- Home still shows store-level recommendation load error, notice and sample-fallback states.
- VoiceOver pass over decision mode and execution mode.

## Slice B — canonical routing

Requires the recorded Decision (see Prerequisites).

```bash
$XB -only-testing:KitchenManagerTests/HomePrimaryTaskTests \
    -only-testing:KitchenManagerTests/HomeDashboardSummaryTests \
    -only-testing:KitchenManagerUITests/HomeDashboardUITests \
    -only-testing:KitchenManagerUITests/PlannerUITests \
    -only-testing:KitchenManagerUITests/RuntimeAccessibilityP1UITests
```

Manual checks:

- Every Home state in the §10 matrix shows exactly one planning row, `用餐计划` (FR-010, SC-001).
- The eat-out seed and the prep seed show the suppressed-plan line as static text —
  `今天另有 N 道计划`, or `今天另有 N 道计划 · 已完成` when all are complete, and no line when
  none exist. No chevron, no button trait, no navigation (FR-011).
- `今日计划已全部完成` appears nowhere.
- VoiceOver reads the context line as text, not as a button.
- `用餐计划` opens Planner as a sheet on the current week with today marked.
- Section order `Today Context → Primary Task → Needs Attention` is unchanged and leaf
  identifiers stay on the controls rather than their containers (FR-021).

## Slice D — Special Plan today

Requires the recorded Decision (see Prerequisites).

```bash
$XB -only-testing:KitchenManagerTests/HomePrimaryTaskTests \
    -only-testing:KitchenManagerTests/HomeDashboardSummaryTests \
    -only-testing:KitchenManagerUITests/HomeDashboardUITests \
    -only-testing:KitchenManagerUITests/PlannerUITests
```

Manual checks, one per §9 row:

- Ordinary day with one Special Plan today → primary task names the plan with time and headcount
  and offers `查看聚餐`, which opens Planner at that plan's own detail (FR-013).
- Several Special Plans today → earliest is primary; its detail states time and headcount only
  (owner copy ruling: no same-day count on Home).
- All dishes cooked → the plan stays primary with `已完成` as a suffix on the time/guest detail.
- Prep day or eat-out dinner with a Special Plan → primary task unchanged, Special Plan reduced to
  one non-interactive context line.
- Ordinary plans present on a Special Plan day → the suppressed-plan line only.
- A Special Plan with zero dishes is pending, not completed. 00:00 and 23:59 both count as today.
- Every existing precedence combination without a Special Plan is unchanged (SC-007).
- VoiceOver pass over the Special Plan primary task and its CTA.

## Slice E — `TodayPlanDetailView` retirement

Requires the recorded Decision (see Prerequisites). Run the zero-reference proof **before**
deleting each symbol, and record the output per symbol (FR-017).

```bash
cd "ios-native/Kitchen Manager"

rg -n 'TodayPlanDetailView' .
rg -n 'markAllTodayCooked' .
rg -n 'removePlan\(' .
rg -n 'pendingTodayPlans' .
rg -n 'today\.plan\.' .
rg -n 'home\.today\.plan\.viewAll' .
rg -n 'home\.plan\.secondaryLink' .
rg -n 'UITEST_SEED_ACCESSIBILITY_TODAY_PLAN' .
```

Reading the proof:

- `removePlan(` also matches D-040's `removePlan(id:)` with Undo, which **must survive**
  (FR-015). Only `removePlan(_ plan:)` and its `TodayPlanPersistenceTests.swift` L193 caller go.
- `pendingTodayPlans` is deleted **only if** the proof shows no remaining caller once the view
  and `markAllTodayCooked()` are gone. A symbol that is not proven dead stays (FR-017).
- `ShoppingGenerationSource.todayPlans` must still resolve to the Planner entry and its test
  sites — do not let a `todayPlans` grep sweep it away (FR-017, SC-011).
- **`移出计划` is not a unique string.** A bare `rg -n '移出计划'` also matches
  `KitchenManagerUITests/PlannerMealDeleteUITests.swift` lines 51 and 184, which assert Planner's
  own D-040 delete and **must survive** (FR-018). Only the retired view's context-menu item and
  its `移出计划？` alert are removed.
- Tests reaching the view by its `今天的计划` navigation title — `HomeDashboardUITests.swift`
  L263 and L386, `PlannerUITests.swift` L138–149, `RuntimeAccessibilityP1UITests.swift` L19–38 —
  and the `UITEST_SEED_ACCESSIBILITY_TODAY_PLAN` fixture (`ContentView.swift` L731) are
  retargeted at the Planner row or removed, never left asserting a deleted surface (FR-018).

Stale-reference gate, expected to print `clean`:

```bash
rg -n 'SmartImportSheet|SmartImportRow|home\.import\.|home\.recommendation\.(refresh|viewAll|moreLink)|home\.plan\.secondaryLink|home\.today\.plan\.viewAll|today\.plan\.|TodayPlanDetailView|全部做完|今日计划已全部完成|移出计划？' \
   "ios-native/Kitchen Manager" && echo "STALE REFERENCES" || echo "clean"

rg -n 'weeklyPlan' "ios-native/Kitchen Manager/KitchenManager/HomeView.swift" && echo "HOME STILL READS weeklyPlan" || echo "clean"
```

Then re-run the affected suites:

```bash
$XB -only-testing:KitchenManagerTests/TodayPlanPersistenceTests \
    -only-testing:KitchenManagerTests/KitchenStoreTests \
    -only-testing:KitchenManagerTests/HomePrimaryTaskTests \
    -only-testing:KitchenManagerUITests/HomeDashboardUITests \
    -only-testing:KitchenManagerUITests/PlannerUITests \
    -only-testing:KitchenManagerUITests/PlannerRegressionUITests \
    -only-testing:KitchenManagerUITests/PlannerMealDeleteUITests \
    -only-testing:KitchenManagerUITests/RuntimeAccessibilityP1UITests
```

Manual checks: no Home state reaches a second plan-management surface; the weekly generator is
reachable from Planner and nowhere else in production (SC-008, User Story 6 scenario 3).

## Slice F — full validation, reconciliation, seal

```bash
$XB -parallel-testing-enabled NO
npm run ios:release:check
```

Gate: the full native suite reports **no new failures beyond the documented baseline reds**
(SC-012). Compare pass/fail counts against the recorded baseline before calling the run green;
a documented baseline red is not a new failure, and a new failure is not a baseline red.

Manual checks for the seal:

- Walk the §10 state matrix once on device or simulator: one planning row, at most one prominent
  CTA, at most one discovery entry, in every state.
- Re-run the Slice A AXXXL and VoiceOver passes on the final build.
- Confirm the `rg` gates above still print `clean`.

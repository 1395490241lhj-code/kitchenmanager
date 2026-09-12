# Feature Specification: Home IA Consolidation

**Feature Branch**: `codex/002-home-ia-consolidation`

**Created**: 2026-09-10 · **Reconciled**: 2026-09-11

**Status**: Sealed for planning, reconciled onto `main` = `a7b7d8f` after weekly-menu
materialization shipped. No product code has been changed by this feature; every implementation
task below is unstarted.

**Input**: Owner-approved Home IA direction (2026-09-10 clarifications), re-derived on 2026-09-11
against shipped Planner ordinary-meal CRUD (D-040) and shipped weekly-menu materialization
(D-041). Audit evidence re-read at `eb894a8`.

## Overview

Home answers one job: **“我今天吃什么，以及现在下一步该做什么？”** Planner is the single canonical
saved-meal planning surface, so Home no longer needs its own add/import hub, its own AI launcher,
a second discovery wording, or a second planning destination. This feature **reduces concepts and
duplicate entry points on native iOS Home**; it is not a visual redesign.

Bounded change delivered by this feature:

1. Give Planner the ordinary-meal capabilities that only `TodayPlanDetailView` has today:
   per-meal `做好了`, initiating `生成今日购物清单`, and hosting the AI weekly generator.
2. Remove `全部做完` (not migrated) and the legacy alert-delete (D-040 delete + Undo is the
   only delete).
3. Retire the Home global top-right `+`.
4. Collapse Home's discovery wording (`查看全部`, `想再加一道`) into one entry, `更多推荐`, and
   remove `AI 换几道` from Home (the recommendation browser already owns regeneration).
5. Canonicalize Home to exactly one planning-management destination, `用餐计划` → Planner, and
   replace the `今日仍有 N 道计划` link with one non-interactive factual context line.
6. Add Special Plan today to `HomePrimaryTask` precedence.
7. **Delete `TodayPlanDetailView`**, its route, its identifiers and the code that only it kept
   alive, once every retained capability above has an owner.

## Clarifications

### Session 2026-09-11 — governing owner decisions (current)

These five decisions govern this specification. Where they conflict with the 2026-09-10 session
below, these win and the earlier answer is marked superseded in place.

- **GD-1 — the weekly-materialization prerequisite is satisfied.** D-041 shipped on
  `main` = `a7b7d8f`: `加入用餐计划` materializes a generated menu into canonical
  `KitchenStore.plans`, `KitchenStore.weeklyPlan` is a resumable draft plus its recovery
  receipt rather than schedule truth, `WeeklyMenuPlannerView` exposes `onMaterialized`, and
  `WeeklyMaterializationSummary` carries the covered `startDate` / `endDate`. Planner can
  therefore host the generator truthfully. Weekly materialization is **not** a blocker for this
  feature and is not future work.
- **GD-2 — `TodayPlanDetailView` retirement belongs to this feature.** Classification **B**:
  removable inside 002 after internal capability parity and re-homing. It is not unowned, not out
  of scope, not deferred to 003, and not deferred to any later feature. No additional feature is
  needed for the retirement.
- **GD-3 — final Home has one planning route.** The final planning-management destination is
  `用餐计划` → Planner. The final feature contract may not retain `今天的计划` navigation,
  `今日仍有 N 道计划` navigation, a `TodayPlanDetailView` route, or any parallel planning
  destination. Intermediate slices may temporarily keep an old route while parity is being built;
  the delivered feature may not.
- **GD-4 — the Decision number is assigned at write time.** D-041 belongs to 003. This feature
  does not own or reserve D-042. Every reference is to the *next available Home IA Decision
  (currently expected D-042; assigned only after re-reading `Decisions.md` at write time)*, and
  the draft in `research.md` stays unnumbered until vault write-back.
- **GD-5 — the approved Home IA is unchanged.** Final semantic hierarchy: Today Context → one
  Primary Task → `更多推荐` → `用餐计划` → `需要处理` → factual/status content where
  justified. Retire the Home toolbar `+`, the duplicate `查看全部` / `想再加一道` discovery
  labels, the Home-level `AI 换几道`, and the parallel planning routes. Special Plan today
  precedence: `.mealPrep` > dinner `eatOut` > Special Plan today > ordinary plan > `.quick` >
  recommendation. Suppressed ordinary-plan context is factual only — `今天另有 N 道计划` when some
  are incomplete, `今天另有 N 道计划 · 已完成` when all are complete, no line when none exist, and
  no tap, chevron or button trait in any case.

### Session 2026-09-10 (historical — kept for provenance)

Answers recorded before weekly materialization shipped. Statements marked **SUPERSEDED** were
correct when made and are no longer active; they are retained because the reasoning behind the
surviving decisions depends on them.

- Q: Is Planner the single canonical saved-meal planning surface, with Home exposing exactly one
  planning-management destination, and do the conflicting portions of D-031 get a new Decision?
  → A: Yes (OD-1). A new Decision supersedes only the conflicting portions of D-031 (decisions
  3–4; decision 5 narrowed for Special Plan today) before Slices B/D/E implement. D-031 history is
  not rewritten. **SUPERSEDED in part (GD-4)**: the number quoted that day was D-041, which 003
  has since taken; the Decision is now the next available one.
- Q: Is `全部做完` migrated or removed? → A: Removed (OD-2). Per-meal completion is the truthful
  model; bulk completion is convenience only, weakens the meal↔consumption relationship, and no
  persisted product state depends on it. **Still active.** `markAllTodayCooked()` goes dead and is
  now cleaned up by this feature's retirement slice (GD-2), not a later one.
- Q: Who owns shopping generation from today's plans? → A: Planner owns the **initiating**
  action `生成今日购物清单`, because the input is the meal plan (OD-3). Shopping / 买菜 owns the
  resulting list and all subsequent management. Not on Home; no shopping-management surface inside
  Planner. **Still active.**
- Q: How are suppressed ordinary plans shown when another primary task wins? → A: At most one
  **non-interactive** factual context line — no chevron, no button treatment, not a second
  planning entry; count/state derived from the ordinary plans (OD-4). **Still active.**
- Q: What copy does that line use? → A: (OD-5) `今天另有 N 道计划` when some are pending;
  `今天另有 N 道计划 · 已完成` when all are complete; no line when none exist. The generic
  `今日计划已全部完成` is rejected because a pending Special Plan makes it false. **Still active.**
- Q: Which comes first on Home, `更多推荐` or `用餐计划`? → A: `更多推荐` above `用餐计划`
  (OD-6), because `更多推荐` is contextual discovery tied to the current meal task and
  `用餐计划` is the broader canonical management destination. Home-scoped rationale, not a
  global visual rule. **Still active.**
- Q: Would a user entering the AI weekly generator from Planner believe Save scheduled meals into
  Planner? → A: Yes, therefore the generator is not moved into Planner and full retirement is
  blocked by the future prerequisite *AI weekly-plan materialization*. **SUPERSEDED (GD-1)**: the
  belief is now correct by construction — `加入用餐计划` really does write canonical meals — so the
  generator moves into Planner and nothing is blocked.
- Q: Per-meal quick completion semantics and placement? → A: Keep `做好了`. Semantics: same
  `MealPlanItem` → existing consumption confirmation → existing consumption handling → mark that
  exact plan cooked; never a bare `isCooked` flip. Placement to evaluate in Slice A: leading
  swipe `做好了` + `编辑`, plus context menu `做好了`, plus VoiceOver custom action; no
  permanent per-row button. Report in Slice A if native swipe density makes this inappropriate.
  **Still active.**
- Q: Special Plan today precedence? → A: Unchanged: mealPrep > dinner eatOut > Special Plan today
  > ordinary plan > quick > recommendation; earliest `scheduledAt` is primary; no slot inferred
  from time; a completed Special Plan may remain today's context. **Still active.**

## 1. Current Home action map (re-audited on `eb894a8`)

Source: `KitchenManager/HomeView.swift`, `HomePrimaryTask.swift`, `HomeDashboardSummary.swift`,
`PlannerView.swift`, `WeeklyMenuPlanner.swift`, `KitchenStore.swift`. “Job” names the user job;
“Overlap” names another visible control that serves the same job.

| Label | Identifier | Visible when | Action / destination | Job | Overlap |
|---|---|---|---|---|---|
| date row (`调整今天安排`) | `home.dayRhythm.row` | always | sheet `TodayRhythmSheet` | context | — |
| `+` `导入与添加` (toolbar, L246) | `home.import.add.button` | always | sheet `SmartImportSheet` (4 rows) | add/import hub | Recipes `+` menu; Inventory `添加食材` + `更多食材操作` |
| ↳ `从小红书导入菜谱` | `home.import.recipe.xiaohongshu` | in sheet | push `ImportRecipeView` | recipe import | Recipes `+ → 从链接导入`; clipboard prompt; share extension |
| ↳ `手动创建菜谱` | `home.import.recipe.manual` | in sheet | push `ManualRecipeView` | recipe create | Recipes `+ → 手动添加` |
| ↳ `扫描购物小票` | `home.import.food.receipt` | in sheet | sheet `RecordFoodSheet(.receipt)` | receipt scan | Inventory `更多食材操作 → 扫描购物小票` |
| ↳ `手动添加食材` | `home.import.food.manual` | in sheet | sheet `RecordFoodSheet(.manual)` | ingredient add | Inventory `添加食材` |
| primary heading | `home.primary.title` / `.detail` | always | none | state | — |
| hero row / expanded rows | `home.today.plan.row.<recipeID>` | `.planExecution` | push `RecipeDetailView(recipe, plan)` | execution review | — |
| `开始做饭` | `home.today.plan.start` | `.planExecution`, lead pending | `cookingFlow` → consumption confirm → `markPlanCooked` | execution | RecipeDetail `开始烹饪` (same flow, by design) |
| `查看菜谱` | `home.today.plan.viewRecipe` / `.start` | `.planExecution` | push `RecipeDetailView` | execution review | hero row |
| `今天的计划 ›` (L1175 cooked, L1196 pending) | `home.today.plan.viewAll` | `.planExecution` | push `TodayPlanDetailView` | **plan management** | `用餐计划` |
| `另有 N 道` | `home.meal.menu.toggle` | `.planExecution`, 3+ dishes | expand in place | execution | — |
| `✨ 想再加一道 ›` (L689) | `home.recommendation.moreLink` | `.planExecution` | push `RecipeRecommendationBrowserView` | **discovery** | `查看全部` |
| `加入今天` / `已加入今天` | `home.recommendation.addToday` | `.recipeRecommendation` | `addPlan(recipe:)` (today, dedup) | decide | browser `recommendation.<id>.addPlan` |
| `AI 换几道` (L1320) | `home.recommendation.refresh` | `.recipeRecommendation` | `generateNewRecommendations` in place | **discovery regen** | browser `recommendation.regenerate.button` (L2465, identical call and label) |
| `查看全部` (L1333) | `home.recommendation.viewAll` | `.recipeRecommendation` | push `RecipeRecommendationBrowserView` | **discovery** | `想再加一道` |
| `今日仍有 N 道计划 ›` (L701) | `home.plan.secondaryLink` | `.eatOut` / `.mealPrepBoard` with pending plans | push `TodayPlanDetailView` | **plan management** | `今天的计划`, `用餐计划` |
| `用餐计划 ›` (L720) | `home.planner.link` | always | sheet `PlannerView()` (fresh; current week) | **plan management** | the two rows above |
| `记一笔今天做的` | `home.mealPrep.add` | `.mealPrepBoard` | push `PreparedComponentsView` | prep | Inventory `更多 → 备餐` (the board's own action) |
| `使用 1 份` / `换一个` | `home.quickMeal.*` | `.quickMeal` | consume portion / rotate | quick | — |
| attention rows / `还有 N 项 ›` | `home.attention.*` / `.overflow` | when items | Inventory / Shopping / stock-in / PreparedComponents | inventory attention | — |
| clipboard prompt / `忽略` | `home.clipboard.import.prompt` / `.ignore.button` | URL on clipboard | sheet `ImportRecipeView` | recipe import | `+ → 从小红书导入` |
| module issue rows | (HomeModuleIssues) | persistence notices | Inventory / Shopping tab | recovery | — |
| Special Plan today | — | **never** | — | — | Only reachable via `用餐计划` → Planner row |

Findings:

- Three visible controls (`今天的计划`, `今日仍有 N 道计划`, `用餐计划`) reach two different
  plan-management surfaces for one job. Planner's week list already shows every row
  `TodayPlanDetailView` shows, with strictly more capability (edit, move, undoable delete).
- `home.today.plan.viewAll` is reused on two mutually exclusive branches (L1177, L1209), so the
  identifier is a route contract rather than a control contract.
- `AI 换几道` on Home and `recommendation.regenerate.button` in the browser call the same
  `generateNewRecommendations`; the browser also carries the generating / error / notice states.
- Every `SmartImportSheet` row is a strict duplicate of a Recipes or Inventory tab entry.
- A Special Plan scheduled for today is invisible on Home: `HomeView`, `HomePrimaryTask` and
  `HomeDashboardSummary` contain no reference to `SpecialPlan` at all.
- `更多推荐` does not exist anywhere in `ios-native/` yet.

## 2. `TodayPlanDetailView` — capabilities and their owners

The view is `HomeView.swift` L2129–2351. It takes no parameters, is pushed by
`.navigationDestination(isPresented: $isShowingTodayPlan)` (L254), and is triggered from exactly
two places: the Today card's `今天的计划` (L636) and `今日仍有 N 道计划` (L707).

| # | Capability | Exact current behavior | Owner after this feature |
|---|---|---|---|
| 1 | per-meal `做好了` (`today.plan.complete.button`, L2333) | `CookConsumptionConfirmationView(planIDs: hasConsumedPlan ? [] : [plan.id])`; on confirm inventory deduction + consumption record, then `markPlanCooked(plan)`, toast `已记录消耗，库存已更新`. It is the tail of the cooking flow without cooking mode. | **Planner row action** (FR-001/002). |
| 2 | `全部做完` (L2186, no identifier) | Visible when `pendingTodayPlans` is non-empty; one confirmation for all not-yet-consumed plans, then `markAllTodayCooked()`, toast `今天的计划已全部完成`. | **Removed** (FR-014). Not migrated. |
| 3 | `生成今日购物清单` (L2193, no identifier) | Push `ShoppingListGenerationView(source: .todayPlans(kitchenStore.todayPlans))`. Sole production construction site of `.todayPlans`. | **Planner overflow** (FR-003). |
| 4 | `AI 生成一周菜单` / `查看已生成的一周菜单` (`today.plan.weeklyMenu.link`, L2205–2221) | Push `WeeklyMenuPlannerView()`, no callback passed. Sole production entry. Subtitle `已安排 N 天 · M 道菜` from `weeklyPlanSubtitle` (L2337). | **Planner-hosted generator** (FR-004/005/006). |
| 5 | legacy delete | Context menu `移出计划` → alert `移出计划？` → `kitchenStore.removePlan(plan)` (L2273), which returns nothing and cannot report a failed persist. Only production caller of that API. Inconsistent with D-040. | **Removed** (FR-015); Planner's undoable delete is the only delete. |
| 6 | row → `RecipeDetailView(recipe, plan)` | Push; `ContentUnavailableView("菜谱暂不可用")` when the recipe is missing. | Planner already has it (`plannedMealDestination`, `PlannerView.swift` L521); Home has it. |
| 7 | empty state `还没有安排今天吃什么` | Unreachable — Home only links here when plans exist. | Planner's empty-week state. |

### 2.1 Weekly-generator truthfulness — re-audited on `a7b7d8f` (gate now satisfied)

The 2026-09-10 audit asked whether a member entering the generator from Planner would wrongly
believe Save scheduled those meals into Planner. On `1a7475b` the answer was yes, because saving
wrote only `kitchenStore.weeklyPlan`. **That is no longer the system.** Current shipped state:

| Surface | Current contract on `a7b7d8f` |
|---|---|
| Screen | `WeeklyMenuPlannerView` (`WeeklyMenuPlanner.swift` L1719), title `生成一周菜单` |
| Result screen | states the covered dates rather than calling itself `本周菜单` (D-041) |
| Primary CTA | `加入用餐计划` (`weekly.result.materialize`, L2173) |
| What it writes | resolves each dish to a canonical `Recipe`, commits a pending receipt, then one all-or-none `KitchenStore.appendPlans` batch into canonical `plans`, then finalizes the receipt |
| Success feedback | toast `已加入用餐计划` |
| `kitchenStore.weeklyPlan` | resumable draft + materialization receipt + draft-local shopping source — never a second schedule |
| Host callback | `var onMaterialized: ((WeeklyMaterializationSummary) -> Void)?` (L1719), currently `nil` at every call site |
| Callback payload | `WeeklyMaterializationSummary` (L217): exactly `let startDate: Date` and `let endDate: Date`, both start-of-day, `endDate` inclusive. No ids, deliberately |
| Callback timing (D-041) | fires once for the first append, for an append whose receipt finalization lagged, and for each explicit recovery choice; never on reopening a finished menu, on passive receipt repair, or on any failure or cancel path |

Consequence: the belief the gate was protecting against is now **correct by construction**. Saving
from a Planner-hosted generator really does schedule canonical meals, so the generator moves into
Planner, and full retirement of `TodayPlanDetailView` is unblocked.

One truthfulness debt survives and belongs to this feature: the entry subtitle
`已安排 N 天 · M 道菜` describes an unmaterialized draft as if it were scheduled. It lives in
`HomeView.swift` (L2337), which 003 could not touch without editing Home. FR-006 fixes it when
the entry is re-homed.


## 3. Capability rehoming contract

**A. Per-meal `做好了` → Planner ordinary-meal row.** Semantics are fixed: the same
`MealPlanItem` → the existing `CookConsumptionConfirmationView` (`planIDs` empty when already
consumed) → existing consumption handling → `markPlanCooked` for that exact plan. Never a bare
`isCooked` flip. A plan completed from Home cooking, RecipeDetail cooking, or Planner
quick-complete is indistinguishable afterwards. Planner today has no completion action at all —
its row shows `已完成` as read-only text (`PlannerView.swift` L377) and completion requires a
push into `RecipeDetailView` plus a full cooking-mode pass. Placement to evaluate in Slice A:
**leading swipe `做好了` beside `编辑`** (the leading edge currently holds only `编辑`; the
trailing edge holds `移出计划`), **plus context menu `做好了`, plus a VoiceOver custom action**,
matching the delete flow's three-path pattern (L394/404/409). No permanent visible completion
button. Hidden for cooked rows. If native swipe density proves inappropriate, Slice A reports
rather than inventing custom controls.

**B. `全部做完` → removed.** Not migrated anywhere. `markAllTodayCooked()` (`KitchenStore.swift`
L1374) loses its only caller and is deleted in Slice E under the zero-reference proof.

**C. `生成今日购物清单` → Planner overflow.** Planner owns *plan → derive shopping*: the item
opens the existing `ShoppingListGenerationView(.todayPlans(kitchenStore.todayPlans))` with the
same input as today. Shopping / 买菜 owns *inspect / edit / use* of the resulting list; Planner
gains no shopping-management surface and Home gains nothing. `ShoppingGenerationSource.todayPlans`
keeps its meaning; this is the re-homing of its only production construction site.

**D. AI weekly generator → hosted by Planner.** See §3.1. Planner owns host navigation only.

**E. Legacy delete → removed.** `TodayPlanDetailView`'s context-menu `移出计划` and its
`移出计划？` alert go; `KitchenStore.removePlan(_ plan:)` loses its only production caller and is
deleted in Slice E. D-040's `removePlan(id:)` + Undo remains the only delete contract.

Resulting Planner addition: one toolbar overflow `Menu` (`ellipsis.circle`, label `更多`) with
`生成今日购物清单` and the weekly-generator entry, plus the row-level `做好了` actions.

### 3.1 Weekly-generator hosting contract

Planner is the **host**; `WeeklyMenuPlannerView` keeps every substantive responsibility.

`WeeklyMenuPlannerView` owns: generation, materialization, recovery and all persistence
semantics, exactly as shipped in 003.

Planner may:

- open `WeeklyMenuPlannerView` from its own navigation;
- pass `onMaterialized`;
- receive the `WeeklyMaterializationSummary`;
- use `startDate` / `endDate` to reveal the relevant Planner range;
- dismiss or pop the generator appropriately after the member's action completes.

Planner MUST NOT:

- inspect receipt internals (`WeeklyMaterializationReceipt`, `planIDs`, `recipeIDs`, `planDates`,
  `state`);
- duplicate or reimplement any materialization logic;
- infer, derive or reconstruct plan ids;
- introduce a second notification channel, observer or event bus for the same event.

**Week rule for a range that crosses Planner weeks.** Planner weeks are Monday-first and
half-open, anchored by `PlannerProjection.startOfWeek(containing:calendar:)`
(`PlannerProjection.swift` L60). D-041 records that a generated range is a rolling 1…7 days from
`startDate` and may legitimately span two Monday–Sunday weeks. The deterministic rule is therefore
**the week containing `summary.startDate`**, which is also the convention the existing private
`PlannerView.reveal(_:)` (L511) already applies to a single dated item. No new week concept is
introduced, and Planner never claims that every meal in the range exists — after a
`保留当前安排` recovery choice some intended meals are deliberately absent, which is exactly why
the summary carries no ids.

## 4. Canonical Home IA (target of this feature)

Ordinary execution day:

    Today Context      date row (+ at most one factual context line in exceptional states)
    Primary task       今天做这些 · 已完成 a/b
                       hero (+ 另有 N 道 expansion)
                       [开始做饭]  查看菜谱
    Discovery entry    更多推荐 ›     (was 想再加一道 / 查看全部)
    Planning entry     用餐计划 ›     (the only planning-management destination)
    Needs Attention    named rows
    Secondary status   carryover, clipboard prompt, module issues

Rule: every visible action has a distinct job — execute, discover, plan, attend. The Home toolbar
is empty (no `+`). `更多推荐` sits above `用餐计划` because it is task-local discovery for the
current meal while `用餐计划` is global plan management (GD-5 / OD-6; Home-scoped rationale).

**Exactly one planning-management destination in every Home state.** There is no interim second
planning row in the delivered feature. Slice ordering may leave one temporarily in the working
tree while Planner parity is being built (§12), but the feature is not complete until Home's only
planning route is `用餐计划`.

## 5. Canonical Planner responsibility

Planner owns: every saved ordinary meal and Special Plan on any date; create / edit / move /
delete / undo (D-040); plan-aware cooking; **quick-complete (A)**; **initiating today's shopping
derivation (C)**; **hosting the AI weekly generator (D, §3.1)**. Planner does **not** own: the
resulting shopping list (Shopping does), generation or materialization logic (the generator does),
a Home-like primary task or today card, or any new row styling.

## 6. Routing contract — Home → Planner

- Presentation: **sheet**, unchanged (D-030 decision 4; Planner carries its own
  `NavigationStack`). Push would require dismantling that stack — out of scope.
- Focus: Home presents a fresh `PlannerView()` each time; `weekStart` is `@State` initialised to
  the week containing `now` (`PlannerView.swift` L118/L128), and the today section header is
  already marked `· 今天`. This already satisfies “focused on today/current week”.
- Previously browsed week: not preserved across presentations; the sheet is re-created. Kept — a
  sheet that reopens on the current week matches Home's explicit “today” context. No week state is
  persisted.
- Accessibility focus: sheet presentation already moves VoiceOver to the sheet. No forced focus
  jump and no programmatic scroll-to-today; empty days collapse to headers, so today is normally
  on the first screen. Revisit only if device checks show otherwise.
- Special Plan primary CTA: same sheet, with Planner's initial path preset to the plan's own
  detail route, so Home never hosts `SpecialPlanDetailView` itself.
- Post-materialization reveal: internal to Planner (§3.1); it changes `weekStart`, not the Home
  route.
- No custom calendar navigation.

## 7. Home `+` removal — reachability audit

| SmartImportSheet row | Canonical surface after removal | Evidence |
|---|---|---|
| 从小红书导入菜谱 | Recipes tab `+` → `从链接导入` (`ImportRecipeView`); also clipboard prompt and share extension on Home | `RecipeViews.swift` toolbar Menu |
| 手动创建菜谱 | Recipes tab `+` → `手动添加` (`ManualRecipeView`) | same |
| 扫描购物小票 | Inventory tab `更多食材操作` → `扫描购物小票` (`RecordFoodSheet(.receipt)`) | `MainFeatureViews.swift` |
| 手动添加食材 | Inventory tab `添加食材` (`inventory.add.button`, `RecordFoodSheet(.manual)`) | `MainFeatureViews.swift` |

Nothing becomes unreachable; each capability sits on the tab that owns its data, one tap deeper
than a Home `+` at worst. Home `+` is an aggregator only and is retired, not repurposed.
`SmartImportSheet` and `SmartImportRow` lose their only caller and are deleted.

## 8. Discovery consolidation contract

- One Home discovery control, label `更多推荐`, identifier `home.recommendation.more`, in both
  modes: replaces the card action `查看全部` (decision mode) and the row `想再加一道` (execution
  mode). Destination unchanged: `RecipeRecommendationBrowserView`. Shape unchanged per mode (card
  action in decision mode, `HomeSecondaryLinkRow` in execution mode).
- `AI 换几道` (`home.recommendation.refresh`) is removed from Home. The browser keeps its
  existing `recommendation.regenerate.button`, the same call with the same label plus generating /
  error / notice states. Home keeps showing store-level load error / notice / sample-fallback
  states, which are not tied to the removed button.
- No other Home AI control is added. D-038 unchanged.
- The attention overflow row `还有 N 项` (`home.attention.overflow`) is a different job and is
  unchanged; it is not a `查看全部`.
- The Expiry sheet path (attention row → browser pre-searched) is unchanged.


## 9. Special Plan today — primary-task contract

Precedence (GD-5, unchanged from the owner's 2026-09-10 answer): `.mealPrep` → dinner `eatOut` →
**Special Plan today** → ordinary Today Plan → `.quick` → recommendation. The shipped
`HomePrimaryTask.resolve` (`HomePrimaryTask.swift` L96–150) already runs mealPrep → eatOut →
`planState != .empty` → quick → recommendation, so this inserts exactly one branch between the
`dinnerIntent == .eatOut` check and the `planState` check.

Definitions, from current data:

- “Special Plan today” = `SpecialPlan.scheduledAt` falls on today's local calendar day
  (`SpecialPlan.swift` L48/L56; `kitchenStore.specialPlans`, `KitchenStore.swift` L776). No slot
  is inferred from the time.
- Primary candidate when several = earliest `scheduledAt`; ties broken by array order.
- “Completed” = `dishes` non-empty and every `dish.isCooked`. A Special Plan with no dishes is
  pending. A completed Special Plan **stays** the primary task with detail `18:00 · 6 人 · 已完成`
  — completion is a suffix on the time/guest facts, never a replacement (owner copy ruling).
- Special Plan completion is a per-dish flag with no inventory consumption. This feature does not
  change that.
- Suppressed ordinary plans on any of these days are stated by the GD-5 / OD-4 / OD-5 context line
  only.

Home does not read `SpecialPlan` at all today, and `HomeDashboardSummary` is not given
`specialPlans`, so this is new input plumbing rather than a rewiring of existing state.

| State | Primary task | Detail | Primary CTA | Context line | Notes |
|---|---|---|---|---|---|
| mealPrep + Special Plan | `.mealPrepBoard` (unchanged) | 先吃快到期的 | `记一笔今天做的` | `今天有聚餐 · 18:30 家宴`; plus `今天另有 N 道计划`(` · 已完成`) if ordinary plans exist | two facts, two lines max; neither navigates |
| dinner eatOut + Special Plan | `.eatOut` (unchanged) | 已安排外食 | none | as above | the member's own `eatOut` wins by approved precedence |
| ordinary meal + Special Plan | **`.specialPlanToday`** | `18:30 · 6 人` | `查看聚餐` → Planner at that plan | `今天另有 N 道计划` | the ordinary plan loses prominent `开始做饭` for the day; `更多推荐` not shown |
| quick + Special Plan | `.specialPlanToday` | as above | `查看聚餐` | none | Special Plan outranks quick |
| multiple Special Plans | `.specialPlanToday` for earliest | `12:00 · 4 人` | `查看聚餐` | per ordinary plans | the rest are reachable via Planner; no second link; no same-day count in Home copy |
| completed Special Plan | `.specialPlanToday` | `18:00 · 6 人 · 已完成` | `查看聚餐` | per ordinary plans | remains today's context; completion is a suffix |
| Special Plan, no ordinary meal | `.specialPlanToday` | time · people | `查看聚餐` | none | no recommendation card |
| ordinary plans all completed, Special Plan pending | `.specialPlanToday` | time · people | `查看聚餐` | `今天另有 N 道计划 · 已完成` | never `今日计划已全部完成` |

Internal consistency check: every existing `HomePrimaryTaskTests` case has no Special Plan and
keeps its result; `testEveryCombinationProducesExactlyOnePrimaryTask` (L151) grows by the new
input dimension. No data or persistence change is needed — `scheduledAt` and `dishes[].isCooked`
already exist.

**Anti-drift (constitution III).** D-031 decision 5 says Special Plan has no independent Home
entry and Home never shows the words `特殊计划` / `AI 聚餐` / `AI 菜单` / `新建特殊计划`. A
Special Plan *scheduled for today* becoming the primary task is a today-state, not a navigation
entry, and its CTA opens Planner (the canonical route). D-031's wording ban is respected by using
the plan's own title and `聚餐` (the word D-040 already uses). The next available Home IA Decision
(currently expected D-042; assigned only after re-reading `Decisions.md` at write time) records
this narrowing before Slice D implements.

## 10. Home state matrix

Columns: Context · Primary task · Primary action · Secondary actions · Planning entry ·
Discovery entry · Removed vs today.

| State | Context | Primary | Primary action | Secondary | Planning | Discovery | Removed |
|---|---|---|---|---|---|---|---|
| no plan (cooking day) | date row | `今天做什么 · 还没决定` recommendation card | `加入今天` | `查看菜谱` | `用餐计划` | `更多推荐` (card action) | `+`, `AI 换几道`, `查看全部` |
| no plan (flexible) | date row | `今天怎么吃` card | same | same | same | same | same |
| 1 dish | date row | `今天做这些 · 已完成 0/1` hero row | `开始做饭` | `查看菜谱` | `用餐计划` | `更多推荐` (row) | `+`, `想再加一道`, `今天的计划` |
| 2 dishes | date row | hero + `配 X` | `开始做饭` | as above | `用餐计划` | `更多推荐` | same |
| 3+ collapsed | date row | hero + `另有 N 道` | `开始做饭` | as above + toggle | `用餐计划` | `更多推荐` | same |
| 3+ expanded | date row | hero + remaining rows | `开始做饭` | as above + rows | `用餐计划` | `更多推荐` | same |
| all ordinary meals completed | date row | `已完成 b/b` hero | `查看菜谱` | — | `用餐计划` | `更多推荐` | `+`, `想再加一道`, `今天的计划` |
| quick day, no plan | date row + quick line | Quick Meal | `使用 1 份` | `换一个` | `用餐计划` | none (unchanged) | `+` |
| mealPrep day, pending plans | date row + prep line + `今天另有 N 道计划` | board | `记一笔今天做的` | board rows | `用餐计划` | none | `+`, `今日仍有 N 道计划 ›` |
| dinner eatOut, stale plan | date row + `今晚外食` + `今天另有 N 道计划` | `今晚 · 已安排外食` | none | — | `用餐计划` | none | `+`, `今日仍有 N 道计划 ›` |
| Special Plan today | date row (+ plan line if ordinary plans) | `.specialPlanToday` | `查看聚餐` | — | `用餐计划` | none | — |
| multiple Special Plans | date row | earliest | `查看聚餐` | — | `用餐计划` | none | — |
| completed Special Plan | date row | `18:00 · 6 人 · 已完成` | `查看聚餐` | — | `用餐计划` | none | — |
| attention / no attention | — | — | — | named rows / one healthy line | — | — | unchanged |
| clipboard prompt | — | — | — | `粘贴导入` / `忽略` | — | — | unchanged (still the only Home import path) |
| persistence / error notices | — | — | — | module issue rows; recommendation error/notice | — | — | unchanged; `planNotice` still has no reader (follow-up) |

**Every state carries exactly one planning row and at most one prominent CTA and one discovery
entry.** No state carries `今天的计划`.

## 11. `TodayPlanDetailView` final disposition

**Verdict: B — retire inside this feature, after internal capability parity.** The view's only
irreplaceable capability was hosting the weekly generator, and D-041 removed that constraint: a
Planner-hosted generator now tells the truth. No other feature owns this retirement, and no
additional feature is required.

Retirement prerequisites, all inside this feature and all preceding Slice E:

1. `做好了` lives on Planner rows with cooking-flow semantics (FR-001/002);
2. `生成今日购物清单` is initiated from Planner (FR-003);
3. the weekly generator is hosted from Planner via `onMaterialized` (FR-004/005/006);
4. `全部做完` is removed rather than migrated (FR-014);
5. the legacy delete is removed; D-040 delete + Undo remains canonical (FR-015);
6. Home has no remaining route to the view (FR-010).

Slice E then deletes, with a zero-reference proof for each:

- `TodayPlanDetailView` (`HomeView.swift` L2129–2351) and its private members `TodayPlanSheet`,
  `planDetailButton`, `completionButton`, `weeklyPlanSubtitle`, `showToast`;
- the route: `isShowingTodayPlan` (L43), its `.navigationDestination` (L254), and
  `TodayPlanSummaryCard.onViewPlan` with its two call sites (L636, L707);
- identifiers `home.today.plan.viewAll`, `today.plan.complete.button`,
  `today.plan.weeklyMenu.link`, `home.plan.secondaryLink`;
- `KitchenStore.markAllTodayCooked()` (L1374) — sole caller is the view, so it is dead outright;
- `KitchenStore.removePlan(_ plan:)` (L1384) — production caller is the view; one test caller
  remains (`KitchenManagerTests/TodayPlanPersistenceTests.swift` L193) and is retired with it;
- `KitchenStore.pendingTodayPlans` (L1015) **only if** proven dead: its five call sites are four
  inside the view plus `markAllTodayCooked`, so it becomes dead once both go — but the proof runs
  before the deletion, not instead of it;
- tests reaching the view by its `今天的计划` navigation title:
  `HomeDashboardUITests.swift` L263 and L386, `PlannerUITests.swift` L138–149,
  `RuntimeAccessibilityP1UITests.swift` L19–38, and the launch fixture
  `UITEST_SEED_ACCESSIBILITY_TODAY_PLAN` (`ContentView.swift` L731), which must be retargeted at
  the Planner row or removed.

Two cautions for Slice E. `ShoppingGenerationSource.todayPlans` loses its only production
construction site but stays alive for the Planner entry and six test sites, so it must not be
deleted. And `移出计划` is not a unique string: `PlannerMealDeleteUITests.swift` L51 and L184 match
that same label against Planner's own delete, so a grep-driven cleanup must not touch them.

## 12. Intermediate states are not the contract

Slice ordering may leave the working tree temporarily carrying an old route — for example, the
`今天的计划` row still present after Slice A has moved capabilities but before Slice B removes the
route. That is an implementation-sequence artifact, disclosed per slice in `tasks.md`. It is not
part of the delivered feature contract, and no success criterion is satisfied by it.


## User Scenarios & Testing *(mandatory)*

### User Story 1 — Complete a planned meal without cooking mode (Priority: P1)

A member cooked a planned dish off-app and wants to record it done, with the same inventory
consequences as cooking in-app, from the surface that owns plans.

**Acceptance scenarios**:

1. **Given** a pending ordinary meal in Planner, **When** the member uses the leading swipe
   `做好了`, the context-menu `做好了`, or the VoiceOver custom action `做好了`, **Then** the
   consumption confirmation for that exact plan opens, and on confirm the row shows `已完成`,
   inventory is deducted once, and a consumption record exists.
2. **Given** a plan already covered by a consumption record, **When** `做好了` is confirmed,
   **Then** no second deduction happens and the plan is marked cooked.
3. **Given** a cooked row, **Then** `做好了` is not offered on any of the three paths.
4. **Given** the same plan completed from Home `开始做饭`, RecipeDetail `开始烹饪`, or Planner
   `做好了`, **Then** the resulting plan and consumption state are identical.
5. **Given** the leading swipe, **Then** `编辑` remains available beside `做好了`; if Slice A finds
   the density inappropriate it reports instead of adding custom controls.

### User Story 2 — Derive today's shopping list from Planner (Priority: P1)

1. **Given** Planner, **When** the member opens the toolbar `更多` menu, **Then**
   `生成今日购物清单` is offered and nothing planning-unrelated is.
2. **Given** `生成今日购物清单`, **Then** the existing generation screen opens with today's plans as
   source, identical to the retired entry's output; the resulting items are managed only in
   Shopping.
3. **Given** today has no plans, **Then** the generation screen shows its existing
   `没有可生成的购物清单` state.

### User Story 3 — Generate a weekly menu from Planner and see it land (Priority: P1)

1. **Given** Planner, **When** the member opens the weekly-generator entry, **Then**
   `WeeklyMenuPlannerView` opens with its own copy and behaviour unchanged from 003.
2. **Given** a generated menu, **When** the member taps `加入用餐计划`, **Then** the meals are
   materialized by the shipped 003 path and Planner reveals the week containing the summary's
   `startDate`, with the generator dismissed.
3. **Given** a generated range spanning two Planner weeks, **Then** Planner reveals the week
   containing `startDate` and the member can page to the rest normally.
4. **Given** a cancelled or failed attempt, **Then** no reveal happens and Planner is unchanged.
5. **Given** a recovery choice that keeps the current arrangement, **Then** Planner reveals the
   range without claiming any specific meal exists.
6. **Given** an existing unmaterialized draft, **Then** the Planner entry describes it as
   generated, never as scheduled.

### User Story 4 — Home shows one discovery entry, one planning entry, and no aggregator (Priority: P1)

1. **Given** execution mode, **Then** Home shows `开始做饭` / `查看菜谱`, exactly one `更多推荐`
   row above exactly one `用餐计划` row, and no `想再加一道`, no `今天的计划` and no `+`.
2. **Given** decision mode, **Then** the recommendation card offers `加入今天`, `查看菜谱`,
   `更多推荐`; `AI 换几道` and `查看全部` are absent; `用餐计划` is the only planning row.
3. **Given** `更多推荐` in either mode, **Then** the recommendation browser opens and its
   regenerate action works there with its generating / error / notice states.
4. **Given** an eat-out or prep day with pending plans, **Then** Today Context carries one
   non-interactive line `今天另有 N 道计划` (or `… · 已完成`), with no chevron or button
   treatment, and `用餐计划` is the only planning row.
5. **Given** `用餐计划`, **Then** Planner opens as a sheet on the current week with today marked.
6. **Given** a Home toolbar, **Then** it has no `+`; every former `+` capability is reachable on
   Recipes or Inventory as listed in §7.

### User Story 5 — A Special Plan today is Home's primary task (Priority: P2)

1. **Given** an ordinary day with a Special Plan scheduled today and no eat-out / prep state,
   **Then** the primary task names the plan with its time and headcount and offers `查看聚餐`,
   which opens Planner at that plan.
2. **Given** several Special Plans today, **Then** the earliest is primary; its detail states
   time and headcount only, later same-day events stay reachable through 用餐计划 / Planner, and
   Home states no same-day count.
3. **Given** every dish cooked, **Then** the plan remains primary with `已完成` as a suffix on
   the time/guest detail.
4. **Given** a prep day or eat-out dinner, **Then** the Special Plan is a single non-interactive
   context line and the primary task is unchanged.
5. **Given** ordinary plans on a Special Plan day, **Then** the context line reads
   `今天另有 N 道计划` or `今天另有 N 道计划 · 已完成`; `今日计划已全部完成` never appears.
6. **Given** the existing precedence combinations without a Special Plan, **Then** every result is
   unchanged.

### User Story 6 — `TodayPlanDetailView` is gone (Priority: P2)

1. **Given** any Home state, **Then** no control navigates to a second plan-management surface and
   the `今天的计划` destination does not exist.
2. **Given** the shipped app, **Then** `TodayPlanDetailView` and its identifiers are absent from
   production code, and every capability it used to own is either owned elsewhere or removed by an
   explicit decision.
3. **Given** the weekly generator, **Then** it is reachable from Planner and nowhere else in
   production.

### Edge Cases

- `做好了` on a plan whose recipe is missing: the confirmation works from the plan itself (it
  needs `recipeID` / `recipeName` only); no crash.
- Materialization summary whose range is a single day: Planner reveals that one week.
- Materialization summary whose `startDate` is in a past week: the rule still applies — reveal the
  week containing `startDate` — and the member can page forward.
- Special Plan today with zero dishes: pending, primary, detail states time/headcount without
  `已完成` and without a `待开始` status (owner copy ruling: the time communicates pending).
- Special Plan today deleted while Home is visible: Home recomputes and falls through to the next
  precedence rule.
- Special Plan today at 00:00 or 23:59: still today by local calendar day.
- Ordinary plans on a Special Plan day are still cookable via Planner / RecipeDetail; only Home
  prominence changes.
- Prep day + Special Plan + ordinary plans: Today Context may carry two factual lines.
- Clipboard prompt during a Special Plan primary: unchanged position below the three layers.
- `kitchenStore.planNotice` still has no reader; this feature does not add one (follow-up).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001** Planner pending ordinary-meal rows MUST offer `做好了` via leading swipe (beside
  `编辑`), context menu and VoiceOver custom action; no permanent button; hidden when cooked.
  Slice A MUST report if native swipe density makes the leading-swipe placement inappropriate.
- **FR-002** `做好了` MUST route the same `MealPlanItem` through the existing consumption
  confirmation and consumption handling and then mark that exact plan cooked; a bare `isCooked`
  flip is prohibited. Completion state MUST equal that of the cooking flow for the same plan.
- **FR-003** Planner MUST expose `生成今日购物清单` in one toolbar overflow menu (`更多`); it MUST
  open the existing generation screen with today's plans as source; Planner MUST NOT gain any
  shopping-list management; Home MUST NOT expose shopping generation.
- **FR-004** Planner MUST host the AI weekly generator by opening `WeeklyMenuPlannerView` and
  passing `onMaterialized`. Planner MUST NOT inspect receipt internals, duplicate materialization
  logic, infer plan ids, or add a second notification channel for the same event.
- **FR-005** On `onMaterialized`, Planner MUST reveal the week containing the summary's
  `startDate` using the existing Monday-first week anchor, and MUST return the member to the
  Planner week list. It MUST NOT assert that any specific meal exists.
- **FR-006** The Planner-hosted generator entry MUST NOT describe an unmaterialized draft as
  scheduled; the existing `已安排 N 天 · M 道菜` wording MUST NOT be carried over unchanged.
- **FR-007** Home MUST have no toolbar `+`; `SmartImportSheet` MUST be deleted; every former
  capability MUST be verified reachable on its owning tab (§7) by test.
- **FR-008** Home MUST show exactly one discovery control, `更多推荐`
  (`home.recommendation.more`), in decision and execution modes, opening the recommendation
  browser; `查看全部` and `想再加一道` MUST NOT exist. In execution mode `更多推荐` MUST sit
  above `用餐计划`.
- **FR-009** `AI 换几道` MUST NOT exist on Home; regeneration MUST remain available in the
  browser with its states.
- **FR-010** Home MUST expose exactly one planning-management destination, `用餐计划`
  (`home.planner.link`), in every state. `今天的计划` (`home.today.plan.viewAll`),
  `今日仍有 N 道计划` (`home.plan.secondaryLink`) and any other route to `TodayPlanDetailView`
  MUST NOT exist in the delivered feature.
- **FR-011** When another primary task suppresses ordinary plans, Home MUST show at most one
  non-interactive Today Context line — no chevron, no button traits — reading
  `今天另有 N 道计划` when any is pending, `今天另有 N 道计划 · 已完成` when all are complete, and
  no line when none exist. `今日计划已全部完成` MUST NOT be used.
- **FR-012** `HomePrimaryTask.resolve` MUST gain a `.specialPlanToday` kind placed between
  eat-out and ordinary plan, with the definitions in §9; all existing precedence results without
  a Special Plan MUST be unchanged.
- **FR-013** The Special Plan primary CTA `查看聚餐` MUST open Planner (sheet) with that plan's
  detail on its path; Home MUST NOT host `SpecialPlanDetailView`.
- **FR-014** `全部做完` MUST be removed from the product and MUST NOT be migrated to Planner or
  anywhere else.
- **FR-015** The legacy alert-delete MUST be removed; D-040's `removePlan(id:)` with Undo MUST be
  the only ordinary-meal delete contract in the app.
- **FR-016** `TodayPlanDetailView`, its route (`isShowingTodayPlan`, its `navigationDestination`,
  `TodayPlanSummaryCard.onViewPlan`) and its identifiers MUST be deleted in this feature, after
  FR-001 through FR-006 and FR-010 have landed.
- **FR-017** Code that only `TodayPlanDetailView` kept alive MUST be removed with a zero-reference
  proof recorded per symbol: `markAllTodayCooked()`, `removePlan(_ plan:)` and its remaining test
  caller, the view's private helpers, and `pendingTodayPlans` **only if** proven dead. A symbol
  that is not proven dead MUST NOT be deleted. `ShoppingGenerationSource.todayPlans` MUST survive.
- **FR-018** Obsolete identifiers and tests MUST be removed or retargeted, not left asserting a
  deleted surface: `home.import.*`, `home.recommendation.refresh` / `viewAll` / `moreLink`,
  `home.plan.secondaryLink`, `home.today.plan.viewAll`, `today.plan.complete.button`,
  `today.plan.weeklyMenu.link`, and the `UITEST_SEED_ACCESSIBILITY_TODAY_PLAN` fixture. Tests
  matching the shared string `移出计划` against Planner's own delete MUST be preserved.
- **FR-019** No Home behaviour may treat `kitchenStore.weeklyPlan` as schedule truth; after
  retirement Home MUST contain no `weeklyPlan` reference at all.
- **FR-020** Every retained Home control MUST keep its identifier, label and destination; no theme
  token, typography, card, chip, badge or gradient is added or changed.
- **FR-021** Section order `Today Context → Primary Task → Needs Attention` and leaf-identifier
  placement MUST be preserved.
- **FR-022** The next available Home IA Decision (currently expected D-042; assigned only after
  re-reading `Decisions.md` at write time) — superseding D-031 decisions 3–4 and narrowing
  decision 5 — MUST be recorded in canonical memory before Slices B, D and E are implemented. This
  feature MUST NOT assume, reserve or pre-write a specific number.

### Key Entities

- **HomePrimaryTask** — presentation-only; gains `.specialPlanToday`, a Special Plan input and the
  suppressed-plan context line model. No persistence.
- **SpecialPlan** — unchanged; `scheduledAt` and `dishes[].isCooked` read only.
- **MealPlanItem** — unchanged; `isCooked` set via existing `markPlanCooked`.
- **WeeklyMaterializationSummary** — read-only host input; `startDate` / `endDate` only.
- **PlannerRoute** — gains the in-repo navigation values for the shopping-generation screen and
  the weekly generator. Navigation values, not data.

## Success Criteria *(mandatory)*

- **SC-001** Home exposes exactly one planning-management destination in every state of the §10
  matrix, enumerated by UI tests over the state seeds.
- **SC-002** Home has no toolbar `+`, and every former `+` capability is reachable from its
  owning tab in ≤ 2 taps (UI test per row).
- **SC-003** Home exposes exactly one discovery control, `更多推荐`, in both modes, above
  `用餐计划` in execution mode.
- **SC-004** No Home-level AI regeneration action exists; regeneration works in the browser with
  its states.
- **SC-005** Planner owns the retained ordinary-meal capabilities: per-meal `做好了` on three
  input paths and `生成今日购物清单`, each with a passing test.
- **SC-006** Planner truthfully hosts weekly generation: materializing from the Planner-hosted
  generator reveals the week containing `startDate`, and the entry never describes a draft as
  scheduled.
- **SC-007** `HomePrimaryTask` includes Special Plan today at the approved precedence, and the
  exhaustive combination test passes with all prior results unchanged.
- **SC-008** `TodayPlanDetailView` has no live production route and the type no longer exists;
  every capability it owned is re-homed or removed by an explicit decision.
- **SC-009** No Home behaviour treats `weeklyPlan` as schedule truth; Home contains zero
  `weeklyPlan` references.
- **SC-010** A plan completed from any origin yields identical persisted state (unit test).
- **SC-011** No production or test reference remains to `SmartImportSheet`, `home.import.*`,
  `home.recommendation.refresh` / `viewAll` / `moreLink`, `home.plan.secondaryLink`,
  `home.today.plan.viewAll`, `today.plan.*`, `全部做完`, `今日计划已全部完成`, or the legacy
  delete alert (`rg` gate in `quickstart.md`), and each deleted store symbol has a recorded
  zero-reference proof.
- **SC-012** Focused Home / Planner / weekly / accessibility suites pass, and the full native suite
  reports no new failures beyond the documented baseline reds.

## Out of Scope

- Any visual restyle, new card, chip, badge, gradient, hero photo, typography or token change.
- Changing generation, materialization, recovery or receipt semantics — those are D-041's and stay
  in `WeeklyMenuPlanner.swift`.
- AI provenance on Planner entries; generated-recipe residue cleanup.
- Quantity-aware readiness; `planNotice` reader; `KitchenStore` decomposition.
- Web/PWA Home; Recipes / Inventory / Shopping IA.
- Planner CRUD design (sealed, D-040).
- Special Plan completion semantics (per-dish flag stays; no consumption).

## Assumptions

- Product copy is Simplified Chinese. Strings used: `更多推荐`, `做好了` (existing), `更多`,
  `生成今日购物清单` (existing), `AI 生成一周菜单` / `查看已生成的一周菜单` (existing), `查看聚餐`,
  `今天有聚餐`, `今天另有 N 道计划`, `今天另有 N 道计划 · 已完成`. `今天还有 N 场` was
  considered and dropped by owner copy ruling: Home is not a same-day Special Plan schedule
  summary.
- FR-006's replacement subtitle is expected to read `已生成 N 天 · M 道菜`, reusing the word the
  adjacent entry label already uses. Exact copy is owner-adjustable; the requirement is that it
  must not claim an unmaterialized draft is scheduled.
- The recommendation browser's regenerate label stays `AI 换几道` (already there; D-038 host
  treatment).
- No schema, migration, sync, provider, flag or entitlement change.

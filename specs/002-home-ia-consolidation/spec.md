# Feature Specification: Home IA Consolidation

**Feature Branch**: `codex/002-home-ia-consolidation`

**Created**: 2026-09-10

**Status**: Sealed for planning — audit + specification + owner clarifications encoded. No product code changed.

**Input**: Owner-approved Home IA direction and owner clarifications (2026-09-10) on top of sealed Planner ordinary-meal CRUD (`main` = `1a7475b`, D-040).

## Overview

Home answers one job: **“我今天吃什么，以及现在下一步该做什么？”** Planner (D-040) is the single
canonical saved-meal planning surface, so Home no longer needs its own add/import hub, its own AI
launcher, or a second discovery wording. This feature **reduces concepts and duplicate entry
points on native iOS Home**; it is not a visual redesign.

Bounded change delivered by this feature:

1. Rehome per-meal quick completion (`做好了`) and today's shopping derivation to Planner; remove
   `全部做完`.
2. Retire the Home global top-right `+`.
3. Collapse Home's discovery wording (`查看全部`, `想再加一道`) into one entry, `更多推荐`, and
   remove `AI 换几道` from Home (the recommendation browser already owns regeneration).
4. Replace the `今日仍有 N 道计划` link with one non-interactive factual context line.
5. Add Special Plan today to `HomePrimaryTask` precedence.
6. Reduce `TodayPlanDetailView` to the capabilities that still have no truthful other home.

Explicitly **not** completed by this feature (see §11): full retirement of `TodayPlanDetailView`
and removal of the `今天的计划` row, because the AI weekly generator would misrepresent itself if
moved into Planner before weekly materialization exists.

## Clarifications

### Session 2026-09-10

- Q: Is Planner the single canonical saved-meal planning surface, with Home exposing exactly one
  planning-management destination, and do the conflicting portions of D-031 get a new Decision?
  → A: Yes (OD-1). A new Decision supersedes only the conflicting portions of D-031 (decisions
  3–4; decision 5 narrowed for Special Plan today) before Slices B/D implement. D-031 history is
  not rewritten. Latest Decision on 2026-09-10 is D-040, so the new one is **D-041** (verified
  in `Decisions.md`; re-verify at write-back time).
- Q: Is `全部做完` migrated or removed? → A: Removed (OD-2). Per-meal completion is the truthful
  model; bulk completion is convenience only, weakens the meal↔consumption relationship, and no
  persisted product state depends on it. `markAllTodayCooked()` may go dead; its cleanup waits
  for the retirement slice that proves zero production references.
- Q: Who owns shopping generation from today's plans? → A: Planner owns the **initiating**
  action `生成今日购物清单` in its lightweight `更多` overflow, because the input is the meal
  plan (OD-3). Shopping / 买菜 owns the resulting list and all subsequent management. Not on
  Home; no shopping-management surface inside Planner.
- Q: How are suppressed ordinary plans shown when another primary task wins? → A: At most one
  **non-interactive** factual context line — no chevron, no button treatment, not a second
  planning entry; count/state derived from the ordinary plans (OD-4).
- Q: What copy does that line use? → A: (OD-5) `今天另有 N 道计划` when some are pending;
  `今天另有 N 道计划 · 已完成` when all are complete; no line when none exist. The generic
  `今日计划已全部完成` is rejected because a pending Special Plan makes it false. The Special
  Plan's own completion belongs to its primary-task presentation.
- Q: Which comes first on Home, `更多推荐` or `用餐计划`? → A: `更多推荐` above `用餐计划`
  (OD-6), because `更多推荐` is contextual discovery tied to the current meal task and
  `用餐计划` is the broader canonical management destination: task-local secondary action
  precedes global plan management. Home-scoped rationale, not a global visual rule.
- Q: Would a user entering the AI weekly generator from Planner believe Save scheduled meals into
  Planner? → A: **Yes** (see §2.1 audit). Therefore the generator is **not** moved into Planner,
  and full `TodayPlanDetailView` retirement is **blocked** by the future prerequisite
  `AI weekly-plan materialization into canonical KitchenStore.plans`. No bridge is added.
- Q: Per-meal quick completion semantics and placement? → A: Keep `做好了`. Semantics: same
  `MealPlanItem` → existing consumption confirmation → existing consumption handling → mark that
  exact plan cooked; never a bare `isCooked` flip. Placement to evaluate in Slice A: leading
  swipe `做好了` + `编辑`, plus context menu `做好了`, plus VoiceOver custom action; no
  permanent per-row button. Report in Slice A if native swipe density makes this inappropriate.
- Q: Special Plan today precedence? → A: Unchanged: mealPrep > dinner eatOut > Special Plan today
  > ordinary plan > quick > recommendation; earliest `scheduledAt` is primary; no slot inferred
  from time; a completed Special Plan may remain today's context.

## 1. Current Home action map (re-audited on `1a7475b`)

Source: `KitchenManager/HomeView.swift`, `HomePrimaryTask.swift`, `PlannerView.swift`,
`KitchenStore.swift`. “Job” names the user job; “Overlap” names another visible control that
serves the same job.

| Label | Identifier | Visible when | Action / destination | Mutation | Job | Overlap |
|---|---|---|---|---|---|---|
| date row (`调整今天安排`) | `home.dayRhythm.row` | always | sheet `TodayRhythmSheet` | day rhythm | context | — |
| `+` `导入与添加` (toolbar) | `home.import.add.button` | always | sheet `SmartImportSheet` (4 rows) | none itself | add/import hub | Recipes `+` menu; Inventory `添加食材` + `更多食材操作` |
| ↳ `从小红书导入菜谱` | `home.import.recipe.xiaohongshu` | in sheet | push `ImportRecipeView` | saves recipe | recipe import | Recipes `+ → 从链接导入`; clipboard prompt; share extension |
| ↳ `手动创建菜谱` | `home.import.recipe.manual` | in sheet | push `ManualRecipeView` | saves recipe | recipe create | Recipes `+ → 手动添加` |
| ↳ `扫描购物小票` | `home.import.food.receipt` | in sheet | sheet `RecordFoodSheet(.receipt)` | inventory | receipt scan | Inventory `更多食材操作 → 扫描购物小票` |
| ↳ `手动添加食材` | `home.import.food.manual` | in sheet | sheet `RecordFoodSheet(.manual)` | inventory | ingredient add | Inventory `添加食材` (`inventory.add.button`) |
| primary heading | `home.primary.title` / `.detail` | always | none | none | state | — |
| hero row (1 dish) | `home.today.plan.row.<recipeID>` | `.planExecution`, 1 dish | push `RecipeDetailView(recipe, plan)` | none | execution review | expanded rows |
| `开始做饭` | `home.today.plan.start` | `.planExecution`, lead pending | `cookingFlow` → consumption confirm → `markPlanCooked` | inventory + cooked | execution | RecipeDetail `开始烹饪` (same flow, by design) |
| `查看菜谱` | `home.today.plan.viewRecipe` (pending) / `home.today.plan.start` (all cooked) | `.planExecution` | push `RecipeDetailView(recipe, plan)` | none | execution review | hero row |
| `今天的计划 ›` | `home.today.plan.viewAll` | `.planExecution` | push `TodayPlanDetailView` | none | **plan management** | `用餐计划` (Planner today section) |
| `另有 N 道` | `home.meal.menu.toggle` | `.planExecution`, 3+ dishes | expand in place | none | execution | — |
| expanded rows | `home.today.plan.row.<recipeID>` | expanded | push `RecipeDetailView(recipe, plan)` | none | execution review | — |
| `✨ 想再加一道 ›` | `home.recommendation.moreLink` | `.planExecution` | push `RecipeRecommendationBrowserView` | none | **discovery** | `查看全部` (other mode, same destination) |
| `加入今天` / `已加入今天` | `home.recommendation.addToday` | `.recipeRecommendation` | `addPlan(recipe:)` (today, dedup) | today plan | decide | browser `recommendation.<id>.addPlan` |
| `查看菜谱` (card) | (card action) | `.recipeRecommendation` | push `RecipeDetailView(recipe)` | none | discovery review | — |
| `AI 换几道` | `home.recommendation.refresh` | `.recipeRecommendation` | `generateNewRecommendations` in place | recommendation store | **discovery regen** | browser `recommendation.regenerate.button` (identical call, identical label) |
| `查看全部` | `home.recommendation.viewAll` | `.recipeRecommendation` | push `RecipeRecommendationBrowserView` | none | **discovery** | `想再加一道` |
| `今日仍有 N 道计划 ›` | `home.plan.secondaryLink` | `.eatOut` / `.mealPrepBoard` with pending plans | push `TodayPlanDetailView` | none | **plan management** | `今天的计划`, `用餐计划` |
| `用餐计划 ›` | `home.planner.link` | always | sheet `PlannerView()` (fresh; current week) | none | **plan management** | the two rows above |
| `记一笔今天做的` | `home.mealPrep.add` | `.mealPrepBoard` | push `PreparedComponentsView` | prepared batch | prep | Inventory `更多 → 备餐` (tab destination; acceptable, it is the board's own action) |
| `使用 1 份` / `换一个` | `home.quickMeal.*` | `.quickMeal` | consume portion / rotate | prepared batch | quick | — |
| attention rows | `home.attention.*` | when items | Inventory filter / Shopping / stock-in / PreparedComponents | none | inventory attention | — |
| `还有 N 项 ›` | `home.attention.overflow` | overflow | Inventory `.all` | none | inventory attention | — |
| clipboard prompt / `忽略` | `home.clipboard.import.prompt` / `home.clipboard.ignore.button` | URL on clipboard | sheet `ImportRecipeView` | saves recipe | recipe import | `+ → 从小红书导入` |
| module issue rows | (HomeModuleIssues) | persistence notices | Inventory / Shopping tab | none | recovery | — |
| Special Plan today | — | **never** | — | — | — | Only reachable via `用餐计划` → Planner row |

Findings:

- Three visible controls (`今天的计划`, `今日仍有 N 道计划`, `用餐计划`) go to two different
  plan-management surfaces for one job. Planner's today section already shows every row
  `TodayPlanDetailView` shows, with strictly more capability (edit, move, undoable delete).
- `AI 换几道` on Home and `recommendation.regenerate.button` in the browser call the same
  `generateNewRecommendations`; the browser also carries the generating/error/notice states.
- Every `SmartImportSheet` row is a strict duplicate of a Recipes or Inventory tab entry.
- A Special Plan scheduled for today is invisible on Home.

## 2. `TodayPlanDetailView` — capabilities it still uniquely owns

| # | Capability | Exact current behavior | Planner equivalent today |
|---|---|---|---|
| 1 | per-meal `做好了` (`today.plan.complete.button`) | Opens `CookConsumptionConfirmationView(planIDs: hasConsumedPlan ? [] : [plan.id])`; on confirm: inventory deduction + consumption record via the confirmation view, then `markPlanCooked(plan)`, toast `已记录消耗，库存已更新`. It is the **tail of the cooking flow without cooking mode**: identical end state (consumption record, inventory, `isCooked`). | None. Planner completes a meal only via `RecipeDetailView → 开始烹饪 → cookingFlow`. |
| 2 | `全部做完` | Visible when `pendingTodayPlans` non-empty. One `CookConsumptionConfirmationView` for all pending, not-yet-consumed plan ids; on confirm `markAllTodayCooked()`; toast `今天的计划已全部完成`. `markAllTodayCooked` has no other caller. | None. **Removed (OD-2).** |
| 3 | `生成今日购物清单` | Push `ShoppingListGenerationView(source: .todayPlans(kitchenStore.todayPlans))` (all of today's plans, cooked included). Sole app entry that feeds **today's plans** into shopping generation; Shopping tab itself has no generation entry. | None. Special Plan detail and Recipe detail generate from their own source. |
| 4 | `AI 生成一周菜单` / `查看已生成的一周菜单` (`today.plan.weeklyMenu.link`) | Push `WeeklyMenuPlannerView`. Sole app entry. See §2.1. | None; **stays here (gate = YES)**. |
| 5 | legacy delete | Context menu `移出计划` → alert `移出计划？` → `kitchenStore.removePlan(plan)` (legacy `didSet` path; no `PlanMutationOutcome`, no undo). Only remaining caller of the legacy API. Inconsistent with D-040. | Planner: swipe / context menu / VoiceOver action → `removePlan(id:)` with undo. |
| 6 | row → RecipeDetail(plan) | Push. | Planner has it. Home has it. |
| 7 | empty state `还没有安排今天吃什么` | Effectively unreachable: Home only links here when plans exist. | Planner empty-week state. |

### 2.1 Weekly-generator truthfulness audit (`WeeklyMenuPlanner.swift`, `1a7475b`)

| Surface | Current user-visible contract |
|---|---|
| Entry label (in `TodayPlanDetailView`) | `AI 生成一周菜单` / `查看已生成的一周菜单`; subtitle `按顿数、人数生成一周安排` / `已安排 N 天 · M 道菜` |
| Screen title | `生成一周菜单`; generate CTA `生成本周菜单`; secondary `查看已保存的本周计划` |
| Result screen | title `本周菜单`; section `本周概览` with `共计 N 顿` / `菜品 M 道`; **day sections headed by real calendar dates** from `plan.startDate` |
| Save CTA | `保存本周计划` in the result `更多` menu (also `重新生成整周`, `生成本周购物清单`, `复制为下一周`, `删除本周计划`) |
| Success feedback | toast `已保存本周计划`; stays on the result screen |
| Destination after save | none (remains on `本周菜单`) |
| Persisted state | `kitchenStore.weeklyPlan` (legacy `WeeklyMealPlan` via `weeklyPlanPersistence`) only. `KitchenStore.plans` is written **only** by `把今天加入计划` / per-recipe `加入今天` (today only). |

Question: would a reasonable user, entering from Planner, believe Save scheduled those meals into
Planner? **Yes.** The flow calls itself `本周计划`, shows dated days like Planner does, says
`已安排 N 天` and `已保存本周计划`, and would be launched from the same surface that displays
dated weeks — yet returning to Planner would show none of those meals. That is exactly the
misleading bridge the owner forbade. Consequence: the generator entry is **not** moved into
Planner in this feature; it stays on `TodayPlanDetailView`, whose full retirement is blocked by
the future prerequisite **AI weekly-plan materialization into canonical `KitchenStore.plans`**.

## 3. Capability rehoming contract

**A. Per-meal `做好了` → Planner ordinary-meal row.** Semantics are fixed: the same
`MealPlanItem` → the existing `CookConsumptionConfirmationView` (`planIDs` empty when already
consumed) → existing consumption handling → `markPlanCooked` for that exact plan. Never a bare
`isCooked` flip. So a plan completed from Home cooking, RecipeDetail cooking, or Planner
quick-complete is indistinguishable afterwards. Placement to evaluate in Slice A: **leading swipe
`做好了` + `编辑`** (the leading edge currently holds only `编辑`; the trailing edge holds
`移出计划`), **plus context menu `做好了`, plus VoiceOver custom action `做好了`**. No permanent
visible completion button. Hidden for cooked rows. If native swipe density proves inappropriate,
Slice A reports rather than inventing custom controls.

**B. `全部做完` → removed (OD-2).** Not migrated anywhere. `markAllTodayCooked()` loses its only
caller; its deletion is deferred to the retirement slice that proves zero production references.

**C. `生成今日购物清单` → Planner `更多` overflow (OD-3).** Planner owns *plan → derive
shopping*: the item pushes the existing `ShoppingListGenerationView(.todayPlans(...))` with the
same input as today (all of today's plans). Shopping / 买菜 owns *inspect / edit / use* of the
resulting list; Planner gains no shopping-management surface and Home gains nothing.

**D. `AI 生成一周菜单` → stays on `TodayPlanDetailView`** (gate = YES, §2.1). No Planner entry,
no relabelled bridge. Weekly materialization is a separate future feature.

**E. Legacy delete path** — removed from `TodayPlanDetailView` in this feature (Planner is the
delete owner under D-040); `removePlan(_ plan:)` becomes dead and is cleaned up with the
retirement slice.

Resulting Planner addition: one toolbar overflow `Menu` (`ellipsis.circle`, label `更多`) with a
single item `生成今日购物清单`, plus the row-level `做好了` actions.

## 4. Canonical Home IA (target of this feature)

Ordinary execution day:

    Today Context      date row (+ at most one factual context line in exceptional states)
    Primary task       今天做这些 · 已完成 a/b
                       hero (+ 另有 N 道 expansion)
                       [开始做饭]  查看菜谱
                       今天的计划 ›   ← INTERIM: retained only while it is the sole truthful host of the weekly generator
    Discovery entry    更多推荐 ›     (was 想再加一道)
    Planning entry     用餐计划 ›     (unchanged)
    Needs Attention    named rows
    Secondary status   carryover, clipboard prompt, module issues

Rule: every visible action has a distinct job — execute, discover, plan, attend. The Home
toolbar is empty (no `+`). `更多推荐` sits above `用餐计划` because it is task-local discovery
for the current meal while `用餐计划` is global plan management (OD-6; Home-scoped rationale).

Interim honesty: until weekly materialization ships, execution mode still shows `今天的计划`,
so OD-1's “exactly one planning-management destination” is reached only on days without an
ordinary plan (Decision, quick, prep, eat-out, Special Plan). The row is retained as an
execution-mode route to a **reduced** `TodayPlanDetailView` (§11); it is not restyled, not
renamed and not added to any other state. Final removal is the first task of the
materialization feature.

## 5. Canonical Planner responsibility

Planner owns: every saved ordinary meal and Special Plan on any date; create / edit / move /
delete / undo (D-040); plan-aware cooking; **quick-complete (A)**; **initiating today's
shopping derivation (C)**. Planner does **not** own: the resulting shopping list (Shopping does),
the AI weekly generator (blocked, §2.1), a Home-like primary task or today card, or any new row
styling.

## 6. Routing contract — Home → Planner

- Presentation: **sheet**, unchanged (D-030 decision 4; Planner carries its own
  `NavigationStack`). Push would require dismantling that stack — out of scope.
- Focus: Home presents a fresh `PlannerView()` each time; `weekStart` is `@State` initialised to
  the week containing `now`, and the today section header is already marked `· 今天` and bold.
  This already satisfies “focused on today/current week”.
- Previously browsed week: not preserved across presentations today (the sheet is re-created).
  Kept: a sheet that reopens on the current week matches Home's explicit “today” context and is
  familiar iOS behaviour. No week state is persisted.
- Accessibility focus: sheet presentation already moves VoiceOver to the sheet. No forced focus
  jump to the today section. Not required: programmatic scroll-to-today (empty days collapse to
  headers, so today is normally on the first screen). Revisit only if device checks show
  otherwise.
- Special Plan primary CTA: same sheet, with Planner's initial path preset to
  `.specialPlan(id)` so Home never hosts `SpecialPlanDetailView` itself.
- No custom calendar navigation.

## 7. Home `+` removal — reachability audit

| SmartImportSheet row | Canonical surface after removal | Evidence |
|---|---|---|
| 从小红书导入菜谱 | Recipes tab `+` → `从链接导入` (`ImportRecipeView`); also clipboard prompt and share extension on Home | `RecipeViews.swift` toolbar Menu |
| 手动创建菜谱 | Recipes tab `+` → `手动添加` (`ManualRecipeView`) | same |
| 扫描购物小票 | Inventory tab `更多食材操作` → `扫描购物小票` (`RecordFoodSheet(.receipt)`) | `MainFeatureViews.swift` ~L404 |
| 手动添加食材 | Inventory tab `添加食材` (`inventory.add.button`, `RecordFoodSheet(.manual)`) | `MainFeatureViews.swift` ~L395 |

Nothing becomes unreachable; each capability sits on the tab that owns its data, one tap
deeper than a Home `+` at worst. Home `+` is an aggregator only and is retired, not repurposed.
`SmartImportSheet` and `SmartImportRow` lose their only caller and are deleted.

## 8. Discovery consolidation contract

- One Home discovery control, label `更多推荐`, identifier `home.recommendation.more`, in both
  modes: replaces the card action `查看全部` (decision mode) and the row `想再加一道`
  (execution mode). Destination unchanged: `RecipeRecommendationBrowserView`. Shape unchanged
  per mode (card action in decision mode, `HomeSecondaryLinkRow` in execution mode).
- `AI 换几道` (`home.recommendation.refresh`) is removed from Home. The browser keeps its
  existing `recommendation.regenerate.button`, which is the same call with the same label,
  generating / error / notice states. Home keeps showing store-level load error / notice /
  sample-fallback states, because those are not tied to the removed button.
- No other Home AI control is added. D-038 unchanged.
- The Expiry sheet path (attention row → browser pre-searched) is unchanged.

## 9. Special Plan today — primary-task contract

Precedence (owner-approved, reconfirmed): `.mealPrep` → dinner `eatOut` → **Special Plan
today** → ordinary Today Plan → `.quick` → recommendation.

Definitions, from current data:

- “Special Plan today” = `SpecialPlan.scheduledAt` falls on today's local calendar day. No
  slot is inferred from the time.
- Primary candidate when several = earliest `scheduledAt`; ties broken by array order.
- “Completed” = `dishes` non-empty and every `dish.isCooked`. A Special Plan with no dishes is
  pending. A completed Special Plan **stays** the primary task with detail `已完成`.
- Special Plan completion is a per-dish flag (`setDishCooked`) with no inventory consumption.
  This feature does not change that.
- Suppressed ordinary plans on any of these days are stated by the OD-4/OD-5 context line only.

| State | Primary task | Detail | Primary CTA | Context line (OD-4/5) | Notes |
|---|---|---|---|---|---|
| mealPrep + Special Plan | `.mealPrepBoard` (unchanged) | 先吃快到期的 | `记一笔今天做的` | `今天有聚餐 · 18:30 家宴`; plus `今天另有 N 道计划`(` · 已完成`) if ordinary plans exist | two facts, two lines max; neither navigates |
| dinner eatOut + Special Plan | `.eatOut` (unchanged) | 已安排外食 | none | as above | user's own `eatOut` wins by approved precedence |
| ordinary meal + Special Plan | **`.specialPlanToday`** | `18:30 · 6 人` | `查看聚餐` → Planner sheet at that plan | `今天另有 N 道计划` | ordinary plan loses prominent `开始做饭` for the day; `更多推荐` not shown |
| quick + Special Plan | `.specialPlanToday` | as above | `查看聚餐` | none | Special Plan outranks quick |
| multiple Special Plans | `.specialPlanToday` for earliest | `12:00 · 4 人 · 今天还有 1 场` | `查看聚餐` | per ordinary plans | the rest are reachable via Planner; no second link |
| completed Special Plan | `.specialPlanToday` | `已完成` | `查看聚餐` | per ordinary plans | remains today's context |
| Special Plan, no ordinary meal | `.specialPlanToday` | time · people | `查看聚餐` | none | no recommendation card |
| ordinary plans all completed, Special Plan pending | `.specialPlanToday` | time · people | `查看聚餐` | `今天另有 N 道计划 · 已完成` | never `今日计划已全部完成` (OD-5) |

Internal consistency check: the approved precedence composes with `HomePrimaryTask.resolve` by
inserting one branch between `dinnerIntent == .eatOut` and `planState != .empty`; every existing
`HomePrimaryTaskTests` case has no Special Plan and keeps its result. The
`testEveryCombinationProducesExactlyOnePrimaryTask` combination count grows by the new input.
No data or persistence change is needed: `scheduledAt` and `dishes[].isCooked` already exist.

**Anti-drift (constitution III):** D-031 decision 5 says Special Plan has no independent Home
entry and Home never shows the words `特殊计划` / `AI 聚餐` / `AI 菜单` / `新建特殊计划`. A
Special Plan *scheduled for today* becoming the primary task is a today-state, not a navigation
entry, and its CTA opens Planner (the canonical route). D-031's wording ban is respected by using
the plan's own title and `聚餐` (the word D-040 already uses). **D-041** records this narrowing
(OD-1) before Slice D implements.

## 10. Home state matrix

Columns: Context · Primary task · Primary action · Secondary actions · Planning entry ·
Discovery entry · Hidden/removed vs today.

| State | Context | Primary | Primary action | Secondary | Planning | Discovery | Removed |
|---|---|---|---|---|---|---|---|
| no plan (cooking day) | date row | `今天做什么 · 还没决定` recommendation card | `加入今天` | `查看菜谱` | `用餐计划` | `更多推荐` (card action) | `+`, `AI 换几道`, `查看全部` |
| no plan (flexible) | date row | `今天怎么吃` card | same | same | same | same | same |
| 1 dish | date row | `今天做这些 · 已完成 0/1` hero row | `开始做饭` | `查看菜谱`; `今天的计划` (interim) | `用餐计划` | `更多推荐` (row) | `+`, `想再加一道` |
| 2 dishes | date row | hero + `配 X` | `开始做饭` | as above | `用餐计划` | `更多推荐` | same |
| 3+ collapsed | date row | hero + `另有 N 道` | `开始做饭` | as above + toggle | `用餐计划` | `更多推荐` | same |
| 3+ expanded | date row | hero + remaining rows | `开始做饭` | as above + rows | `用餐计划` | `更多推荐` | same |
| all ordinary meals completed | date row | `已完成 b/b` hero | `查看菜谱` | `今天的计划` (interim) | `用餐计划` | `更多推荐` | `+`, `想再加一道` |
| quick day, no plan | date row + quick line | Quick Meal | `使用 1 份` | `换一个` | `用餐计划` | none (unchanged) | `+` |
| mealPrep day, pending plans | date row + prep line + `今天另有 N 道计划` | board | `记一笔今天做的` | board rows | `用餐计划` | none | `+`, `今日仍有 N 道计划 ›` |
| dinner eatOut, stale plan | date row + `今晚外食` + `今天另有 N 道计划` | `今晚 · 已安排外食` | none | — | `用餐计划` | none | `+`, `今日仍有 N 道计划 ›` |
| Special Plan today | date row (+ plan line if ordinary plans) | `.specialPlanToday` | `查看聚餐` | — | `用餐计划` | none | — |
| multiple Special Plans | date row | earliest | `查看聚餐` | — | `用餐计划` | none | — |
| completed Special Plan | date row | `已完成` | `查看聚餐` | — | `用餐计划` | none | — |
| attention / no attention | — | — | — | named rows / one healthy line | — | — | unchanged |
| clipboard prompt | — | — | — | `粘贴导入` / `忽略` | — | — | unchanged (still the only Home import path) |
| persistence / error notices | — | — | — | module issue rows; recommendation error/notice | — | — | unchanged; `planNotice` still has no reader (follow-up) |

No state exceeds one prominent CTA and one discovery entry. Execution mode carries two planning
rows (`今天的计划` interim + `用餐计划`) until materialization; every other state carries exactly
one. Flagged, not hidden.

## 11. `TodayPlanDetailView` final disposition

**Verdict: C — full retirement must wait for the weekly-materialization feature.** The view is
the only truthful host of the AI weekly generator, and the generator cannot enter Planner
without misrepresenting Save (§2.1). Choosing A or B would require either a misleading bridge or
making the generator unreachable; both are ruled out.

What this feature does to the view (**interim reduction**, all owner-decided):

- remove `全部做完` and its `.cookAll` sheet (OD-2);
- remove `生成今日购物清单` (now Planner `更多`);
- remove the legacy context-menu delete and its alert (Planner owns delete with undo);
- keep: the today rows, per-row `做好了` (identical semantics to Planner's), row → RecipeDetail,
  the weekly generator link, the `今天的计划` title and its single Home route
  `home.today.plan.viewAll` in execution mode.
- `home.plan.secondaryLink` (eat-out / prep route) is removed in favour of the OD-4 context line;
  the generator is therefore reachable only in execution mode, which is already its condition in
  Decision mode today. Disclosed as an accepted interim limitation.

Deferred to the materialization feature (explicit prerequisite list): delete
`TodayPlanDetailView`, `TodayPlanSheet`, `isShowingTodayPlan` + its `navigationDestination`,
`onViewPlan` on `TodayPlanSummaryCard`, `home.today.plan.viewAll`, `today.plan.complete.button`,
`today.plan.weeklyMenu.link`; dead `KitchenStore.removePlan(_ plan:)` and `markAllTodayCooked()`
with their tests; `PlannerUITests.testTodayPlanDetailNoLongerCarriesAPlannerRoute` and
`HomeDashboardUITests.testTodayPlanViewAllStillReachesTheFullPlan`; the vault Home contract lines
naming the row.

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
   `生成今日购物清单` is offered and nothing else planning-unrelated is.
2. **Given** `生成今日购物清单`, **Then** the existing generation screen opens with today's plans as
   source, identical to the retired entry's output; the resulting items are managed only in
   Shopping.
3. **Given** today has no plans, **Then** the generation screen shows its existing
   `没有可生成的购物清单` state.

### User Story 3 — Home shows one discovery entry and no aggregator (Priority: P1)

1. **Given** execution mode, **Then** Home shows `开始做饭` / `查看菜谱`, exactly one `更多推荐`
   row above exactly one `用餐计划` row, the interim `今天的计划` row, and no `想再加一道` or `+`.
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

### User Story 4 — A Special Plan today is Home's primary task (Priority: P2)

1. **Given** an ordinary day with a Special Plan scheduled today and no eat-out / prep state,
   **Then** the primary task names the plan with its time and headcount and offers `查看聚餐`,
   which opens Planner at that plan.
2. **Given** several Special Plans today, **Then** the earliest is primary and the detail says
   `今天还有 N 场`.
3. **Given** every dish cooked, **Then** the plan remains primary with `已完成`.
4. **Given** a prep day or eat-out dinner, **Then** the Special Plan is a single non-interactive
   context line and the primary task is unchanged.
5. **Given** ordinary plans on a Special Plan day, **Then** the context line reads
   `今天另有 N 道计划` or `今天另有 N 道计划 · 已完成`; `今日计划已全部完成` never appears.
6. **Given** the 32 existing precedence combinations without a Special Plan, **Then** every
   result is unchanged.

### User Story 5 — `TodayPlanDetailView` is reduced truthfully (Priority: P2)

1. **Given** `今天的计划` in execution mode, **Then** it shows today's rows with `做好了`, and the
   weekly generator link; `全部做完`, `生成今日购物清单` and the delete context menu are absent.
2. **Given** the weekly generator opened from there, **Then** its copy and behaviour are unchanged
   (no bridge into Planner claimed).
3. **Given** any non-execution Home state, **Then** no control navigates to `今天的计划`.

### Edge Cases

- `做好了` on a plan whose recipe is missing: the confirmation view still works from the plan
  (it needs `recipeID` / `recipeName` only); no crash.
- Special Plan today with zero dishes: pending, primary, detail without `已完成`.
- Special Plan today deleted while Home is visible: Home recomputes; falls through to the next
  precedence rule.
- Special Plan today at 00:00 or 23:59: still today by local calendar day.
- Ordinary plans on a Special Plan day are still cookable via Planner / RecipeDetail; only Home
  prominence changes.
- Prep day + Special Plan + ordinary plans: Today Context may carry two factual lines (prep
  explanation is existing; `今天有聚餐…` and `今天另有 N 道计划` are each at most one).
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
- **FR-004** The AI weekly generator MUST NOT be given a Planner entry, a relabelled bridge, or
  materialization in this feature; its existing entry on `TodayPlanDetailView` MUST remain
  reachable in execution mode.
- **FR-005** Home MUST have no toolbar `+`; `SmartImportSheet` MUST be deleted; every former
  capability MUST be verified reachable on its owning tab (§7) by test.
- **FR-006** Home MUST show `用餐计划` (`home.planner.link`) in every state; `今日仍有 N 道计划`
  (`home.plan.secondaryLink`) MUST NOT exist; `今天的计划` (`home.today.plan.viewAll`) MUST appear
  only in execution mode and only until the materialization feature removes it.
- **FR-007** When another primary task suppresses ordinary plans, Home MUST show at most one
  non-interactive Today Context line — no chevron, no button traits — reading
  `今天另有 N 道计划` when any is pending, `今天另有 N 道计划 · 已完成` when all are complete, and
  no line when none exist. `今日计划已全部完成` MUST NOT be used.
- **FR-008** Home MUST show exactly one discovery control, `更多推荐`
  (`home.recommendation.more`), in decision and execution modes, opening the recommendation
  browser; `查看全部` and `想再加一道` MUST NOT exist. In execution mode `更多推荐` MUST sit
  above `用餐计划` (OD-6).
- **FR-009** `AI 换几道` MUST NOT exist on Home; regeneration MUST remain available in the
  browser with its states.
- **FR-010** `HomePrimaryTask.resolve` MUST gain a `.specialPlanToday` kind placed between
  eat-out and ordinary plan, with the definitions in §9; all existing precedence results without
  a Special Plan MUST be unchanged.
- **FR-011** The Special Plan primary CTA `查看聚餐` MUST open Planner (sheet) with that plan's
  detail on its path; Home MUST NOT host `SpecialPlanDetailView`.
- **FR-012** `TodayPlanDetailView` MUST be reduced in this feature to: today rows, per-row
  `做好了` with FR-002 semantics, row → RecipeDetail, and the weekly generator link. `全部做完`,
  `生成今日购物清单` and the legacy delete context menu / alert MUST be removed from it.
- **FR-013** `markAllTodayCooked()` and `removePlan(_ plan:)` MUST NOT be deleted in this feature;
  their removal belongs to the retirement slice of the materialization feature once zero
  production references are proven.
- **FR-014** Every retained Home control MUST keep its identifier, label and destination; no
  theme token, typography, card, chip, badge or gradient is added or changed.
- **FR-015** Section order `Today Context → Primary Task → Needs Attention` and leaf-identifier
  placement MUST be preserved.
- **FR-016** D-041 (superseding D-031 decisions 3–4 and narrowing decision 5) MUST be recorded in
  canonical memory before Slices B and D are implemented.

### Key Entities

- **HomePrimaryTask** — presentation-only; gains `.specialPlanToday` and a Special Plan input.
  No persistence.
- **SpecialPlan** — unchanged; `scheduledAt` and `dishes[].isCooked` read only.
- **MealPlanItem** — unchanged; `isCooked` set via existing `markPlanCooked`.
- **PlannerRoute** — gains `.shoppingToday` (in-repo navigation value, not data).

## Success Criteria *(mandatory)*

- **SC-001** In every Home state at most one prominent CTA and one discovery entry are visible;
  exactly one planning row except execution mode, which carries the interim `今天的计划` plus
  `用餐计划`; enumerated by UI tests over the state-matrix seeds.
- **SC-002** Zero capabilities lost: each §2 capability has a passing test at its owner
  (Planner, reduced `TodayPlanDetailView`) or an owner-approved removal (`全部做完`, legacy delete).
- **SC-003** A plan completed from any origin yields identical persisted state (unit test).
- **SC-004** Every former `+` capability is reachable from its tab in ≤ 2 taps (UI test per row).
- **SC-005** `HomePrimaryTaskTests` exhaustive combination test passes with the Special Plan
  input added and all prior results unchanged.
- **SC-006** No production or test reference to `SmartImportSheet`, `home.import.*`,
  `home.recommendation.refresh` / `viewAll` / `moreLink`, `home.plan.secondaryLink`, `全部做完`,
  or the legacy delete alert remains (`rg` gate in quickstart).
- **SC-007** Focused Home / Planner / accessibility suites pass; full native suite reports no
  new failures beyond the documented Settings baseline red.

## Out of Scope

- Any visual restyle, new card, chip, badge, gradient, hero photo, typography or token change.
- Weekly-menu materialization into Planner and full `TodayPlanDetailView` retirement (blocked;
  §11); AI provenance on Planner entries.
- Quantity-aware readiness; `planNotice` reader; KitchenStore decomposition; dead-code removal
  of `markAllTodayCooked` / `removePlan(_:)`.
- Web/PWA Home; Recipes / Inventory / Shopping IA.
- Planner CRUD design (sealed, D-040).
- Special Plan completion semantics (per-dish flag stays; no consumption).

## Assumptions

- Product copy is Simplified Chinese; strings: `更多推荐`, `做好了` (existing), `更多`,
  `生成今日购物清单` (existing), `查看聚餐`, `今天有聚餐`, `今天还有 N 场`, `今天另有 N 道计划`,
  `今天另有 N 道计划 · 已完成`.
- The recommendation browser's regenerate label stays `AI 换几道` (already there; D-038 host
  treatment).
- No schema, migration, sync, provider, flag or entitlement change.


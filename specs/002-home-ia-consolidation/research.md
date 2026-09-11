# Research: Home IA Consolidation — design decisions

All unknowns resolved from fresh inspection of `1a7475b` and the owner clarifications of
2026-09-10 (spec `## Clarifications`). No open questions remain.

## D1 — Quick-complete lives on Planner rows: leading swipe + context menu + VoiceOver action

**Decision**: pending ordinary rows get `做好了` as the first leading swipe action beside `编辑`
(`allowsFullSwipe: false`, as the existing edge already is), in `.contextMenu`, and as
`.accessibilityAction(named:)`. It presents the existing `CookConsumptionConfirmationView` for that
`MealPlanItem` (`planIDs` empty when `hasConsumedPlan`) and calls `markPlanCooked` — the same tail
the cooking flow and `TodayPlanDetailView.completionButton` use.

**Rationale**: owner instruction; the leading edge currently carries one action so two is
Mail-like native density; trailing edge stays `移出计划`; a permanent button is forbidden; the
shared confirmation keeps trust-before-automation and identical completion from every origin.

**Alternatives**: RecipeDetail secondary action (rejected: `开始烹饪` already ends in the same
confirmation); bare `isCooked` flip (prohibited). Slice A must report, not improvise, if the
two-action leading edge proves inappropriate at Accessibility sizes.

## D2 — `全部做完` is removed, not rehomed (OD-2)

**Decision**: delete the control and its `.cookAll` sheet from `TodayPlanDetailView`. Leave
`markAllTodayCooked()` in the store (FR-013); it is cleaned up by the retirement slice of the
materialization feature after a zero-reference proof.

**Rationale**: per-meal completion is the truthful model; bulk completion weakens the
meal↔consumption relationship; no persisted state depends on it.

## D3 — Shopping derivation: Planner initiates, Shopping owns the result (OD-3)

**Decision**: Planner toolbar gains a trailing `Menu` (`ellipsis.circle`, label `更多`, id
`planner.more.menu`) with one item `生成今日购物清单` (`planner.more.shoppingToday`) →
`PlannerRoute.shoppingToday` → `ShoppingListGenerationView(.todayPlans(kitchenStore.todayPlans))`.

**Rationale**: the input is the meal plan; generation is source-bound everywhere else; the
generated items land in Shopping, which keeps all subsequent management. One overflow item is the
least prominent native placement.

**Alternatives**: Shopping bulk-menu item (rejected by owner: Shopping would initiate from a
source it does not display); Home (forbidden).

## D4 — The AI weekly generator stays where it is; no Planner entry, no bridge

**Decision**: gate answered YES (spec §2.1). `today.plan.weeklyMenu.link` remains on the reduced
`TodayPlanDetailView`; `WeeklyMenuPlanner.swift` is untouched.

**Rationale**: `保存本周计划` on a dated `本周菜单` screen, launched from Planner, would read as
scheduling into Planner while writing only `weeklyPlan`. A relabelled bridge would exist only to
permit deletion, which the owner ruled out.

**Alternatives**: Planner `更多` entry with truthful draft copy (rejected: only permitted under a
NO answer); Recipes tab placement (not evaluated: unrequested IA change).

## D5 — Home → Planner stays a fresh sheet on the current week; `initialPath` for Special Plan

**Decision**: keep `.sheet { PlannerView() }`; add `init(initialPath: [PlannerRoute] = [], …)`.

**Rationale**: current behaviour already lands on the current week with today marked; a
re-created sheet is standard iOS; push would require removing Planner's own `NavigationStack`.

## D6 — Suppressed ordinary plans become one non-interactive context line (OD-4/OD-5)

**Decision**: when the primary task is `.mealPrepBoard`, `.eatOut` or `.specialPlanToday` and
ordinary plans exist today, Today Context shows one `Text` line: `今天另有 N 道计划` if any is
pending, `今天另有 N 道计划 · 已完成` if all are cooked; nothing otherwise. No chevron, no button
trait, identifier `home.context.otherPlans`. `HomePrimaryTask` exposes the line model so the copy
is unit-tested.

**Rationale**: D-039 already allows one meaningful context line in exceptional states; keeps
`用餐计划` the only planning row on those days; `今日计划已全部完成` rejected because a pending
Special Plan makes it false.

## D7 — Special Plan today is a new `HomePrimaryTaskKind`, decided in the pure function

**Decision**: add `.specialPlanToday`; `resolve` takes today's Special Plans sorted by `scheduledAt`;
the branch sits after `eatOut` and before `planState != .empty`. Earliest wins; completed =
non-empty dishes all cooked; completed plans remain primary. Suppressed under prep / eat-out the
plan is one context line `今天有聚餐 · <HH:mm> <title>` (`home.context.specialPlan`).

**Rationale**: keeps the single testable decision point; existing 32 combinations unchanged when
the input is empty; no persistence.

## D8 — Discovery consolidation reuses the browser's regenerate; `更多推荐` above `用餐计划` (OD-6)

**Decision**: delete Home `AI 换几道`; rename `查看全部` / `想再加一道` to `更多推荐` with one
identifier `home.recommendation.more`; in execution mode the row stays above `用餐计划`.

**Rationale**: `recommendation.regenerate.button` already exists with identical behaviour and
richer state handling. Order: `更多推荐` is contextual discovery for the current meal task,
`用餐计划` is global plan management; task-local secondary action precedes global management.
Home-scoped rationale only.

## D9 — `TodayPlanDetailView` is reduced now, retired later (verdict C)

**Decision**: remove `全部做完`, `生成今日购物清单`, the legacy delete context menu + alert; keep
rows, `做好了`, RecipeDetail navigation, the weekly generator link, the `今天的计划` title and its
execution-mode Home route. Remove `home.plan.secondaryLink` (eat-out / prep route) in favour of
D6; the generator is then reachable only in execution mode, which is its condition in Decision
mode already.

**Rationale**: capability ownership first; the only capability without a truthful new home is the
generator, and it must not be moved before materialization.

## D-041 draft (for vault write-back at seal; not yet recorded)

> **D-041 — Home keeps one planning route to Planner; Special Plan today may be the primary task**
>
> Supersedes **only** D-031 decision 3 (the Today card action `今天的计划` is interim, not a
> permanent Home destination, and disappears with weekly materialization) and decision 4 (the
> weekly generator's placement is no longer a Home-contract fact; it stays on the reduced
> `TodayPlanDetailView` until materialization). Narrows decision 5: a Special Plan scheduled for
> today may be Home's primary task with a single CTA `查看聚餐` that opens Planner at that plan;
> Home still hosts no Special Plan navigation entry and none of the banned words. D-031 decisions
> 1, 2 and 6 and its Home-responsibility statement remain in force. Suppressed ordinary plans are
> stated by one non-interactive line (`今天另有 N 道计划` / `… · 已完成`), never a second planning
> row. `全部做完` is removed; per-meal `做好了` lives in Planner with cooking-flow semantics.
> Planner initiates `生成今日购物清单`; Shopping owns the result. Home has no `+` and no `AI 换几道`;
> its single discovery entry is `更多推荐`, placed above `用餐计划` because task-local discovery
> precedes global plan management (Home-scoped rationale).


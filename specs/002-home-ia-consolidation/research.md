# Research: Home IA Consolidation — design decisions

Unknowns resolved from fresh inspection of `eb894a8` on top of `main` = `a7b7d8f`, plus the
owner clarifications of 2026-09-10 and the governing decisions of 2026-09-11 (spec
`## Clarifications`). No open questions remain.

Where a 2026-09-10 decision was reversed by shipped code, the entry states what changed rather
than pretending the original reasoning never happened.

## D1 — Quick-complete lives on Planner rows: leading swipe + context menu + VoiceOver action

**Decision**: pending ordinary rows get `做好了` as the first leading swipe action beside `编辑`
(`allowsFullSwipe: false`, as the existing edge already is), in `.contextMenu`, and as
`.accessibilityAction(named:)`. Each presents the existing `CookConsumptionConfirmationView` for
that `MealPlanItem` (exact plan IDs always preserved; an already-consumed plan confirms with
zero deduction through the shared already-satisfied state) and calls `markPlanCooked` — the same
tail the cooking flow uses; the TodayPlanDetail counterpart has been deleted.

**Rationale**: owner instruction; the leading edge currently carries one action so two is
Mail-like native density; the trailing edge stays `移出计划`; a permanent button is forbidden; the
shared confirmation keeps trust-before-automation and identical completion from every origin. The
three-path shape mirrors what Planner's delete already does (swipe, context menu, VoiceOver custom
action), so it is the established pattern in this exact view rather than a new one.

**Alternatives**: RecipeDetail secondary action (rejected: `开始烹饪` already ends in the same
confirmation, and reaching it costs a push plus a full cooking-mode pass); bare `isCooked` flip
(prohibited). Slice A must report, not improvise, if the two-action leading edge proves
inappropriate at Accessibility sizes.

## D2 — `全部做完` is removed, not rehomed (OD-2)

**Decision**: delete the control and its `.cookAll` sheet, and delete
`KitchenStore.markAllTodayCooked()` in Slice E once the zero-reference proof passes.

**Rationale**: per-meal completion is the truthful model; bulk completion weakens the
meal↔consumption relationship; no persisted state depends on it. The deleted store method had exactly one
production caller — the retired view — so its cleanup belongs to this feature rather
than a later one.

**Changed since 2026-09-10**: the cleanup was previously deferred to a future retirement slice
owned by another feature. That feature does not exist; Slice E here owns it.

## D3 — Shopping derivation: Planner initiates, Shopping owns the result (OD-3)

**Decision**: Planner's toolbar gains a trailing `Menu` (`ellipsis.circle`, label `更多`)
containing `生成今日购物清单`, which opens
`ShoppingListGenerationView(.todayPlans(kitchenStore.todayPlans))`.

**Rationale**: the input is the meal plan; generation is source-bound everywhere else; the
generated items land in Shopping, which keeps all subsequent management. One overflow item is the
least prominent native placement. `ShoppingGenerationSource.todayPlans` survives — this re-homes
its only production construction site rather than retiring the case.

**Alternatives**: a Shopping bulk-menu item (rejected by the owner: Shopping would initiate from a
source it does not display); Home (forbidden).

## D4 — The AI weekly generator moves into Planner, hosted not absorbed

**Decision**: Planner hosts `WeeklyMenuPlannerView` from its own navigation and passes
`onMaterialized`. The generator keeps generation, materialization, recovery and persistence.

**Rationale**: the 2026-09-10 gate asked whether a member entering from Planner would wrongly
believe Save scheduled meals into Planner. On `1a7475b` that belief was false, so the move was
refused. D-041 shipped on `a7b7d8f` and made the belief **true**: `加入用餐计划` resolves recipes,
commits a receipt, and writes canonical `MealPlanItem`s through one all-or-none
`KitchenStore.appendPlans` batch. The reason for refusing the move no longer exists, and the
generator is now hosted by Planner.

**Changed since 2026-09-10**: this reverses D4 as it was originally written. The old entry
concluded “stays on `TodayPlanDetailView`; `WeeklyMenuPlanner.swift` is untouched”. The file is
still untouched, but the host changes.

**Alternatives**: leaving the generator on a surviving reduced view (rejected: it would keep a
second plan-management destination alive purely to host one link, which is the duplication this
feature exists to remove); giving it a Home entry (rejected: Home hosts no generation, D-038);
building a Planner-side generator (rejected: it would duplicate D-041's logic).

## D5 — Home → Planner stays a fresh sheet on the current week; initial path for Special Plan

**Decision**: keep `.sheet { PlannerView() }`; add an initial-path seed so Home can open Planner
directly at a Special Plan's detail.

**Rationale**: current behaviour already lands on the current week with today marked
(`weekStart` is `@State` initialised from `PlannerProjection.startOfWeek(containing: now)`); a
re-created sheet is standard iOS; a push would require removing Planner's own `NavigationStack`.
`PlannerRoute` and `NavigationStack(path:)` already exist, so seeding the path is the smallest
change that keeps Home from hosting `SpecialPlanDetailView`.

## D6 — Suppressed ordinary plans become one non-interactive context line (OD-4/OD-5)

**Decision**: when the primary task is `.mealPrepBoard`, `.eatOut` or `.specialPlanToday` and
ordinary plans exist today, Today Context shows one `Text` line: `今天另有 N 道计划` if any is
pending, `今天另有 N 道计划 · 已完成` if all are cooked, nothing otherwise. No chevron, no button
trait, identifier `home.context.otherPlans`. `HomePrimaryTask` exposes the line model so the copy
is unit-tested rather than asserted only through the UI.

**Rationale**: D-039 already allows one meaningful context line in exceptional states; it keeps
`用餐计划` the only planning row on those days; `今日计划已全部完成` is rejected because a pending
Special Plan makes it false.

## D7 — Special Plan today is a new `HomePrimaryTaskKind`, decided in the pure function

**Decision**: add `.specialPlanToday`; `resolve` takes today's Special Plans sorted by
`scheduledAt`; the branch sits after the `eatOut` check and before `planState != .empty`. Earliest
wins; completed = non-empty dishes all cooked; completed plans remain primary. Suppressed under
prep or eat-out, the plan is one context line `今天有聚餐 · <HH:mm> <title>`
(`home.context.specialPlan`), with ` · 已完成` appended for a completed event.

**Rationale**: keeps the single testable decision point that `HomePrimaryTaskTests` already
exercises exhaustively; existing combinations are unchanged when the input is empty; no
persistence. Home now passes Special Plans into the resolver; HomeDashboardSummary remains unchanged.

## D8 — Discovery consolidation reuses the browser's regenerate; `更多推荐` above `用餐计划` (OD-6)

**Decision**: delete Home's `AI 换几道`; replace `查看全部` and `想再加一道` with `更多推荐` under
one identifier `home.recommendation.more`; in execution mode the row stays above `用餐计划`.

**Rationale**: `recommendation.regenerate.button` already exists in the browser with identical
behaviour, the same label and richer state handling. Order: `更多推荐` is contextual discovery for
the current meal task and `用餐计划` is global plan management, so task-local secondary action
precedes global management. Home-scoped rationale only. `更多推荐` is now the implemented Home discovery label.

## D9 — `TodayPlanDetailView` is retired in this feature (classification B)

**Decision**: after Planner has parity (D1, D3, D4) and Home has one planning route, delete the
view, its route, its identifiers and the code only it kept alive.

**Rationale**: capability ownership first, deletion second. Every capability now has an owner or
an explicit removal decision, so nothing is lost by deleting the view. Keeping it would preserve
exactly what this feature exists to remove: a second plan-management destination reachable by two
Home controls, carrying a delete path that contradicts D-040 and a subtitle that calls a draft
scheduled.

**Changed since 2026-09-10**: the original entry recorded verdict C — retirement deferred to a
future weekly-materialization feature — because the generator had no truthful other home. That
feature shipped as 003, so the deferral has no remaining basis and no successor feature is needed.

**Alternatives**: keeping a reduced view (rejected above); deleting the view before parity
(rejected: it would drop capabilities the owner chose to keep).

## D10 — Host contract and the week rule for a materialized range

**Decision**: Planner owns host navigation only. It may open `WeeklyMenuPlannerView`, pass
`onMaterialized`, receive `WeeklyMaterializationSummary`, use `startDate`/`endDate` to reveal the
relevant range, and dismiss the generator. It may not inspect receipt internals, duplicate
materialization logic, infer plan ids, or add a second notification channel. When the covered
range crosses two Planner weeks, Planner reveals **the week containing `startDate`**.

**Rationale**: the summary deliberately carries no ids, because after a `保留当前安排` recovery
choice some intended meals are absent on purpose; a host that inferred ids would claim rows that
may not exist. For the week rule, D-041 records that a generated range is a rolling 1…7 days from
`startDate` and may legitimately span two Monday–Sunday weeks, and the codebase already resolves a
single dated item to `PlannerProjection.startOfWeek(containing:)` in the private
`PlannerView.reveal(_:)`. Anchoring on `startDate` reuses that convention instead of inventing a
week concept, and it lands the member on the first day of what they just created.

**Alternatives**: revealing the week containing `endDate` (rejected: it skips the beginning of the
member's own range); introducing a multi-week view (rejected: unrequested IA change); doing
nothing after materialization (rejected: the member would be left on the generator with no
evidence their meals exist).

## D11 — Decision assignment completed as D-042

**Decision**: D-042 was assigned after reading canonical `Decisions.md` and accepted before
B/D/E. The unnumbered draft below is preserved only as historical provenance.

**Rationale**: the 2026-09-10 session verified D-040 as the latest Decision and therefore wrote
D-041 into this spec. 003 then shipped and took D-041 for canonical plan ownership. A spec that
pins a number ahead of the write is wrong the moment another feature seals first, so the number is
resolved against `Decisions.md` at the moment of writing, not now.

## Historical Decision draft — unnumbered; superseded by recorded D-042

> **Home keeps one planning route to Planner; Special Plan today may be the primary task**
>
> Supersedes **only** D-031 decision 3 (the Today card action `今天的计划` is retired, not
> renamed: Home has no second plan-management destination) and decision 4 (the weekly generator's
> placement is no longer a Home-contract fact; Planner hosts it, and D-041 already answered what
> D-031 deferred about its data model). Narrows decision 5: a Special Plan scheduled for today may
> be Home's primary task with a single CTA `查看聚餐` that opens Planner at that plan; Home still
> hosts no Special Plan navigation entry and none of the banned words. D-031 decisions 1, 2 and 6
> and its Home-responsibility statement remain in force. Suppressed ordinary plans are stated by
> one non-interactive line (`今天另有 N 道计划` / `… · 已完成`), never a second planning row.
> `全部做完` is removed; per-meal `做好了` lives on Planner rows with cooking-flow semantics.
> Planner initiates `生成今日购物清单` and Shopping owns the result. Planner hosts the AI weekly
> generator as a host only, consuming D-041's `onMaterialized` and revealing the week containing
> the summary's `startDate`. Home has no `+` and no `AI 换几道`; its single discovery entry is
> `更多推荐`, placed above `用餐计划` because task-local discovery precedes global plan management
> (Home-scoped rationale). `TodayPlanDetailView` is deleted.

The assignment described above is complete. No new Decision is requested at seal.

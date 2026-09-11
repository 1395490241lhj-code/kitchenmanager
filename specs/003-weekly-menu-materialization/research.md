# Research: Weekly Menu → Canonical Planner Materialization

Resolved from fresh inspection of `1a7475b` plus the owner clarifications (spec `## Clarifications`).
No open questions.

## R1 — One batch over fully formed items; a loop of `addPlan` is rejected

**Decision**: `appendPlans(_ items: [MealPlanItem], calendar:) -> PlanBatchOutcome`, committing once
via `commitPlans`. The name is distinct from D-040's shipped `addPlans(_ additions:)`, whose same-day
deduplication is the opposite contract; two overloads under one name would hide which rule applies.

**Rationale**: `TodayPlanPersistence.replacePlans` is one `context.save()` with `context.rollback()`
on failure, so the batch is atomic; each `addPlan` is its own save, so a loop can stop half-way.
Taking whole `MealPlanItem` values satisfies every contract requirement at once — caller-known ids,
explicit dates, `nil` servings, legitimate duplicates — with no optional-date tuple.

**Why a separate outcome type**: `TodayPlanRecord.id` is `@Attribute(.unique)` and `replacePlans`
uniques its incoming dictionary by id, so two items sharing an id would silently collapse into one
row — the batch must reject that before writing. `PlanMutationOutcome` has no case for a refused
precondition, and widening that sealed D-040 enum would force three exhaustive Planner switches to
change. `PlanBatchOutcome` keeps D-040 untouched and makes rejection observable.

**Alternatives**: a store-layer transaction (none exists); per-item upsert (same partiality);
reporting empty input as an empty success (rejected: a vacuous success reads like a real one).

## R2 — Recipes first, in one batch; residue is kept (OD-3)

**Decision**: `RecipeStore.saveUserRecipes([Recipe])` → one `replaceRecipes`. Reuse is **safe
exact-identity reuse**: an id already present is reused only when the stored recipe carries the same
content, and the same id carrying conflicting content fails explicitly rather than being overwritten
or silently replaced. Identical dishes inside one request collapse to the first. Identity is exact —
id, then content equality to confirm it — never a name match or a likeness score.

**Rationale**: `RecipeStore` and `KitchenStore` own separate `ModelContext`s on the shared container
and SwiftData offers no cross-context transaction, so the honest guarantee is per-store. Recipes must
be durable before plans, otherwise a materialized row can point at a recipe that was never saved —
the dangling-id bug today's `加入今日计划` already produces. Orphan recipes after a plan failure are
real, viewable, deletable recipes with no schedule, and they are what makes retry idempotent.

**Alternatives**: compensating deletion (a third write that can itself fail, and it would break
retry's id reuse — explicitly rejected by OD-3); single-recipe loop (N transactions).

## R3 — Rolling N-day dates, reusing the draft's own arithmetic (OD-11)

**Decision**: `startOfDay(startDate) + dayIndex days` → `MealPlanItem.normalizedPlannerDate`.
Planner grouping is untouched, so a menu may span two Monday-anchored Planner weeks.

**Rationale**: identical to `dayTitle` and `dayIndexForToday`, so there is one date implementation;
DST and timezone caveats are exactly those D-040 already documents. The generator's `numberOfDays` is
1–7, so the copy states the explicit range rather than a fixed “7 天” or any `本周` claim.

## R4 — `plannedServings` is `nil` (OD-4)

**Decision**: every materialized item carries `nil`.

**Rationale**: `WeeklyMealPlan.servings` is the household stepper used for generation; the code
already states it is not a per-dish numerator, and `MealPlanItem.plannedServings` documents `nil` as
“nobody stated a target”. Writing the headcount per dish would restate a number the user never chose
for that dish and would silently re-create the ambiguity D-040 removed.

## R5 — Append with one confirmation (OD-5)

**Decision**: append after existing same-day rows; one confirmation when any target date already
holds ordinary meals, stating that existing meals remain and generated meals are added; identical
recipe/day pairs remain valid; no name-based dedup.

**Rationale**: explicit dated adds never dedupe under D-040; nothing is ever replaced; one prompt is
the smallest honest interruption.

## R6 — Exact-identity receipt, not a `(recipeID, date)` heuristic (OD-7)

**Decision**: allocate the exact `MealPlanItem` ids before writing anything canonical, persist them in
a **pending** receipt on the draft, run the batch with exactly those ids, then mark the receipt
**materialized**. Recovery compares those ids against `plans` and only while the receipt is pending.

**Rationale**: `(recipeID, date)` is not a unique key — duplicates are legal and an equivalent meal may
already exist independently — so a full-set match cannot prove provenance. Exact ids can. Persisting
the ids *before* the batch is what makes an interrupted attempt recoverable rather than ambiguous.

**Why a materialized receipt is never re-verified**: deleting a materialized meal in Planner is
legitimate; re-checking presence would re-offer the CTA and re-create meals the user removed.

**Partial subset**: surfaced as an explicit recovery case with two user actions
(`重新加入缺少的 N 道` using only the missing exact ids, or `保留当前安排` finalizing the receipt without
writing). Automatic repair is wrong because a missing id is equally consistent with a deliberate
Planner deletion; blind re-adding is exactly the duplication OD-7 forbids.

## R7 — The pending receipt needs an observable draft write

**Decision**: add `KitchenStore.commitWeeklyPlan(_:) -> Bool`, mirroring `commitPlans`
(persist-before-publish, publish suppressed so `didSet` does not repeat the write).

**Rationale**: `saveWeeklyPlan` publishes first and persists from `didSet`, where a failure becomes
`weeklyPlanNotice` copy only. A pending receipt written that way could be lost while the canonical
batch proceeds, producing exactly the unrecoverable state OD-7's ordering exists to prevent.

## R8 — Manual add-today actions are removed outright (OD-1)

**Decision**: delete `把今天加入计划` and per-dish `加入今日计划` from the result surface in every
state, along with `addRecipeToTodayPlan` / `addDayToTodayPlan`.

**Rationale**: they add to today regardless of the dish's date, can persist a `weekly-ai-…` id no
recipe carries, and after materialization would double-add through a legacy path. OD-1 requires
convergence on one canonical action; keeping them “pre-Save only” would retain the dangling-id
hazard and a second way to reach `plans` from this screen.

## R9 — Host callback for post-materialization navigation (OD-8)

**Decision**: `onMaterialized: ((WeeklyMaterializationSummary) -> Void)?` on the generator/result
surface, where the summary is the covered date range only (`startDate`, `endDate`). It fires once
per member-initiated completion — first append, append whose receipt finalization lagged,
`重新加入缺少的 N 道`, `保留当前安排` — and never as a state observer: reopening a finished menu,
passive receipt repair and every failure or cancel path stay silent. The legacy Home host passes
nothing; a future Planner host may pop and reveal the dates.

**Rationale**: the generator is currently pushed on the Home tab stack where Planner is a sheet, so
it cannot dismiss “back to Planner”; the policy belongs to whoever hosts it. Empty draft disables
the CTA. Ids were dropped from the summary: after `保留当前安排` some intended meals are absent on
purpose, so any id list would either claim rows that do not exist or need bookkeeping no host needs.

## R10 — Restock derives from canonical plans (OD-9)

**Decision**: the global branch in `RestockSuggestionEngine` stops reading `kitchenStore.weeklyPlan`
and instead expands **pending** ordinary meals from today through today + 6 days, fed to a new
`ShoppingGenerationSource.plannedMeals([MealPlanItem])` case. The restock source case renames
`.weeklyPlan` → `.plannedMeals`; the reason becomes `未来 7 天计划需要`. The slice is a pure
`PlannedMealHorizon` projection taking `plans:` as a parameter, matching the existing Home projections.

**Why a new generator case instead of reusing `.todayPlans`** (owner gate): `.todayPlans` means today,
and Home still uses it that way. Passing a seven-day set through it would make the name a lie and
label the resulting shopping items `今日计划`. The new case resolves through the same branch body — a
`MealPlanItem` becomes a recipe identically either way — and only its label differs (`用餐计划`), so
the cost is one enum case and one label line.

**Measured scope (OD-9 asked for the exact dependency)**: three production files plus one small new
file. The `ShoppingListGenerator` change is three lines — the new case, its label, and adding it to
the existing `.todayPlans` branch pattern — because a `MealPlanItem` list carries no date logic, no
`isCooked` filter and no today check in there; the horizon stays with the caller. **No existing test
breaks**: no test
seeds a `weeklyPlan` before calling the engine, the two absence assertions stay true, and the
accessibility seed clears local data first.

**Naming residue closed**: an earlier draft of this decision reused `.todayPlans` for the multi-day
slice and recorded the misleading name as a follow-up. The owner rejected that trade, so the slice
ships its own case and Home's `今日计划` label is untouched. No follow-up remains.

**Kept as draft state**: backup/restore, guest-merge `weeklyPlanCount`, migration and
`clearAllLocalData` continue to carry `weeklyPlan`; that does not make it a schedule. The in-flow
`生成购物清单` keeps using `.weeklyPlan` explicitly (OD-9 boundary A), so
`ShoppingScalingTests.testWeeklyHouseholdHeadcountNeverScales` survives.

**Dead code found during the audit**: `KitchenStore.todaysWeeklyMeals()` has no callers and maps today
onto the draft's `dayIndex` — a second-schedule reading. Removed as part of R10.
`RestockSuggestionSource.label` is unreachable (the reason string is hardcoded at the call site) and
is deleted along with the case rename, rather than left holding a second copy of the copy.

## R11b — The receipt binds days, not just recipes

**Decision**: the receipt carries `planDates` parallel to `planIDs` and `recipeIDs`, and integrity
requires all three sequences to match the current draft.

**Rationale**: identity and recipe alone cannot describe the mapping. The same recipe on Monday and
Tuesday produces the id sequence `[R, R]` either way, so a draft whose days moved would still pass
and a retry would write the approved ids onto the draft's current days — meals silently relocated
without anyone approving it. Relying on the result screen currently offering no way to move a dish
is not a durable guarantee; persistence recovery has to be self-describing.

**Alternatives**: storing whole `MealPlanItem`s in the receipt (rejected: a second schedule model);
recipe names or positional heuristics (rejected: guessing). A pending receipt that predates the
field is treated as stale rather than assumed correct.

## R11 — Decision number is taken, never reserved (OD-10)

**Decision**: at Slice E, re-read `Decisions.md` and take the actual next number — D-041 if nothing
lands first. 002 rebases to the number after.

**Draft Decision text (number assigned at reconciliation):**

> **D-0xx — Weekly menu materialization writes canonical Planner meals under an exact-identity
> receipt.** The generated menu is a rolling N-day draft (N ≤ 7) starting at its own `startDate`; it
> may span two Planner weeks and is never described as `本周`. Its single canonical action resolves
> recipes, allocates the exact `MealPlanItem` ids, persists a pending receipt on the draft, writes all
> items in one atomic batch through `commitPlans`, then marks the receipt materialized. Success copy
> (`已加入用餐计划`) appears only when those exact ids are durably present. Recovery uses exact id
> identity only; a partial set is an explicit user-resolved case. Plan materialization is all-or-none;
> generated recipes persisted first may remain in the library if the plan write fails, and retry
> reuses them. `plannedServings` is `nil`. Existing Planner meals are appended to after one
> confirmation, never replaced. The manual add-today actions are removed. `KitchenStore.weeklyPlan` is
> a resumable draft, a receipt and an in-flow shopping source — never a schedule; global restock
> derives from canonical `plans`. No provenance is stored on `MealPlanItem` or `Recipe`.

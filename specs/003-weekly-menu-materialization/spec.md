# Feature Specification: Weekly Menu → Canonical Planner Materialization

**Feature Branch**: `codex/003-weekly-menu-materialization`

**Created**: 2026-09-10

**Status**: Sealed for planning — audit + specification + owner clarifications (OD-1…OD-11) encoded. No product code changed.

**Input**: Owner brief “003 — Weekly Menu → Canonical Planner Materialization” and the owner clarifications of 2026-09-10, on `main` = `1a7475b` (D-040 Planner CRUD sealed). Prerequisite for completing 002 (Home IA consolidation), whose local spec branch (`4e6623a`) is untouched.

## Overview

The AI menu generator tells the user a week was **saved** (`保存本周计划` → `已保存本周计划`, dated day
sections, `已安排 N 天 · M 道菜`) but persists only the legacy `KitchenStore.weeklyPlan`, which Planner
never reads. Target invariant:

> When the generator says the menu was added to the meal plan, the exact intended canonical
> `MealPlanItem`s are durably present in `KitchenStore.plans` — all of them, or none.

Bounded change: one canonical materialization action writing canonical plans atomically with
caller-allocated ids under a pending/materialized receipt; truthful rolling-N-day copy; removal of
the manual add-today bypasses; and migration of global restock semantics off the unmaterialized
draft. No Home changes, no AI provenance, no visual redesign.

## Clarifications

### Session 2026-09-10

- Q: Keep the manual add-today actions? → A: **OD-1 remove both** (`把今天加入计划`, per-dish
  `加入今日计划`) from the result surface in every state. They ignore the dish's date, can persist
  dangling `recipeID`s, and can double-add after materialization. 003 converges on **one**
  full-result canonical materialization action.
- Q: A `.local` dish whose `Recipe` no longer exists at materialization time? → A: **OD-2 fail
  honestly.** Never recreate silently, never match by name, never reclassify as `.ai`, never persist
  a dangling `recipeID`. Name the affected dish; keep the draft for correction or regeneration.
- Q: Recipes persisted but the plan batch then fails? → A: **OD-3** plan materialization is all-or-none;
  newly persisted generated recipes may remain in the library. No compensating deletion to fake
  cross-context atomicity. Retry reuses already-persisted recipe ids.
- Q: `plannedServings`? → A: **OD-4 `nil`.** `WeeklyMealPlan.servings` is generation/household
  context, not a proven per-dish target. No `?? 2` fallback. Revisitable only by a separate
  servings/quantity feature.
- Q: Existing Planner meals on target dates? → A: **OD-5 append**, never silently replace. One
  explicit confirmation when any target date already holds ordinary meals, stating that existing
  meals remain and generated meals are added. Same-recipe/same-day duplicates stay valid; no
  name-based dedup.
- Q: User-visible copy? → A: **OD-6** retire `本周菜单` / `保存本周计划` / `已保存本周计划`. Entry
  `生成一周菜单`; result context is the explicit date range; primary CTA `加入用餐计划`; success
  `已加入用餐计划`. Describe what happened: canonical Planner entries were created. Claim no week
  boundary the data does not use.
- Q: Idempotency mechanism? → A: **OD-7 reject** heuristic recovery from `(recipeID, date)` matching —
  that pair is not unique, duplicates are legal, and a full-set match cannot prove provenance. Use
  **exact `MealPlanItem` identity**: resolve recipes → allocate exact UUIDs → persist a *pending*
  receipt carrying those ids → one atomic batch using exactly those ids → mark the receipt
  materialized. Recovery rules in §7. The receipt belongs to the weekly draft record. No AI
  provenance on `MealPlanItem`; no second Planner schedule.
- Q: Regeneration after a successful materialization? → A: it must not alter or remove already-created
  Planner meals; confirmation states `重新生成不会更改已经加入用餐计划的菜品。`; a regenerated draft gets a
  fresh receipt. A successful receipt is never reused for a new draft.
- Q: Post-materialization navigation? → A: **OD-8** the generator does not own navigation policy.
  Expose a host-level completion callback; the legacy host may offer `查看用餐计划`; a future Planner
  host (002) may dismiss and reveal the materialized dates. Empty draft → CTA disabled. No custom
  navigation system.
- Q: Legacy `weeklyPlan` and restock semantics? → A: **OD-9 modified.** `weeklyPlan` is a resumable
  generated draft + materialization receipt, never a canonical schedule. Inside the draft/result
  flow, shopping calculations may use the draft explicitly. Global restock / inventory surfaces MUST
  derive scheduled-plan semantics from canonical `KitchenStore.plans`, and MUST NOT show copy like
  `本周计划需要` sourced from an unmaterialized draft. Backup / guest-merge may keep carrying the
  draft; that does not make it a schedule.
- Q: Decision number? → A: **OD-10 reserve nothing.** The vault ends at D-040; 002 has only a local
  spec proposal and has not consumed D-041. At 003 final reconciliation, re-read `Decisions.md` and
  take the actual next number (D-041 if nothing lands first); 002 rebases to the next one after.
- Q: What does “a week” mean here? → A: **OD-11** a rolling N-day menu (N = `numberOfDays`, 1–7,
  default 7) beginning at the generated `startDate` (default today). Mapping is start civil day +
  offsets `0…N-1` through the existing Planner-date normalization. It may legitimately span two
  Monday–Sunday Planner weeks; that is not an error. Do not silently switch generation to the
  Monday–Sunday week, do not call the result `本周菜单`, and do not claim timezone-independent
  civil-date semantics. Planner keeps grouping materialized dates into its own weeks.

## 1. Current architecture (audited on `1a7475b`)

All in `KitchenManager/WeeklyMenuPlanner.swift` unless noted.

| Layer | What exists | Notes |
|---|---|---|
| Input | `WeeklyMenuPlannerInput`: `numberOfDays` 1–7 (default 7), `mealsPerDay` 1–3, `dishesPerMeal` 1–4, `servings` 1–12 (default 2, labelled `N 人`), cuisines, flavors, `maxCookingTime`, expiring-first, avoid-repeat, exclusions, `allowNewAIRecipes`, free text | `WeeklyMenuPlannerView`, title `生成一周菜单`, CTA `生成本周菜单` |
| Response | `AIWeeklyMenuResponse`: `days[dayIndex].meals[mealIndex].recipes[]` (`existingRecipeID?`, name, ingredients?, steps?, tags?, cookingTime?, difficulty?, reason?, source?, `baseServings?`), `shoppingItems?`, `warnings?` | `baseServings` is decoded then dropped |
| Draft | `WeeklyMealPlan` { `startDate`, `days`, `shoppingItems`, `servings`, `summary`, `createdAt` }; `WeeklyMealPlanRecipe` { `id`, title, ingredients, seasonings?, steps, tags, cookingTime?, difficulty?, reason?, `source: .local/.ai`, `existingRecipeID?`, `isSavedToLibrary` } | no plan-level identity; `createdAt` only |
| Draft store | `WeeklyMenuPlannerStore` (`@MainActor`, `@StateObject` per view): generate / regenerate / replace / move / remove, `savePlan`, `addRecipeToTodayPlan`, `addDayToTodayPlan`, `saveRecipeToLibrary`, `addShoppingItems`; `loadSavedPlanIfNeeded` rehydrates from `kitchenStore.weeklyPlan` | |
| Persistence | `KitchenStore.weeklyPlan` (`@Published`, `didSet → persistWeeklyPlanIfNeeded` → `WeeklyPlanPersistence.replacePlan`, failure becomes `weeklyPlanNotice` only); `WeeklyPlanRecord` (one SwiftData record, JSON `planData`); legacy UserDefaults `native_km_weekly_plan_v1` via `WeeklyPlanMigration` | the draft write path has **no observable outcome** today (§5) |
| Canonical plans | `KitchenStore.plans` → `TodayPlanRecord` via `commitPlans` (persist-before-publish) / `persistPlansIfNeeded` (legacy `didSet`) | `TodayPlanRecord.id` is `@Attribute(.unique)` |
| Other `weeklyPlan` readers | result `生成本周购物清单`; `RestockSuggestionEngine` (`InventoryConsumption.swift:225`); `TodayPlanDetailView` row title/subtitle (`HomeView.swift:2213, 2338`); `duplicateWeeklyPlanForNextWeek`; **dead** `KitchenStore.todaysWeeklyMeals()` (no callers); backup/restore; `clearAllLocalData`; `InventoryMergePlanner.weeklyPlanCount`; flag-gated sync/guest-merge smokes | it is not dead state |
| Entry routes | `TodayPlanDetailView` → `today.plan.weeklyMenu.link` (sole production route); DEBUG `PlannerRegressionFixture` states | 002 may later host it from Planner |
| Tests | `WeeklyPlanPersistenceTests`, `WeeklyMealPlanDerivedCountTests`, `WeeklyMenuBaseYieldCompatibilityTests`, `ShoppingScalingTests.testWeeklyHouseholdHeadcountNeverScales`; `PlannerUITests` asserts reachability only | the weekly views carry **no** accessibility identifiers and **no** generation/Save UI tests |

### 1.1 Precise current flow

    user input
    → AI → AIWeeklyMenuResponse
    → makePlan: startDate = existingStartDate ?? startOfDay(today); day = startDate + dayIndex
       · DTO existingRecipeID resolving in recipeStore.recipes and source != "ai" → .local, id = matched.id
       · otherwise → .ai, id = "weekly-ai-<uuid>", absent from RecipeStore
    → WeeklyMenuResultView (title 本周菜单; dated headers; per-dish ⋯: 查看菜谱 / 替换这道 / 移到其他天 /
      保存到菜谱库 (AI) / 加入今日计划 / 从计划移除; overview 把今天加入计划;
      ⋯: 重新生成整周 / 保存本周计划 / 生成本周购物清单 / 复制为下一周 / 删除本周计划)
    → 保存本周计划 → saveWeeklyPlan → weeklyPlan didSet → WeeklyPlanRecord
    → toast 已保存本周计划; screen unchanged
    → KitchenStore.plans UNCHANGED → Planner shows nothing → Home shows nothing

### 1.2 Why Save is semantically false

Save persists `WeeklyMealPlan` only. Canonical `plans` (D-040) is written solely by the two manual
actions, which add to **today** regardless of the dish's day and — for AI dishes not yet saved to the
library — with a `recipeID` (`weekly-ai-…`) no `Recipe` carries, so Planner and Home fall back to
`菜谱暂不可用`. The copy promises a schedule the canonical source never receives.

## 2. Generated-recipe lifecycle

| | Existing-recipe dish (`.local`) | New AI dish (`.ai`) |
|---|---|---|
| canonical `Recipe.id` | yes (`existingRecipeID == id`), verified **at generation time only** | no — `weekly-ai-<uuid>` until `saveUserRecipe` persists a user recipe under that same id |
| content | copied from the matched recipe | from DTO; empty steps become `["暂未提供详细步骤。"]` in `domainRecipe` |
| `baseServings` | the recipe's own | dropped (`nil`), pinned by `WeeklyMenuBaseYieldCompatibilityTests` |
| date identity | `startDate + dayIndex` | same |
| may vanish before materialization | **yes** (user deleted the recipe) → OD-2 refusal | n/a |

To become `MealPlanItem(id, recipeID, recipeName, date, plannedServings, isCooked)` a dish needs: a
canonical recipe id `recipeStore.recipe(id:)` resolves; the Planner date (§6); `plannedServings = nil`
(OD-4); and a caller-allocated `id` (§5). No provenance field and no `来自一周菜单` label anywhere.

## 3. Materialization state machine

States are derived, not stored twice: the stored receipt (§4) plus `kitchenStore.plans` determine the
state.

| State | Condition | Result surface |
|---|---|---|
| **S0 NotStarted** | receipt `nil` | CTA `加入用餐计划` enabled (disabled when the draft has no dishes); draft fully editable |
| **S1 Pending, none present** | receipt `.pending`, no `planIDs` in `plans` | CTA `重试加入用餐计划`; editing disabled, because the receipt's ids are bound to the current dish set; honest error line. Regenerating or deleting the menu is the way out, including when a retry refuses under OD-2 |
| **S2 Pending, all present** | receipt `.pending`, every `planID` in `plans` | materialization succeeded; finalize the receipt on appearance, then behave as S4 |
| **S3 Pending, some present** | receipt `.pending`, a strict non-empty subset present | invariant violation; explicit recovery (below). Never blind re-add, never claim success |
| **S4 Materialized** | receipt `.materialized` | frozen: CTA reads `已加入用餐计划` and is disabled; editing hidden; host affordance `查看用餐计划` |

Happy path from S0:

1. **Resolve.** Every `.local` dish must resolve in `RecipeStore` now. Any miss → refuse before any
   write, name the dish (`「X」已不在菜谱库`), stay S0 (OD-2).
2. **Collision check.** Compute target dates; if any holds existing ordinary meals, show one
   confirmation (OD-5) and stop unless confirmed.
3. **Prepare recipes.** Persist every `.ai` dish not already in the library through **one** batch
   recipe write; ids already present are reused. Failure → S0 with an honest error; retry is safe.
4. **Allocate + commit the pending receipt.** Build the exact `MealPlanItem` values (ids allocated
   now), write `{state: .pending, planIDs, recipeIDs, startedAt}` together with the updated
   `isSavedToLibrary` flags through an **observable** draft write (§5). Failure → S0 with an honest
   error; nothing was added to the plan; recipes from step 3 remain (OD-3).
5. **Batch.** One atomic canonical write of exactly those items. Failure → **S1**; error copy
   `未能加入用餐计划，请稍后重试`; no success copy.
6. **Finalize.** Receipt → `.materialized` with `completedAt`. Success copy `已加入用餐计划` is shown
   because the exact ids are durably present. If this last write fails, success still stands and a
   non-blocking notice says the menu record could not be updated; the next open reconciles via S2.

Retry from S1 re-runs steps 1, 3 and 5 with the **same** `planIDs`; recipes resolved in step 3 are
reused by id, so no duplicate recipes and no duplicate plans. A step-1 refusal during a retry leaves
the receipt pending rather than returning to S0.

S3 recovery: state the fact (`这份菜单只有部分菜品在用餐计划中`) and offer two explicit actions —
`加入缺少的 N 道` (one batch using only the missing exact ids) and `标记为已加入` (finalize the receipt
without writing, for the user who deliberately removed meals in Planner). No automatic repair,
because a missing id is equally consistent with a legitimate Planner deletion.

A `.materialized` receipt is **never** re-verified against `plans`: deleting a materialized meal in
Planner is legitimate and must not reopen the CTA.

Regeneration is allowed in every state and never touches existing Planner meals. When the current
receipt is `.pending` or `.materialized`, confirm with
`重新生成不会更改已经加入用餐计划的菜品。`; the new draft starts at S0 with `materialization = nil`.
`复制到下一个 7 天` likewise produces a receipt-free draft.

App termination: before step 4's commit nothing durable exists beyond possible recipe residue;
between 4 and 5 → S1; between 5 and 6 → S2; after 6 → S4.

## 4. Receipt model

Stored inside the existing JSON payload of `WeeklyPlanRecord`; no SwiftData schema change, and
legacy payloads decode with `materialization == nil`.

    enum WeeklyMaterializationState: String, Codable { case pending, materialized }

    struct WeeklyMaterializationReceipt: Codable, Hashable {
        var state: WeeklyMaterializationState
        var planIDs: [UUID]      // exact MealPlanItem ids, in creation order
        var recipeIDs: [String]  // recipes prepared for this attempt, for retry reuse
        var startedAt: Date
        var completedAt: Date?
    }

    // WeeklyMealPlan
    var materialization: WeeklyMaterializationReceipt?

Classification is a pure function over the receipt and the current plans:

    enum WeeklyMaterializationStatus: Equatable {
        case notStarted
        case pending(missing: [UUID])
        case partiallyPresent(present: [UUID], missing: [UUID])
        case materialized
    }

`planIDs` order matches draft order (day ascending, then meal, then dish), so a retry recreates the
same rows in the same relative order.

## 5. Canonical batch contract

**Finding:** N independent `addPlan` calls **can** partially materialize — each runs its own
`commitPlans` → `replacePlans` → `context.save()`. Weekly materialization must therefore never loop
over single-item writes.

`commitPlans` already takes a whole array, and `TodayPlanPersistence.replacePlans` performs one
`context.save()` with `context.rollback()` on failure. The batch API is one call over fully formed
values, so caller ids, explicit dates, `nil` servings and legitimate duplicates are all expressible
without optional-date tuples:

    @discardableResult
    func appendPlans(_ items: [MealPlanItem], calendar: Calendar = .current) -> PlanBatchOutcome

    enum PlanBatchOutcome: Equatable {
        case saved([MealPlanItem])
        case rejected(PlanBatchRejection)
        case persistenceFailed
    }

    enum PlanBatchRejection: Equatable {
        case empty
        case duplicateIDsInBatch([UUID])
        case idsAlreadyPresent([UUID])
    }

Rules: caller `id`s are preserved exactly; each item's own `date` is normalized through
`MealPlanItem.normalizedPlannerDate` so date normalization keeps one implementation; items append
after existing rows in the given order; duplicate `(recipeID, date)` pairs are allowed; duplicate
**ids** within the batch or already present in `plans` are rejected **before** any write, because
`TodayPlanRecord.id` is unique and `replacePlans` would otherwise silently collapse two rows into
one; empty input is rejected rather than reported as a vacuous success; the single write goes
through the existing private `commitPlans`, so D-040's single-write-path invariant is unchanged.

The name is deliberately not `addPlans`: D-040 already ships `addPlans(_ additions: [(recipe:plannedServings:)])`,
whose same-day deduplication is the opposite contract, and two overloads under one name would leave a
reader unable to tell which applies. `PlanMutationOutcome` is likewise left untouched: a separate
batch outcome type avoids widening a sealed D-040 contract that three Planner call sites switch over
exhaustively.

The weekly draft needs the same honesty, because step 4 of §3 must be observable:

    @discardableResult
    func commitWeeklyPlan(_ plan: WeeklyMealPlan) -> Bool   // persist-before-publish, mirrors commitPlans

Today's `saveWeeklyPlan` publishes first and persists from `didSet`, where a failure can only become
`weeklyPlanNotice` copy — a pending receipt written that way could be lost while the batch proceeds.

## 6. Date mapping (OD-11)

Draft day → date: `calendar.date(byAdding: .day, value: dayIndex, to: calendar.startOfDay(for: startDate))`
— exactly what `dayTitle` and `dayIndexForToday` already compute — then
`MealPlanItem.normalizedPlannerDate` (local noon, `+12h` from start of day). No second week-boundary
algorithm: Planner keeps grouping by `PlannerProjection.startOfWeek` (Monday), so an N-day menu
generated mid-week legitimately spans two Planner weeks. DST: `byAdding: .day` on `startOfDay` is
calendar-correct, and `+12h` yields 13:00 on a 23-hour day — still the same civil day. This is the
documented D-040 normalization strategy, not timezone independence.

Covered by test: `dayIndex 0` = today; a span crossing Sunday→Monday; a DST transition inside the
span; `复制到下一个 7 天` (+7); Planner's today section shows `dayIndex 0`.

## 7. Idempotency and recovery (OD-7)

Heuristic recovery from `(recipeID, date)` is rejected: duplicates are legal, equivalent meals may
exist independently, and a full-set match cannot prove those rows came from this materialization.
Recovery is by exact id only, and only while the receipt is `.pending`:

| Observation | Behaviour |
|---|---|
| pending, none of `planIDs` present | retry with the same ids (S1) |
| pending, all present | materialization succeeded; repair the receipt to `.materialized` (S2) |
| pending, strict subset present | explicit recovery case (S3); never duplicate, never claim success |
| materialized | frozen; no presence re-check |

The CTA is unavailable in S2/S4, blocked by `isMaterializing` during the attempt, and the batch
rejects ids already present, so a double tap cannot produce a second set of rows even if the UI
guard were bypassed.

## 8. Restock / `weeklyPlan` semantics (OD-9)

Audit (`InventoryConsumption.swift`): `RestockSuggestionEngine.generate` reads `kitchenStore.weeklyPlan`,
expands it through `ShoppingListGenerator(source: .weeklyPlan(plan))` and emits suggestions with the
hardcoded reason `本周计划需要` and `source: .weeklyPlan`. It surfaces in exactly two places, both
global: the Inventory tab's `补货建议` section and the cook-confirmation sheet's `补货建议` section.
Each row shows `suggestion.reason`. The `source` enum drives only the `加入 N 项常备补货` bulk filter
(`.pantryStaple`), the shopping provenance string, and de-dup precedence; it never affects order.
`RestockSuggestionSource.label` is unreachable dead code (the reason string is hardcoded at the call
site).

Disposition: the global branch stops reading the draft and derives from canonical `plans` —
**pending** (not cooked) ordinary meals from today through today + 6 days, a forward horizon giving
comparable reach to the old draft without inventing a week boundary. Those items feed the existing
`ShoppingGenerationSource.todayPlans([MealPlanItem])` case, which contains no date logic, no
`isCooked` filter and no today check, so **no `ShoppingListGenerator` change is required**; the restock
engine builds its own `RestockSuggestion` values and never reads `sourceLabel`, so nothing is
mislabelled `今日计划`. The source case renames `.weeklyPlan` → `.plannedMeals` and the reason becomes
`用餐计划需要`. The date slice is a small pure projection so it is testable without the store.

Scope impact reported as OD-9 requires: two production files (`InventoryConsumption.swift`, plus one
new pure projection), no `ShoppingListGenerator` change, and **no existing test breaks** — no test in
the repo seeds a `weeklyPlan` and then calls the engine, the two absence assertions stay true, and
the accessibility seed clears local data first. Inside the draft/result flow the draft is still used
explicitly for `生成购物清单` (OD-9 boundary A), which keeps `ShoppingGenerationSource.weeklyPlan` and
its test `ShoppingScalingTests.testWeeklyHouseholdHeadcountNeverScales` alive.

Post-feature role of `weeklyPlan` / `WeeklyPlanRecord`: resumable generated draft + materialization
receipt + in-flow shopping source. Not a schedule; Planner reads only `plans`. Backup, guest-merge
counts, migration and `clearAllLocalData` keep carrying it as draft state. The dead
`KitchenStore.todaysWeeklyMeals()` (no callers) is removed as part of ending the second-schedule
reading; `RestockSuggestionSource.label` is left alone unless the rename makes it trivially
correctable.

## 9. Copy contract (OD-6 + OD-11)

| Current | After 003 |
|---|---|
| input CTA `生成本周菜单` | `生成菜单` |
| input `查看已保存的本周计划` | `查看上次生成的菜单` |
| result title `本周菜单` | `生成的菜单`, with the explicit range (e.g. `9月10日 – 9月16日`) stated in the overview |
| overview header `本周概览` | `菜单概览` |
| overview `把今天加入计划` | removed (OD-1) |
| dish ⋯ `加入今日计划` / `已在今天` | removed (OD-1) |
| — | **new primary CTA `加入用餐计划`** in the result overview (`weekly.result.materialize`) |
| ⋯ `保存本周计划` | removed (replaced by the CTA above) |
| ⋯ `重新生成整周` | `重新生成` |
| ⋯ `生成本周购物清单` | `生成购物清单` |
| ⋯ `复制为下一周` | `复制到下一个 7 天` |
| ⋯ `删除本周计划` | `删除这份菜单` |
| toast `已保存本周计划` | `已加入用餐计划` (only per §3 step 6) |
| — | **new collision confirmation** `其中 N 天已经有安排。加入后会保留现有安排，并追加生成的菜品。` with `取消` / `继续加入` (OD-5) |
| toast `已复制为下一周计划` | `已复制到下一个 7 天` |
| regenerate alert body `当前未保存的计划会被新结果替换。` | `当前菜单会被新结果替换。重新生成不会更改已经加入用餐计划的菜品。` |
| delete alert body `已保存的本周计划将被删除，此操作无法撤销。` | `这份生成的菜单将被删除，已加入用餐计划的菜品不受影响。` |
| shopping import source `本周菜单` (`addShoppingItems`) and `sourceLabel(.weeklyPlan)` | `生成的菜单` |
| generator warning `本周计划中没有安排菜品` | `这份菜单里没有菜品` |
| restock reason `本周计划需要` | `用餐计划需要` (and the source case renames, §8) |

Entry-row copy in `TodayPlanDetailView` (`AI 生成一周菜单` / `查看已生成的一周菜单`, subtitle
`已安排 N 天 · M 道菜`) lives in `HomeView.swift` and is **not** changed by 003, which must not edit
Home or 002 (§12). `已安排` is true only once a receipt is materialized, so this is a disclosed
residual: whichever of 002/003 lands second corrects the subtitle to distinguish a draft from a
materialized menu. Recorded as a follow-up, not silently left as correct.

## 10. Test contract

Unit:

- `appendPlans(_:)`: N items keep their exact ids, names, normalized dates and `nil` servings; append
  after existing rows in order; duplicate `(recipeID, date)` allowed; duplicate ids in batch and ids
  already present rejected with no write; empty rejected; `FailingTodayPlanPersistence` →
  `.persistenceFailed` with `plans` unchanged (no partial); existing rows and Special Plans untouched.
- `commitWeeklyPlan`: returns `false` and publishes nothing on a failing weekly persistence.
- Materializer mapping: `dayIndex` → date incl. Sunday→Monday span and a DST day; `.local` id reuse;
  `.ai` → user recipe under the draft id with `baseServings == nil`; missing `.local` refused before
  any write (OD-2); `plannedServings == nil` (OD-4); no provenance fields.
- Batch recipe save: one write; already-present ids reused; in-batch fingerprint duplicates collapse.
- Receipt + status: pending written before the batch; `.materialized` after; classification for
  notStarted / pending-none / pending-all / pending-subset / materialized; a materialized receipt is
  not re-verified after a Planner deletion; regeneration and duplicate clear the receipt.
- Failure ordering (§3): each step's failure leaves the documented state; retry from S1 reuses ids
  and produces no duplicates; recipe residue after a plan failure is present and reusable (OD-3).
- Restock: suggestions derive from canonical pending plans in the horizon, not from an
  unmaterialized draft; a draft alone yields no restock suggestion; reason reads `用餐计划需要`.
- Legacy: `weeklyPlan` alone never yields Planner entries; legacy payloads decode with no receipt.

UI (stubbed weekly response + `PlannerRegressionFixture` states): materialize → success copy →
Planner shows the dated menu; today's dishes appear on Home; relaunch keeps both; reopened result is
frozen; double tap adds nothing; the collision confirmation appears only when dates collide and
existing meals survive; the plan-failure fixture shows no success copy and retries cleanly; the
manual add-today actions are absent; empty draft disables the CTA.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Adding a generated menu to the meal plan (Priority: P1)

1. **Given** a generated result, **When** the member taps `加入用餐计划` and confirms any collision
   prompt, **Then** every dish appears in Planner on its own date in draft order, today's dishes
   appear in Home's today plan, and the result reads `已加入用餐计划`.
2. **Given** dishes that are new AI recipes, **Then** each is in the recipe library and its Planner
   row opens that recipe.
3. **Given** the canonical write fails, **Then** no meal appears anywhere, no success copy is shown,
   and retry creates exactly one set of meals.

### User Story 2 — Materialization cannot duplicate or silently replace (Priority: P1)

1. **Given** a materialized result, **When** the CTA is tapped again or the result is reopened,
   **Then** it reads `已加入用餐计划`, is disabled, and no duplicates exist.
2. **Given** target dates with existing meals, **When** materializing, **Then** one confirmation
   states that existing meals remain and generated meals are added, and afterwards the existing
   meals are unchanged.
3. **Given** an interrupted attempt (pending receipt, no meals), **When** the result is reopened,
   **Then** retry uses the same ids and produces one set of meals.

### User Story 3 — The result screen tells the truth (Priority: P2)

1. **Given** the result screen, **Then** no wording claims a saved plan before materialization, the
   date range is stated explicitly, no manual add-today action exists in any state, and after
   success the host affordance `查看用餐计划` is available.
2. **Given** regeneration after a successful materialization, **Then** the confirmation states that
   already-added dishes are unchanged, and they are.

### User Story 4 — Restock stops inventing a schedule (Priority: P2)

1. **Given** an unmaterialized generated draft and no canonical plans, **Then** the Inventory
   `补货建议` section and the cook-confirmation sheet show no plan-derived suggestion and no
   `本周计划需要` copy.
2. **Given** canonical upcoming meals, **Then** plan-derived suggestions appear with reason
   `用餐计划需要`.

### Edge Cases

- `.local` dish whose recipe was deleted → named refusal, no write, draft preserved.
- Two identical AI dishes in one draft → the second reuses the first's persisted id.
- Receipt finalization fails after a successful batch → success stands; reopening repairs via S2.
- The member deletes some materialized meals in Planner → receipt stays materialized; no re-offer.
- Pending receipt whose meals were partly removed before relaunch → S3 explicit recovery.
- App relaunch mid-result before the CTA → draft restored, S0.
- Draft with zero dishes → CTA disabled; the batch would reject `.empty` anyway.

## Requirements *(mandatory)*

- **FR-001** `KitchenStore` MUST expose `appendPlans(_ items: [MealPlanItem], calendar:) -> PlanBatchOutcome`, named distinctly from D-040's same-day-deduplicating `addPlans(_ additions:)`,
  committing through `commitPlans` in one `replacePlans`: caller ids preserved, each date normalized,
  duplicates by `(recipeID, date)` allowed, duplicate/colliding ids and empty input rejected before
  any write, partial materialization impossible, existing rows untouched.
- **FR-002** Materialization MUST write canonical plans only through FR-001 and MUST show
  `已加入用餐计划` only after the exact intended ids are durably present.
- **FR-003** Every `.ai` dish MUST be persisted as an ordinary user recipe (same draft id, no
  provenance, `baseServings` nil) through one batch recipe write before the plan batch; already-present
  ids MUST be reused rather than treated as failure.
- **FR-004** A `.local` dish whose recipe no longer resolves MUST fail materialization honestly,
  naming the dish, with no write, no silent recreation, no name matching, no reclassification and no
  dangling `recipeID` (OD-2).
- **FR-005** Dates MUST derive from `startDate + dayIndex` through the existing Planner normalization;
  no new week-boundary logic; spanning two Planner weeks MUST be treated as correct (OD-11).
- **FR-006** `plannedServings` MUST be `nil` for every materialized item; `WeeklyMealPlan.servings`
  MUST NOT be reinterpreted as a per-dish target and no `?? 2` fallback may be reintroduced (OD-4).
- **FR-007** Materialization MUST append; existing Planner meals MUST never be replaced or reordered
  and Special Plans MUST be untouched; when any target date already holds ordinary meals, exactly one
  confirmation MUST state that existing meals remain and generated meals are added (OD-5).
- **FR-008** The draft MUST carry a materialization receipt written **pending** with the exact
  intended ids before the batch and marked **materialized** after success; recovery MUST use exact id
  identity only; `(recipeID, date)` heuristics MUST NOT be used; a strict subset MUST be treated as an
  explicit recovery case that neither duplicates nor claims success (OD-7).
- **FR-009** `KitchenStore` MUST expose an observable weekly-draft write (`commitWeeklyPlan`) so the
  pending receipt cannot be lost silently.
- **FR-010** The CTA MUST be disabled while materializing, when the draft is empty, and after
  success; failures MUST leave the draft retryable with `isSavedToLibrary` persisted for recipes
  already created (OD-3).
- **FR-011** `把今天加入计划` and per-dish `加入今日计划` MUST be removed from the result surface in
  every state; no legacy path may materialize the draft again (OD-1).
- **FR-012** Copy MUST follow §9; `本周菜单`, `保存本周计划` and `已保存本周计划` MUST NOT exist, and
  the result MUST state its explicit date range (OD-6/OD-11).
- **FR-013** Regeneration and duplication MUST clear the receipt, MUST NOT alter already-created
  Planner meals, and MUST confirm with `重新生成不会更改已经加入用餐计划的菜品。` when a receipt exists.
- **FR-014** The generator MUST expose a host completion callback for post-materialization
  navigation; the legacy host MAY offer `查看用餐计划`; no custom navigation system (OD-8).
- **FR-015** Global restock/inventory surfaces MUST derive scheduled-plan semantics from canonical
  `plans`, MUST NOT read the unmaterialized draft, and MUST NOT show `本周计划需要`; the draft/result
  flow MAY still use the draft explicitly for its own shopping generation (OD-9).
- **FR-016** Legacy `weeklyPlan` MUST remain a resumable draft + receipt + in-flow shopping source;
  Planner MUST NOT read it; no migration, record deletion or backup-format change.
- **FR-017** No Home, `TodayPlanDetailView`, 002 spec, Special Plan, sync, provenance or visual change.
- **FR-018** At final reconciliation the next available Decision number MUST be re-read from
  `Decisions.md` and taken; no number may be reserved for an unimplemented feature (OD-10).

### Key Entities

- **MealPlanItem** — unchanged shape; created in batch with caller-allocated ids.
- **WeeklyMealPlan** — + `materialization: WeeklyMaterializationReceipt?`.
- **WeeklyMaterializationReceipt / State / Status** — §4.
- **PlanBatchOutcome / PlanBatchRejection** — §5.
- **Recipe** (user) — created from `.ai` dishes; no new fields.
- **RestockSuggestionSource** — `.weeklyPlan` → `.plannedMeals`.

## Success Criteria *(mandatory)*

- **SC-001** After a successful materialization the number of new `MealPlanItem`s equals the draft
  dish count, each with the receipt's exact id, correct date and recipe, and the count is unchanged by
  any further attempt, reopen or relaunch.
- **SC-002** A forced canonical write failure leaves `plans` identical and shows no success copy, and
  the following retry produces exactly one set of meals.
- **SC-003** Existing Planner meals and Special Plans are unchanged after any materialization, and a
  collision is always confirmed first.
- **SC-004** `本周菜单`, `保存本周计划`, `已保存本周计划`, `本周计划需要` and both manual add-today
  actions no longer exist in the product.
- **SC-005** Planner and Home reflect a materialized menu immediately and after relaunch with no
  Home or Planner code change.
- **SC-006** With an unmaterialized draft as the only source, no global restock suggestion is
  plan-derived.
- **SC-007** Focused unit + UI suites pass; the full native suite shows no new failures beyond the
  documented Settings baseline red.

## Out of Scope

Special Plan Home precedence / CRUD; Home navigation hierarchy and any `HomeView.swift` edit;
quantity-aware sufficiency; sync; AI provenance; provider redesign; visual redesign; deleting
`WeeklyPlanRecord`, its migration or the backup format; a Planner-week shopping source; hosting the
generator from Planner (002).

## Assumptions

- Simplified Chinese copy as tabulated in §9.
- No SwiftData schema change: the receipt rides the existing JSON payload and legacy records decode
  with `materialization == nil`.
- Single SwiftData container, one `ModelContext` per store, no cross-context transaction (verified).
- The restock horizon is today through today + 6 days, pending meals only; it is a named constant,
  not a week boundary.


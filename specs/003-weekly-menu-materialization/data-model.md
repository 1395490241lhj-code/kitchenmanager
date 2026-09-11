# Data Model: Weekly Menu → Canonical Planner Materialization

No SwiftData schema change. The receipt is one optional field inside the existing JSON payload of
`WeeklyPlanRecord`, so legacy records decode with `materialization == nil`.

## 1. Materialization receipt (OD-7)

    enum WeeklyMaterializationState: String, Codable {
        case pending        // exact ids allocated and persisted; canonical batch not yet confirmed
        case materialized   // the exact ids were durably written to KitchenStore.plans
    }

    struct WeeklyMaterializationReceipt: Codable, Hashable {
        /// Where this attempt got to. Never inferred from the plans array.
        var state: WeeklyMaterializationState
        /// The exact MealPlanItem ids this attempt will create / has created,
        /// in draft order (day ascending, then meal, then dish).
        var planIDs: [UUID]
        /// Recipe ids prepared for this attempt (pre-existing and newly persisted),
        /// so a retry reuses them instead of creating duplicates.
        var recipeIDs: [String]
        var startedAt: Date
        var completedAt: Date?
    }

    // WeeklyMealPlan gains exactly one field:
    var materialization: WeeklyMaterializationReceipt?   // nil = never attempted / regenerated

Invariants:

- `planIDs.count` equals the draft's dish count at the moment the receipt was written.
- `planIDs` are allocated **before** the canonical batch and never regenerated on retry.
- Regeneration and `复制到下一个 7 天` produce a draft with `materialization == nil`; a successful
  receipt is never carried onto a new draft.
- The receipt is written through `commitWeeklyPlan` (§4), never through the `didSet` path, so a
  failed receipt write is observable.

## 2. Derived status (pure function; never stored)

    enum WeeklyMaterializationStatus: Equatable {
        case notStarted
        case pending(missing: [UUID])
        case partiallyPresent(present: [UUID], missing: [UUID])
        case materialized
    }

    static func status(
        receipt: WeeklyMaterializationReceipt?,
        plans: [MealPlanItem]
    ) -> WeeklyMaterializationStatus

Rules:

| receipt | presence of `planIDs` in `plans` | status |
|---|---|---|
| `nil` | — | `.notStarted` |
| `.pending` | none | `.pending(missing: planIDs)` |
| `.pending` | all | `.materialized` (receipt repaired on appearance) |
| `.pending` | strict non-empty subset | `.partiallyPresent` |
| `.materialized` | **not examined** | `.materialized` |

A materialized receipt is deliberately never re-verified: the member may legitimately delete a
materialized meal in Planner, and re-checking would re-offer the action and recreate it.

## 3. State machine (spec §3)

| Status | CTA | Draft editing | Extra affordance |
|---|---|---|---|
| `.notStarted` | `加入用餐计划` (disabled when the draft has no dishes) | full | — |
| in flight | disabled, progress | disabled | — |
| `.pending` | `重试加入用餐计划` | disabled (ids already committed to) | honest error line |
| `.partiallyPresent` | none | disabled | `加入缺少的 N 道` and `标记为已加入` |
| `.materialized` | `已加入用餐计划`, disabled | hidden | `查看用餐计划` (host callback) |

Write order and what is durable after each step:

| Step | Write | Durable after | Failure → |
|---|---|---|---|
| 1 resolve | none | — | refuse, name the dish (OD-2), stay `.notStarted` |
| 2 collision check | none | — | user cancels, stay `.notStarted` |
| 3 prepare recipes | `saveUserRecipes` (one recipe-context save) | new user recipes | stay `.notStarted`, retry safe |
| 4 pending receipt | `commitWeeklyPlan` (one weekly-context save, also persists `isSavedToLibrary`) | receipt + ids | stay `.notStarted`; recipes remain (OD-3) |
| 5 canonical batch | `appendPlans(_:)` (one plan-context save) | all plan rows | `.pending`, no success copy |
| 6 finalize receipt | `commitWeeklyPlan` | `.materialized` | success still true; notice only; next open repairs via status |

## 4. Store contracts

    // KitchenStore
    @discardableResult
    func appendPlans(_ items: [MealPlanItem], calendar: Calendar = .current) -> PlanBatchOutcome

    @discardableResult
    func commitWeeklyPlan(_ plan: WeeklyMealPlan) -> Bool   // persist-before-publish

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

    // RecipeStore
    func saveUserRecipes(_ recipes: [Recipe]) throws   // one replaceRecipes; existing ids reused

`appendPlans` (named apart from D-040's deduplicating `addPlans(_ additions:)`) preserves caller ids exactly, normalizes each item's own `date` through
`MealPlanItem.normalizedPlannerDate`, appends in the given order, allows duplicate
`(recipeID, date)` pairs, and rejects before writing when ids repeat within the batch or already
exist in `plans` (`TodayPlanRecord.id` is `@Attribute(.unique)` and `replacePlans` would otherwise
collapse the pair into one row). `PlanMutationOutcome` is unchanged.

## 5. Mapping types

    struct WeeklyMenuMaterializer {
        struct PreparedItem { let item: MealPlanItem; let recipe: Recipe; let isNewRecipe: Bool }
        enum Failure: Error, Equatable { case missingRecipe(title: String) }

        static func prepare(
            plan: WeeklyMealPlan,
            recipeStore: RecipeStore,
            calendar: Calendar = .current
        ) throws -> [PreparedItem]
    }

Each `PreparedItem.item` carries a freshly allocated `id`, `recipeID` resolved per spec §2,
`recipeName` from the recipe, the normalized date from `startDate + dayIndex`, `plannedServings: nil`
and `isCooked: false`. No provenance field exists on either type.

## 6. Restock migration (OD-9)

    // new pure projection
    enum PlannedMealHorizon {
        static let forwardDays = 6   // today through today + 6, inclusive
        static func upcoming(
            plans: [MealPlanItem],
            from reference: Date = Date(),
            days: Int = forwardDays,
            calendar: Calendar = .current
        ) -> [MealPlanItem]          // pending (not cooked) meals inside the window, date ascending
    }

    // RestockSuggestionSource
    case plannedMeals   // was .weeklyPlan

`RestockSuggestionEngine` feeds `PlannedMealHorizon.upcoming(plans:)` into the existing
`ShoppingGenerationSource.todayPlans([MealPlanItem])` case (no `ShoppingListGenerator` change) and
emits the reason `用餐计划需要`. The draft is no longer read by any global surface.

## 7. Unchanged

`MealPlanItem` shape, `TodayPlanRecord`, `WeeklyPlanRecord` schema, `Recipe` shape,
`PlanMutationOutcome`, private `commitPlans`, `PlannerProjection`, the weekly migration key, the
backup format, guest-merge counts, and `ShoppingGenerationSource` cases.

## 8. Removed

`addRecipeToTodayPlan`, `addDayToTodayPlan`, `savePlan` (replaced by the materialization flow), the
dead `KitchenStore.todaysWeeklyMeals()`, and the copy listed in spec §9.

## 9. Accessibility identifiers (the weekly views currently have none)

`weekly.input.generate`, `weekly.input.viewLast`, `weekly.result.materialize`,
`weekly.result.materialized`, `weekly.result.retry`, `weekly.result.repair.add`,
`weekly.result.repair.markDone`, `weekly.result.viewPlanner`, `weekly.result.range`,
`weekly.result.dish.<recipeID>`, `weekly.collision.confirm`, `weekly.collision.cancel`,
`weekly.regenerate.confirm`.


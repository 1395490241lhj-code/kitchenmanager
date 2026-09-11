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
        /// The canonical recipe id behind each intended plan, in the same
        /// candidate order as `planIDs` and of the same length — `recipeIDs[i]`
        /// belongs to `planIDs[i]`, duplicates included.
        var recipeIDs: [String]
        /// The normalized Planner day each intended meal belongs on, parallel to
        /// `planIDs` and `recipeIDs`. Recipes alone cannot prove the mapping:
        /// the same recipe on two days yields an identical id sequence, so a
        /// draft whose days changed would still look like a match and a retry
        /// would move approved meals. `nil` marks a receipt written before this
        /// was recorded, whose mapping is therefore unproven.
        var planDates: [Date]?
        var startedAt: Date
        var completedAt: Date?
    }

    // WeeklyMealPlan gains exactly one field:
    var materialization: WeeklyMaterializationReceipt?   // nil = never attempted / regenerated

Invariants:

- `planIDs.count`, `recipeIDs.count` and `planDates.count` all equal the draft's dish count at the
  moment the receipt was written, and all three follow the same candidate order.
- A retry checks that correspondence before reusing the ids: matching candidate count, `recipeIDs`
  sequence **and** `planDates` sequence. Any mapping-relevant difference — an added, removed,
  reordered or moved dish, a changed `startDate`, disagreeing array lengths, or a pending receipt
  with no recorded dates — is stale. The mapping from old ids onto new dishes is never guessed, no
  replacement ids are allocated, and nothing is remapped by recipe name.
- Retry and partial recovery rebuild each meal from the receipt's own mapping (`planIDs[i]`,
  `recipeIDs[i]`, `planDates[i]`); the draft supplies only the display name, and only after the
  integrity check has passed.
- Decode: `planDates` is absent from any receipt written before it existed, and decodes as `nil`. A
  **pending** receipt with `nil` dates is stale, because its mapping was never proven. A
  **materialized** receipt still short-circuits, since it claims no mapping to re-derive. No
  SwiftData migration is involved — the field lives in the existing JSON payload.
- `planIDs` are allocated **before** the canonical batch and never regenerated on retry.
- Regeneration and `复制到 7 天后` produce a draft with `materialization == nil`; a successful
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

    static func resolve(
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
| `.pending` | `加入用餐计划` again (same ids) | per-dish actions visible, disabled (ids already committed to) | the failure was named in the `未能加入用餐计划` alert |
| `.partiallyPresent` | none | disabled | `重新加入缺少的 N 道` and `保留当前安排` |
| `.materialized` | `已加入用餐计划`, disabled | hidden (`查看菜谱` stays) | the host's own `查看用餐计划`, if it offers one; the callback does not fire on reopen |

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
    func saveUserRecipes(_ recipes: [Recipe]) throws   // one replaceRecipes; safe exact-identity reuse

    enum UserRecipeBatchError: Error { case idConflict(id: String), persistenceFailed }

`appendPlans` (named apart from D-040's deduplicating `addPlans(_ additions:)`) preserves caller ids exactly, normalizes each item's own `date` through
`MealPlanItem.normalizedPlannerDate`, appends in the given order, allows duplicate
`(recipeID, date)` pairs, and rejects before writing when ids repeat within the batch or already
exist in `plans` (`TodayPlanRecord.id` is `@Attribute(.unique)` and `replacePlans` would otherwise
collapse the pair into one row). `PlanMutationOutcome` is unchanged.

### 4.1 Host notification

    nonisolated struct WeeklyMaterializationSummary: Equatable {
        let startDate: Date   // first covered day, start-of-day in the materialization calendar
        let endDate: Date     // last covered day
    }

    // WeeklyMenuPlannerStore
    @discardableResult
    func repairReceiptIfMealsArePresent(kitchenStore: KitchenStore, now: Date = Date()) -> Bool

    enum WeeklyMaterializationOutcome: Equatable {
        case materialized([MealPlanItem])
        case materializedNeedsReceiptRepair([MealPlanItem])   // meals durable, receipt lagging
        case receiptRepaired                                   // nothing appended
        case alreadyMaterialized
        case confirmationRequired(WeeklyMaterializationCollision)
        case missingLocalRecipe(dishName: String)
        case recipeIdentityConflict(dishName: String)
        case recipePersistenceFailed, receiptPersistenceFailed, planPersistenceFailed
        case partialRecoveryRequired(present: [UUID], missing: [UUID])
        case staleReceipt
        case emptyDraft
    }

`onMaterialized: ((WeeklyMaterializationSummary) -> Void)?` fires once per member-initiated
completion: the `.materialized`, `.materializedNeedsReceiptRepair` and `.receiptRepaired` outcomes
of a tap (`materialize`, `materializeMissingMeals`, `acceptCurrentSchedule`) reach it, decided in one
place (`WeeklyMaterializationHostNotification.summary(for:of:calendar:)`); every other outcome does
not. Passive `.task` receipt repair goes through `repairReceiptIfMealsArePresent`, which returns a
`Bool` and so cannot produce a notifiable outcome. `acceptCurrentSchedule` on a finalized receipt
returns `.alreadyMaterialized`, so settling a menu is reported once. The summary carries no ids:
after `保留当前安排` some intended meals are absent on purpose.

## 5. Mapping types

    @MainActor
    enum WeeklyMenuMaterializer {
        struct Preparation {
            let candidates: [WeeklyMenuCandidate]
            /// Generated recipes the library does not hold yet, in candidate
            /// order and deduplicated by id.
            let recipesToPersist: [Recipe]
        }
        enum ResolutionFailure: Error, Equatable {
            case missingLocalRecipe(dishName: String), recipeIdentityConflict(dishName: String)
        }

        static func prepare(
            plan: WeeklyMealPlan,
            recipeStore: RecipeStore,
            calendar: Calendar = .current
        ) throws -> Preparation
    }

    nonisolated struct WeeklyMenuCandidate: Equatable {
        let dishID: String, dishName: String
        let dayIndex: Int, mealIndex: Int
        let date: Date          // already normalized the way the Planner stores dates
        let recipeID: String    // resolved from the canonical recipe, never the draft's copy
        let recipeName: String
        let planID: UUID        // the exact id the meal will carry
    }

Each candidate carries its allocated `planID`, the `recipeID` resolved per spec §2, `recipeName`
from the recipe, and the normalized date from `startDate + dayIndex`. The `MealPlanItem` built from
it takes `plannedServings: nil` and `isCooked: false`. No provenance field exists on either type.

## 6. Restock migration (OD-9)

    // new pure projection
    nonisolated enum PlannedMealHorizon {
        static let defaultForwardDays = 6   // today through today + 6, inclusive
        static func upcoming(
            plans: [MealPlanItem],
            from reference: Date = Date(),
            forwardDays: Int = defaultForwardDays,
            calendar: Calendar = .current
        ) -> [MealPlanItem]   // pending (not cooked) meals inside the window, in the order plans holds them
    }

    // ShoppingGenerationSource
    case plannedMeals([MealPlanItem])   // new; .todayPlans keeps meaning today

    // RestockSuggestionSource
    case plannedMeals   // was .weeklyPlan; the dead `label` property is gone

Civil days, not 24-hour multiples: both ends run through `calendar.startOfDay`, so a day that gains
or loses an hour is still one day. That makes it exactly as timezone-stable as the normalized dates
`MealPlanItem` already stores — no claim beyond that. Order is the caller's array order, not a new
sort: this is a filter, and Restock aggregates by ingredient anyway.

`RestockSuggestionEngine` feeds `PlannedMealHorizon.upcoming(plans:)` into
`ShoppingGenerationSource.plannedMeals([MealPlanItem])` and emits the reason `未来 7 天计划需要`. It
never reads the draft, the receipt, or how a plan was created: a meal in `plans` counts, and a meal
deleted from `plans` stops counting on the next recomputation. Both restock surfaces recompute
through the existing observable store — `plans` is `@Published`, and the Inventory section reads it
through a computed property — so no new observation machinery is involved.

## 7. Unchanged

`MealPlanItem` shape, `TodayPlanRecord`, `WeeklyPlanRecord` schema, `Recipe` shape,
`PlanMutationOutcome`, private `commitPlans`, `PlannerProjection`, the weekly migration key, the
backup format, guest-merge counts, and the pre-existing `ShoppingGenerationSource` cases —
`.todayPlans` keeps meaning today, and `.plannedMeals` is added per §6.

## 8. Removed

`addRecipeToTodayPlan`, `addDayToTodayPlan`, `savePlan` (replaced by the materialization flow), the
dead `KitchenStore.todaysWeeklyMeals()`, and the copy listed in spec §9.

## 9. Accessibility identifiers (the weekly views currently have none)

As implemented: `weekly.result.range`, `weekly.result.materialize`,
`weekly.result.materialized`, `weekly.result.regenerate`, `weekly.result.recover.add`,
`weekly.result.recover.keep`, `weekly.result.dish.menu`, `weekly.collision.confirm`,
`weekly.collision.cancel`.

Only what a behaviour test needs to be stable. The failure and stale alerts are matched by their
native titles, and no identifier was added to an element a test does not reach.

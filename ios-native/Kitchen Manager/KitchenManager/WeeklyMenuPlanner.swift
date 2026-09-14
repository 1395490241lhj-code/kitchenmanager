import Combine
import SwiftUI
import UIKit

// MARK: - Persisted plan models
//
// The generated menu is a draft, not a schedule. `KitchenStore.plans` is the
// only schedule Planner and Home read; a menu reaches it by being materialized
// in one canonical batch, which also records a receipt on the draft so an
// interrupted attempt can be finished later. See `WeeklyMenuMaterializer`.

struct WeeklyMealPlanRecipe: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var ingredients: [String]
    var seasonings: [String]? = nil
    var steps: [String]
    var tags: [String]
    var cookingTime: Int?
    var difficulty: String?
    var reason: String?
    var source: RecommendationSource
    var existingRecipeID: String?
    var isSavedToLibrary = false
}

struct WeeklyMealPlanMeal: Identifiable, Codable, Hashable {
    var id = UUID()
    var mealIndex: Int
    var title: String?
    var recipes: [WeeklyMealPlanRecipe]
}

struct WeeklyMealPlanDay: Identifiable, Codable, Hashable {
    var id = UUID()
    var dayIndex: Int
    var meals: [WeeklyMealPlanMeal]
}

struct WeeklyMealPlanShoppingItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var quantityText: String?
    var unit: String?
    var reason: String?
}

// MARK: - Materialization receipt
//
// The generated menu is a draft. Turning it into real Planner meals writes a
// batch of canonical `MealPlanItem`s, and that write has to survive being
// interrupted: the app can be killed between persisting the plans and recording
// that it did so. The receipt is how a later launch tells those cases apart.
//
// It records the *exact* ids the batch will create, before the batch runs.
// Identity by id is the only thing that can prove which rows came from this
// menu: `(recipeID, date)` is not unique — the same dish twice on one day is a
// legitimate plan, and an equivalent meal may already exist for unrelated
// reasons — so matching on it could neither confirm nor deny a materialization.
//
// This is recovery metadata for the draft. It is not a second schedule, and it
// adds no provenance to `MealPlanItem`: a materialized meal is an ordinary meal.

nonisolated enum WeeklyMaterializationState: String, Codable {
    /// Ids are allocated and durable; the canonical batch is not yet confirmed.
    case pending
    /// The exact ids were durably written to `KitchenStore.plans`.
    case materialized
}

nonisolated struct WeeklyMaterializationReceipt: Codable, Hashable {
    /// How far this attempt got. Never inferred from the plans array — see
    /// `WeeklyMaterializationStatus.resolve(receipt:plans:)` for why.
    var state: WeeklyMaterializationState
    /// The exact `MealPlanItem` ids this attempt creates, in draft order (day
    /// ascending, then meal, then dish). A retry reuses these rather than
    /// allocating replacements, which is what keeps a retry from duplicating.
    var planIDs: [UUID]
    /// The canonical recipe behind each intended meal, parallel to `planIDs`
    /// and the same length — `recipeIDs[i]` belongs to `planIDs[i]`, duplicates
    /// included — so a retry reuses those recipes instead of creating
    /// near-copies.
    var recipeIDs: [String]
    /// The normalized Planner day each intended meal belongs on, parallel to
    /// `planIDs` and `recipeIDs`.
    ///
    /// Without this the receipt could not describe its own mapping: the same
    /// recipe on Monday and on Tuesday produces an identical id sequence, so a
    /// draft whose days had changed would still look like a match and a retry
    /// would write the approved ids onto whatever days the draft now shows.
    /// Recovery has to be self-describing rather than depend on the screen
    /// happening to offer no way to move a dish.
    ///
    /// `nil` means a receipt written before this was recorded. Such a receipt
    /// cannot prove its mapping, so a pending one is treated as stale.
    var planDates: [Date]?
    var startedAt: Date
    var completedAt: Date?

    init(
        state: WeeklyMaterializationState,
        planIDs: [UUID],
        recipeIDs: [String],
        planDates: [Date]?,
        startedAt: Date,
        completedAt: Date? = nil
    ) {
        self.state = state
        self.planIDs = planIDs
        self.recipeIDs = recipeIDs
        self.planDates = planDates
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

/// What a receipt and the current canonical plans say, together.
///
/// Derived, never stored: storing it would give two places to disagree about
/// whether a menu is on the plan.
nonisolated enum WeeklyMaterializationStatus: Equatable {
    case notStarted
    case pending(missing: [UUID])
    case partiallyPresent(present: [UUID], missing: [UUID])
    case materialized

    static func resolve(
        receipt: WeeklyMaterializationReceipt?,
        plans: [MealPlanItem]
    ) -> WeeklyMaterializationStatus {
        guard let receipt else { return .notStarted }

        // A finalized receipt is deliberately never re-verified against `plans`.
        // Deleting a materialized meal in the Planner is an ordinary thing to do,
        // and re-checking presence would make the old menu look unsaved again and
        // offer to recreate the very rows the member just removed.
        guard receipt.state == .pending else { return .materialized }

        // A pending receipt with no ids is degenerate — an empty draft never
        // reaches materialization. Reporting it as pending keeps it retryable and
        // honest rather than claiming a menu that was never written.
        guard !receipt.planIDs.isEmpty else { return .pending(missing: []) }

        let present = Set(plans.map(\.id))
        let found = receipt.planIDs.filter { present.contains($0) }
        let missing = receipt.planIDs.filter { !present.contains($0) }

        if found.isEmpty { return .pending(missing: missing) }
        if missing.isEmpty { return .materialized }

        // A partial set cannot come from the batch itself, which is all-or-none.
        // It means something later removed some of these rows, so it is an
        // exceptional case for the caller to resolve — never a cue to recreate
        // the missing ones, which may have been deleted on purpose.
        return .partiallyPresent(present: found, missing: missing)
    }
}

struct WeeklyMealPlan: Codable, Hashable {
    var startDate: Date
    var days: [WeeklyMealPlanDay]
    var shoppingItems: [WeeklyMealPlanShoppingItem]
    var servings: Int
    var summary: String?
    var createdAt: Date
    /// Recovery metadata for turning this draft into canonical Planner meals.
    ///
    /// `nil` for a draft that has never been materialized, and for every menu
    /// stored before this existed: the synthesized decoder reads an absent key as
    /// `nil`, so old `WeeklyPlanRecord` payloads keep decoding unchanged.
    var materialization: WeeklyMaterializationReceipt?

    /// The number of dishes this plan actually contains, always counted from
    /// the plan's own contents.
    ///
    /// Presentation must never carry its own dish total alongside the recipes:
    /// a stored count and an edited menu drift apart silently, and the screen
    /// then states a number the plan does not hold. This was computed inline
    /// inside a private view property, where no test could reach it.
    var dishCount: Int {
        days.reduce(0) { $0 + $1.meals.reduce(0) { $0 + $1.recipes.count } }
    }

    /// Days actually present in the plan, for the same reason.
    var dayCount: Int { days.count }
}

// MARK: - Materialization candidates and outcomes

/// One dish of the draft, resolved to everything a canonical meal needs.
///
/// The sequence of these *is* the materialization: day ascending, then meal,
/// then the dish's own position in its meal. Nothing here comes from dictionary
/// iteration, because the receipt records ids against this order and a retry has
/// to land on the same dishes.
nonisolated struct WeeklyMenuCandidate: Equatable {
    /// The draft dish this came from, for reporting which one went wrong.
    let dishID: String
    let dishName: String
    let dayIndex: Int
    let mealIndex: Int
    /// The civil day, already normalized the way the Planner stores dates.
    let date: Date
    /// Resolved from the canonical recipe, never from the draft's own copy.
    let recipeID: String
    let recipeName: String
    /// The exact id the meal will carry.
    let planID: UUID
}

/// What a completed planning action tells whoever is hosting the generator.
///
/// Only the days the menu covers, which is all a host needs to reveal them in
/// the Planner. Ids are deliberately absent: after 保留当前安排 some intended
/// meals are absent on purpose, and any list of ids would either claim rows
/// that do not exist or need a second field to explain which ones do.
nonisolated struct WeeklyMaterializationSummary: Equatable {
    let startDate: Date
    let endDate: Date
}

extension WeeklyMealPlan {
    /// The first and last civil day this menu covers, as start-of-day instants
    /// in `calendar`. One implementation, shared by the overview row and the
    /// host summary, so they can never disagree.
    nonisolated func coveredDays(calendar: Calendar = .current) -> (start: Date, end: Date) {
        let start = calendar.startOfDay(for: startDate)
        let lastIndex = days.map(\.dayIndex).max() ?? 0
        let end = calendar.date(byAdding: .day, value: lastIndex, to: start) ?? start
        return (start, end)
    }
}

/// Decides whether an outcome of a **member-initiated** action completes the
/// planning action for the host.
///
/// The callback is not a state observer. It fires when the member's own tap
/// just brought the menu to a settled state — the meals were added, or the
/// member chose to keep the plan as it is — and never because a screen was
/// opened onto a menu that was already settled. Passive receipt repair goes
/// through `WeeklyMenuPlannerStore.repairReceiptIfMealsArePresent`, which
/// returns a `Bool` and so cannot reach this function at all.
nonisolated enum WeeklyMaterializationHostNotification {
    static func summary(
        for outcome: WeeklyMaterializationOutcome,
        of plan: WeeklyMealPlan,
        calendar: Calendar = .current
    ) -> WeeklyMaterializationSummary? {
        switch outcome {
        case .materialized, .materializedNeedsReceiptRepair, .receiptRepaired:
            // `.receiptRepaired` here can only be 保留当前安排 (or re-adding
            // when nothing turned out to be missing): both are the member
            // settling the menu. The meals-durable-but-receipt-lagging case is
            // a success too, because the plan really changed.
            let range = plan.coveredDays(calendar: calendar)
            return WeeklyMaterializationSummary(startDate: range.start, endDate: range.end)
        case .alreadyMaterialized, .confirmationRequired, .missingLocalRecipe,
             .recipeIdentityConflict, .recipePersistenceFailed, .receiptPersistenceFailed,
             .planPersistenceFailed, .partialRecoveryRequired, .staleReceipt, .emptyDraft:
            return nil
        }
    }
}

/// What a member is about to append onto, when they already planned something.
nonisolated struct WeeklyMaterializationCollision: Equatable {
    /// Distinct target days that already hold ordinary meals.
    let dayCount: Int
    let dates: [Date]
    /// Ordinary meals already standing on those days.
    let existingMealCount: Int
}

/// Every way materializing a menu can end.
///
/// Deliberately not a `Bool` or a notice string: the screen has to tell a member
/// whose recipe went missing apart from one whose disk is full, and tell both
/// apart from a menu that is already on the plan. Collapsing them would put the
/// wrong sentence in front of all three.
nonisolated enum WeeklyMaterializationOutcome: Equatable {
    /// The exact intended meals are durable and the receipt says so.
    case materialized([MealPlanItem])
    /// The meals are durable — the member's schedule really did change — but the
    /// receipt could not be updated to say so. Reopening repairs it.
    case materializedNeedsReceiptRepair([MealPlanItem])
    /// A previous attempt had already written the meals; only the receipt was
    /// behind, and it has now been finalized. Nothing was appended.
    case receiptRepaired
    /// This draft is already on the plan. It cannot be added twice.
    case alreadyMaterialized
    /// Target days already hold ordinary meals. Nothing was written; call again
    /// with `confirmedAppend` once the member has agreed.
    case confirmationRequired(WeeklyMaterializationCollision)
    /// A dish points at a recipe that is no longer in the library.
    case missingLocalRecipe(dishName: String)
    /// A generated recipe's id is taken by different content. Carries the dish
    /// name, because an id means nothing to the person reading the screen.
    case recipeIdentityConflict(dishName: String)
    case recipePersistenceFailed
    case receiptPersistenceFailed
    case planPersistenceFailed
    /// Some of the intended meals are present and some are not. Only the member
    /// can say which they meant, so nothing is written.
    case partialRecoveryRequired(present: [UUID], missing: [UUID])
    /// The draft changed after the receipt was written, so the recorded ids can
    /// no longer be matched to dishes without guessing.
    case staleReceipt
    /// Nothing to materialize.
    case emptyDraft

    var materializedItems: [MealPlanItem]? {
        switch self {
        case .materialized(let items), .materializedNeedsReceiptRepair(let items): return items
        default: return nil
        }
    }

    /// Whether the member's schedule actually changed. True for the repair
    /// case too, which is only ever reached after the meals are durable and
    /// carries the items that were written.
    var didChangeSchedule: Bool {
        materializedItems != nil
    }
}

// MARK: - Materializer

/// Turns a generated menu into the meals the Planner and Home already read.
///
/// Pure resolution, deliberately separate from the writes: every dish is
/// resolved and every id allocated before anything touches the disk, so a
/// problem with the menu is reported before a menu is half-written.
@MainActor
enum WeeklyMenuMaterializer {
    enum ResolutionFailure: Error, Equatable {
        case missingLocalRecipe(dishName: String)
        case recipeIdentityConflict(dishName: String)

        var outcome: WeeklyMaterializationOutcome {
            switch self {
            case .missingLocalRecipe(let dishName): return .missingLocalRecipe(dishName: dishName)
            case .recipeIdentityConflict(let dishName): return .recipeIdentityConflict(dishName: dishName)
            }
        }
    }

    struct Preparation {
        let candidates: [WeeklyMenuCandidate]
        /// Generated recipes the library does not hold yet, in candidate order
        /// and deduplicated by id.
        let recipesToPersist: [Recipe]
    }

    /// Resolves the whole draft, or fails before a single write.
    static func prepare(
        plan: WeeklyMealPlan,
        recipeStore: RecipeStore,
        calendar: Calendar = .current
    ) throws -> Preparation {
        let start = calendar.startOfDay(for: plan.startDate)
        var candidates: [WeeklyMenuCandidate] = []
        var toPersist: [Recipe] = []
        var pendingIDs = Set<String>()

        for day in plan.days.sorted(by: { $0.dayIndex < $1.dayIndex }) {
            // Adding days to a start-of-day date is the same arithmetic the
            // result screen's own headers use, so the meal lands on the day the
            // member was looking at.
            let raw = calendar.date(byAdding: .day, value: day.dayIndex, to: start) ?? start
            let date = MealPlanItem.normalizedPlannerDate(for: raw, calendar: calendar)

            for meal in day.meals.sorted(by: { $0.mealIndex < $1.mealIndex }) {
                for dish in meal.recipes {
                    let resolved = try resolve(dish: dish, recipeStore: recipeStore)
                    if resolved.needsPersisting, pendingIDs.insert(resolved.recipe.id).inserted {
                        toPersist.append(resolved.recipe)
                    }
                    candidates.append(
                        WeeklyMenuCandidate(
                            dishID: dish.id,
                            dishName: dish.title,
                            dayIndex: day.dayIndex,
                            mealIndex: meal.mealIndex,
                            date: date,
                            recipeID: resolved.recipe.id,
                            recipeName: resolved.recipe.title,
                            planID: UUID()
                        )
                    )
                }
            }
        }

        return Preparation(candidates: candidates, recipesToPersist: toPersist)
    }

    private struct Resolved {
        let recipe: Recipe
        let needsPersisting: Bool
    }

    private static func resolve(
        dish: WeeklyMealPlanRecipe,
        recipeStore: RecipeStore
    ) throws -> Resolved {
        // A dish that named an existing recipe must still name one. The library
        // is editable, so this is re-checked now rather than trusted from
        // generation time — and a miss stops everything instead of writing a
        // meal that opens onto nothing.
        if dish.source != .ai, let existingID = dish.existingRecipeID {
            guard let canonical = recipeStore.recipe(id: existingID) else {
                throw ResolutionFailure.missingLocalRecipe(dishName: dish.title)
            }
            return Resolved(recipe: canonical, needsPersisting: false)
        }

        let generated = WeeklyMenuPlannerStore.domainRecipe(from: dish)

        // Already stored under this exact id. Reuse it only if it is the same
        // recipe: an earlier attempt that failed later leaves exactly this, and
        // reusing it is what keeps a retry from creating near-copies. Different
        // content under the same id is refused rather than overwritten — it may
        // be the member's own recipe.
        if let stored = recipeStore.userRecipes.first(where: { $0.id == generated.id }) {
            guard RecipeStore.fingerprint(for: stored) == RecipeStore.fingerprint(for: generated) else {
                throw ResolutionFailure.recipeIdentityConflict(dishName: dish.title)
            }
            return Resolved(recipe: stored, needsPersisting: false)
        }

        // The same generated dish listed twice in one menu is one recipe; the
        // caller collapses it, saving it once.
        return Resolved(recipe: generated, needsPersisting: true)
    }

    /// Builds the meals, optionally reusing ids a receipt already recorded.
    ///
    /// `plannedServings` is left unstated: the menu's headcount describes the
    /// household it was generated for, not how much of each dish to cook.
    static func items(for candidates: [WeeklyMenuCandidate]) -> [MealPlanItem] {
        candidates.map { candidate in
            MealPlanItem(
                id: candidate.planID,
                recipeID: candidate.recipeID,
                recipeName: candidate.recipeName,
                date: candidate.date,
                plannedServings: nil
            )
        }
    }

    /// Rebuilds the meals a pending receipt already committed to.
    ///
    /// Identity, recipe and day all come from the receipt, so a retry restores
    /// what was approved rather than what the draft happens to say now. Only the
    /// display name comes from the draft, and only once `receiptMatches` has
    /// proved the two describe the same meals.
    ///
    /// `nil` when the receipt cannot describe its own mapping.
    static func items(
        from receipt: WeeklyMaterializationReceipt,
        candidates: [WeeklyMenuCandidate]
    ) -> [MealPlanItem]? {
        guard receiptMatches(receipt, candidates: candidates),
              let planDates = receipt.planDates else { return nil }
        return receipt.planIDs.enumerated().map { index, planID in
            MealPlanItem(
                id: planID,
                recipeID: receipt.recipeIDs[index],
                recipeName: candidates[index].recipeName,
                date: planDates[index],
                plannedServings: nil
            )
        }
    }

    /// Whether a receipt still describes this draft, well enough to reuse its
    /// ids without guessing.
    ///
    /// Every mapping-relevant field has to agree: how many meals were intended,
    /// which recipe each one was for, and which day each one belonged on. The
    /// dates are what make the check complete — the same recipe on two days
    /// gives an identical id sequence, so recipes alone would let an edited
    /// menu pass and move approved meals onto different days.
    ///
    /// A receipt with no recorded dates cannot prove its mapping at all, so it
    /// never matches.
    static func receiptMatches(
        _ receipt: WeeklyMaterializationReceipt,
        candidates: [WeeklyMenuCandidate]
    ) -> Bool {
        guard let planDates = receipt.planDates else { return false }
        return receipt.planIDs.count == candidates.count
            && receipt.recipeIDs.count == candidates.count
            && planDates.count == candidates.count
            && receipt.recipeIDs == candidates.map(\.recipeID)
            && planDates == candidates.map(\.date)
    }

    /// Distinct target days that already carry ordinary meals.
    ///
    /// Special Plans are a different kind of entry and never count as a clash:
    /// hosting a dinner is not the same as having already planned this dish.
    static func collision(
        for candidates: [WeeklyMenuCandidate],
        plans: [MealPlanItem],
        calendar: Calendar = .current
    ) -> WeeklyMaterializationCollision? {
        var days: [Date] = []
        var existing = 0

        for date in candidates.map(\.date) where !days.contains(date) {
            let onThatDay = plans.filter { calendar.isDate($0.date, inSameDayAs: date) }
            guard !onThatDay.isEmpty else { continue }
            days.append(date)
            existing += onThatDay.count
        }

        guard !days.isEmpty else { return nil }
        return WeeklyMaterializationCollision(
            dayCount: days.count,
            dates: days.sorted(),
            existingMealCount: existing
        )
    }
}

// MARK: - Request DTOs

struct WeeklyMenuInventoryPayload: Encodable {
    let name: String
    let quantity: Double
    let unit: String
    let remainingDays: Int?
    let isExpiringSoon: Bool
}

struct WeeklyMenuRecipeSummary: Encodable {
    let id: String
    let title: String
    let ingredients: [String]
    let tags: [String]
    let cookingTime: Int?
    let difficulty: String?
}

/// The Special Plan composer's one addition to the shared request: the user's
/// verbatim description of the meal plus the date context needed to resolve
/// relative phrases like 这周六. Present only for Special Plans; the weekly
/// planner never sets it, so its prompt and responses are unchanged.
struct WeeklyMenuEventRequest: Encodable {
    /// The user's original words, untouched.
    let request: String
    /// "yyyy-MM-dd EEEE" in the user's calendar, e.g. "2026-09-02 星期三".
    let today: String
    /// Only set when the composer was opened from a specific Planner day and
    /// the request itself names no date.
    let fallbackDate: String?
}

struct AIWeeklyMenuRequest: Encodable {
    let numberOfDays: Int
    let mealsPerDay: Int
    /// `0` lets the model choose the count from the request; any other value
    /// is exact. Only Special Plans send `0`.
    let dishesPerMeal: Int
    let servings: Int
    let cuisines: [String]
    let flavors: [String]
    let maxCookingTime: Int?
    let prioritizeExpiringIngredients: Bool
    let avoidRepeatedMainIngredients: Bool
    let excludedIngredients: [String]
    let allowNewAIRecipes: Bool
    let additionalRequest: String?
    let inventory: [WeeklyMenuInventoryPayload]
    let existingRecipes: [WeeklyMenuRecipeSummary]
    let excludedRecipeNames: [String]
    let eventRequest: WeeklyMenuEventRequest?

    init(
        numberOfDays: Int,
        mealsPerDay: Int,
        dishesPerMeal: Int,
        servings: Int,
        cuisines: [String],
        flavors: [String],
        maxCookingTime: Int?,
        prioritizeExpiringIngredients: Bool,
        avoidRepeatedMainIngredients: Bool,
        excludedIngredients: [String],
        allowNewAIRecipes: Bool,
        additionalRequest: String?,
        inventory: [WeeklyMenuInventoryPayload],
        existingRecipes: [WeeklyMenuRecipeSummary],
        excludedRecipeNames: [String],
        eventRequest: WeeklyMenuEventRequest? = nil
    ) {
        self.numberOfDays = numberOfDays
        self.mealsPerDay = mealsPerDay
        self.dishesPerMeal = dishesPerMeal
        self.servings = servings
        self.cuisines = cuisines
        self.flavors = flavors
        self.maxCookingTime = maxCookingTime
        self.prioritizeExpiringIngredients = prioritizeExpiringIngredients
        self.avoidRepeatedMainIngredients = avoidRepeatedMainIngredients
        self.excludedIngredients = excludedIngredients
        self.allowNewAIRecipes = allowNewAIRecipes
        self.additionalRequest = additionalRequest
        self.inventory = inventory
        self.existingRecipes = existingRecipes
        self.excludedRecipeNames = excludedRecipeNames
        self.eventRequest = eventRequest
    }
}

// MARK: - Response DTOs
//
// Custom decoders tolerate the same kind of field-naming drift as the other AI
// DTOs in this project (AIGeneratedRecipeDTO, AIRecipeItem, ...).

struct AIWeeklyMenuRecipeDTO: Decodable {
    let existingRecipeID: String?
    let name: String
    let ingredients: [String]?
    let steps: [String]?
    let tags: [String]?
    let cookingTime: Int?
    let difficulty: String?
    let reason: String?
    let source: String?
    /// The yield the model says its written quantities produce.
    ///
    /// Optional at this layer on purpose: the weekly planner never asks for it
    /// and its responses will not carry it, so requiring it here would break
    /// weekly generation. Special Plan is the only caller that demands a value,
    /// and it enforces that in its own adapter.
    let baseServings: Int?

    enum CodingKeys: String, CodingKey {
        case existingRecipeID, existingRecipeId, recipeId, recipeID
        case name, title
        case ingredients, steps, method, tags
        case cookingTime, cooking_time
        case difficulty, reason, source, baseServings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        existingRecipeID = (try? container.decode(String.self, forKey: .existingRecipeID))
            ?? (try? container.decode(String.self, forKey: .existingRecipeId))
            ?? (try? container.decode(String.self, forKey: .recipeId))
            ?? (try? container.decode(String.self, forKey: .recipeID))
        name = (try? container.decode(String.self, forKey: .name))
            ?? (try? container.decode(String.self, forKey: .title))
            ?? ""
        ingredients = try? container.decode([String].self, forKey: .ingredients)
        tags = try? container.decode([String].self, forKey: .tags)
        difficulty = try? container.decode(String.self, forKey: .difficulty)
        reason = try? container.decode(String.self, forKey: .reason)
        source = try? container.decode(String.self, forKey: .source)
        baseServings = try? container.decode(Int.self, forKey: .baseServings)

        if let value = try? container.decode(Int.self, forKey: .cookingTime) {
            cookingTime = value
        } else if let value = try? container.decode(Int.self, forKey: .cooking_time) {
            cookingTime = value
        } else {
            cookingTime = nil
        }

        if let value = try? container.decode([String].self, forKey: .steps) {
            steps = value
        } else if let value = try? container.decode([String].self, forKey: .method) {
            steps = value
        } else {
            steps = nil
        }
    }
}

struct AIWeeklyMealDTO: Decodable {
    let mealIndex: Int
    let title: String?
    let recipes: [AIWeeklyMenuRecipeDTO]

    enum CodingKeys: String, CodingKey { case mealIndex, meal_index, title, recipes }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mealIndex = (try? container.decode(Int.self, forKey: .mealIndex))
            ?? (try? container.decode(Int.self, forKey: .meal_index))
            ?? 0
        title = try? container.decode(String.self, forKey: .title)
        recipes = (try? container.decode([AIWeeklyMenuRecipeDTO].self, forKey: .recipes)) ?? []
    }
}

struct AIWeeklyMenuDayDTO: Decodable {
    let dayIndex: Int
    let meals: [AIWeeklyMealDTO]

    enum CodingKeys: String, CodingKey { case dayIndex, day_index, meals }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dayIndex = (try? container.decode(Int.self, forKey: .dayIndex))
            ?? (try? container.decode(Int.self, forKey: .day_index))
            ?? 0
        meals = (try? container.decode([AIWeeklyMealDTO].self, forKey: .meals)) ?? []
    }
}

struct AIWeeklyShoppingItemDTO: Decodable {
    let name: String
    let quantityText: String?
    let unit: String?
    let reason: String?

    enum CodingKeys: String, CodingKey { case name, quantity, qty, unit, reason }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        unit = try? container.decode(String.self, forKey: .unit)
        reason = try? container.decode(String.self, forKey: .reason)

        if let number = try? container.decode(Double.self, forKey: .quantity) {
            quantityText = number.formatted(.number.precision(.fractionLength(0...2)))
        } else if let text = try? container.decode(String.self, forKey: .quantity) {
            quantityText = text
        } else if let number = try? container.decode(Double.self, forKey: .qty) {
            quantityText = number.formatted(.number.precision(.fractionLength(0...2)))
        } else {
            quantityText = try? container.decode(String.self, forKey: .qty)
        }
    }
}

/// The model's reading of a Special Plan request, returned in the same
/// response as the menu. Every field is optional and decoding never fails on
/// this object: a missing or malformed reading costs the plan a derived
/// field, never the menu.
struct AIWeeklyMenuEventDTO: Decodable {
    let title: String?
    /// "yyyy-MM-dd HH:mm" in the user's local time, or nil when the request
    /// named no date.
    let scheduledAt: String?
    let peopleCount: Int?
    let constraintNotes: [String]?
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case title, scheduledAt, scheduled_at, peopleCount, people_count, constraintNotes, constraint_notes, notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try? container.decode(String.self, forKey: .title)
        scheduledAt = (try? container.decode(String.self, forKey: .scheduledAt))
            ?? (try? container.decode(String.self, forKey: .scheduled_at))
        peopleCount = (try? container.decode(Int.self, forKey: .peopleCount))
            ?? (try? container.decode(Int.self, forKey: .people_count))
        constraintNotes = (try? container.decode([String].self, forKey: .constraintNotes))
            ?? (try? container.decode([String].self, forKey: .constraint_notes))
        notes = try? container.decode(String.self, forKey: .notes)
    }
}

struct AIWeeklyMenuResponse: Decodable {
    let days: [AIWeeklyMenuDayDTO]
    let shoppingItems: [AIWeeklyShoppingItemDTO]?
    let warnings: [String]?
    /// Present only when the request carried an `eventRequest`.
    let event: AIWeeklyMenuEventDTO?

    enum CodingKeys: String, CodingKey { case days, shoppingItems, warnings, event }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        days = try container.decode([AIWeeklyMenuDayDTO].self, forKey: .days)
        shoppingItems = try? container.decode([AIWeeklyShoppingItemDTO].self, forKey: .shoppingItems)
        warnings = try? container.decode([String].self, forKey: .warnings)
        event = try? container.decode(AIWeeklyMenuEventDTO.self, forKey: .event)
    }
}

enum WeeklyMenuPlannerError: LocalizedError {
    case invalidResponse
    case emptyPlan
    case noRecipesAvailable
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidResponse, .emptyPlan:
            return "暂时无法生成周菜单。请稍后重试，或者调整人数和偏好。"
        case .noRecipesAvailable:
            return "菜谱库是空的，请先添加几道菜谱，或者允许 AI 生成新菜。"
        case .cancelled:
            return "请求已取消。"
        }
    }
}

// MARK: - Service
//
// Reuses `AIChatService` (the same client every other AI feature in this app
// goes through) — there is no dedicated weekly-menu endpoint on the backend,
// and `/api/ai-chat` places no restriction on `taskType` values.

struct WeeklyMenuPlannerService {
    private let chatService = AIChatService()

    func generatePlan(request: AIWeeklyMenuRequest) async throws -> AIWeeklyMenuResponse {
        let content = try await chatService.request(
            prompt: try Self.prompt(for: request),
            taskType: "weekly-menu-plan",
            timeout: 100,
            specialPlanDishCount: Self.schemaDishCount(for: request)
        )
        guard let data = content.data(using: .utf8),
              let response = try? JSONDecoder().decode(AIWeeklyMenuResponse.self, from: data) else {
            throw WeeklyMenuPlannerError.invalidResponse
        }
        guard !response.days.isEmpty else {
            throw WeeklyMenuPlannerError.emptyPlan
        }
        return response
    }

    /// The dish count the server may ask the provider to enforce in the
    /// response schema.
    ///
    /// Only a Special Plan request qualifies, and only one that fixed a count:
    /// the ordinary weekly planner keeps its tolerant JSON-object format, and
    /// a request that lets the model choose has no cardinality to enforce.
    static func schemaDishCount(for request: AIWeeklyMenuRequest) -> Int? {
        guard request.eventRequest != nil, request.dishesPerMeal > 0 else { return nil }
        return request.dishesPerMeal
    }

    /// The exact bytes sent to the model. Extracted from `generatePlan` so the
    /// request/response contract it states can be asserted directly instead of
    /// only through a live call.
    static func prompt(for request: AIWeeklyMenuRequest) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let requestData = try encoder.encode(request)
        guard let requestJSON = String(data: requestData, encoding: .utf8) else {
            throw WeeklyMenuPlannerError.invalidResponse
        }

        return """
        你是 Kitchen Manager 的一周菜单规划助手。请根据下面的条件生成菜单。

        条件 JSON：
        \(requestJSON)

        要求：
        - 恰好生成 numberOfDays 天，dayIndex 从 0 开始，不遗漏也不多余。
        - 每天恰好生成 mealsPerDay 顿，\(Self.dishCardinalityClause(for: request))mealIndex 从 0 开始。
        - 每道菜必须标注 source："existing" 表示来自 existingRecipes（此时 existingRecipeID 必须是 existingRecipes 中真实存在的 id），"ai" 表示全新菜谱（此时必须给出完整 ingredients 和 steps）。
        - allowNewAIRecipes 为 false 时，只能使用 existingRecipes 里的菜，绝不能出现 source 为 ai 的菜；existingRecipes 为空时如实说明无法安排。
        - 优先使用 inventory 中的食材，尤其是 isExpiringSoon 为 true 的食材，可以安排在前几天。
        - 不要安排明显超出库存数量的菜。
        - 避免连续多顿使用同一主食材。
        - 同一天尽量荤素搭配。
        - 遵守 maxCookingTime、cuisines、flavors 和 excludedIngredients。
        - 不要出现重复菜名，也不要使用 excludedRecipeNames 中的菜。\(Self.shoppingRule(for: request))
        - 只返回 JSON 对象，不要 Markdown、代码围栏或额外解释。\(Self.eventInstructions(for: request))

        严格 JSON 格式：
        {\(request.eventRequest == nil ? "" : Self.eventSchema)
          "days": [
            {
              "dayIndex": 0,
              "meals": [
                {
                  "mealIndex": 0,
                  "title": "晚餐",
                  "recipes": [
        \(Self.recipeShape(for: request))
                  ]
                }
              ]
            }
          ],\(Self.shoppingShape(for: request))
          "warnings": []
        }
        """
    }

    /// The exact-count clause of the cardinality rule.
    ///
    /// `dishesPerMeal == 0` is the request saying "you choose the count", not a
    /// request for zero dishes, so the clause must be absent in that case.
    /// Stating it anyway left the prompt demanding 恰好 0 道菜 while the event
    /// rules asked for 3 to 8; a model resolving that in favour of the
    /// cardinality rule returns an empty meal. Every request that fixes a count
    /// — the weekly planner always does — keeps the sentence byte-for-byte.
    static func dishCardinalityClause(for request: AIWeeklyMenuRequest) -> String {
        request.dishesPerMeal > 0 ? "每顿恰好 dishesPerMeal 道菜，" : ""
    }

    /// Extra rules for a Special Plan request, each on its own line after the
    /// shared rules. Empty for the weekly planner, so its prompt is
    /// byte-for-byte what it was.
    static func eventInstructions(for request: AIWeeklyMenuRequest) -> String {
        guard let event = request.eventRequest else { return "" }
        // The dish count is the one condition the app fixes before asking, so
        // that the number the prompt asks for and the number the client
        // validates are the same number. Everything else in the request is
        // still read from the user's own words.
        var lines = [
            request.dishesPerMeal > 0
                ? "- 这一顿的菜数已由应用确定为 \(request.dishesPerMeal) 道：必须恰好生成 \(request.dishesPerMeal) 道菜。即使 eventRequest.request 没有写明菜数，也不要自行增减。"
                : "- dishesPerMeal 为 0 时，由你根据 eventRequest 里的人数与场合决定这一顿的菜数（3 到 8 道）。",
            "- eventRequest.request 是用户对这次做饭的原话，是最重要的条件：场合、人数、日期时间、忌口、菜系、复杂程度、想吃的食材都以它为准；唯独菜数不由它决定，以上一条为准。",
            "- 同时在返回 JSON 里额外给出 event 对象，如实解读这段原话：title 是简短活动名（如「周六朋友聚餐」）；peopleCount 是就餐人数（没说时按场合估计）；constraintNotes 是必须遵守的忌口或要求，每条一句；notes 是其他偏好摘要，没有则为空字符串。",
            "- scheduledAt 用 \"yyyy-MM-dd HH:mm\" 表示，以 eventRequest.today 为今天推算「这周六」「明天」等相对日期；用户只说了日期没说时间时按 18:00；完全没说日期时填 null。"
        ]
        if let fallback = event.fallbackDate {
            lines.append("- 用户没说日期时可以按 \(fallback) 这一天安排。")
        }
        return lines.map { "\n        " + $0 }.joined()
    }

    /// `shoppingItems` is a weekly-only field.
    ///
    /// `WeeklyMenuPlannerStore.makePlan` is its one consumer. Special Plan
    /// shopping is deterministic — `ShoppingListGenerator` aggregates the
    /// accepted recipes' own ingredients and reconciles against the home
    /// kitchen only when the plan says to — so an AI-estimated quantity must
    /// never become a Special Plan shopping number. Asking for the field
    /// anyway would spend output on something nothing reads, and would put a
    /// second, untrusted source of shopping quantities in the response.
    static func shoppingRule(for request: AIWeeklyMenuRequest) -> String {
        guard request.eventRequest == nil else { return "" }
        return "\n- 缺少的食材列在 shoppingItems 中，数量按 servings 估算，未知时可以省略数量或填“适量”。"
    }

    static func shoppingShape(for request: AIWeeklyMenuRequest) -> String {
        guard request.eventRequest == nil else { return "" }
        return """

          "shoppingItems": [
            {"name": "鸡胸肉", "quantity": 2, "unit": "块", "reason": "还缺 1 块"}
          ],
        """
    }

    /// The recipe object(s) the response shape shows.
    ///
    /// A Special Plan dish is one of two disjoint shapes, and showing them as
    /// one merged object is worse than showing neither: a dish the model
    /// writes carries its own ingredients, steps and the contracted
    /// `baseServings`, while a dish it reuses carries only the id of the
    /// recipe the user already owns. A single example mixing `existingRecipeID`
    /// with a recipe body and `source: "existing"` describes a dish that
    /// neither branch of the response schema accepts, and steers the model
    /// toward the branch that cannot carry a recipe at all.
    ///
    /// The weekly planner keeps its original single example byte-for-byte: it
    /// has no strict schema and no base-yield contract to describe.
    static func recipeShape(for request: AIWeeklyMenuRequest) -> String {
        guard request.eventRequest != nil else { return weeklyRecipeShape }
        return """
                    {
                      "source": "ai",
                      "name": "菜名",
                      "ingredients": ["食材 1"],
                      "steps": ["步骤 1"],
                      "tags": ["标签"],
                      "cookingTime": 30,
                      "difficulty": "简单",
                      "reason": "推荐原因",
                      "baseServings": \(SpecialPlanMenuBounds.aiRecipeBaseServings)
                    },
                    {
                      "source": "existing",
                      "existingRecipeID": "existingRecipes 中真实存在的 id",
                      "name": "菜名",
                      "reason": "推荐原因"
                    }
        """
    }

    static let weeklyRecipeShape = """
                    {
                      "existingRecipeID": "已有菜谱的 id 或 null",
                      "name": "菜名",
                      "ingredients": ["食材 1"],
                      "steps": ["步骤 1"],
                      "tags": ["标签"],
                      "cookingTime": 30,
                      "difficulty": "简单",
                      "reason": "推荐原因",
                      "source": "existing"
                    }
        """

    static let eventSchema = """

          "event": {
            "title": "周六朋友聚餐",
            "scheduledAt": "2026-09-05 18:30",
            "peopleCount": 7,
            "constraintNotes": ["1 人不吃辣"],
            "notes": "想吃鱼和牛肉，不要太复杂"
          },
        """
}

// MARK: - Input state

struct WeeklyMenuPlannerInput {
    var numberOfDays = 7
    var mealsPerDay = 1
    var dishesPerMeal = 2
    var servings = 2
    var selectedCuisines: Set<String> = []
    var selectedFlavors: Set<String> = []
    var maxCookingTime: Int?
    var prioritizeExpiringIngredients = true
    var avoidRepeatedMainIngredients = true
    var excludedIngredientsText = ""
    var allowNewAIRecipes = true
    var additionalRequest = ""
}

// MARK: - Store

@MainActor
final class WeeklyMenuPlannerStore: ObservableObject {
    @Published var input = WeeklyMenuPlannerInput()
    @Published private(set) var isGenerating = false
    @Published var generatedPlan: WeeklyMealPlan?
    @Published var errorMessage: String?
    @Published private(set) var replacingRecipeID: String?

    /// The one network call the store makes. Injectable so a test can hold a
    /// request in flight and finish it on cue; production wires the live
    /// service, and a DEBUG launch argument can substitute the UI-test stub.
    private let generate: (AIWeeklyMenuRequest) async throws -> AIWeeklyMenuResponse
    private var generationTask: Task<AIWeeklyMenuResponse, Error>?
    private var activeRequestID: UUID?
    private var replaceTask: Task<AIWeeklyMenuResponse, Error>?
    private var activeReplaceRequestID: UUID?

    init(generate: ((AIWeeklyMenuRequest) async throws -> AIWeeklyMenuResponse)? = nil) {
        if let generate {
            self.generate = generate
            return
        }
        #if DEBUG
        if WeeklyMenuGenerationFixture.isEnabled {
            self.generate = WeeklyMenuGenerationFixture.generate
            return
        }
        #endif
        let service = WeeklyMenuPlannerService()
        self.generate = { try await service.generatePlan(request: $0) }
    }

    func loadSavedPlanIfNeeded(from kitchenStore: KitchenStore) {
        guard generatedPlan == nil else { return }
        generatedPlan = kitchenStore.weeklyPlan
    }

    func generatePlan(recipeStore: RecipeStore, kitchenStore: KitchenStore) async {
        guard !isGenerating else { return }
        guard input.allowNewAIRecipes || !recipeStore.recipes.isEmpty else {
            errorMessage = WeeklyMenuPlannerError.noRecipesAvailable.localizedDescription
            return
        }
        await run(excludedRecipeNames: [], recipeStore: recipeStore, kitchenStore: kitchenStore)
    }

    func regeneratePlan(recipeStore: RecipeStore, kitchenStore: KitchenStore) async {
        guard !isGenerating else { return }
        await run(
            excludedRecipeNames: Self.allRecipeNames(in: generatedPlan),
            recipeStore: recipeStore,
            kitchenStore: kitchenStore
        )
    }

    private func run(
        excludedRecipeNames: [String],
        recipeStore: RecipeStore,
        kitchenStore: KitchenStore
    ) async {
        cancelGeneration()
        let requestID = UUID()
        activeRequestID = requestID
        isGenerating = true
        errorMessage = nil
        let previousPlan = generatedPlan
        let existingStartDate = generatedPlan?.startDate

        let request = makeRequest(
            recipeStore: recipeStore,
            kitchenStore: kitchenStore,
            excludedRecipeNames: excludedRecipeNames
        )
        let task = Task { try await self.generate(request) }
        generationTask = task

        do {
            let response = try await task.value
            guard activeRequestID == requestID, !Task.isCancelled else { return }
            generatedPlan = Self.makePlan(
                from: response,
                recipeStore: recipeStore,
                servings: input.servings,
                existingStartDate: existingStartDate
            )
        } catch is CancellationError {
        } catch {
            guard activeRequestID == requestID else { return }
            generatedPlan = previousPlan
            errorMessage = Self.generationErrorMessage(for: error)
        }
        if activeRequestID == requestID {
            isGenerating = false
            activeRequestID = nil
            generationTask = nil
        }
    }

    func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        activeRequestID = nil
        isGenerating = false
    }

    /// What a failed weekly generation is allowed to say. Only errors whose
    /// wording was written for a member may speak for themselves; everything
    /// else — a URLSession failure, an HTTP body, a decoding error — becomes
    /// this flow's own sentence, so nothing technical reaches the alert.
    ///
    /// `AIChatServiceError` is deliberately split. `rateLimited` carries the
    /// wait the member actually needs. `unavailable` is the chat client's
    /// catch-all for anything it did not recognise, so it means "unknown" here
    /// rather than "the service is down". `invalidResponse` / `emptyResponse`
    /// talk about 菜谱, which is the wrong noun for a week of menus.
    static func generationErrorMessage(for error: Error) -> String {
        let fallback = WeeklyMenuPlannerError.invalidResponse.localizedDescription
        switch error {
        case let weekly as WeeklyMenuPlannerError:
            switch weekly {
            case .invalidResponse, .emptyPlan, .noRecipesAvailable:
                return weekly.localizedDescription
            case .cancelled:
                // Cancellation is caught before this and never shown; nothing
                // throws this case today.
                return fallback
            }
        case let chat as AIChatServiceError:
            switch chat {
            case .rateLimited:
                return chat.localizedDescription
            case .unavailable, .invalidResponse, .emptyResponse:
                return fallback
            }
        default:
            return fallback
        }
    }

    /// The member left the weekly workflow, so everything it owns stops.
    /// Cancelling generation alone would leave a per-dish replacement running
    /// against a draft nobody can reach any more.
    func abandonWorkflow() {
        cancelGeneration()
        replaceTask?.cancel()
        replaceTask = nil
        activeReplaceRequestID = nil
        replacingRecipeID = nil
    }

    func replaceRecipe(
        dayIndex: Int,
        mealIndex: Int,
        recipeID: String,
        recipeStore: RecipeStore,
        kitchenStore: KitchenStore
    ) async {
        guard let plan = generatedPlan else { return }
        guard let dayIdx = plan.days.firstIndex(where: { $0.dayIndex == dayIndex }),
              let mealIdx = plan.days[dayIdx].meals.firstIndex(where: { $0.mealIndex == mealIndex }),
              plan.days[dayIdx].meals[mealIdx].recipes.contains(where: { $0.id == recipeID }) else {
            return
        }

        replaceTask?.cancel()
        let requestID = UUID()
        activeReplaceRequestID = requestID
        replacingRecipeID = recipeID
        errorMessage = nil

        let excludedNames = Self.allRecipeNames(in: plan)
        let request = makeRequest(
            recipeStore: recipeStore,
            kitchenStore: kitchenStore,
            excludedRecipeNames: excludedNames,
            numberOfDaysOverride: 1,
            mealsPerDayOverride: 1,
            dishesPerMealOverride: 1
        )
        let task = Task { try await self.generate(request) }
        replaceTask = task

        do {
            let response = try await task.value
            guard activeReplaceRequestID == requestID, !Task.isCancelled else { return }
            guard let newDTO = response.days.first?.meals.first?.recipes.first else {
                throw WeeklyMenuPlannerError.invalidResponse
            }
            // Patch the *live* draft, never the copy captured before the await:
            // whatever the member did to other dishes while this request ran
            // must survive. The target is addressed by its slot (day, meal,
            // recipe id), the same identity every other draft mutation uses.
            // If that slot no longer holds the dish — removed or moved
            // meanwhile — the result is dropped without complaint: nothing
            // to replace, nothing to resurrect.
            if var live = generatedPlan,
               let liveDayIdx = live.days.firstIndex(where: { $0.dayIndex == dayIndex }),
               let liveMealIdx = live.days[liveDayIdx].meals.firstIndex(where: { $0.mealIndex == mealIndex }),
               let liveRecipeIdx = live.days[liveDayIdx].meals[liveMealIdx].recipes.firstIndex(where: { $0.id == recipeID }) {
                live.days[liveDayIdx].meals[liveMealIdx].recipes[liveRecipeIdx] = Self.makeRecipe(from: newDTO, recipeStore: recipeStore)
                generatedPlan = live
            }
        } catch is CancellationError {
        } catch {
            guard activeReplaceRequestID == requestID else { return }
            errorMessage = "暂时无法替换这道菜，请稍后重试。"
        }
        if activeReplaceRequestID == requestID {
            replacingRecipeID = nil
            activeReplaceRequestID = nil
            replaceTask = nil
        }
    }

    func moveRecipe(_ recipeID: String, fromDay: Int, mealIndex: Int, toDay: Int) {
        guard var plan = generatedPlan else { return }
        guard let fromDayIdx = plan.days.firstIndex(where: { $0.dayIndex == fromDay }),
              let fromMealIdx = plan.days[fromDayIdx].meals.firstIndex(where: { $0.mealIndex == mealIndex }),
              let recipeIdx = plan.days[fromDayIdx].meals[fromMealIdx].recipes.firstIndex(where: { $0.id == recipeID }),
              let toDayIdx = plan.days.firstIndex(where: { $0.dayIndex == toDay }) else {
            return
        }
        let recipe = plan.days[fromDayIdx].meals[fromMealIdx].recipes.remove(at: recipeIdx)
        if plan.days[toDayIdx].meals.isEmpty {
            plan.days[toDayIdx].meals.append(WeeklyMealPlanMeal(mealIndex: 0, title: nil, recipes: [recipe]))
        } else {
            plan.days[toDayIdx].meals[0].recipes.append(recipe)
        }
        generatedPlan = plan
    }

    func removeRecipe(_ recipeID: String, dayIndex: Int, mealIndex: Int) {
        guard var plan = generatedPlan else { return }
        guard let dayIdx = plan.days.firstIndex(where: { $0.dayIndex == dayIndex }),
              let mealIdx = plan.days[dayIdx].meals.firstIndex(where: { $0.mealIndex == mealIndex }) else {
            return
        }
        plan.days[dayIdx].meals[mealIdx].recipes.removeAll { $0.id == recipeID }
        generatedPlan = plan
    }

    func removeShoppingItems(at offsets: IndexSet) {
        guard var plan = generatedPlan else { return }
        plan.shoppingItems.remove(atOffsets: offsets)
        generatedPlan = plan
    }

    // MARK: - Materialization
    //
    // The whole point of the feature: turning the generated menu into the meals
    // the Planner and Home already read, and being able to say truthfully
    // afterwards whether that happened.
    //
    // The order below is the contract. Recipes are durable before any meal
    // references them; the intended ids are durable before the meals are
    // written; and the receipt is only marked done once the meals are really
    // there. Every step that can fail leaves a state the next launch can read.

    @Published private(set) var isMaterializing = false

    /// Adds the whole menu to the meal plan.
    ///
    /// Call once; if the answer is `.confirmationRequired`, call again with
    /// `confirmedAppend: true` after the member agrees. A draft that was already
    /// materialized, or half-materialized, routes to the recovery paths instead.
    @discardableResult
    func materialize(
        kitchenStore: KitchenStore,
        recipeStore: RecipeStore,
        confirmedAppend: Bool = false,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> WeeklyMaterializationOutcome {
        guard let draft = generatedPlan, draft.dishCount > 0 else { return .emptyDraft }

        // Every write below is synchronous on the main actor, so this cannot be
        // re-entered; the flag exists so the screen can show the attempt.
        isMaterializing = true
        defer { isMaterializing = false }

        let preparation: WeeklyMenuMaterializer.Preparation
        do {
            preparation = try WeeklyMenuMaterializer.prepare(
                plan: draft, recipeStore: recipeStore, calendar: calendar
            )
        } catch let failure as WeeklyMenuMaterializer.ResolutionFailure {
            return failure.outcome
        } catch {
            return .recipePersistenceFailed
        }

        switch WeeklyMaterializationStatus.resolve(receipt: draft.materialization, plans: kitchenStore.plans) {
        case .materialized:
            // The status says every intended meal is there. If the receipt still
            // says pending, a previous attempt wrote the meals and only failed
            // to record it — so finish the bookkeeping rather than claiming the
            // menu was already handled, and never append a second time.
            if draft.materialization?.state == .pending {
                // The meals are already there; only the record lagged, so a
                // failed write here is exactly that and nothing more.
                return finalize(draft: draft, kitchenStore: kitchenStore, now: now)
                    ? .receiptRepaired : .receiptPersistenceFailed
            }
            return .alreadyMaterialized

        case .partiallyPresent(let present, let missing):
            return .partialRecoveryRequired(present: present, missing: missing)

        case .pending(let missing):
            // The member already agreed to append when this receipt was written;
            // asking again during recovery would be asking twice for one act.
            guard let receipt = draft.materialization,
                  let intended = WeeklyMenuMaterializer.items(
                      from: receipt, candidates: preparation.candidates
                  ) else {
                // The draft no longer describes the meals this receipt approved,
                // so which id belongs on which day is unknowable. Say so rather
                // than move someone's meals.
                return .staleReceipt
            }
            return write(
                draft: draft,
                preparation: preparation,
                items: intended,
                appending: missing,
                kitchenStore: kitchenStore,
                recipeStore: recipeStore,
                calendar: calendar,
                now: now
            )

        case .notStarted:
            if !confirmedAppend,
               let collision = WeeklyMenuMaterializer.collision(
                   for: preparation.candidates, plans: kitchenStore.plans, calendar: calendar
               ) {
                // Nothing has been written, and nothing will be until the member
                // has seen what they are adding to.
                return .confirmationRequired(collision)
            }
            return write(
                draft: draft,
                preparation: preparation,
                items: WeeklyMenuMaterializer.items(for: preparation.candidates),
                appending: nil,
                kitchenStore: kitchenStore,
                recipeStore: recipeStore,
                calendar: calendar,
                now: now
            )
        }
    }

    /// Recovery choice: put back only the meals that are missing.
    ///
    /// Uses their original ids, dates and dishes, so the result is the menu the
    /// member agreed to rather than a fresh copy of it.
    @discardableResult
    func materializeMissingMeals(
        kitchenStore: KitchenStore,
        recipeStore: RecipeStore,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> WeeklyMaterializationOutcome {
        guard let draft = generatedPlan, let receipt = draft.materialization else { return .emptyDraft }
        guard receipt.state == .pending else { return .alreadyMaterialized }

        isMaterializing = true
        defer { isMaterializing = false }

        let preparation: WeeklyMenuMaterializer.Preparation
        do {
            preparation = try WeeklyMenuMaterializer.prepare(
                plan: draft, recipeStore: recipeStore, calendar: calendar
            )
        } catch let failure as WeeklyMenuMaterializer.ResolutionFailure {
            return failure.outcome
        } catch {
            return .recipePersistenceFailed
        }

        // Each missing meal is rebuilt from the receipt's own mapping — its id,
        // its recipe and the day it was approved for — not from whatever the
        // draft says today.
        guard let intended = WeeklyMenuMaterializer.items(
            from: receipt, candidates: preparation.candidates
        ) else { return .staleReceipt }

        let present = Set(kitchenStore.plans.map(\.id))
        let missing = receipt.planIDs.filter { !present.contains($0) }
        guard !missing.isEmpty else {
            return finalize(draft: draft, kitchenStore: kitchenStore, now: now)
                ? .receiptRepaired : .receiptPersistenceFailed
        }

        return write(
            draft: draft,
            preparation: preparation,
            items: intended,
            appending: missing,
            kitchenStore: kitchenStore,
            recipeStore: recipeStore,
            calendar: calendar,
            now: now
        )
    }

    /// Bookkeeping only: if every intended meal is already on the plan but the
    /// receipt still says pending, mark it done. Appends nothing, asks nothing.
    ///
    /// Returns whether the receipt is now finalized. A `Bool` on purpose — this
    /// is not a planning action, so it must not be able to produce an outcome
    /// the host could be told about.
    @discardableResult
    func repairReceiptIfMealsArePresent(
        kitchenStore: KitchenStore,
        now: Date = Date()
    ) -> Bool {
        guard let draft = generatedPlan, let receipt = draft.materialization else { return false }
        guard receipt.state == .pending else { return true }
        guard case .materialized = WeeklyMaterializationStatus.resolve(
            receipt: receipt, plans: kitchenStore.plans
        ) else { return false }
        return finalize(draft: draft, kitchenStore: kitchenStore, now: now)
    }

    /// Recovery choice: leave the plan as the member has it now.
    ///
    /// The menu counts as handled and will not offer to add itself again. The
    /// meals they removed stay removed.
    @discardableResult
    func acceptCurrentSchedule(
        kitchenStore: KitchenStore,
        now: Date = Date()
    ) -> WeeklyMaterializationOutcome {
        guard let draft = generatedPlan, let receipt = draft.materialization else { return .emptyDraft }
        // Settling a menu is done once. A finalized receipt has nothing left to
        // accept, and reporting a repair would read as a second completion.
        guard receipt.state == .pending else { return .alreadyMaterialized }
        // Nothing is appended on this path, so a failed receipt write is a
        // plain failure — never the "meals are there, record lagged" case.
        return finalize(draft: draft, kitchenStore: kitchenStore, now: now)
            ? .receiptRepaired : .receiptPersistenceFailed
    }

    // MARK: Write order

    /// Recipes, then the intended ids, then the meals, then the receipt.
    ///
    /// `appending` names the subset to write when a previous attempt already
    /// wrote the rest; `nil` means all of them.
    private func write(
        draft: WeeklyMealPlan,
        preparation: WeeklyMenuMaterializer.Preparation,
        items: [MealPlanItem],
        appending: [UUID]?,
        kitchenStore: KitchenStore,
        recipeStore: RecipeStore,
        calendar: Calendar,
        now: Date
    ) -> WeeklyMaterializationOutcome {
        // 1. Every recipe a meal will point at becomes durable first. A meal
        //    referencing a recipe that was never saved is the dangling state
        //    this whole feature exists to stop.
        if !preparation.recipesToPersist.isEmpty {
            do {
                try recipeStore.saveUserRecipes(preparation.recipesToPersist)
            } catch UserRecipeBatchError.idConflict(let id) {
                // Resolution normally catches this first; if the library changed
                // underneath, name the dish rather than the id.
                let dishName = preparation.candidates.first { $0.recipeID == id }?.dishName ?? id
                return .recipeIdentityConflict(dishName: dishName)
            } catch {
                return .recipePersistenceFailed
            }
        }

        // 2. The intended meals become durable before the meals themselves do,
        //    so an attempt interrupted after this point can be finished rather
        //    than guessed at. The receipt is built from the very items about to
        //    be written — id, recipe and day for each one — so it describes its
        //    own mapping instead of leaning on the draft still looking the same.
        var pending = draft
        pending.materialization = WeeklyMaterializationReceipt(
            state: .pending,
            planIDs: items.map(\.id),
            recipeIDs: items.map(\.recipeID),
            planDates: items.map(\.date),
            startedAt: draft.materialization?.startedAt ?? now
        )
        markPersistedRecipes(in: &pending, ids: Set(preparation.recipesToPersist.map(\.id)))
        guard kitchenStore.commitWeeklyPlan(pending) else { return .receiptPersistenceFailed }
        publish(pending)

        // 3. One batch, all of it or none of it.
        let wanted = appending.map { subset in
            items.filter { subset.contains($0.id) }
        } ?? items
        // The caller's calendar, not the device's: the dates were resolved in
        // it, and re-normalizing them in another one would shift the meals.
        switch kitchenStore.appendPlans(wanted, calendar: calendar) {
        case .saved:
            break
        case .rejected, .persistenceFailed:
            // The receipt stays pending and keeps its ids, which is what makes
            // the next attempt a retry rather than a second menu.
            return .planPersistenceFailed
        }

        // 4. Only now is it true to say the menu is on the plan.
        return finalize(draft: pending, kitchenStore: kitchenStore, now: now)
            ? .materialized(items)
            : .materializedNeedsReceiptRepair(items)
    }

    /// Marks the receipt done, and says only whether that write stuck.
    ///
    /// A `Bool`, because what a failure *means* belongs to the caller. After
    /// `appendPlans` the meals are durable and a lost receipt is bookkeeping;
    /// from 保留当前安排 nothing was written at all, and reporting the same
    /// success there would tell the member their menu was added when it was not.
    private func finalize(
        draft: WeeklyMealPlan,
        kitchenStore: KitchenStore,
        now: Date
    ) -> Bool {
        guard let receipt = draft.materialization else { return false }
        var finalized = draft
        finalized.materialization = WeeklyMaterializationReceipt(
            state: .materialized,
            planIDs: receipt.planIDs,
            recipeIDs: receipt.recipeIDs,
            planDates: receipt.planDates,
            startedAt: receipt.startedAt,
            completedAt: now
        )
        guard kitchenStore.commitWeeklyPlan(finalized) else { return false }
        publish(finalized)
        return true
    }

    private func publish(_ plan: WeeklyMealPlan) {
        generatedPlan = plan
    }

    /// Records which generated recipes are now in the library, so a retry knows
    /// not to offer them again.
    private func markPersistedRecipes(in plan: inout WeeklyMealPlan, ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for dayIndex in plan.days.indices {
            for mealIndex in plan.days[dayIndex].meals.indices {
                for recipeIndex in plan.days[dayIndex].meals[mealIndex].recipes.indices
                where ids.contains(plan.days[dayIndex].meals[mealIndex].recipes[recipeIndex].id) {
                    plan.days[dayIndex].meals[mealIndex].recipes[recipeIndex].isSavedToLibrary = true
                }
            }
        }
    }

    func saveRecipeToLibrary(_ recipe: WeeklyMealPlanRecipe, recipeStore: RecipeStore) throws {
        guard recipe.source == .ai else { return }
        try recipeStore.saveUserRecipe(Self.domainRecipe(from: recipe))
        markSaved(recipeID: recipe.id)
    }

    func addShoppingItems(_ items: [WeeklyMealPlanShoppingItem], kitchenStore: KitchenStore) {
        let additions = items.compactMap { item -> KitchenShoppingItem? in
            let normalized = Self.normalizedName(item.name)
            guard !normalized.isEmpty else { return nil }
            guard !kitchenStore.availableInventory.contains(where: { Self.normalizedName($0.name) == normalized }) else {
                return nil
            }
            let quantity = Double(item.quantityText ?? "") ?? 1
            let unit = item.unit?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "适量"
            return KitchenShoppingItem(
                name: item.name,
                quantity: quantity,
                unit: unit,
                source: "生成的菜单"
            )
        }
        kitchenStore.addShoppingItems(additions)
    }

    private func markSaved(recipeID: String) {
        guard var plan = generatedPlan else { return }
        for dayIndex in plan.days.indices {
            for mealIndex in plan.days[dayIndex].meals.indices {
                for recipeIndex in plan.days[dayIndex].meals[mealIndex].recipes.indices
                where plan.days[dayIndex].meals[mealIndex].recipes[recipeIndex].id == recipeID {
                    plan.days[dayIndex].meals[mealIndex].recipes[recipeIndex].isSavedToLibrary = true
                }
            }
        }
        generatedPlan = plan
    }

    private func makeRequest(
        recipeStore: RecipeStore,
        kitchenStore: KitchenStore,
        excludedRecipeNames: [String],
        numberOfDaysOverride: Int? = nil,
        mealsPerDayOverride: Int? = nil,
        dishesPerMealOverride: Int? = nil
    ) -> AIWeeklyMenuRequest {
        let inventoryPayload = kitchenStore.recipeCreationInventory.map { item in
            WeeklyMenuInventoryPayload(
                name: item.name,
                quantity: item.quantity,
                unit: item.unit,
                remainingDays: item.remainingDays,
                isExpiringSoon: (item.remainingDays ?? 999) <= 3
            )
        }
        let recipeSummaries = recipeStore.recipes.prefix(60).map { recipe in
            WeeklyMenuRecipeSummary(
                id: recipe.id,
                title: recipe.title,
                ingredients: recipe.ingredients,
                tags: recipe.tags,
                cookingTime: recipe.cookingTime,
                difficulty: recipe.difficulty
            )
        }
        let excludedIngredients = input.excludedIngredientsText
            .components(separatedBy: CharacterSet(charactersIn: " ,，、\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return AIWeeklyMenuRequest(
            numberOfDays: numberOfDaysOverride ?? input.numberOfDays,
            mealsPerDay: mealsPerDayOverride ?? input.mealsPerDay,
            dishesPerMeal: dishesPerMealOverride ?? input.dishesPerMeal,
            servings: input.servings,
            cuisines: Array(input.selectedCuisines),
            flavors: Array(input.selectedFlavors),
            maxCookingTime: input.maxCookingTime,
            prioritizeExpiringIngredients: input.prioritizeExpiringIngredients,
            avoidRepeatedMainIngredients: input.avoidRepeatedMainIngredients,
            excludedIngredients: excludedIngredients,
            allowNewAIRecipes: input.allowNewAIRecipes,
            additionalRequest: input.additionalRequest.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            inventory: Array(inventoryPayload),
            existingRecipes: Array(recipeSummaries),
            excludedRecipeNames: excludedRecipeNames
        )
    }

    private static func allRecipeNames(in plan: WeeklyMealPlan?) -> [String] {
        guard let plan else { return [] }
        return plan.days.flatMap { $0.meals.flatMap { $0.recipes.map(\.title) } }
    }

    private static func makePlan(
        from response: AIWeeklyMenuResponse,
        recipeStore: RecipeStore,
        servings: Int,
        existingStartDate: Date?
    ) -> WeeklyMealPlan {
        let days = response.days
            .sorted { $0.dayIndex < $1.dayIndex }
            .map { dayDTO in
                WeeklyMealPlanDay(
                    dayIndex: dayDTO.dayIndex,
                    meals: dayDTO.meals
                        .sorted { $0.mealIndex < $1.mealIndex }
                        .map { mealDTO in
                            WeeklyMealPlanMeal(
                                mealIndex: mealDTO.mealIndex,
                                title: mealDTO.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                                recipes: mealDTO.recipes.map { makeRecipe(from: $0, recipeStore: recipeStore) }
                            )
                        }
                )
            }

        let shoppingItems: [WeeklyMealPlanShoppingItem] = (response.shoppingItems ?? []).compactMap { dto in
            let name = dto.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return WeeklyMealPlanShoppingItem(
                name: name,
                quantityText: dto.quantityText,
                unit: dto.unit,
                reason: dto.reason
            )
        }

        return WeeklyMealPlan(
            startDate: existingStartDate ?? Calendar.current.startOfDay(for: Date()),
            days: days,
            shoppingItems: shoppingItems,
            servings: servings,
            summary: response.warnings?.first,
            createdAt: Date()
        )
    }

    private static func makeRecipe(
        from dto: AIWeeklyMenuRecipeDTO,
        recipeStore: RecipeStore
    ) -> WeeklyMealPlanRecipe {
        let name = dto.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existingID = dto.existingRecipeID,
           dto.source?.lowercased() != "ai",
           let matched = recipeStore.recipes.first(where: { $0.id == existingID }) {
            return WeeklyMealPlanRecipe(
                id: matched.id,
                title: matched.title,
                ingredients: matched.ingredients,
                steps: matched.steps,
                tags: matched.tags,
                cookingTime: matched.cookingTime,
                difficulty: matched.difficulty,
                reason: dto.reason,
                source: .local,
                existingRecipeID: matched.id
            )
        }

        let ingredients = (dto.ingredients ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let steps = (dto.steps ?? []).map(EditableRecipeDraft.cleanStep).filter { !$0.isEmpty }
        return WeeklyMealPlanRecipe(
            id: "weekly-ai-\(UUID().uuidString.lowercased())",
            title: name.isEmpty ? "未命名菜谱" : name,
            ingredients: ingredients,
            steps: steps,
            tags: dto.tags ?? [],
            cookingTime: dto.cookingTime,
            difficulty: dto.difficulty,
            reason: dto.reason,
            source: .ai,
            existingRecipeID: nil
        )
    }

    static func domainRecipe(from recipe: WeeklyMealPlanRecipe) -> Recipe {
        Recipe(
            id: recipe.existingRecipeID ?? recipe.id,
            title: recipe.title,
            cookingTime: recipe.cookingTime,
            difficulty: recipe.difficulty,
            tags: recipe.tags,
            ingredients: recipe.ingredients,
            seasonings: recipe.seasonings ?? [],
            steps: recipe.steps.isEmpty ? ["暂未提供详细步骤。"] : recipe.steps
        )
    }

    private static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Input view

struct WeeklyMenuPlannerView: View {
    /// Handed this screen's store while the generator is on the navigation
    /// stack, so the layer that owns the route can end the workflow when the
    /// route is genuinely removed. The screen itself cannot tell that moment
    /// apart from pushing one of its own pickers: `onDisappear` fires for both,
    /// and `isPresented` still reads true inside it.
    var onWorkflowActive: ((WeeklyMenuPlannerStore) -> Void)?
    /// Passed straight through to the result screen. Defaults to nothing, so a
    /// host that does not care about navigation is unaffected.
    var onMaterialized: ((WeeklyMaterializationSummary) -> Void)?

    @EnvironmentObject private var recipeStore: RecipeStore
    @EnvironmentObject private var kitchenStore: KitchenStore
    @StateObject private var store = WeeklyMenuPlannerStore()
    @State private var isShowingResult = false
    /// True while this screen is the one on screen. A pushed picker or the
    /// result destination turns it false.
    @State private var isOnScreen = false
    /// A finished menu waiting for its own screen. Generation can land while a
    /// picker is open, and pushing the result from under the member would take
    /// away the screen they are using, so it waits until they come back.
    @State private var hasResultWaiting = false

    var body: some View {
        Form {
            Section("规划天数与顿数") {
                Stepper("计划 \(store.input.numberOfDays) 天", value: $store.input.numberOfDays, in: 1...7)
                Stepper("每天 \(store.input.mealsPerDay) 顿", value: $store.input.mealsPerDay, in: 1...3)
                Stepper("每顿 \(store.input.dishesPerMeal) 道", value: $store.input.dishesPerMeal, in: 1...4)
                Stepper("\(store.input.servings) 人", value: $store.input.servings, in: 1...12)
            }

            Section("菜系与口味") {
                NavigationLink {
                    MultiSelectionListView(
                        title: "菜系偏好",
                        options: AIRecipeGeneratorStore.cuisineOptions,
                        selection: $store.input.selectedCuisines
                    )
                } label: {
                    LabeledContent("菜系偏好", value: summaryText(store.input.selectedCuisines, placeholder: "不限"))
                }
                NavigationLink {
                    MultiSelectionListView(
                        title: "口味偏好",
                        options: AIRecipeGeneratorStore.flavorOptions,
                        selection: $store.input.selectedFlavors
                    )
                } label: {
                    LabeledContent("口味偏好", value: summaryText(store.input.selectedFlavors, placeholder: "不限"))
                }
                Picker("最长烹饪时间", selection: $store.input.maxCookingTime) {
                    Text("不限").tag(Int?.none)
                    Text("15 分钟内").tag(Int?.some(15))
                    Text("30 分钟内").tag(Int?.some(30))
                    Text("45 分钟内").tag(Int?.some(45))
                    Text("60 分钟内").tag(Int?.some(60))
                }
            }

            Section("食材安排") {
                Toggle("优先消耗临期食材", isOn: $store.input.prioritizeExpiringIngredients)
                Toggle("避免连续重复主食材", isOn: $store.input.avoidRepeatedMainIngredients)
                TextField(
                    "忌口或排除食材，例如：花生、香菜",
                    text: $store.input.excludedIngredientsText,
                    axis: .vertical
                )
                .lineLimit(2...4)
            }

            Section {
                Toggle("允许 AI 生成新菜", isOn: $store.input.allowNewAIRecipes)
                if !store.input.allowNewAIRecipes && recipeStore.recipes.isEmpty {
                    Label("菜谱库是空的，建议先添加几道菜谱，或者允许 AI 生成新菜。", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(AppTheme.warningInk)
                }
            } header: {
                Text("菜谱来源")
            }

            Section("额外要求") {
                TextField(
                    "例如：适合带饭、周末想吃点特别的",
                    text: $store.input.additionalRequest,
                    axis: .vertical
                )
                .lineLimit(3...6)
            }

            Section {
                Button {
                    Task {
                        await store.generatePlan(recipeStore: recipeStore, kitchenStore: kitchenStore)
                        guard store.generatedPlan != nil else { return }
                        // Only take over the screen if this is still the screen.
                        if isOnScreen {
                            isShowingResult = true
                        } else {
                            hasResultWaiting = true
                        }
                    }
                } label: {
                    HStack {
                        Spacer()
                        if store.isGenerating {
                            ProgressView().tint(AppTheme.onManagementAction)
                        } else {
                            Label("生成菜单", systemImage: "sparkles")
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(KitchenTheme.aiIndigo)
                .foregroundStyle(AppTheme.onManagementAction)
                .disabled(store.isGenerating)

                if kitchenStore.weeklyPlan != nil {
                    Button("查看上次生成的菜单") {
                        store.generatedPlan = kitchenStore.weeklyPlan
                        isShowingResult = true
                    }
                }
            }
        }
        // Matches the row that opens it. 本周 is deliberately not used here: it
        // is the planner's old word, and this screen is a separate generator.
        .navigationTitle("生成一周菜单")
        .scrollContentBackground(.hidden).background(KitchenTheme.canvas)
        .contentMargins(.horizontal, KitchenTheme.pageGutter, for: .scrollContent)
        .tint(KitchenTheme.cookingGreen)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $isShowingResult) {
            WeeklyMenuResultView(store: store, onMaterialized: onMaterialized)
        }
        .alert(
            "暂时无法生成菜单",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "请稍后重试，或者调整人数和偏好。")
        }
        .onAppear {
            isOnScreen = true
            onWorkflowActive?(store)
            store.loadSavedPlanIfNeeded(from: kitchenStore)
            if hasResultWaiting {
                hasResultWaiting = false
                // One hop, because this runs while the picker is still popping
                // and a push issued inside that transition is dropped.
                DispatchQueue.main.async { isShowingResult = true }
            }
        }
        .onDisappear {
            isOnScreen = false
        }
    }

    private func summaryText(_ selection: Set<String>, placeholder: String) -> String {
        selection.isEmpty ? placeholder : selection.sorted().joined(separator: "、")
    }
}

struct MultiSelectionListView: View {
    let title: String
    let options: [String]
    @Binding var selection: Set<String>

    var body: some View {
        List(options, id: \.self) { option in
            Button {
                if selection.contains(option) {
                    selection.remove(option)
                } else {
                    selection.insert(option)
                }
            } label: {
                HStack {
                    Text(option).foregroundStyle(.primary)
                    Spacer()
                    if selection.contains(option) {
                        Image(systemName: "checkmark").foregroundStyle(AppTheme.primary)
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Result view

/// The three things that can interrupt adding a menu to the meal plan, kept out
/// of the result view's own modifier chain so each stays type-checkable.
private struct WeeklyMaterializationAlerts: ViewModifier {
    @Binding var collision: WeeklyMaterializationCollision?
    @Binding var isShowingStaleNotice: Bool
    @Binding var failureMessage: String?
    let onConfirmAppend: () -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                "已有安排",
                isPresented: Binding(
                    get: { collision != nil },
                    set: { if !$0 { collision = nil } }
                ),
                presenting: collision
            ) { _ in
                Button("继续加入") {
                    collision = nil
                    onConfirmAppend()
                }
                .accessibilityIdentifier("weekly.collision.confirm")
                Button("取消", role: .cancel) { collision = nil }
                    .accessibilityIdentifier("weekly.collision.cancel")
            } message: { collision in
                Text("其中 \(collision.dayCount) 天已经有安排。加入后会保留现有安排，并追加生成的菜品。")
            }
            .alert("这份菜单已发生变化", isPresented: $isShowingStaleNotice) {
                Button("好", role: .cancel) { isShowingStaleNotice = false }
            } message: {
                Text("这份菜单已发生变化，无法继续之前的加入操作。请重新生成菜单。已经加入用餐计划的菜品不会被更改。")
            }
            .alert(
                "未能加入用餐计划",
                isPresented: Binding(
                    get: { failureMessage != nil },
                    set: { if !$0 { failureMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) { failureMessage = nil }
            } message: {
                Text(failureMessage ?? "请稍后重试。")
            }
    }
}

struct WeeklyMenuResultView: View {
    @EnvironmentObject private var recipeStore: RecipeStore
    @EnvironmentObject private var kitchenStore: KitchenStore
    @ObservedObject var store: WeeklyMenuPlannerStore
    /// Lets whoever presents this screen decide where to go afterwards. The
    /// generator has no business owning navigation policy, so when nobody is
    /// listening a finished menu simply stays on screen.
    var onMaterialized: ((WeeklyMaterializationSummary) -> Void)?

    @State private var isShowingRegenerateConfirm = false
    @State private var isShowingDeleteConfirm = false
    @State private var isShowingShoppingGeneration = false
    @State private var viewingRecipe: Recipe?
    @State private var saveErrorMessage: String?
    @State private var failureMessage: String?
    @State private var pendingCollision: WeeklyMaterializationCollision?
    @State private var isShowingStaleNotice = false
    /// One repair attempt per appearance. A menu whose meals are already on the
    /// plan only needs its bookkeeping finished, and retrying that forever would
    /// spin on a disk that is not cooperating.
    @State private var hasAttemptedReceiptRepair = false
    @State private var toastMessage: String?
    @State private var toastStyle: AppFeedbackStyle = .success

    var body: some View {
        List {
            if let plan = store.generatedPlan {
                overviewSection(plan)
                ForEach(plan.days) { day in
                    Section {
                        ForEach(day.meals) { meal in
                            mealSection(meal, dayIndex: day.dayIndex, mealsPerDay: mealsPerDay(plan))
                                .plannerRow()
                        }
                    } header: {
                        Text(dayTitle(day, startDate: plan.startDate)).plannerSectionTitle()
                    }
                }
                if !plan.shoppingItems.isEmpty {
                    shoppingSection(plan)
                }
            } else {
                ContentUnavailableView("还没有生成菜单", systemImage: "calendar")
            }
        }
        .navigationTitle("生成的菜单")
        .plannerList()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("重新生成", systemImage: "arrow.clockwise") {
                        isShowingRegenerateConfirm = true
                    }
                    .disabled(store.isGenerating || store.isMaterializing)
                    .accessibilityIdentifier("weekly.result.regenerate")
                    Button("生成购物清单", systemImage: "cart.badge.plus") {
                        isShowingShoppingGeneration = true
                    }
                    .disabled(store.generatedPlan == nil)
                    if kitchenStore.weeklyPlan != nil {
                        Button("复制到 7 天后", systemImage: "doc.on.doc") {
                            if let copy = kitchenStore.duplicateWeeklyPlanForNextWeek() {
                                store.generatedPlan = copy
                                showToast("已复制到 7 天后")
                            }
                        }
                        Button("删除这份菜单", systemImage: "trash", role: .destructive) {
                            isShowingDeleteConfirm = true
                        }
                    }
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
            }
        }
        .navigationDestination(item: $viewingRecipe) { recipe in
            RecipeDetailView(recipe: recipe)
        }
        .navigationDestination(isPresented: $isShowingShoppingGeneration) {
            if let plan = store.generatedPlan {
                ShoppingListGenerationView(source: .weeklyPlan(plan))
            }
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                FeedbackToast(message: toastMessage, style: toastStyle)
            }
        }
        .alert("重新生成菜单？", isPresented: $isShowingRegenerateConfirm) {
            Button("重新生成", role: .destructive) {
                Task { await store.regeneratePlan(recipeStore: recipeStore, kitchenStore: kitchenStore) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前菜单会被新结果替换。重新生成不会更改已经加入用餐计划的菜品。")
        }
        .alert("删除这份菜单？", isPresented: $isShowingDeleteConfirm) {
            Button("删除", role: .destructive) {
                kitchenStore.deleteWeeklyPlan()
                store.generatedPlan = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这份生成的菜单将被删除，已加入用餐计划的菜品不受影响。")
        }
        .alert(
            "暂时无法生成菜单",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "请稍后重试，或者调整人数和偏好。")
        }
        .alert(
            "无法保存到菜谱库",
            isPresented: Binding(
                get: { saveErrorMessage != nil },
                set: { if !$0 { saveErrorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) { saveErrorMessage = nil }
        } message: {
            Text(saveErrorMessage ?? "请稍后重试。")
        }
        .modifier(
            WeeklyMaterializationAlerts(
                collision: $pendingCollision,
                isShowingStaleNotice: $isShowingStaleNotice,
                failureMessage: $failureMessage,
                onConfirmAppend: { runMaterialization(confirmedAppend: true) }
            )
        )
        .onDisappear {
            store.cancelGeneration()
        }
        .task {
            repairReceiptIfTheMealsAreAlreadyThere()
        }
    }

    private func overviewSection(_ plan: WeeklyMealPlan) -> some View {
        Section {
            overviewRows(plan)
            materializationControl(plan)
        } header: {
            Text("菜单概览").plannerSectionTitle()
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: KitchenTheme.rowVerticalInset, leading: KitchenTheme.pageGutter,
                                 bottom: KitchenTheme.rowVerticalInset, trailing: KitchenTheme.pageGutter))
    }

    @ViewBuilder
    private func overviewRows(_ plan: WeeklyMealPlan) -> some View {
        let meals: String = "\(totalMeals(plan)) 顿"
        let dishes: String = "\(totalDishes(plan)) 道"
        let purchases: String = "\(plan.shoppingItems.count) 项"
        LabeledContent("日期", value: dateRangeText(plan))
            .accessibilityIdentifier("weekly.result.range")
        LabeledContent("共计", value: meals)
        LabeledContent("菜品", value: dishes)
        LabeledContent("预计新增采购", value: purchases)
    }

    // MARK: - Adding the menu to the meal plan

    /// What the plan itself says about this menu, which is the only thing worth
    /// showing. A menu whose meals are all present counts as added even if its
    /// receipt has not been marked done yet.
    private var materializationStatus: WeeklyMaterializationStatus {
        WeeklyMaterializationStatus.resolve(
            receipt: store.generatedPlan?.materialization,
            plans: kitchenStore.plans
        )
    }

    private var isAddedToPlan: Bool {
        materializationStatus == .materialized
    }

    /// The draft is the member's to reshape only until an attempt binds ids to
    /// this exact dish set. After that, regenerating is the way to a new draft.
    private var isDraftEditable: Bool {
        materializationStatus == .notStarted
    }

    @ViewBuilder
    private func materializationControl(_ plan: WeeklyMealPlan) -> some View {
        switch materializationStatus {
        case .materialized:
            // Deliberately not a button. The menu is on the plan, and the meals
            // are the Planner's to edit from here — including deleting one,
            // which does not make this menu unadded.
            Label("已加入用餐计划", systemImage: "checkmark.circle.fill")
                .foregroundStyle(AppTheme.successInk)
                .accessibilityIdentifier("weekly.result.materialized")

        case .partiallyPresent(_, let missing):
            let addTitle: String = "重新加入缺少的 \(missing.count) 道"
            VStack(alignment: .leading, spacing: 10) {
                Text("用餐计划中只保留了这份菜单的一部分。你可以重新加入缺少的菜品，或保留现在的安排。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(addTitle) {
                    handle(
                        store.materializeMissingMeals(
                            kitchenStore: kitchenStore, recipeStore: recipeStore
                        )
                    )
                }
                .disabled(store.isMaterializing)
                .accessibilityIdentifier("weekly.result.recover.add")
                Button("保留当前安排") {
                    handle(store.acceptCurrentSchedule(kitchenStore: kitchenStore))
                }
                .disabled(store.isMaterializing)
                .accessibilityIdentifier("weekly.result.recover.keep")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .notStarted, .pending:
            Button {
                runMaterialization()
            } label: {
                if store.isMaterializing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在加入…")
                    }
                } else {
                    Text("加入用餐计划")
                }
            }
            .tint(AppTheme.brand)
            .disabled(store.isMaterializing || plan.dishCount == 0)
            .accessibilityIdentifier("weekly.result.materialize")
        }
    }

    private func runMaterialization(confirmedAppend: Bool = false) {
        handle(
            store.materialize(
                kitchenStore: kitchenStore,
                recipeStore: recipeStore,
                confirmedAppend: confirmedAppend
            )
        )
    }

    /// A menu whose meals are already on the plan only needs its receipt
    /// finished. That is not a second attempt to add anything — the orchestrator
    /// refuses to append in this state — so it runs quietly, once per visit.
    private func repairReceiptIfTheMealsAreAlreadyThere() {
        guard !hasAttemptedReceiptRepair,
              store.generatedPlan?.materialization?.state == .pending,
              materializationStatus == .materialized else { return }
        hasAttemptedReceiptRepair = true
        // Whether the repair write succeeds or not, the meals are durable and
        // the screen already says so. A failure is left for the next visit. This
        // is bookkeeping, not a planning action, so it never reaches `handle`
        // and the host is not told.
        _ = store.repairReceiptIfMealsArePresent(kitchenStore: kitchenStore)
    }

    /// Turns an outcome into the one thing worth telling the member.
    private func handle(_ outcome: WeeklyMaterializationOutcome) {
        switch outcome {
        case .materialized, .materializedNeedsReceiptRepair:
            // The meals are durable in both cases; the second one only means the
            // menu record lagged behind, which the next visit repairs.
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showToast("已加入用餐计划")
            notifyHost(for: outcome)

        case .receiptRepaired:
            // Reached from a tap only through 保留当前安排 (or re-adding when
            // nothing was missing after all): the member settled the menu.
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showToast("已保留当前安排")
            notifyHost(for: outcome)

        case .alreadyMaterialized:
            break

        case .confirmationRequired(let collision):
            pendingCollision = collision

        case .missingLocalRecipe(let dishName):
            failureMessage = "「\(dishName)」已不在菜谱库。请替换或移除这道菜后再试。"

        case .recipeIdentityConflict(let dishName):
            failureMessage = "「\(dishName)」与菜谱库里的另一份菜谱冲突。请替换这道菜后再试。"

        case .recipePersistenceFailed:
            failureMessage = "菜谱没能保存到设备，请稍后重试。"

        case .receiptPersistenceFailed:
            failureMessage = "菜单没能保存到设备，请稍后重试。"

        case .planPersistenceFailed:
            failureMessage = "用餐计划没能更新，请稍后重试。"

        case .partialRecoveryRequired:
            // Shown in place by `materializationControl`, where the member can
            // act on it, rather than as an alert they must dismiss first.
            break

        case .staleReceipt:
            isShowingStaleNotice = true

        case .emptyDraft:
            failureMessage = "这份菜单里还没有菜品。"
        }
    }

    /// Every call into `handle` comes from a member's tap, so this is the only
    /// place the host is told, and each tap reaches it at most once.
    private func notifyHost(for outcome: WeeklyMaterializationOutcome) {
        guard let onMaterialized, let plan = store.generatedPlan,
              let summary = WeeklyMaterializationHostNotification.summary(for: outcome, of: plan)
        else { return }
        onMaterialized(summary)
    }

    /// The days this menu actually covers. It starts when it was generated and
    /// runs for as many days as were asked for, so it is stated as a range
    /// rather than as a week it may not line up with.
    private func dateRangeText(_ plan: WeeklyMealPlan) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M月d日"
        let (start, end) = plan.coveredDays(calendar: calendar)
        if calendar.isDate(start, inSameDayAs: end) {
            return formatter.string(from: start)
        }
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }

    private func mealSection(_ meal: WeeklyMealPlanMeal, dayIndex: Int, mealsPerDay: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(mealTitle(meal, mealsPerDay: mealsPerDay))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(meal.recipes.enumerated()), id: \.element.id) { index, recipe in
                dishRow(recipe, dayIndex: dayIndex, mealIndex: meal.mealIndex)
                if index < meal.recipes.count - 1 { Divider() }
            }
        }
        .padding(.vertical, 2)
    }

    private func dishRow(_ recipe: WeeklyMealPlanRecipe, dayIndex: Int, mealIndex: Int) -> some View {
        let isInLibrary = recipe.isSavedToLibrary
            || recipeStore.userRecipes.contains { $0.id == recipe.id }
        let coverage = inventoryCoverage(for: recipe)

        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(recipe.title).font(.subheadline.weight(.semibold))
                    if recipe.source == .ai {
                        Text("AI 新菜")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppTheme.textSecondary.opacity(0.12), in: Capsule())
                    }
                }
                if !recipe.tags.isEmpty {
                    Text(recipe.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
                if let reason = recipe.reason, !reason.isEmpty {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    if let time = recipe.cookingTime {
                        Label("\(time) 分钟", systemImage: "clock")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if coverage.uses > 0 {
                        Label("有 \(coverage.uses) 样在库", systemImage: "checkmark.circle")
                            .font(.caption2).foregroundStyle(AppTheme.successInk)
                    }
                    if coverage.missing > 0 {
                        Label("缺 \(coverage.missing) 样", systemImage: "cart.badge.plus")
                            .font(.caption2).foregroundStyle(AppTheme.warningInk)
                    }
                }
            }
            Spacer()
            if store.replacingRecipeID == recipe.id {
                ProgressView()
            } else {
                Menu {
                    Button("查看菜谱", systemImage: "book.pages") {
                        viewingRecipe = recipeForDetail(recipe)
                    }
                    // Once the meals are on the plan the Planner owns them, and a
                    // draft edited here would no longer be the menu that was added,
                    // so the editing actions go away. While an attempt is pending
                    // the receipt's ids are bound to this exact dish set, so they
                    // stay visible but locked; regenerating is the way to a new draft.
                    if !isAddedToPlan {
                        Button("替换这道", systemImage: "arrow.triangle.2.circlepath") {
                            Task {
                                await store.replaceRecipe(
                                    dayIndex: dayIndex,
                                    mealIndex: mealIndex,
                                    recipeID: recipe.id,
                                    recipeStore: recipeStore,
                                    kitchenStore: kitchenStore
                                )
                            }
                        }
                        .disabled(!isDraftEditable)
                        let otherDays = otherDayIndices(excluding: dayIndex)
                        if !otherDays.isEmpty {
                            Menu("移到其他天") {
                                ForEach(otherDays, id: \.self) { targetDay in
                                    Button("第 \(targetDay + 1) 天") {
                                        store.moveRecipe(recipe.id, fromDay: dayIndex, mealIndex: mealIndex, toDay: targetDay)
                                    }
                                }
                            }
                            .disabled(!isDraftEditable)
                        }
                    }
                    // Offered only while the recipe really is missing from the
                    // library. Materializing the menu stores it, so continuing to
                    // offer it afterwards would invite a member to save what they
                    // already have.
                    if recipe.source == .ai && !isInLibrary {
                        Button("保存到菜谱库", systemImage: "square.and.arrow.down") {
                            attemptSaveToLibrary(recipe)
                        }
                    }
                    if !isAddedToPlan {
                        Divider()
                        Button("从计划移除", systemImage: "trash", role: .destructive) {
                            store.removeRecipe(recipe.id, dayIndex: dayIndex, mealIndex: mealIndex)
                        }
                        .disabled(!isDraftEditable)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.primary)
                }
                .accessibilityIdentifier("weekly.result.dish.menu")
            }
        }
        .padding(.vertical, 4)
    }

    private func shoppingSection(_ plan: WeeklyMealPlan) -> some View {
        Section {
            ForEach(plan.shoppingItems) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                        if let reason = item.reason, !reason.isEmpty {
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text([item.quantityText, item.unit].compactMap { $0 }.joined(separator: " "))
                        .foregroundStyle(.secondary)
                }
            }
            .onDelete { offsets in
                store.removeShoppingItems(at: offsets)
            }

            Button("加入买菜清单（\(plan.shoppingItems.count)）") {
                store.addShoppingItems(plan.shoppingItems, kitchenStore: kitchenStore)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                showToast("已加入买菜清单")
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.managementActionFill)
            .foregroundStyle(AppTheme.onManagementAction)
        } header: {
            Text("需要购买").plannerSectionTitle()
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: KitchenTheme.rowVerticalInset, leading: KitchenTheme.pageGutter,
                                 bottom: KitchenTheme.rowVerticalInset, trailing: KitchenTheme.pageGutter))
    }


    private func attemptSaveToLibrary(_ recipe: WeeklyMealPlanRecipe) {
        do {
            try store.saveRecipeToLibrary(recipe, recipeStore: recipeStore)
            showToast("已保存到菜谱库")
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }

    private func showToast(_ message: String, style: AppFeedbackStyle = .success) {
        withAnimation { toastMessage = message; toastStyle = style }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            await MainActor.run { withAnimation { toastMessage = nil } }
        }
    }


    private func recipeForDetail(_ recipe: WeeklyMealPlanRecipe) -> Recipe {
        if let existingID = recipe.existingRecipeID,
           let matched = recipeStore.recipes.first(where: { $0.id == existingID }) {
            return matched
        }
        return Recipe(
            id: recipe.id,
            title: recipe.title,
            cookingTime: recipe.cookingTime,
            difficulty: recipe.difficulty,
            tags: recipe.tags,
            ingredients: recipe.ingredients,
            steps: recipe.steps.isEmpty ? ["暂未提供详细步骤。"] : recipe.steps
        )
    }

    private func inventoryCoverage(for recipe: WeeklyMealPlanRecipe) -> (uses: Int, missing: Int) {
        let names = kitchenStore.recipeCreationInventory.map(\.name)
        let uses = recipe.ingredients.filter { ingredient in
            names.contains { ingredient.localizedCaseInsensitiveContains($0) }
        }.count
        return (uses, max(0, recipe.ingredients.count - uses))
    }

    private func otherDayIndices(excluding dayIndex: Int) -> [Int] {
        (store.generatedPlan?.days.map(\.dayIndex) ?? []).filter { $0 != dayIndex }.sorted()
    }

    private func totalMeals(_ plan: WeeklyMealPlan) -> Int {
        plan.days.reduce(0) { $0 + $1.meals.count }
    }

    private func totalDishes(_ plan: WeeklyMealPlan) -> Int {
        plan.days.reduce(0) { $0 + $1.meals.reduce(0) { $0 + $1.recipes.count } }
    }

    private func mealsPerDay(_ plan: WeeklyMealPlan) -> Int {
        plan.days.first?.meals.count ?? 1
    }

    private func dayIndexForToday(_ plan: WeeklyMealPlan) -> Int? {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: plan.startDate)
        return calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: Date())).day
    }

    private func dayTitle(_ day: WeeklyMealPlanDay, startDate: Date) -> String {
        let weekdaySymbols = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        guard let date = Calendar.current.date(byAdding: .day, value: day.dayIndex, to: startDate) else {
            return "第 \(day.dayIndex + 1) 天"
        }
        let weekday = Calendar.current.component(.weekday, from: date) - 1
        let symbol = weekdaySymbols.indices.contains(weekday) ? weekdaySymbols[weekday] : ""
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        let dateText = formatter.string(from: date)
        return symbol.isEmpty ? dateText : "\(symbol) · \(dateText)"
    }

    private func mealTitle(_ meal: WeeklyMealPlanMeal, mealsPerDay: Int) -> String {
        if let title = meal.title, !title.isEmpty { return title }
        if mealsPerDay <= 1 { return "今日安排" }
        let names = ["早餐", "午餐", "晚餐"]
        return names.indices.contains(meal.mealIndex) ? names[meal.mealIndex] : "第 \(meal.mealIndex + 1) 顿"
    }
}

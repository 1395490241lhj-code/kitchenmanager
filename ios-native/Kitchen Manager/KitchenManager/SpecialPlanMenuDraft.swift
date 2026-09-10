import Combine
import Foundation

// MARK: - Special plan menu draft (transient)
//
// Everything in this file is transient. A generated menu lives here — never in
// SwiftData, never in RecipeStore — until the user taps 保存菜单. Leaving the
// screen discards it, and no AI transcript is kept: the draft is structured
// state, not a conversation.

/// One proposed dish. Either resolves to a recipe the library already has
/// (existingRecipeID set) or carries a full AI draft that acceptance will turn
/// into a new user recipe.
struct SpecialPlanMenuDraftDish: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var ingredients: [String]
    var seasonings: [String]
    var steps: [String]
    var tags: [String]
    var cookingTime: Int?
    var difficulty: String?
    var reason: String?
    /// Non-nil when the AI picked a recipe the user already owns.
    var existingRecipeID: String?
    /// The yield this dish's quantities were written for, as declared by the
    /// model and already validated against the generation contract.
    ///
    /// Carried rather than re-derived at save time: the saved recipe's yield
    /// has to trace back to what the response actually said, not to a constant
    /// the save path re-asserts on its own.
    var baseServings: Int?

    var isExistingRecipe: Bool { existingRecipeID != nil }

    /// The recipe this dish would produce on acceptance. Built through the same
    /// Recipe initializer the rest of the app uses, so ingredient/seasoning
    /// classification stays identical.
    func makeRecipe(id: String) -> Recipe {
        Recipe(
            id: id,
            title: title,
            cookingTime: cookingTime,
            difficulty: difficulty,
            tags: tags,
            ingredients: ingredients,
            seasonings: seasonings,
            steps: steps.isEmpty ? ["暂未提供详细步骤。"] : steps,
            // From the validated response, never re-asserted here.
            baseServings: baseServings
        )
    }
}

@MainActor
final class SpecialPlanMenuDraftStore: ObservableObject {
    /// The proposed menu. Empty unless a generation succeeded.
    @Published private(set) var dishes: [SpecialPlanMenuDraftDish] = []
    /// True only while a menu or replacement request is in flight. Acceptance
    /// is synchronous, so there is no separate "saving" state to observe: the
    /// presence of a draft is simply `dishes`.
    @Published private(set) var isGenerating = false
    @Published var errorMessage: String?
    /// Which dish is mid-replacement, so its row can show progress without
    /// blocking the rest of the draft.
    @Published private(set) var replacingDishID: UUID?

    private let generator: SpecialPlanMenuGenerator

    /// Handles on the requests in flight. Held so the user can stop one.
    ///
    /// Without these the composer had no cancellation path at any layer: the
    /// sheet disabled its own 取消 and its interactive dismissal while a request
    /// ran, so a 50 s timeout was a 50 s trap. A generation the user cannot
    /// leave is the agency failure this store exists to remove.
    private var composeTask: Task<SpecialPlanComposition, Error>?
    private var activeComposeID: UUID?
    private var replaceTask: Task<SpecialPlanMenuDraftDish, Error>?
    private var activeReplaceID: UUID?

    /// `dishes` seeds a draft that was composed elsewhere — the creation sheet
    /// generates before the plan exists, then hands the menu to the detail.
    init(
        generator: SpecialPlanMenuGenerator,
        dishes: [SpecialPlanMenuDraftDish] = []
    ) {
        self.generator = generator
        self.dishes = dishes
    }

    convenience init(dishes: [SpecialPlanMenuDraftDish] = []) {
        self.init(generator: SpecialPlanMenuGenerator(), dishes: dishes)
    }

    var hasDraft: Bool { !dishes.isEmpty }
    var isBusy: Bool { isGenerating }

    // MARK: - Composition

    /// The composer's one action: read the request and write a menu in a single
    /// round trip. On success the draft holds the menu and the model's reading
    /// of the request is returned for the caller to turn into plan fields. On
    /// failure the previous draft is untouched and `nil` is returned.
    ///
    /// Cancellation returns `nil` exactly like a failure, but leaves
    /// `errorMessage` alone: stopping on purpose is not an error, and the
    /// caller must not turn it into one.
    @discardableResult
    func compose(
        _ input: SpecialPlanMenuGenerator.Input,
        kitchenStore: KitchenStore,
        recipeStore: RecipeStore,
        excludedRecipeNames: [String] = []
    ) async -> SpecialPlanInterpretation? {
        guard !isBusy else { return nil }
        let requestID = UUID()
        activeComposeID = requestID
        isGenerating = true
        errorMessage = nil
        // The draft you already had survives a failure *and* a cancellation
        // because nothing below writes `dishes` until a composition actually
        // succeeds. That is a structural guarantee, not a restore step.
        //
        // An explicit `dishes = previous` in the failure path looked harmless
        // and was not: `discard()` empties the draft while a request is still
        // in flight, and the cancelled request would then put the discarded
        // dishes back. Restoring a snapshot can only ever fight a deliberate
        // later edit, so there is no snapshot.
        // Only the request that still owns the store clears its busy state. A
        // cancelled request must not switch the spinner back on for whatever
        // replaced it.
        defer {
            if activeComposeID == requestID {
                isGenerating = false
                activeComposeID = nil
                composeTask = nil
            }
        }

        // Read on the main actor before the task starts, so the request is built
        // from a snapshot rather than from stores read off an escaping closure.
        // The full creation pool is offered; the generator sends none of it when
        // the plan does not use home inventory.
        let inventory = kitchenStore.recipeCreationInventory
        let existingRecipes = recipeStore.recipes
        let generator = self.generator
        let task = Task {
            try await generator.composeMenu(
                input,
                inventory: inventory,
                existingRecipes: existingRecipes,
                excludedRecipeNames: excludedRecipeNames
            )
        }
        composeTask = task

        do {
            let composition = try await task.value
            // A cancelled or superseded request never writes a draft.
            guard activeComposeID == requestID else { return nil }
            dishes = composition.dishes
            return composition.interpretation
        } catch {
            // Cancelled, or superseded by a later request. Deliberately keyed on
            // ownership rather than on the error type: a cancelled URLSession
            // surfaces as `APIError.cancelled` in production and as
            // `CancellationError` through the test seam, and neither is a
            // failure the user should be told about.
            guard activeComposeID == requestID, !Self.isCancellation(error) else { return nil }
            errorMessage = Self.message(for: error)
            return nil
        }
    }

    /// Regenerates the menu for a plan that already exists, from the plan's
    /// own saved request. The model's reading of the request is discarded
    /// here: the plan's fields were settled when it was created or edited.
    func generate(
        for plan: SpecialPlan,
        kitchenStore: KitchenStore,
        recipeStore: RecipeStore
    ) async {
        await compose(
            SpecialPlanMenuGenerator.Input(plan: plan),
            kitchenStore: kitchenStore,
            recipeStore: recipeStore,
            excludedRecipeNames: plan.dishes.map(\.recipeName)
        )
    }

    /// Adopts a draft composed by another store instance (the creation or edit
    /// sheet), replacing whatever this one held.
    func adopt(_ newDishes: [SpecialPlanMenuDraftDish]) {
        activeReplaceID = nil
        replaceTask?.cancel()
        replaceTask = nil
        dishes = newDishes
        errorMessage = nil
        replacingDishID = nil
    }

    // MARK: - Targeted replacement

    /// Replaces exactly one dish. Every other dish keeps its identity and
    /// content, and a failure leaves the original dish in place.
    func replaceDish(
        id dishID: UUID,
        for plan: SpecialPlan,
        kitchenStore: KitchenStore,
        recipeStore: RecipeStore
    ) async {
        guard !isBusy, replacingDishID == nil else { return }
        guard let index = dishes.firstIndex(where: { $0.id == dishID }) else { return }
        let requestID = UUID()
        activeReplaceID = requestID
        replacingDishID = dishID
        errorMessage = nil
        let original = dishes[index]

        // A row keeps its dishID across retries; only this request token owns
        // the result, error and cleanup after an await.
        defer {
            if activeReplaceID == requestID {
                activeReplaceID = nil
                replacingDishID = nil
                replaceTask = nil
            }
        }

        do {
            // Every current dish name is excluded so the model does not simply
            // hand back something already on the menu.
            let exclusions = dishes.map(\.title) + plan.dishes.map(\.recipeName)
            let inventory = kitchenStore.recipeCreationInventory
            let existingRecipes = recipeStore.recipes
            let generator = self.generator
            let task = Task {
                try await generator.generateReplacement(
                    for: plan,
                    inventory: inventory,
                    existingRecipes: existingRecipes,
                    excludedRecipeNames: exclusions
                )
            }
            replaceTask = task
            var replacement = try await task.value
            // Cancelled while in flight: the original dish stays exactly as it
            // was, which is the same guarantee a failure gives.
            guard activeReplaceID == requestID else { return }
            // Keep the row's identity stable so SwiftUI replaces content in
            // place rather than animating a delete + insert.
            replacement.id = original.id
            guard let current = dishes.firstIndex(where: { $0.id == dishID }) else {
                return
            }
            dishes[current] = replacement
        } catch {
            if activeReplaceID == requestID, !Self.isCancellation(error) {
                errorMessage = Self.message(for: error)
            }
        }
    }

    func removeDish(id dishID: UUID) {
        dishes.removeAll { $0.id == dishID }
    }

    /// Stops whatever is in flight and hands the surface back to the user.
    ///
    /// The draft is not touched: requests write only when they still own their
    /// result. No snapshot can resurrect a deliberately discarded draft. Safe
    /// to call unconditionally on dismissal, even when nothing is running.
    func cancelGeneration() {
        composeTask?.cancel()
        composeTask = nil
        activeComposeID = nil
        isGenerating = false

        activeReplaceID = nil
        replaceTask?.cancel()
        replaceTask = nil
        replacingDishID = nil
    }

    func discard() {
        cancelGeneration()
        dishes = []
        errorMessage = nil
    }

    // MARK: - Acceptance

    /// Turns the draft into canonical state. Recipes are created first and the
    /// plan is written last; if any recipe fails to save, every recipe created
    /// by this call is rolled back and the plan is left untouched.
    @discardableResult
    func save(
        to planID: UUID,
        kitchenStore: KitchenStore,
        recipeStore: RecipeStore
    ) -> Bool {
        guard !isBusy, !dishes.isEmpty else { return false }
        errorMessage = nil

        do {
            let references = try SpecialPlanMenuAcceptance.acceptMenu(
                dishes: dishes,
                planID: planID,
                kitchenStore: kitchenStore,
                recipeStore: recipeStore
            )
            guard !references.isEmpty else {
                errorMessage = SpecialPlanMenuAcceptanceError.nothingToSave.localizedDescription
                return false
            }
            dishes = []
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? SpecialPlanMenuGeneratorError.invalidResponse.errorDescription
            ?? "操作失败，请稍后重试。"
    }

    /// A stop the user asked for, in either of the two shapes it arrives in.
    /// `APIClient` already maps a cancelled `URLSession` and a cancelled `Task`
    /// onto `APIError.cancelled`; the test seam throws `CancellationError`
    /// directly. Neither is a failure worth showing.
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let apiError = error as? APIError, case .cancelled = apiError { return true }
        return false
    }
}

// MARK: - Turning a reading into plan fields

extension SpecialPlanInterpretation {
    /// A brand-new plan from the composer. Fields the model did not read are
    /// filled with the least surprising value and stay visible on the detail,
    /// where the user can re-describe the meal to change them:
    ///
    /// - title: the model's, else the request's opening words;
    /// - date: the model's, else the Planner day the sheet was opened from at
    ///   18:00, else the next 18:00 from now;
    /// - headcount: the model's, else a number the request states, else 2.
    func makePlan(
        requestText: String,
        usesHomeInventory: Bool,
        contextDate: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> SpecialPlan {
        let created = now
        return SpecialPlan(
            title: resolvedTitle(requestText: requestText),
            scheduledAt: resolvedDate(contextDate: contextDate, now: now, calendar: calendar),
            peopleCount: resolvedPeopleCount(requestText: requestText),
            constraintNotes: constraintNotes,
            notes: notes,
            requestText: requestText,
            usesHomeInventory: usesHomeInventory,
            createdAt: created,
            updatedAt: created
        )
    }

    /// An edited plan: the same derivation, applied onto the existing plan so
    /// its id, dishes and creation time survive. The previous date is the
    /// fallback when the new request names none.
    func apply(
        to plan: SpecialPlan,
        requestText: String,
        usesHomeInventory: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> SpecialPlan {
        var updated = plan
        updated.title = resolvedTitle(requestText: requestText)
        // A re-description that names no date keeps the plan's exact time,
        // not a 18:00 re-reading of the same day.
        updated.scheduledAt = scheduledAt ?? plan.scheduledAt
        updated.peopleCount = resolvedPeopleCount(requestText: requestText)
        updated.constraintNotes = SpecialPlan.normalizedConstraintNotes(constraintNotes)
        updated.notes = notes
        updated.requestText = requestText.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.usesHomeInventory = usesHomeInventory
        updated.updatedAt = now
        return updated
    }

    func resolvedTitle(requestText: String) -> String {
        if let title { return title }
        let opening = requestText
            .split(whereSeparator: { "，。,.；;！!？?\n".contains($0) })
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if opening.isEmpty { return "特殊安排" }
        return String(opening.prefix(12))
    }

    func resolvedDate(contextDate: Date?, now: Date, calendar: Calendar) -> Date {
        if let scheduledAt { return scheduledAt }
        if let contextDate {
            return calendar.date(bySettingHour: 18, minute: 0, second: 0, of: contextDate) ?? contextDate
        }
        let tonight = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now) ?? now
        if tonight > now { return tonight }
        return calendar.date(byAdding: .day, value: 1, to: tonight) ?? tonight
    }

    func resolvedPeopleCount(requestText: String) -> Int {
        peopleCount ?? SpecialPlanRequestReading(requestText: requestText).peopleCount ?? 2
    }
}

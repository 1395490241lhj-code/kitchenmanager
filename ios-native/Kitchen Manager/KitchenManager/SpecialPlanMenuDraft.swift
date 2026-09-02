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

    init(generator: SpecialPlanMenuGenerator = SpecialPlanMenuGenerator()) {
        self.generator = generator
    }

    var hasDraft: Bool { !dishes.isEmpty }
    var isBusy: Bool { isGenerating }

    // MARK: - Generation

    func generate(
        for plan: SpecialPlan,
        kitchenStore: KitchenStore,
        recipeStore: RecipeStore
    ) async {
        guard !isBusy else { return }
        isGenerating = true
        errorMessage = nil
        // A failed generation must leave the previous draft untouched.
        let previous = dishes

        do {
            let generated = try await generator.generateMenu(
                for: plan,
                inventory: kitchenStore.recipeCreationInventory,
                expiringItems: kitchenStore.recipeCreationExpiringItems,
                existingRecipes: recipeStore.recipes,
                excludedRecipeNames: plan.dishes.map(\.recipeName)
            )
            dishes = generated
        } catch {
            dishes = previous
            errorMessage = Self.message(for: error)
        }
        isGenerating = false
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
        replacingDishID = dishID
        errorMessage = nil
        let original = dishes[index]

        do {
            // Every current dish name is excluded so the model does not simply
            // hand back something already on the menu.
            let exclusions = dishes.map(\.title) + plan.dishes.map(\.recipeName)
            var replacement = try await generator.generateReplacement(
                for: plan,
                inventory: kitchenStore.recipeCreationInventory,
                expiringItems: kitchenStore.recipeCreationExpiringItems,
                existingRecipes: recipeStore.recipes,
                excludedRecipeNames: exclusions
            )
            // Keep the row's identity stable so SwiftUI replaces content in
            // place rather than animating a delete + insert.
            replacement.id = original.id
            guard let current = dishes.firstIndex(where: { $0.id == dishID }) else { return }
            dishes[current] = replacement
        } catch {
            errorMessage = Self.message(for: error)
        }
        replacingDishID = nil
    }

    func removeDish(id dishID: UUID) {
        dishes.removeAll { $0.id == dishID }
    }

    func discard() {
        dishes = []
        errorMessage = nil
        replacingDishID = nil
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
}

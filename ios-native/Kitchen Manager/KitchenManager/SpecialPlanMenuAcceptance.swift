import Foundation

// MARK: - Special plan menu acceptance
//
// Turning a transient draft into canonical state. This is the only place a
// generated *menu* is allowed to touch RecipeStore or SpecialPlan, and it runs
// as one all-or-nothing step: every recipe this call creates is rolled back if
// any later step fails, so a failed save can never leave orphan recipes behind
// with no plan referencing them.
//
// The recipe resolution rules themselves live in `GeneratedRecipeMaterializer`,
// which the conversation workspace shares. They are the same rules, in one
// place — not a second implementation that can drift from this one.

enum SpecialPlanMenuAcceptanceError: LocalizedError, Equatable {
    case nothingToSave
    case planMissing
    case recipeSaveFailed(String)
    /// The recipes were written but the plan itself could not be saved. A
    /// separate case because retrying is the right answer here, where
    /// `planMissing` names a plan that is gone and retrying cannot help.
    case planSaveFailed

    var errorDescription: String? {
        switch self {
        case .nothingToSave:
            return "没有可保存的菜品。"
        case .planMissing:
            return "这个特殊计划已不存在，菜单未保存。"
        case .recipeSaveFailed(let title):
            return "保存「\(title)」失败，菜单未保存，请稍后重试。"
        case .planSaveFailed:
            return "菜单保存失败，请稍后重试。"
        }
    }
}

enum SpecialPlanMenuAcceptance {
    /// Accepts a draft menu.
    ///
    /// Order matters: recipes are resolved or created first so the plan only
    /// ever stores ids that already exist, and the plan write happens last.
    /// Recipes created here are tracked so they can be removed again if a later
    /// recipe fails, which keeps the library free of half-written menus.
    @MainActor
    @discardableResult
    static func acceptMenu(
        dishes: [SpecialPlanMenuDraftDish],
        planID: UUID,
        kitchenStore: KitchenStore,
        recipeStore: RecipeStore
    ) throws -> [SpecialPlanDish] {
        guard !dishes.isEmpty else { throw SpecialPlanMenuAcceptanceError.nothingToSave }
        guard kitchenStore.specialPlans.contains(where: { $0.id == planID }) else {
            throw SpecialPlanMenuAcceptanceError.planMissing
        }
        // Defence in depth on the only path that writes a generated recipe.
        // Generation already rejects a non-conforming draft, so this is the
        // same rule rather than a second one: reaching here with a bad yield
        // means the draft came from somewhere else, and writing it would
        // fabricate the provenance the contract exists to establish.
        do {
            try SpecialPlanMenuGenerator.validateBaseYield(dishes)
        } catch {
            throw SpecialPlanMenuAcceptanceError.recipeSaveFailed(dishes.first?.title ?? "")
        }

        // The resolution rules live in `GeneratedRecipeMaterializer` because the
        // conversation workspace needs the identical ones. This call site keeps
        // its own error vocabulary: the helper says what went wrong, and this
        // says what it means for a menu.
        let batch: MaterializedRecipeBatch
        do {
            batch = try GeneratedRecipeMaterializer.materialize(
                dishes.map {
                    GeneratedRecipeCandidate(
                        existingRecipeID: $0.existingRecipeID,
                        recipe: $0.makeRecipe(id: "special-ai-\(UUID().uuidString.lowercased())")
                    )
                },
                recipeStore: recipeStore
            )
        } catch GeneratedRecipeMaterializerError.saveFailed(let title) {
            throw SpecialPlanMenuAcceptanceError.recipeSaveFailed(title)
        } catch {
            throw SpecialPlanMenuAcceptanceError.recipeSaveFailed(dishes.first?.title ?? "")
        }

        let references = batch.recipes.map {
            SpecialPlanDish(recipeID: $0.id, recipeName: $0.title)
        }

        // The plan write is last, so nothing references a recipe that does not
        // exist yet, and it persists before it publishes — a menu the database
        // refused must not be sitting on screen looking saved.
        let outcome = kitchenStore.setSpecialPlanDishes(planID: planID, dishes: references)
        switch outcome {
        case .saved:
            return references
        case .notFound:
            GeneratedRecipeMaterializer.rollbackCreatedRecipes(batch.createdRecipeIDs, recipeStore: recipeStore)
            throw SpecialPlanMenuAcceptanceError.planMissing
        case .persistenceFailed:
            GeneratedRecipeMaterializer.rollbackCreatedRecipes(batch.createdRecipeIDs, recipeStore: recipeStore)
            throw SpecialPlanMenuAcceptanceError.planSaveFailed
        case .rejected:
            // Unreachable as written: an empty menu is refused at the top of
            // this method, and `references` holds exactly one dish per draft.
            // Mapped to the retryable failure rather than trapped, so if either
            // guard ever changes this degrades into an honest error instead of
            // a crash — and still rolls back, which is the part that matters.
            GeneratedRecipeMaterializer.rollbackCreatedRecipes(batch.createdRecipeIDs, recipeStore: recipeStore)
            throw SpecialPlanMenuAcceptanceError.planSaveFailed
        }
    }

}

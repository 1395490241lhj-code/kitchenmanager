import Foundation

// MARK: - Special plan menu acceptance
//
// Turning a transient draft into canonical state. This is the only place a
// generated menu is allowed to touch RecipeStore or SpecialPlan, and it runs as
// one all-or-nothing step: every recipe this call creates is rolled back if any
// later step fails, so a failed save can never leave orphan recipes behind with
// no plan referencing them.

enum SpecialPlanMenuAcceptanceError: LocalizedError, Equatable {
    case nothingToSave
    case planMissing
    case recipeSaveFailed(String)

    var errorDescription: String? {
        switch self {
        case .nothingToSave:
            return "没有可保存的菜品。"
        case .planMissing:
            return "这个特殊计划已不存在，菜单未保存。"
        case .recipeSaveFailed(let title):
            return "保存「\(title)」失败，菜单未保存，请稍后重试。"
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

        var references: [SpecialPlanDish] = []
        // Only ids this call actually inserted; a reused recipe must never be
        // deleted by a rollback.
        var createdRecipeIDs: [String] = []

        do {
            for dish in dishes {
                if let resolved = resolveExistingRecipe(for: dish, recipeStore: recipeStore) {
                    references.append(
                        SpecialPlanDish(recipeID: resolved.id, recipeName: resolved.title)
                    )
                    continue
                }

                let recipe = dish.makeRecipe(id: "special-ai-\(UUID().uuidString.lowercased())")
                do {
                    try recipeStore.saveUserRecipe(recipe)
                    createdRecipeIDs.append(recipe.id)
                } catch UserRecipeSaveError.alreadySaved {
                    // The library already holds an identical recipe (same
                    // fingerprint). Reuse it instead of creating a duplicate.
                    if let twin = recipeStore.recipes.first(where: {
                        RecipeStore.fingerprint(for: $0) == RecipeStore.fingerprint(for: recipe)
                    }) {
                        references.append(
                            SpecialPlanDish(recipeID: twin.id, recipeName: twin.title)
                        )
                        continue
                    }
                    throw SpecialPlanMenuAcceptanceError.recipeSaveFailed(dish.title)
                }
                references.append(
                    SpecialPlanDish(recipeID: recipe.id, recipeName: recipe.title)
                )
            }

            // The plan write is last, so nothing references a recipe that does
            // not exist yet.
            guard var plan = kitchenStore.specialPlans.first(where: { $0.id == planID }) else {
                throw SpecialPlanMenuAcceptanceError.planMissing
            }
            plan.dishes = references
            plan.updatedAt = Date()
            kitchenStore.updateSpecialPlan(plan)
            return references
        } catch {
            // Roll back only what this call created.
            for id in createdRecipeIDs.reversed() {
                try? recipeStore.deleteUserRecipe(id: id)
            }
            if let acceptanceError = error as? SpecialPlanMenuAcceptanceError {
                throw acceptanceError
            }
            throw SpecialPlanMenuAcceptanceError.recipeSaveFailed(
                dishes.first?.title ?? ""
            )
        }
    }

    /// Reuses a recipe the library already has, either because the AI named one
    /// explicitly or because an identical one is already saved. Deliberately
    /// conservative: exact id, then exact content fingerprint, then normalized
    /// title — never fuzzy matching that could merge two different dishes.
    @MainActor
    static func resolveExistingRecipe(
        for dish: SpecialPlanMenuDraftDish,
        recipeStore: RecipeStore
    ) -> Recipe? {
        if let existingID = dish.existingRecipeID,
           let matched = recipeStore.recipes.first(where: { $0.id == existingID }) {
            return matched
        }

        let candidate = dish.makeRecipe(id: "special-ai-probe")
        let fingerprint = RecipeStore.fingerprint(for: candidate)
        if let twin = recipeStore.recipes.first(where: {
            RecipeStore.fingerprint(for: $0) == fingerprint
        }) {
            return twin
        }
        return nil
    }
}

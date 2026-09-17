import Foundation

// MARK: - Generated recipe materialization
//
// Turning a recipe the AI produced into something canonical state is allowed to
// point at. Special Plan menu acceptance has done this since it shipped; the
// conversation workspace needs the identical rules, so they live here once
// rather than being reimplemented next to a second caller.
//
// The resolution order is deliberately conservative and unchanged: the exact id
// the model named, then an exact content fingerprint, and only then a new user
// recipe. Never a name match or a likeness score — merging two different dishes
// because they read alike is worse than saving one more recipe.

/// One dish a caller wants to end up holding a real recipe id for.
nonisolated struct GeneratedRecipeCandidate: Equatable {
    /// The library recipe the model explicitly named, if it named one.
    var existingRecipeID: String?
    /// The recipe to create when nothing existing matches. Its id is the id the
    /// new user recipe gets, so the caller can record it before the write and
    /// retry with the same id afterwards.
    var recipe: Recipe
}

/// What a batch resolved to, and what it is responsible for undoing.
nonisolated struct MaterializedRecipeBatch: Equatable {
    /// One recipe per candidate, in the order the candidates arrived.
    let recipes: [Recipe]
    /// Only the ids *this call* inserted. A reused recipe is not in here, which
    /// is what stops compensation from deleting something the user already had.
    let createdRecipeIDs: [String]
}

enum GeneratedRecipeMaterializerError: LocalizedError, Equatable {
    /// The library refused the recipe and no identical one could be reused.
    case saveFailed(title: String)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let title):
            return "保存「\(title)」失败，请稍后重试。"
        }
    }
}

enum GeneratedRecipeMaterializer {
    /// Resolves or creates every candidate, or leaves the library untouched.
    ///
    /// A partial batch is never returned: if any candidate fails, the recipes
    /// this call already created are removed again before the error is thrown,
    /// so a caller can never be handed half a menu or leave orphan recipes that
    /// nothing references.
    @MainActor
    static func materialize(
        _ candidates: [GeneratedRecipeCandidate],
        recipeStore: RecipeStore
    ) throws -> MaterializedRecipeBatch {
        var resolved: [Recipe] = []
        var createdRecipeIDs: [String] = []

        do {
            for candidate in candidates {
                if let existing = resolveExisting(candidate, recipeStore: recipeStore) {
                    resolved.append(existing)
                    continue
                }

                let recipe = candidate.recipe
                do {
                    try recipeStore.saveUserRecipe(recipe)
                    createdRecipeIDs.append(recipe.id)
                } catch UserRecipeSaveError.alreadySaved {
                    // The library already holds an identical recipe. Reuse it
                    // instead of creating a duplicate.
                    guard let twin = fingerprintTwin(of: recipe, in: recipeStore) else {
                        throw GeneratedRecipeMaterializerError.saveFailed(title: recipe.title)
                    }
                    resolved.append(twin)
                    continue
                }
                resolved.append(recipe)
            }
        } catch {
            rollbackCreatedRecipes(createdRecipeIDs, recipeStore: recipeStore)
            throw error
        }

        return MaterializedRecipeBatch(recipes: resolved, createdRecipeIDs: createdRecipeIDs)
    }

    /// A recipe the library already has: the exact id the model named, or an
    /// exact content twin. A named id that no longer resolves is not an error —
    /// the dish falls back to the content it arrived with.
    @MainActor
    static func resolveExisting(
        _ candidate: GeneratedRecipeCandidate,
        recipeStore: RecipeStore
    ) -> Recipe? {
        resolveExisting(candidate, recipes: recipeStore.recipes)
    }

    /// Shared by the read-only confirmation preview and the actual writer.
    @MainActor
    static func resolveExisting(_ candidate: GeneratedRecipeCandidate, recipes: [Recipe]) -> Recipe? {
        if let existingID = candidate.existingRecipeID,
           let matched = recipes.first(where: { $0.id == existingID }) {
            return matched
        }
        let fingerprint = RecipeStore.fingerprint(for: candidate.recipe)
        return recipes.first { RecipeStore.fingerprint(for: $0) == fingerprint }
    }

    /// Removes recipes a failed sequence created. Best effort on purpose: a
    /// delete that itself fails must not replace the original error, which is
    /// the one the user needs to hear about.
    @MainActor
    static func rollbackCreatedRecipes(_ ids: [String], recipeStore: RecipeStore) {
        for id in ids.reversed() {
            try? recipeStore.deleteUserRecipe(id: id)
        }
    }

    @MainActor
    private static func fingerprintTwin(of recipe: Recipe, in recipeStore: RecipeStore) -> Recipe? {
        let fingerprint = RecipeStore.fingerprint(for: recipe)
        return recipeStore.recipes.first { RecipeStore.fingerprint(for: $0) == fingerprint }
    }
}

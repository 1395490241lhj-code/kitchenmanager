import SwiftUI

// MARK: - The cooking flow, in one place
//
// P-2 of the behavior-contract prototype. Home's primary action used to open a
// recipe page and stop there, so 开始准备 described a navigation rather than the
// thing the user came to do. Making it start cooking meant either duplicating
// the cook → confirm → mark chain into Home, or extracting it once.
//
// It is extracted once. Two implementations of "what cooking a planned dish
// does" would eventually disagree about the part that writes inventory, which
// is the one part that must not have two answers.

/// The dish a cooking flow is about, and the plan it belongs to when there is
/// one. An ordinary recipe cooked outside any plan carries `plan == nil` and
/// deliberately marks nothing complete.
struct CookingFlowRequest: Identifiable, Equatable {
    let recipe: Recipe
    let plan: MealPlanItem?

    var id: String { "\(plan?.id.uuidString ?? "-")|\(recipe.id)" }

    /// The yield this cook starts from: the plan's stated target when it has
    /// one, otherwise the recipe's own base. Never 1 by default — a recipe with
    /// a stated yield should be cooked as written rather than divided down.
    var initialServings: Int {
        plan?.plannedServings ?? recipe.baseServings ?? 1
    }
}

private struct CookingFlowModifier: ViewModifier {
    @Binding var request: CookingFlowRequest?
    @ObservedObject var session: RecipeCookingSession
    @EnvironmentObject private var kitchenStore: KitchenStore

    /// Held separately from `request` so the confirmation can outlive the
    /// full-screen cover: the cover closes first, then the sheet asks. That
    /// order is `RecipeDetailView`'s existing behaviour, preserved exactly.
    @State private var confirming: CookingFlowRequest?

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $request) { active in
                RecipeCookingModeView(
                    recipe: active.recipe,
                    session: session,
                    plan: active.plan
                ) {
                    request = nil
                    confirming = active
                } onExit: {
                    // Leaving cooking mode writes nothing. That is the whole
                    // point of a confirmation-first flow.
                    request = nil
                }
                .environmentObject(kitchenStore)
            }
            .sheet(item: $confirming) { active in
                CookConsumptionConfirmationView(
                    title: active.recipe.title,
                    planIDs: active.plan.map { [$0.id] } ?? [],
                    recipeID: active.recipe.id,
                    recipeName: active.recipe.title,
                    // A planned dish deducts against its plan; a recipe cooked
                    // outside a plan supplies the recipe instead.
                    recipe: active.plan == nil ? active.recipe : nil,
                    servings: session.servings
                ) {
                    if let plan = active.plan { kitchenStore.markPlanCooked(plan) }
                }
            }
    }
}

extension View {
    /// Presents cooking mode for `request`, then the consumption confirmation,
    /// then marks the plan cooked — the one definition of that chain.
    ///
    /// The session is supplied by the host rather than owned here:
    /// `RecipeDetailView`'s serving stepper and ingredient checklist are bound
    /// to the same session the cook runs on, and taking it away would split that
    /// screen's state in two.
    func cookingFlow(
        request: Binding<CookingFlowRequest?>,
        session: RecipeCookingSession
    ) -> some View {
        modifier(CookingFlowModifier(request: request, session: session))
    }
}


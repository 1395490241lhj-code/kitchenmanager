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
    /// Set when the recipe was opened from a Special Plan dish. The cook is
    /// then that dish's cook (D-047): its receipt is keyed to the dish, so
    /// ticking the dish afterwards finds it instead of deducting again.
    var specialPlanDish: SpecialPlanDishCookingContext? = nil

    var id: String { "\(plan?.id.uuidString ?? specialPlanDish?.dishID.uuidString ?? "-")|\(recipe.id)" }

    /// The confirmation target for a Special Plan dish, or nil when the event
    /// does not use home inventory — the same rule as ticking the dish.
    var specialPlanConsumptionTarget: CookConsumptionTarget? {
        guard let dish = specialPlanDish, dish.usesHomeInventory else { return nil }
        return .specialPlanDish(
            planID: dish.planID,
            dishID: dish.dishID,
            planTitleSnapshot: dish.planTitle,
            recipe: recipe
        )
    }

    /// The yield this cook starts from: the plan's stated target when it has
    /// one, otherwise the recipe's own base. Never 1 by default — a recipe with
    /// a stated yield should be cooked as written rather than divided down.
    var initialServings: Int {
        plan?.plannedServings ?? recipe.baseServings ?? 1
    }

    /// Today's uncooked meal of this exact recipe, for a cook started from a
    /// page that was not opened for any plan. Cooking it as a direct recipe and
    /// then ticking the meal deducted the same dish twice. This only finds the
    /// candidate; the member is asked whether it is that meal. Matched by
    /// recipe id, never by name.
    static func todayPlanCandidate(
        recipeID: String,
        plans: [MealPlanItem],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> MealPlanItem? {
        plans
            .filter { !$0.isCooked && $0.recipeID == recipeID && calendar.isDate($0.date, inSameDayAs: now) }
            .min { $0.date < $1.date }
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
                    if let dish = active.specialPlanDish, !dish.usesHomeInventory {
                        // Cooked away from the home kitchen: complete the dish
                        // and deduct nothing, as ticking it on the plan does.
                        _ = kitchenStore.completeSpecialPlanDish(planID: dish.planID, dishID: dish.dishID)
                    } else {
                        confirming = active
                    }
                } onExit: {
                    // Leaving cooking mode writes nothing. That is the whole
                    // point of a confirmation-first flow.
                    request = nil
                }
                .environmentObject(kitchenStore)
            }
            .sheet(item: $confirming) { active in
                if let target = active.specialPlanConsumptionTarget, let dish = active.specialPlanDish {
                    CookConsumptionConfirmationView(
                        target: target,
                        title: active.recipe.title,
                        recipeID: active.recipe.id,
                        recipeName: active.recipe.title
                    ) { setOutcome in
                        setOutcome(kitchenStore.completeSpecialPlanDish(planID: dish.planID, dishID: dish.dishID))
                    }
                } else {
                    plannedOrDirectConfirmation(active)
                }
            }
    }

    private func plannedOrDirectConfirmation(_ active: CookingFlowRequest) -> some View {
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

/// Which Special Plan dish a recipe page was opened for.
struct SpecialPlanDishCookingContext: Hashable {
    let planID: UUID
    let dishID: UUID
    let planTitle: String
    let usesHomeInventory: Bool

    init(plan: SpecialPlan, dish: SpecialPlanDish) {
        planID = plan.id
        dishID = dish.id
        planTitle = plan.title
        usesHomeInventory = plan.usesHomeInventory
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


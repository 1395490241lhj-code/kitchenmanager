import SwiftUI

#if DEBUG
/// Fails one ordinary-plan write, so a UI test can drive a sheet's failure and
/// retry path through the production store, view and persistence protocol
/// rather than a stubbed screen.
///
/// Which write fails is selectable because the two flows need different ones:
/// creation fails on the first write there is, while editing needs a meal to
/// exist first, so its failure is the second.
enum PlanPersistenceFailureFixture {
    static var failingWriteIndex: Int? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("UITEST_PLAN_FIRST_WRITE_FAILS") { return 1 }
        if arguments.contains("UITEST_PLAN_SECOND_WRITE_FAILS") { return 2 }
        if arguments.contains("UITEST_PLAN_THIRD_WRITE_FAILS") { return 3 }
        return nil
    }

    struct InjectedFailure: Error {}

    @MainActor
    final class FailOneWrite: TodayPlanPersistenceProtocol {
        private let wrapped: TodayPlanPersistenceProtocol
        private let failingIndex: Int
        private var writeCount = 0

        init(wrapping wrapped: TodayPlanPersistenceProtocol, failingIndex: Int) {
            self.wrapped = wrapped
            self.failingIndex = failingIndex
        }

        func loadPlans() throws -> [MealPlanItem] { try wrapped.loadPlans() }

        func replacePlans(with items: [MealPlanItem]) throws {
            writeCount += 1
            guard writeCount != failingIndex else { throw InjectedFailure() }
            try wrapped.replacePlans(with: items)
        }

        func upsert(_ item: MealPlanItem) throws { try wrapped.upsert(item) }
        func delete(id: UUID) throws { try wrapped.delete(id: id) }
        func deleteAll() throws { try wrapped.deleteAll() }
    }
}

/// Deterministic regression data in fresh in-memory stores; uses normal production views.
enum PlannerRegressionFixture {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("UITEST_SEED_PLANNER_REGRESSION") }
    static var state: String { ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("PLANNER_DATA_") }) ?? "PLANNER_DATA_WEEK" }
    static let calendar = Calendar(identifier: .gregorian)
    static let monday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 12))!
    static let now = calendar.date(byAdding: .day, value: 2, to: monday)!
    static let planID = UUID(uuidString: "61000000-0000-0000-0000-000000000001")!
    static let recipes = RecipeRegressionFixture.recipes + [
        Recipe(id: "planner-greens", title: "蒜蓉上海青", cookingTime: 10, difficulty: "简单", tags: ["家常菜"], ingredients: ["上海青 300 克"], seasonings: ["蒜 3 瓣"], steps: ["热锅炒香蒜末，加入上海青炒熟。"], baseServings: 2)
    ]
    static var plan: SpecialPlan {
        SpecialPlan(id: planID, title: "周三家常晚餐", scheduledAt: calendar.date(bySettingHour: 18, minute: 30, second: 0, of: now)!,
                    peopleCount: 4, constraintNotes: ["一位不吃辣"],
                    requestText: "周三四个人在家吃晚饭，做四道家常菜，一位不吃辣。",
                    usesHomeInventory: true,
                    dishes: [recipes[1], recipes[2], recipes[3], recipes[6]].enumerated().map { index, recipe in
                        SpecialPlanDish(id: UUID(uuidString: String(format: "62000000-0000-0000-0000-%012d", index + 1))!,
                                        recipeID: recipe.id, recipeName: recipe.title, isCooked: index == 2)
                    })
    }
    static var draft: [SpecialPlanMenuDraftDish] {
        [recipes[1], recipes[2], recipes[3], recipes[6]].map {
            SpecialPlanMenuDraftDish(title: $0.title, ingredients: $0.ingredients, seasonings: $0.seasonings,
                                     steps: $0.steps, tags: $0.tags, cookingTime: $0.cookingTime,
                                     difficulty: $0.difficulty, reason: "适合这次家常晚餐", existingRecipeID: $0.id, baseServings: $0.baseServings)
        }
    }
    @MainActor static func seed(kitchen: KitchenStore, library: RecipeStore) {
        for recipe in recipes { library.add(recipe) }
        kitchen.specialPlans = state == "PLANNER_DATA_SPECIAL" || state == "PLANNER_DATA_DETAIL" || state == "PLANNER_DATA_DRAFT" ? [plan] : []
        kitchen.plans = []
        guard state != "PLANNER_DATA_EMPTY", state != "PLANNER_DATA_SPECIAL", state != "PLANNER_DATA_DETAIL", state != "PLANNER_DATA_DRAFT" else { return }
        let days = state == "PLANNER_DATA_MIXED" ? [0, 2, 5] : Array(0..<7)
        for day in days {
            let count = state == "PLANNER_DATA_MULTI" && day == 0 ? 4 : 1
            for index in 0..<count {
                let recipe = recipes[(day + index) % recipes.count]
                kitchen.plans.append(MealPlanItem(id: UUID(uuidString: String(format: "63000000-0000-0000-0000-%012d", day * 10 + index + 1))!,
                    recipeID: recipe.id, recipeName: recipe.title,
                    date: calendar.date(byAdding: .day, value: day, to: monday)!,
                    plannedServings: index == 1 ? nil : (index == 2 ? 4 : 2), isCooked: day == 0 && state == "PLANNER_DATA_WEEK"))
            }
        }
    }
}

struct PlannerRegressionHost: View {
    @EnvironmentObject private var kitchen: KitchenStore
    @EnvironmentObject private var library: RecipeStore
    @State private var ready = false
    var body: some View {
        Color.clear
            .task {
                PlannerRegressionFixture.seed(kitchen: kitchen, library: library)
                ready = true
            }
            .sheet(isPresented: $ready) {
                if PlannerRegressionFixture.state == "PLANNER_DATA_RESULT" {
                    PlannerRegressionWeeklyResult()
                } else if PlannerRegressionFixture.state == "PLANNER_DATA_WEEKLY" {
                    NavigationStack { WeeklyMenuPlannerView() }
                } else if PlannerRegressionFixture.state == "PLANNER_DATA_DETAIL" || PlannerRegressionFixture.state == "PLANNER_DATA_DRAFT" {
                    NavigationStack {
                        SpecialPlanDetailView(planID: PlannerRegressionFixture.planID,
                            initialDraft: PlannerRegressionFixture.state == "PLANNER_DATA_DRAFT" ? PlannerRegressionFixture.draft : []) { }
                            .navigationDestination(for: PlannerRoute.self) { route in
                                if case .recipe(let id) = route, let recipe = library.recipe(id: id) { RecipeDetailView(recipe: recipe) }
                            }
                    }
                } else {
                    PlannerView(now: PlannerRegressionFixture.now, calendar: PlannerRegressionFixture.calendar)
                }
            }
    }
}

private struct PlannerRegressionWeeklyResult: View {
    @StateObject private var store = WeeklyMenuPlannerStore()
    var body: some View {
        NavigationStack { WeeklyMenuResultView(store: store) }
            .task {
                let dishes = PlannerRegressionFixture.recipes.prefix(4).map {
                    WeeklyMealPlanRecipe(id: $0.id, title: $0.title, ingredients: $0.ingredients,
                        seasonings: $0.seasonings, steps: $0.steps, tags: $0.tags,
                        cookingTime: $0.cookingTime, difficulty: $0.difficulty, reason: nil,
                        source: .local, existingRecipeID: $0.id, isSavedToLibrary: true)
                }
                store.generatedPlan = WeeklyMealPlan(startDate: PlannerRegressionFixture.monday,
                    days: [WeeklyMealPlanDay(dayIndex: 0, meals: [WeeklyMealPlanMeal(mealIndex: 2, title: "晚餐", recipes: dishes)]),
                           WeeklyMealPlanDay(dayIndex: 1, meals: [])],
                    shoppingItems: [], servings: 4, summary: nil, createdAt: PlannerRegressionFixture.monday)
            }
    }
}
#endif

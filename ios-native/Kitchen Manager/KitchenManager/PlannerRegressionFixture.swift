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
        // The weekly-host states keep days 0 and 2 free so the seeded draft's
        // own meals can materialize without a collision dialog.
        let days: [Int]
        switch state {
        case "PLANNER_DATA_MIXED":
            days = [0, 2, 5]
        case "PLANNER_DATA_HOST_WEEKLY", "PLANNER_DATA_HOST_WEEKLY_CROSS":
            days = [3, 4]
        default:
            days = Array(0..<7)
        }
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
        if state == "PLANNER_DATA_HOST_WEEKLY" {
            kitchen.weeklyPlan = WeeklyMenuRegressionFixture.plan()
        } else if state == "PLANNER_DATA_HOST_WEEKLY_CROSS" {
            kitchen.weeklyPlan = WeeklyMenuRegressionFixture.crossWeekPlan
        }
        if state == "PLANNER_DATA_CONSUMED",
           let pending = kitchen.plans.first(where: { $0.id == consumedPlanID }) {
            // Pending Planner meal whose consumption is already recorded but
            // whose cooked state is still false: exactly the already-satisfied
            // confirmation state the zero-deduction UI must show. The empty
            // record deducts nothing and marks nothing cooked.
            kitchen.applyConsumption([], planIDs: [pending.id], recipeID: nil, recipeName: pending.recipeName)
        }
    }
    /// The fixture's own "today" (Wednesday) meal — pinned by id because the
    /// device calendar's today is not the fixture's.
    static let consumedPlanID = UUID(uuidString: "63000000-0000-0000-0000-000000000021")!
}

/// Deterministic weekly-menu result states, so the materialization flow can be
/// exercised without an AI call.
///
/// `generatedPlan` is the seam: the result screen reads it, and every state
/// below is just a different draft plus whatever the canonical plan already
/// holds. Nothing here changes how materialization itself behaves.
@MainActor
enum WeeklyMenuRegressionFixture {
    /// Two dishes, on the fixture's first and third day.
    static var dishes: [WeeklyMealPlanRecipe] {
        PlannerRegressionFixture.recipes.prefix(2).map { recipe in
            WeeklyMealPlanRecipe(
                id: recipe.id, title: recipe.title, ingredients: recipe.ingredients,
                seasonings: recipe.seasonings, steps: recipe.steps, tags: recipe.tags,
                cookingTime: recipe.cookingTime, difficulty: recipe.difficulty,
                reason: nil, source: .local, existingRecipeID: recipe.id, isSavedToLibrary: true
            )
        }
    }

    static var startDate: Date { PlannerRegressionFixture.monday }

    static func date(dayIndex: Int) -> Date {
        let calendar = PlannerRegressionFixture.calendar
        let start = calendar.startOfDay(for: startDate)
        let raw = calendar.date(byAdding: .day, value: dayIndex, to: start) ?? start
        return MealPlanItem.normalizedPlannerDate(for: raw, calendar: calendar)
    }

    static func plan(receipt: WeeklyMaterializationReceipt? = nil) -> WeeklyMealPlan {
        let all = dishes
        return WeeklyMealPlan(
            startDate: startDate,
            days: [
                WeeklyMealPlanDay(dayIndex: 0, meals: [
                    WeeklyMealPlanMeal(mealIndex: 0, title: "晚餐", recipes: [all[0]])
                ]),
                WeeklyMealPlanDay(dayIndex: 2, meals: [
                    WeeklyMealPlanMeal(mealIndex: 0, title: "晚餐", recipes: [all[1]])
                ])
            ],
            shoppingItems: [],
            servings: 2,
            summary: nil,
            createdAt: startDate,
            materialization: receipt
        )
    }

    /// A draft whose covered days cross two calendar weeks: the range starts
    /// Saturday and reaches into the following Monday. Revealing it must open
    /// the week that contains the start, not the week of its last day.
    static var crossWeekPlan: WeeklyMealPlan {
        let calendar = PlannerRegressionFixture.calendar
        let start = calendar.date(byAdding: .day, value: 5, to: calendar.startOfDay(for: startDate))!
        let all = dishes
        return WeeklyMealPlan(
            startDate: MealPlanItem.normalizedPlannerDate(for: start, calendar: calendar),
            days: [
                WeeklyMealPlanDay(dayIndex: 0, meals: [
                    WeeklyMealPlanMeal(mealIndex: 0, title: "晚餐", recipes: [all[0]])
                ]),
                WeeklyMealPlanDay(dayIndex: 2, meals: [
                    WeeklyMealPlanMeal(mealIndex: 0, title: "晚餐", recipes: [all[1]])
                ])
            ],
            shoppingItems: [],
            servings: 2,
            summary: nil,
            createdAt: start
        )
    }

    static let planIDs = [
        UUID(uuidString: "64000000-0000-0000-0000-000000000001")!,
        UUID(uuidString: "64000000-0000-0000-0000-000000000002")!
    ]

    static func receipt(state: WeeklyMaterializationState) -> WeeklyMaterializationReceipt {
        WeeklyMaterializationReceipt(
            state: state,
            planIDs: planIDs,
            recipeIDs: dishes.map(\.id),
            planDates: [date(dayIndex: 0), date(dayIndex: 2)],
            startedAt: startDate,
            completedAt: state == .materialized ? startDate : nil
        )
    }

    static func meal(index: Int) -> MealPlanItem {
        MealPlanItem(
            id: planIDs[index],
            recipeID: dishes[index].id,
            recipeName: dishes[index].title,
            date: date(dayIndex: index == 0 ? 0 : 2)
        )
    }

    /// Seeds the canonical plan and returns the draft the result screen opens on.
    static func seed(state: String, kitchen: KitchenStore) -> WeeklyMealPlan {
        switch state {
        case "PLANNER_DATA_WEEKLY_COLLISION":
            // Something already stands on the menu's first day.
            kitchen.plans = [
                MealPlanItem(
                    recipeID: "planner-greens", recipeName: "蒜蓉上海青", date: date(dayIndex: 0)
                )
            ]
            return plan()

        case "PLANNER_DATA_WEEKLY_ADDED":
            kitchen.plans = [meal(index: 0), meal(index: 1)]
            return plan(receipt: receipt(state: .materialized))

        case "PLANNER_DATA_WEEKLY_REPAIR":
            // The meals landed; only the receipt never got marked done.
            kitchen.plans = [meal(index: 0), meal(index: 1)]
            return plan(receipt: receipt(state: .pending))

        case "PLANNER_DATA_WEEKLY_PARTIAL":
            kitchen.plans = [meal(index: 0)]
            return plan(receipt: receipt(state: .pending))

        case "PLANNER_DATA_WEEKLY_STALE":
            // A pending receipt for two meals against a one-dish draft.
            kitchen.plans = []
            var edited = plan(receipt: receipt(state: .pending))
            edited.days[1].meals[0].recipes = []
            return edited

        case "PLANNER_DATA_WEEKLY_MISSING_RECIPE":
            kitchen.plans = []
            var broken = plan()
            broken.days[0].meals[0].recipes[0].existingRecipeID = "gone-from-library"
            broken.days[0].meals[0].recipes[0].id = "gone-from-library"
            return broken

        default:
            kitchen.plans = []
            return plan()
        }
    }
}

private struct WeeklyMenuRegressionResult: View {
    let state: String
    @EnvironmentObject private var kitchen: KitchenStore
    @StateObject private var store = WeeklyMenuPlannerStore()

    var body: some View {
        NavigationStack { WeeklyMenuResultView(store: store) }
            .task {
                store.generatedPlan = WeeklyMenuRegressionFixture.seed(state: state, kitchen: kitchen)
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
                if PlannerRegressionFixture.state.hasPrefix("PLANNER_DATA_WEEKLY_") {
                    WeeklyMenuRegressionResult(state: PlannerRegressionFixture.state)
                } else if PlannerRegressionFixture.state == "PLANNER_DATA_RESULT" {
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

/// A stand-in for the weekly generator's network call: waits long enough for a
/// UI test to navigate around it, honours cancellation exactly like the real
/// request, then answers with one AI dish per requested day. Selected by the
/// `UITEST_WEEKLY_STUB_GENERATION` launch argument only.
enum WeeklyMenuGenerationFixture {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("UITEST_WEEKLY_STUB_GENERATION") }

    static func generate(_ request: AIWeeklyMenuRequest) async throws -> AIWeeklyMenuResponse {
        try await Task.sleep(for: .seconds(15))
        let days: [[String: Any]] = (0..<request.numberOfDays).map { day in
            ["dayIndex": day,
             "meals": [["mealIndex": 0, "title": "晚餐",
                        "recipes": [["name": "测试菜 \(day + 1)", "ingredients": ["番茄 2 个"], "steps": ["炒熟"], "source": "ai"]]]]]
        }
        return try JSONDecoder().decode(
            AIWeeklyMenuResponse.self,
            from: JSONSerialization.data(withJSONObject: ["days": days])
        )
    }
}
#endif

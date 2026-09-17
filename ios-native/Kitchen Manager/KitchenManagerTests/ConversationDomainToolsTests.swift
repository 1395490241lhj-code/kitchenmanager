import XCTest
@testable import KitchenManager

/// The AI-safe canonical mutation seams.
///
/// Every test here is about one promise: a conversation action either persists
/// and then publishes, or it publishes nothing at all. A model-driven mutation
/// has no user sitting in a form to notice that the disk refused a write, so
/// "the array changed but the database did not" is not a state this layer is
/// allowed to reach.
@MainActor
final class ConversationDomainToolsTests: XCTestCase {
    // MARK: - Doubles

    /// Succeeds until `shouldFail` is set, so a test can build real state and
    /// then fail exactly the one write it is about.
    private final class ToggleableTodayPlanPersistence: TodayPlanPersistenceProtocol {
        struct ExpectedFailure: Error {}
        var plans: [MealPlanItem] = []
        var shouldFail = false
        var replaceCallCount = 0

        func loadPlans() throws -> [MealPlanItem] { plans }
        func replacePlans(with items: [MealPlanItem]) throws {
            replaceCallCount += 1
            if shouldFail { throw ExpectedFailure() }
            plans = items
        }
        func upsert(_ item: MealPlanItem) throws {}
        func delete(id: UUID) throws {}
        func deleteAll() throws { plans = [] }
    }

    private final class ToggleableSpecialPlanPersistence: SpecialPlanPersistenceProtocol {
        struct ExpectedFailure: Error {}
        var plans: [SpecialPlan] = []
        var shouldFail = false
        var replaceCallCount = 0

        func loadPlans() throws -> [SpecialPlan] { plans }
        func replacePlans(with plans: [SpecialPlan]) throws {
            replaceCallCount += 1
            if shouldFail { throw ExpectedFailure() }
            self.plans = plans
        }
        func upsert(_ plan: SpecialPlan) throws {}
        func delete(id: UUID) throws {}
        func deleteAll() throws { plans = [] }
    }

    private final class ToggleableShoppingListPersistence: ShoppingListPersistenceProtocol {
        struct ExpectedFailure: Error {}
        var items: [KitchenShoppingItem] = []
        var shouldFail = false
        var replaceCallCount = 0

        func loadShoppingItems() throws -> [KitchenShoppingItem] { items }
        func replaceShoppingItems(with items: [KitchenShoppingItem]) throws {
            replaceCallCount += 1
            if shouldFail { throw ExpectedFailure() }
            self.items = items
        }
        func upsert(_ item: KitchenShoppingItem) throws {}
        func delete(id: UUID) throws {}
        func deleteAll() throws { items = [] }
    }

    private final class ToggleableUserRecipePersistence: UserRecipePersistenceProtocol {
        struct ExpectedFailure: Error {}
        var recipes: [Recipe] = []
        var shouldFail = false
        /// Every library write — save and delete alike — goes through
        /// `replaceRecipes`, so this counts canonical recipe writes.
        var replaceCallCount = 0

        func loadRecipes() throws -> [Recipe] { recipes }
        func storedRecordCount() throws -> Int { recipes.count }
        func replaceRecipes(with recipes: [Recipe]) throws {
            replaceCallCount += 1
            if shouldFail { throw ExpectedFailure() }
            self.recipes = recipes
        }
        func deleteAll() throws { recipes = [] }
    }

    // MARK: - Fixtures

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
    }

    private func makeStore(
        todayPlan: TodayPlanPersistenceProtocol? = nil,
        specialPlan: SpecialPlanPersistenceProtocol? = nil,
        shoppingList: ShoppingListPersistenceProtocol? = nil
    ) -> KitchenStore {
        KitchenStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            shoppingListPersistence: shoppingList,
            todayPlanPersistence: todayPlan,
            specialPlanPersistence: specialPlan
        )
    }

    private func makeRecipeStore() -> RecipeStore {
        RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    private func makeRecipeStore(_ persistence: UserRecipePersistenceProtocol) -> RecipeStore {
        RecipeStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            userRecipePersistence: persistence,
            recipePreferencePersistence: KitchenPersistenceFactory.isolatedInMemory().recipePreferences
        )
    }

    private func recipe(
        id: String = "recipe-1",
        title: String = "番茄炒蛋",
        ingredients: [String] = ["番茄 2 个", "鸡蛋 3 个"],
        steps: [String] = ["炒熟"]
    ) -> Recipe {
        Recipe(
            id: id,
            title: title,
            cookingTime: 15,
            difficulty: "简单",
            tags: ["家常菜"],
            ingredients: ingredients,
            seasonings: ["盐 少许"],
            steps: steps
        )
    }

    private func seedPlans(_ store: KitchenStore) -> [MealPlanItem] {
        let items = [
            MealPlanItem(recipeID: "a", recipeName: "宫保鸡丁", date: day(2026, 3, 18), plannedServings: 2, isCooked: true),
            MealPlanItem(recipeID: "b", recipeName: "红烧肉", date: day(2026, 3, 19), plannedServings: 2),
            MealPlanItem(recipeID: "c", recipeName: "炒青菜", date: day(2026, 3, 20), plannedServings: 4, isCooked: true)
        ]
        XCTAssertTrue(store.appendPlans(items, calendar: calendar).didPersist)
        return store.plans
    }

    private func specialPlan(dishes: [SpecialPlanDish]) -> SpecialPlan {
        SpecialPlan(
            title: "朋友聚餐",
            scheduledAt: day(2026, 3, 21),
            peopleCount: 7,
            constraintNotes: ["1 人不吃辣"],
            notes: "客厅那桌",
            requestText: "周六 7 个人",
            usesHomeInventory: true,
            dishes: dishes
        )
    }

    // MARK: - Planner replacement

    /// One durable write, and only the named rows change. Plan identity and the
    /// day the meal sits on are what the rest of the app joins against — a
    /// replacement that reissued them would silently orphan consumption records.
    func testPlannerReplacementRewritesOnlyNamedRowsInOneWrite() {
        let persistence = ToggleableTodayPlanPersistence()
        let store = makeStore(todayPlan: persistence)
        let seeded = seedPlans(store)
        let writesBefore = persistence.replaceCallCount

        let outcome = store.replacePlanRecipes([
            PlanRecipeReplacement(planID: seeded[0].id, recipeID: "x", recipeName: "清蒸鲈鱼", plannedServings: 4),
            PlanRecipeReplacement(planID: seeded[2].id, recipeID: "y", recipeName: "蒜蓉西兰花", plannedServings: nil)
        ])

        guard case .saved(let after) = outcome else {
            return XCTFail("expected a durable replacement, got \(outcome)")
        }
        XCTAssertEqual(persistence.replaceCallCount - writesBefore, 1, "a replacement is one commit, not a remove plus an add")
        XCTAssertEqual(after.map(\.id), [seeded[0].id, seeded[2].id])
        XCTAssertEqual(store.plans.map(\.id), seeded.map(\.id), "plan identity and order survive")
        XCTAssertEqual(store.plans.map(\.recipeID), ["x", "b", "y"])
        XCTAssertEqual(store.plans.map(\.recipeName), ["清蒸鲈鱼", "红烧肉", "蒜蓉西兰花"])
        XCTAssertEqual(store.plans.map(\.date), seeded.map(\.date), "a replacement never moves a meal to another day")
        XCTAssertEqual(store.plans.map(\.plannedServings), [4, 2, nil])
        XCTAssertEqual(
            store.plans.map(\.isCooked), [false, false, false],
            "a replaced row is a different dish, so it cannot still be cooked"
        )
        XCTAssertEqual(try persistence.loadPlans(), store.plans, "memory and disk agree")
    }

    /// The untouched row keeps its own cooked state: resetting is scoped to the
    /// rows this call actually rewrote.
    func testPlannerReplacementLeavesAnUntouchedCookedRowAlone() {
        let store = makeStore()
        let seeded = seedPlans(store)

        _ = store.replacePlanRecipes([
            PlanRecipeReplacement(planID: seeded[1].id, recipeID: "x", recipeName: "清蒸鲈鱼", plannedServings: 2)
        ])

        XCTAssertTrue(store.plans[2].isCooked, "a row nobody replaced keeps its execution state")
    }

    func testPlannerReplacementValidatesServingsInsteadOfClamping() {
        let store = makeStore()
        let seeded = seedPlans(store)

        _ = store.replacePlanRecipes([
            PlanRecipeReplacement(planID: seeded[0].id, recipeID: "x", recipeName: "清蒸鲈鱼", plannedServings: 13)
        ])

        // The replacement itself is applied; only the out-of-range serving count
        // is dropped, which is what `Recipe.validatedBaseServings` does
        // everywhere else. A source claiming 13 servings is confused, and
        // silently storing 12 would hide that rather than surface it.
        XCTAssertEqual(store.plans[0].recipeName, "清蒸鲈鱼")
        XCTAssertNil(
            store.plans[0].plannedServings,
            "an out-of-range serving count is dropped as unknown, never clamped into range"
        )
    }

    func testPlannerReplacementPublishesNothingWhenPersistenceFails() {
        let persistence = ToggleableTodayPlanPersistence()
        let store = makeStore(todayPlan: persistence)
        let seeded = seedPlans(store)
        let durable = try? persistence.loadPlans()
        persistence.shouldFail = true

        let outcome = store.replacePlanRecipes([
            PlanRecipeReplacement(planID: seeded[0].id, recipeID: "x", recipeName: "清蒸鲈鱼", plannedServings: 4),
            PlanRecipeReplacement(planID: seeded[1].id, recipeID: "y", recipeName: "蒜蓉西兰花", plannedServings: 2)
        ])

        guard case .persistenceFailed = outcome else {
            return XCTFail("expected a refused write, got \(outcome)")
        }
        XCTAssertEqual(store.plans, seeded, "neither replacement may be visible when the pair failed")
        XCTAssertEqual(try persistence.loadPlans(), durable)
        XCTAssertNotNil(store.planNotice)
    }

    func testPlannerReplacementRejectsDuplicateTargetsBeforeAnyWrite() {
        let persistence = ToggleableTodayPlanPersistence()
        let store = makeStore(todayPlan: persistence)
        let seeded = seedPlans(store)
        let writesBefore = persistence.replaceCallCount

        let outcome = store.replacePlanRecipes([
            PlanRecipeReplacement(planID: seeded[0].id, recipeID: "x", recipeName: "清蒸鲈鱼", plannedServings: 2),
            PlanRecipeReplacement(planID: seeded[0].id, recipeID: "y", recipeName: "蒜蓉西兰花", plannedServings: 2)
        ])

        XCTAssertEqual(outcome, .rejected(.duplicateTargets([seeded[0].id])))
        XCTAssertEqual(persistence.replaceCallCount, writesBefore, "a malformed request is refused before it reaches the disk")
        XCTAssertEqual(store.plans, seeded)
    }

    func testPlannerReplacementRejectsAMissingTargetBeforeAnyWrite() {
        let persistence = ToggleableTodayPlanPersistence()
        let store = makeStore(todayPlan: persistence)
        let seeded = seedPlans(store)
        let writesBefore = persistence.replaceCallCount
        let ghost = UUID()

        let outcome = store.replacePlanRecipes([
            PlanRecipeReplacement(planID: seeded[0].id, recipeID: "x", recipeName: "清蒸鲈鱼", plannedServings: 2),
            PlanRecipeReplacement(planID: ghost, recipeID: "y", recipeName: "蒜蓉西兰花", plannedServings: 2)
        ])

        XCTAssertEqual(outcome, .rejected(.missingTargets([ghost])))
        XCTAssertEqual(persistence.replaceCallCount, writesBefore)
        XCTAssertEqual(store.plans, seeded, "the resolvable half of a broken batch must not land on its own")
    }

    func testPlannerReplacementRejectsAnEmptyRequest() {
        let store = makeStore()
        XCTAssertEqual(store.replacePlanRecipes([]), .rejected(.empty))
    }

    /// The row is cooked, a consumption record already deducted it, and the
    /// dish is now being replaced. Resetting `isCooked` under that record would
    /// leave the meal looking cookable while `CookConsumptionStore` still reads
    /// it as settled — the user would confirm the new dish, be told it worked,
    /// and have nothing deducted from inventory.
    func testPlannerReplacementRefusesARowAConsumptionRecordAlreadyCovers() throws {
        let persistence = ToggleableTodayPlanPersistence()
        let store = makeStore(todayPlan: persistence)
        store.addInventory(name: "番茄", quantity: 5, unit: "个", expiryDate: nil)
        let seeded = seedPlans(store)
        let consumed = seeded[0]
        let drafts = InventoryConsumptionPlanner().plan(
            for: [.init(recipe: recipe(id: "a", title: "宫保鸡丁"), servings: 2)],
            inventory: store.inventory
        )
        store.applyConsumption(drafts, planIDs: [consumed.id], recipeID: "a", recipeName: "宫保鸡丁")
        XCTAssertTrue(store.hasConsumedPlan(consumed.id))
        let writesBefore = persistence.replaceCallCount

        let outcome = store.replacePlanRecipes([
            PlanRecipeReplacement(planID: seeded[1].id, recipeID: "x", recipeName: "清蒸鲈鱼", plannedServings: 2),
            PlanRecipeReplacement(planID: consumed.id, recipeID: "y", recipeName: "蒜蓉西兰花", plannedServings: 2)
        ])

        XCTAssertEqual(outcome, .rejected(.consumedTargets([consumed.id])))
        XCTAssertEqual(
            persistence.replaceCallCount, writesBefore,
            "a replacement this floor cannot make consistent is refused before the disk"
        )
        XCTAssertEqual(store.plans, seeded, "the resolvable half must not land on its own")
        XCTAssertTrue(store.plans[0].isCooked, "the consumed row keeps the state its record describes")
    }

    // MARK: - Planner restore (deterministic Undo)

    func testRestorePlanItemsPutsTheExactRowsBack() {
        let store = makeStore()
        let seeded = seedPlans(store)
        _ = store.replacePlanRecipes([
            PlanRecipeReplacement(planID: seeded[0].id, recipeID: "x", recipeName: "清蒸鲈鱼", plannedServings: 4)
        ])

        let outcome = store.restorePlanItems([seeded[0]])

        XCTAssertTrue(outcome.didPersist)
        XCTAssertEqual(store.plans, seeded, "Undo restores the row verbatim, cooked state included")
    }

    func testRestorePlanItemsPublishesNothingWhenPersistenceFails() {
        let persistence = ToggleableTodayPlanPersistence()
        let store = makeStore(todayPlan: persistence)
        let seeded = seedPlans(store)
        _ = store.replacePlanRecipes([
            PlanRecipeReplacement(planID: seeded[0].id, recipeID: "x", recipeName: "清蒸鲈鱼", plannedServings: 4)
        ])
        let replaced = store.plans
        persistence.shouldFail = true

        XCTAssertTrue(store.restorePlanItems([seeded[0]]).didFailToPersist)
        XCTAssertEqual(store.plans, replaced, "a failed Undo leaves the world exactly as it was")
    }

    func testRestorePlanItemsReportsAMissingRowInsteadOfReinventingIt() {
        let store = makeStore()
        _ = seedPlans(store)
        let ghost = MealPlanItem(recipeID: "z", recipeName: "消失的菜", date: day(2026, 3, 22))

        XCTAssertTrue(store.restorePlanItems([ghost]).isNotFound, "restore puts a row back; it does not create one")
    }

    // MARK: - Special Plan dish replacement

    func testSpecialPlanDishReplacementChangesOnlyNamedDishes() {
        let persistence = ToggleableSpecialPlanPersistence()
        let store = makeStore(specialPlan: persistence)
        let dishes = [
            SpecialPlanDish(recipeID: "d1", recipeName: "麻婆豆腐"),
            SpecialPlanDish(recipeID: "d2", recipeName: "番茄炒蛋", isCooked: true)
        ]
        let plan = specialPlan(dishes: dishes)
        store.addSpecialPlan(plan)
        let writesBefore = persistence.replaceCallCount

        let outcome = store.replaceSpecialPlanDishes(
            planID: plan.id,
            replacements: [
                SpecialPlanDishReplacement(dishID: dishes[0].id, recipeID: "d9", recipeName: "清蒸鲈鱼")
            ]
        )

        guard case .saved(let after) = outcome else {
            return XCTFail("expected a durable replacement, got \(outcome)")
        }
        XCTAssertEqual(persistence.replaceCallCount - writesBefore, 1, "one durable write")
        XCTAssertEqual(after.title, plan.title)
        XCTAssertEqual(after.scheduledAt, plan.scheduledAt)
        XCTAssertEqual(after.peopleCount, plan.peopleCount)
        XCTAssertEqual(after.constraintNotes, plan.constraintNotes)
        XCTAssertEqual(after.notes, plan.notes)
        XCTAssertEqual(after.requestText, plan.requestText)
        XCTAssertEqual(after.usesHomeInventory, plan.usesHomeInventory)
        XCTAssertEqual(after.dishes.map(\.id), dishes.map(\.id), "a dish keeps its identity and its place")
        XCTAssertEqual(after.dishes.map(\.recipeID), ["d9", "d2"])
        XCTAssertEqual(after.dishes.map(\.recipeName), ["清蒸鲈鱼", "番茄炒蛋"])
        XCTAssertEqual(after.dishes.map(\.isCooked), [false, true], "only the replaced dish loses its cooked state")
        XCTAssertEqual(store.specialPlans, [after])
        XCTAssertEqual(try persistence.loadPlans(), [after])
    }

    func testSpecialPlanDishReplacementPublishesNothingWhenPersistenceFails() {
        let persistence = ToggleableSpecialPlanPersistence()
        let store = makeStore(specialPlan: persistence)
        let dishes = [
            SpecialPlanDish(recipeID: "d1", recipeName: "麻婆豆腐"),
            SpecialPlanDish(recipeID: "d2", recipeName: "番茄炒蛋")
        ]
        let plan = specialPlan(dishes: dishes)
        store.addSpecialPlan(plan)
        persistence.shouldFail = true

        let outcome = store.replaceSpecialPlanDishes(
            planID: plan.id,
            replacements: [
                SpecialPlanDishReplacement(dishID: dishes[0].id, recipeID: "d9", recipeName: "清蒸鲈鱼"),
                SpecialPlanDishReplacement(dishID: dishes[1].id, recipeID: "d8", recipeName: "蒜蓉西兰花")
            ]
        )

        XCTAssertTrue(outcome.didFailToPersist)
        XCTAssertEqual(store.specialPlans, [plan], "neither dish may be visible when the pair failed")
        XCTAssertNotNil(store.specialPlanNotice)
    }

    func testSpecialPlanDishReplacementRejectsAnUnknownDishBeforeAnyWrite() {
        let persistence = ToggleableSpecialPlanPersistence()
        let store = makeStore(specialPlan: persistence)
        let dishes = [SpecialPlanDish(recipeID: "d1", recipeName: "麻婆豆腐")]
        let plan = specialPlan(dishes: dishes)
        store.addSpecialPlan(plan)
        let writesBefore = persistence.replaceCallCount

        let outcome = store.replaceSpecialPlanDishes(
            planID: plan.id,
            replacements: [
                SpecialPlanDishReplacement(dishID: dishes[0].id, recipeID: "d9", recipeName: "清蒸鲈鱼"),
                SpecialPlanDishReplacement(dishID: UUID(), recipeID: "d8", recipeName: "蒜蓉西兰花")
            ]
        )

        XCTAssertTrue(outcome.isNotFound)
        XCTAssertEqual(persistence.replaceCallCount, writesBefore)
        XCTAssertEqual(store.specialPlans, [plan])
    }

    func testSpecialPlanDishReplacementRejectsADuplicateTargetBeforeAnyWrite() {
        let persistence = ToggleableSpecialPlanPersistence()
        let store = makeStore(specialPlan: persistence)
        let dishes = [SpecialPlanDish(recipeID: "d1", recipeName: "麻婆豆腐")]
        let plan = specialPlan(dishes: dishes)
        store.addSpecialPlan(plan)
        let writesBefore = persistence.replaceCallCount

        let outcome = store.replaceSpecialPlanDishes(
            planID: plan.id,
            replacements: [
                SpecialPlanDishReplacement(dishID: dishes[0].id, recipeID: "d9", recipeName: "清蒸鲈鱼"),
                SpecialPlanDishReplacement(dishID: dishes[0].id, recipeID: "d8", recipeName: "蒜蓉西兰花")
            ]
        )

        XCTAssertEqual(
            outcome.rejection, .duplicateTargets([dishes[0].id]),
            "naming one dish twice does not describe one outcome"
        )
        XCTAssertEqual(persistence.replaceCallCount, writesBefore)
        XCTAssertEqual(store.specialPlans, [plan])
    }

    func testSpecialPlanDishReplacementReportsAMissingPlan() {
        let store = makeStore()
        let outcome = store.replaceSpecialPlanDishes(
            planID: UUID(),
            replacements: [SpecialPlanDishReplacement(dishID: UUID(), recipeID: "d9", recipeName: "清蒸鲈鱼")]
        )
        XCTAssertTrue(outcome.isNotFound)
    }

    /// A whole-list assignment, so an empty menu would erase the event's dishes
    /// in one durable write. No caller asks for that by saying "nothing".
    func testSettingAnEmptyMenuIsRefusedBeforeAnyWrite() {
        let persistence = ToggleableSpecialPlanPersistence()
        let store = makeStore(specialPlan: persistence)
        let dishes = [SpecialPlanDish(recipeID: "d1", recipeName: "麻婆豆腐")]
        let plan = specialPlan(dishes: dishes)
        store.addSpecialPlan(plan)
        let writesBefore = persistence.replaceCallCount

        let outcome = store.setSpecialPlanDishes(planID: plan.id, dishes: [])

        XCTAssertEqual(outcome.rejection, .empty)
        XCTAssertEqual(persistence.replaceCallCount, writesBefore)
        XCTAssertEqual(store.specialPlans, [plan], "an event's menu survives a request to write nothing")
    }

    func testSpecialPlanDishReplacementTrimsTheDisplayName() {
        let store = makeStore()
        let dishes = [SpecialPlanDish(recipeID: "d1", recipeName: "麻婆豆腐")]
        let plan = specialPlan(dishes: dishes)
        store.addSpecialPlan(plan)

        let outcome = store.replaceSpecialPlanDishes(
            planID: plan.id,
            replacements: [SpecialPlanDishReplacement(dishID: dishes[0].id, recipeID: "d9", recipeName: "  清蒸鲈鱼  ")]
        )

        XCTAssertEqual(outcome.value?.dishes.first?.recipeName, "清蒸鲈鱼")
    }

    func testRestoreSpecialPlanPutsTheExactSnapshotBack() {
        let persistence = ToggleableSpecialPlanPersistence()
        let store = makeStore(specialPlan: persistence)
        let dishes = [SpecialPlanDish(recipeID: "d1", recipeName: "麻婆豆腐", isCooked: true)]
        let plan = specialPlan(dishes: dishes)
        store.addSpecialPlan(plan)
        _ = store.replaceSpecialPlanDishes(
            planID: plan.id,
            replacements: [SpecialPlanDishReplacement(dishID: dishes[0].id, recipeID: "d9", recipeName: "清蒸鲈鱼")]
        )

        XCTAssertTrue(store.restoreSpecialPlan(plan).didPersist)
        XCTAssertEqual(store.specialPlans, [plan], "Undo restores the event verbatim, cooked dishes included")
        XCTAssertEqual(try persistence.loadPlans(), [plan])
    }

    func testRestoreSpecialPlanPublishesNothingWhenPersistenceFails() {
        let persistence = ToggleableSpecialPlanPersistence()
        let store = makeStore(specialPlan: persistence)
        let dishes = [SpecialPlanDish(recipeID: "d1", recipeName: "麻婆豆腐")]
        let plan = specialPlan(dishes: dishes)
        store.addSpecialPlan(plan)
        _ = store.replaceSpecialPlanDishes(
            planID: plan.id,
            replacements: [SpecialPlanDishReplacement(dishID: dishes[0].id, recipeID: "d9", recipeName: "清蒸鲈鱼")]
        )
        let replaced = store.specialPlans
        persistence.shouldFail = true

        XCTAssertTrue(store.restoreSpecialPlan(plan).didFailToPersist)
        XCTAssertEqual(store.specialPlans, replaced)
    }

    // MARK: - Shopping additions

    func testShoppingAdditionsMergeAndPublishOnlyAfterPersistence() {
        let persistence = ToggleableShoppingListPersistence()
        let store = makeStore(shoppingList: persistence)
        store.addShopping(name: "鸡蛋", quantity: 6, unit: "个", source: "手动添加")
        let before = store.shoppingItems
        let writesBefore = persistence.replaceCallCount

        let outcome = store.addShoppingItemsPersisted([
            KitchenShoppingItem(name: "鸡蛋", quantity: 4, unit: "个", source: "Kitchen AI"),
            KitchenShoppingItem(name: "番茄", quantity: 2, unit: "个", source: "Kitchen AI")
        ])

        guard case .saved(let receipt) = outcome else {
            return XCTFail("expected a durable addition, got \(outcome)")
        }
        XCTAssertEqual(persistence.replaceCallCount - writesBefore, 1, "a batch is one durable write")
        XCTAssertEqual(receipt.before, before)
        XCTAssertEqual(receipt.after, store.shoppingItems)
        XCTAssertEqual(store.shoppingItems.count, 2, "the existing merge behavior is unchanged")
        XCTAssertEqual(store.shoppingItems[0].quantity, 10, "a pending same-unit row absorbs the addition")
        XCTAssertEqual(store.shoppingItems[1].name, "番茄")
        XCTAssertEqual(try persistence.loadShoppingItems(), store.shoppingItems)
    }

    func testShoppingAdditionsPublishNothingWhenPersistenceFails() {
        let persistence = ToggleableShoppingListPersistence()
        let store = makeStore(shoppingList: persistence)
        store.addShopping(name: "鸡蛋", quantity: 6, unit: "个")
        let before = store.shoppingItems
        persistence.shouldFail = true

        let outcome = store.addShoppingItemsPersisted([
            KitchenShoppingItem(name: "番茄", quantity: 2, unit: "个", source: "Kitchen AI")
        ])

        XCTAssertTrue(outcome.didFailToPersist)
        XCTAssertEqual(store.shoppingItems, before, "a refused write leaves nothing on the list")
        XCTAssertNotNil(store.shoppingNotice)
    }

    func testShoppingAdditionsRejectAnEmptyBatch() {
        let persistence = ToggleableShoppingListPersistence()
        let store = makeStore(shoppingList: persistence)
        let writesBefore = persistence.replaceCallCount

        XCTAssertEqual(store.addShoppingItemsPersisted([]).rejection, .empty)
        XCTAssertEqual(persistence.replaceCallCount, writesBefore)
    }

    func testRestoreShoppingItemsPutsTheExactSnapshotBack() {
        let persistence = ToggleableShoppingListPersistence()
        let store = makeStore(shoppingList: persistence)
        store.addShopping(name: "鸡蛋", quantity: 6, unit: "个")
        let before = store.shoppingItems
        _ = store.addShoppingItemsPersisted([
            KitchenShoppingItem(name: "番茄", quantity: 2, unit: "个", source: "Kitchen AI")
        ])

        XCTAssertTrue(store.restoreShoppingItems(before).didPersist)
        XCTAssertEqual(store.shoppingItems, before)
        XCTAssertEqual(try persistence.loadShoppingItems(), before)
    }

    func testRestoreShoppingItemsPublishesNothingWhenPersistenceFails() {
        let persistence = ToggleableShoppingListPersistence()
        let store = makeStore(shoppingList: persistence)
        store.addShopping(name: "鸡蛋", quantity: 6, unit: "个")
        let before = store.shoppingItems
        _ = store.addShoppingItemsPersisted([
            KitchenShoppingItem(name: "番茄", quantity: 2, unit: "个", source: "Kitchen AI")
        ])
        let added = store.shoppingItems
        persistence.shouldFail = true

        XCTAssertTrue(store.restoreShoppingItems(before).didFailToPersist)
        XCTAssertEqual(store.shoppingItems, added)
    }

    // MARK: - Generated recipe materialization

    func testMaterializerReusesTheRecipeTheModelNamed() throws {
        let recipeStore = makeRecipeStore()
        let existing = recipe(id: "user-existing", title: "红烧牛腩", ingredients: ["牛腩 500 克"], steps: ["炖煮"])
        try recipeStore.saveUserRecipe(existing)

        let batch = try GeneratedRecipeMaterializer.materialize(
            [GeneratedRecipeCandidate(existingRecipeID: "user-existing", recipe: recipe(id: "new-id", title: "红烧牛腩"))],
            recipeStore: recipeStore
        )

        XCTAssertEqual(batch.recipes.map(\.id), ["user-existing"])
        XCTAssertTrue(batch.createdRecipeIDs.isEmpty, "a reused recipe was never created by this call")
        XCTAssertEqual(recipeStore.userRecipes.count, 1)
    }

    func testMaterializerReusesAnIdenticalRecipeByFingerprint() throws {
        let recipeStore = makeRecipeStore()
        let existing = recipe(id: "user-twin")
        try recipeStore.saveUserRecipe(existing)

        let batch = try GeneratedRecipeMaterializer.materialize(
            [GeneratedRecipeCandidate(existingRecipeID: nil, recipe: recipe(id: "new-id"))],
            recipeStore: recipeStore
        )

        XCTAssertEqual(batch.recipes.map(\.id), ["user-twin"])
        XCTAssertTrue(batch.createdRecipeIDs.isEmpty)
        XCTAssertEqual(recipeStore.userRecipes.count, 1, "identical content is never duplicated")
    }

    func testMaterializerCreatesWhatItCannotResolveAndTracksOnlyThose() throws {
        let recipeStore = makeRecipeStore()
        try recipeStore.saveUserRecipe(recipe(id: "user-twin"))

        let batch = try GeneratedRecipeMaterializer.materialize(
            [
                GeneratedRecipeCandidate(existingRecipeID: nil, recipe: recipe(id: "new-a")),
                GeneratedRecipeCandidate(existingRecipeID: nil, recipe: recipe(id: "new-b", title: "蒜蓉虾", ingredients: ["虾 300 克"], steps: ["蒸"]))
            ],
            recipeStore: recipeStore
        )

        XCTAssertEqual(batch.recipes.map(\.id), ["user-twin", "new-b"])
        XCTAssertEqual(batch.createdRecipeIDs, ["new-b"], "compensation must never reach a recipe this call reused")
    }

    /// A named id that no longer resolves is not an error: the dish falls back
    /// to being written as a new recipe carrying the content it arrived with.
    func testMaterializerFallsBackWhenTheNamedRecipeIsGone() throws {
        let recipeStore = makeRecipeStore()

        let batch = try GeneratedRecipeMaterializer.materialize(
            [GeneratedRecipeCandidate(existingRecipeID: "deleted-recipe", recipe: recipe(id: "new-a", title: "白灼菜心"))],
            recipeStore: recipeStore
        )

        XCTAssertEqual(batch.recipes.map(\.id), ["new-a"])
        XCTAssertEqual(batch.createdRecipeIDs, ["new-a"])
    }

    func testRollbackRemovesOnlyTheRecipesThisCallCreated() throws {
        let recipeStore = makeRecipeStore()
        try recipeStore.saveUserRecipe(recipe(id: "user-twin"))
        let batch = try GeneratedRecipeMaterializer.materialize(
            [
                GeneratedRecipeCandidate(existingRecipeID: nil, recipe: recipe(id: "new-a")),
                GeneratedRecipeCandidate(existingRecipeID: nil, recipe: recipe(id: "new-b", title: "蒜蓉虾", ingredients: ["虾 300 克"], steps: ["蒸"]))
            ],
            recipeStore: recipeStore
        )

        GeneratedRecipeMaterializer.rollbackCreatedRecipes(batch.createdRecipeIDs, recipeStore: recipeStore)

        XCTAssertEqual(recipeStore.userRecipes.map(\.id), ["user-twin"], "a pre-existing recipe survives a rollback")
    }

    // MARK: - Special Plan menu acceptance under a failed plan write

    /// The recipes were written and the plan write then failed. The library must
    /// not keep recipes nothing references, and the menu must not be sitting on
    /// screen looking saved.
    func testAcceptingAMenuRollsBackItsRecipesWhenThePlanWriteFails() throws {
        let persistence = ToggleableSpecialPlanPersistence()
        let store = makeStore(specialPlan: persistence)
        let recipeStore = makeRecipeStore()
        let plan = specialPlan(dishes: [])
        store.addSpecialPlan(plan)
        persistence.shouldFail = true

        XCTAssertThrowsError(
            try SpecialPlanMenuAcceptance.acceptMenu(
                dishes: [draftDish("红烧牛腩"), draftDish("蒜蓉虾")],
                planID: plan.id,
                kitchenStore: store,
                recipeStore: recipeStore
            )
        ) { error in
            XCTAssertEqual(error as? SpecialPlanMenuAcceptanceError, .planSaveFailed)
        }

        XCTAssertEqual(store.specialPlans.first?.dishes, [], "a menu the database refused is not published")
        XCTAssertTrue(
            recipeStore.userRecipes.isEmpty,
            "every recipe this call created is rolled back, so none is left with no plan referencing it"
        )
    }

    private func draftDish(_ title: String) -> SpecialPlanMenuDraftDish {
        SpecialPlanMenuDraftDish(
            title: title,
            ingredients: ["\(title)的主料 300 克"],
            seasonings: ["盐 少许"],
            steps: ["做熟"],
            tags: [],
            cookingTime: nil,
            difficulty: nil,
            reason: nil,
            existingRecipeID: nil,
            baseServings: SpecialPlanMenuBounds.aiRecipeBaseServings
        )
    }

    // MARK: - Domain tool live reads
    //
    // Conversation memory is not truth. Every read below has to answer from the
    // store as it is at the moment of the call, because the alternative — a
    // transcript observation reused as a current fact — is how a conversation
    // confidently tells someone to cook something they already ate.

    private func makeTools(
        _ store: KitchenStore,
        _ recipeStore: RecipeStore
    ) -> KitchenConversationDomainTools {
        KitchenConversationDomainTools(
            kitchenStore: store,
            recipeStore: recipeStore,
            calendar: calendar
        )
    }

    private func inventoryItem(
        name: String,
        quantity: Double = 2,
        unit: String = "个",
        expiresInDays: Int? = nil,
        kind: InventoryItemKind = .ordinary
    ) -> InventoryItem {
        InventoryItem(
            name: name,
            quantity: quantity,
            unit: unit,
            expiryDate: expiresInDays.map { Calendar.current.date(byAdding: .day, value: $0, to: Date())! },
            kind: kind
        )
    }

    /// Staples and ready-to-cook food are on hand and must be readable, but they
    /// are not the same kind of fact as an ordinary ingredient: one is stocked
    /// rather than dated, the other is already a dish. A context that flattened
    /// them would let the assistant propose cooking with a finished meal.
    func testInventoryContextReadsCurrentTruthWithKindsIntact() {
        let store = makeStore()
        let tools = makeTools(store, makeRecipeStore())
        store.inventory = [
            inventoryItem(name: "番茄", quantity: 5),
            inventoryItem(name: "菠菜", expiresInDays: 1),
            inventoryItem(name: "酱油", quantity: 1, unit: "瓶", kind: .staple),
            inventoryItem(name: "速冻饺子", quantity: 1, unit: "袋", expiresInDays: 2, kind: .readyToCook),
            inventoryItem(name: "牛奶", quantity: 0, unit: "盒", expiresInDays: 1)
        ]

        let context = tools.inventoryContext(now: Date())

        XCTAssertEqual(
            context.available.map(\.name), ["番茄", "菠菜", "酱油", "速冻饺子"],
            "a row with nothing left is not on hand"
        )
        XCTAssertEqual(context.available.first { $0.name == "酱油" }?.isStaple, true)
        XCTAssertEqual(context.available.first { $0.name == "速冻饺子" }?.isReadyToCook, true)
        XCTAssertEqual(
            context.expiring.map(\.name), ["菠菜", "速冻饺子"],
            "the expiring set is the app's own, so a staple can never appear in it"
        )
    }

    /// Tonight is today's ordinary schedule and nothing else. A Special Plan is
    /// its own event with its own reading — inferring a meal slot from its
    /// `scheduledAt` is exactly what the Home contract forbids.
    func testTonightPlanContextReadsOnlyTodaysOrdinaryPlans() {
        let store = makeStore()
        let tools = makeTools(store, makeRecipeStore())
        let seeded = seedPlans(store)
        store.addSpecialPlan(specialPlan(dishes: [SpecialPlanDish(recipeID: "s", recipeName: "佛跳墙")]))

        let context = tools.tonightPlanContext(now: day(2026, 3, 19), calendar: calendar)

        XCTAssertEqual(context.meals.map(\.planID), [seeded[1].id])
        XCTAssertEqual(context.meals.map(\.recipeName), ["红烧肉"])
        XCTAssertEqual(context.meals.map(\.isCooked), [false])
        XCTAssertEqual(context.day, calendar.startOfDay(for: day(2026, 3, 19)))
    }

    /// The week is read from `KitchenStore.plans`, which is the canonical
    /// ordinary-meal schedule, plus the Special Plans that actually fall in it.
    func testPlannerWeekContextReadsCanonicalPlansAndCurrentSpecialPlans() {
        let store = makeStore()
        let tools = makeTools(store, makeRecipeStore())
        let seeded = seedPlans(store)
        XCTAssertTrue(
            store.appendPlans(
                [MealPlanItem(recipeID: "d", recipeName: "下周的菜", date: day(2026, 3, 26))],
                calendar: calendar
            ).didPersist
        )
        let inWeek = specialPlan(dishes: [SpecialPlanDish(recipeID: "s", recipeName: "佛跳墙")])
        var outOfWeek = specialPlan(dishes: [])
        outOfWeek.scheduledAt = day(2026, 4, 4)
        store.addSpecialPlan(inWeek)
        store.addSpecialPlan(outOfWeek)

        let context = tools.plannerWeekContext(weekStart: day(2026, 3, 16), calendar: calendar)

        XCTAssertEqual(
            context.meals.map(\.planID), seeded.map(\.id),
            "the week answers from the canonical schedule, not from a draft weekly menu"
        )
        XCTAssertEqual(context.specialPlans.map(\.planID), [inWeek.id])
        XCTAssertEqual(context.specialPlans.first?.dishCount, 1)
        XCTAssertEqual(context.specialPlans.first?.peopleCount, 7)
    }

    func testSpecialPlanContextReadsTheCurrentEventOrNothing() {
        let store = makeStore()
        let tools = makeTools(store, makeRecipeStore())
        let plan = specialPlan(dishes: [
            SpecialPlanDish(recipeID: "s1", recipeName: "佛跳墙"),
            SpecialPlanDish(recipeID: "s2", recipeName: "白灼虾", isCooked: true)
        ])
        store.addSpecialPlan(plan)

        let context = tools.specialPlanContext(id: plan.id)

        XCTAssertEqual(context?.title, "朋友聚餐")
        XCTAssertEqual(context?.peopleCount, 7)
        XCTAssertEqual(context?.constraintNotes, ["1 人不吃辣"])
        XCTAssertEqual(context?.usesHomeInventory, true, "whether the home fridge counts is part of the event's truth")
        XCTAssertEqual(context?.dishes.map(\.recipeName), ["佛跳墙", "白灼虾"])
        XCTAssertEqual(context?.dishes.map(\.isCooked), [false, true])
        XCTAssertNil(tools.specialPlanContext(id: UUID()), "a plan that is gone is nil, never an empty event")
    }

    func testResolveRecipeAnswersFromTheRecipeStore() throws {
        let store = makeStore()
        let recipeStore = makeRecipeStore()
        let tools = makeTools(store, recipeStore)
        try recipeStore.saveUserRecipe(recipe(id: "user-1", title: "红烧牛腩"))

        XCTAssertEqual(tools.resolveRecipe(query: "different title", recipeID: "user-1")?.title, "红烧牛腩")
        XCTAssertNil(tools.resolveRecipe(query: "红烧牛腩", recipeID: "never-existed"))
    }

    /// The same tool instance, asked twice across a change, must answer twice.
    /// This is the whole reason the adapter holds store references instead of
    /// copies of kitchen state.
    func testReadsAnswerFromCurrentStateOnEveryCall() {
        let store = makeStore()
        let tools = makeTools(store, makeRecipeStore())
        let seeded = seedPlans(store)

        XCTAssertEqual(tools.tonightPlanContext(now: day(2026, 3, 19), calendar: calendar).meals.count, 1)

        XCTAssertTrue(store.removePlan(id: seeded[1].id).didPersist)
        store.inventory = [inventoryItem(name: "番茄")]

        XCTAssertTrue(
            tools.tonightPlanContext(now: day(2026, 3, 19), calendar: calendar).meals.isEmpty,
            "a plan the user deleted is not still tonight's dinner"
        )
        XCTAssertEqual(tools.inventoryContext(now: Date()).available.map(\.name), ["番茄"])
    }

    // MARK: - Domain tool mutations

    private func block(_ recipe: Recipe, isTransient: Bool) -> AIRecipeBlock {
        AIRecipeBlock(recipe: recipe, isTransient: isTransient)
    }

    /// A recipe the library already holds is referenced, not copied, and the
    /// receipt claims nothing was created — which is what keeps a later Undo
    /// from deleting a recipe this action never wrote.
    func testAddingACanonicalRecipeToTonightCreatesNothing() throws {
        let store = makeStore()
        let recipeStore = makeRecipeStore()
        let tools = makeTools(store, recipeStore)
        let existing = recipe(id: "user-1", title: "红烧牛腩", ingredients: ["牛腩 500 克"], steps: ["炖煮"])
        try recipeStore.saveUserRecipe(existing)

        let receipt = try tools.addRecipeToTonight(block(existing, isTransient: false), now: day(2026, 3, 19))

        guard case let .tonightPlan(plan, createdRecipeIDs) = receipt else {
            return XCTFail("expected a tonight-plan receipt, got \(receipt)")
        }
        XCTAssertEqual(createdRecipeIDs, [], "a recipe that already existed was not created by this call")
        XCTAssertEqual(plan.recipeID, "user-1")
        XCTAssertEqual(store.plans.map(\.id), [plan.id])
        XCTAssertEqual(
            tools.tonightPlanContext(now: day(2026, 3, 19), calendar: calendar).meals.map(\.planID), [plan.id],
            "the meal lands on the day the read asks about"
        )
        XCTAssertEqual(recipeStore.userRecipes.count, 1)
    }

    /// A generated dish becomes a real recipe first, so the plan only ever
    /// stores an id that already exists.
    func testAddingATransientRecipeToTonightMaterializesItFirst() throws {
        let store = makeStore()
        let recipeStore = makeRecipeStore()
        let tools = makeTools(store, recipeStore)

        let receipt = try tools.addRecipeToTonight(
            block(recipe(id: "ai-1", title: "冬瓜汤", ingredients: ["冬瓜 300 克"], steps: ["煮"]), isTransient: true),
            now: day(2026, 3, 19)
        )

        guard case let .tonightPlan(plan, createdRecipeIDs) = receipt else {
            return XCTFail("expected a tonight-plan receipt, got \(receipt)")
        }
        XCTAssertEqual(createdRecipeIDs, ["ai-1"])
        XCTAssertEqual(recipeStore.userRecipes.map(\.id), ["ai-1"])
        XCTAssertEqual(plan.recipeID, "ai-1")
        XCTAssertEqual(plan.recipeName, "冬瓜汤")
        XCTAssertEqual(store.plans.map(\.id), [plan.id])
    }

    /// The transient dish turns out to be one the library already has. The
    /// receipt must not name it: an Undo that deleted it would destroy a recipe
    /// the user owned before this conversation started.
    func testATransientRecipeThatAlreadyExistsIsNeverClaimedAsCreated() throws {
        let store = makeStore()
        let recipeStore = makeRecipeStore()
        let tools = makeTools(store, recipeStore)
        try recipeStore.saveUserRecipe(recipe(id: "user-twin"))

        let receipt = try tools.addRecipeToTonight(
            block(recipe(id: "ai-1"), isTransient: true),
            now: day(2026, 3, 19)
        )

        guard case let .tonightPlan(plan, createdRecipeIDs) = receipt else {
            return XCTFail("expected a tonight-plan receipt, got \(receipt)")
        }
        XCTAssertEqual(createdRecipeIDs, [], "a reused recipe is not this action's to delete")
        XCTAssertEqual(plan.recipeID, "user-twin")

        try tools.undo(receipt)

        XCTAssertEqual(recipeStore.userRecipes.map(\.id), ["user-twin"], "Undo never reaches a pre-existing recipe")
    }

    /// The recipe was written and the plan write then failed. The library must
    /// not keep a recipe nothing references.
    func testAFailedTonightWriteCompensatesTheRecipeItCreated() {
        let persistence = ToggleableTodayPlanPersistence()
        let store = makeStore(todayPlan: persistence)
        let recipeStore = makeRecipeStore()
        let tools = makeTools(store, recipeStore)
        persistence.shouldFail = true

        XCTAssertThrowsError(
            try tools.addRecipeToTonight(
                block(recipe(id: "ai-1", title: "冬瓜汤"), isTransient: true),
                now: day(2026, 3, 19)
            )
        ) { XCTAssertEqual($0 as? AIDomainToolError, .persistenceFailed) }

        XCTAssertTrue(store.plans.isEmpty, "a refused write leaves no meal on the schedule")
        XCTAssertTrue(recipeStore.userRecipes.isEmpty, "the recipe this call created is compensated")
    }

    func testUndoingATonightAdditionRemovesThePlanAndItsCreatedRecipe() throws {
        let store = makeStore()
        let recipeStore = makeRecipeStore()
        let tools = makeTools(store, recipeStore)
        let receipt = try tools.addRecipeToTonight(
            block(recipe(id: "ai-1", title: "冬瓜汤"), isTransient: true),
            now: day(2026, 3, 19)
        )

        try tools.undo(receipt)

        XCTAssertTrue(store.plans.isEmpty)
        XCTAssertTrue(recipeStore.userRecipes.isEmpty, "nothing references it any more, so it goes with the plan")
    }

    /// The same dish was also planned for another day. Undoing tonight cannot
    /// take the recipe out from under that other row.
    func testUndoKeepsACreatedRecipeAnotherPlanStillReferences() throws {
        let store = makeStore()
        let recipeStore = makeRecipeStore()
        let tools = makeTools(store, recipeStore)
        let receipt = try tools.addRecipeToTonight(
            block(recipe(id: "ai-1", title: "冬瓜汤"), isTransient: true),
            now: day(2026, 3, 19)
        )
        XCTAssertTrue(
            store.appendPlans(
                [MealPlanItem(recipeID: "ai-1", recipeName: "冬瓜汤", date: day(2026, 3, 22))],
                calendar: calendar
            ).didPersist
        )

        try tools.undo(receipt)

        XCTAssertEqual(store.plans.map(\.date), [day(2026, 3, 22)].map { MealPlanItem.normalizedPlannerDate(for: $0, calendar: calendar) })
        XCTAssertEqual(recipeStore.userRecipes.map(\.id), ["ai-1"], "a recipe another plan still cooks is not deleted")
    }

    func testUndoKeepsACreatedRecipeASpecialPlanDishStillReferences() throws {
        let store = makeStore()
        let recipeStore = makeRecipeStore()
        let tools = makeTools(store, recipeStore)
        let receipt = try tools.addRecipeToTonight(
            block(recipe(id: "ai-1", title: "冬瓜汤"), isTransient: true),
            now: day(2026, 3, 19)
        )
        store.addSpecialPlan(specialPlan(dishes: [SpecialPlanDish(recipeID: "ai-1", recipeName: "冬瓜汤")]))

        try tools.undo(receipt)

        XCTAssertTrue(store.plans.isEmpty)
        XCTAssertEqual(recipeStore.userRecipes.map(\.id), ["ai-1"], "an event still serving it keeps it alive")
    }

    // MARK: Planner replacement through the tool surface

    func testReplacingPlannedMealsRecordsBothSidesAndUndoRestoresThem() throws {
        let store = makeStore()
        let recipeStore = makeRecipeStore()
        let tools = makeTools(store, recipeStore)
        let seeded = seedPlans(store)

        let receipt = try tools.replacePlannedMeals([
            AIPlannerMealChange(
                planID: seeded[0].id,
                replacement: block(recipe(id: "ai-1", title: "清蒸鲈鱼"), isTransient: true),
                plannedServings: 4
            )
        ])

        guard case let .plannerReplacement(before, after, createdRecipeIDs) = receipt else {
            return XCTFail("expected a planner receipt, got \(receipt)")
        }
        XCTAssertEqual(before, [seeded[0]], "the receipt carries the exact pre-mutation row")
        XCTAssertEqual(after.map(\.recipeName), ["清蒸鲈鱼"])
        XCTAssertEqual(createdRecipeIDs, ["ai-1"], "a replacement that generated a dish owns that recipe too")
        XCTAssertEqual(store.plans[0].plannedServings, 4)
        XCTAssertFalse(store.plans[0].isCooked)

        try tools.undo(receipt)

        XCTAssertEqual(store.plans, seeded, "Undo restores the row exactly, cooked state included")
    }

    /// A replacement that generated a dish created a recipe, so Undo has to take
    /// it back with the row. The receipt is the only record of which recipe that
    /// was, which is why it carries the ids rather than the caller guessing.
    func testUndoingAPlannerReplacementRemovesTheRecipeItCreated() throws {
        let store = makeStore()
        let recipeStore = makeRecipeStore()
        let tools = makeTools(store, recipeStore)
        let seeded = seedPlans(store)
        let receipt = try tools.replacePlannedMeals([
            AIPlannerMealChange(
                planID: seeded[0].id,
                replacement: block(recipe(id: "ai-1", title: "清蒸鲈鱼"), isTransient: true),
                plannedServings: nil
            )
        ])
        XCTAssertEqual(recipeStore.userRecipes.map(\.id), ["ai-1"])

        try tools.undo(receipt)

        XCTAssertEqual(store.plans, seeded)
        XCTAssertTrue(recipeStore.userRecipes.isEmpty, "nothing cooks it any more, so it goes back with the row")
    }

    /// Same replacement, but the user meanwhile planned the new dish for another
    /// day. The live reference rule outranks the receipt: Undo restores the row
    /// and leaves the recipe alone.
    func testUndoingAPlannerReplacementKeepsARecipeAnotherPlanStillReferences() throws {
        let store = makeStore()
        let recipeStore = makeRecipeStore()
        let tools = makeTools(store, recipeStore)
        let seeded = seedPlans(store)
        let receipt = try tools.replacePlannedMeals([
            AIPlannerMealChange(
                planID: seeded[0].id,
                replacement: block(recipe(id: "ai-1", title: "清蒸鲈鱼"), isTransient: true),
                plannedServings: nil
            )
        ])
        XCTAssertTrue(
            store.appendPlans(
                [MealPlanItem(recipeID: "ai-1", recipeName: "清蒸鲈鱼", date: day(2026, 3, 22))],
                calendar: calendar
            ).didPersist
        )

        try tools.undo(receipt)

        XCTAssertEqual(store.plans.prefix(3).map(\.recipeID), seeded.map(\.recipeID))
        XCTAssertEqual(recipeStore.userRecipes.map(\.id), ["ai-1"], "a recipe another plan still cooks survives")
    }

    /// The recipe was written and the plan write then failed. Nothing is
    /// published and nothing is left in the library.
    func testAFailedPlannerWriteCompensatesTheRecipesItCreated() {
        let persistence = ToggleableTodayPlanPersistence()
        let store = makeStore(todayPlan: persistence)
        let recipeStore = makeRecipeStore()
        let tools = makeTools(store, recipeStore)
        let seeded = seedPlans(store)
        persistence.shouldFail = true

        XCTAssertThrowsError(
            try tools.replacePlannedMeals([
                AIPlannerMealChange(
                    planID: seeded[0].id,
                    replacement: block(recipe(id: "ai-1", title: "清蒸鲈鱼"), isTransient: true),
                    plannedServings: nil
                )
            ])
        ) { XCTAssertEqual($0 as? AIDomainToolError, .persistenceFailed) }

        XCTAssertEqual(store.plans, seeded, "a refused write leaves the schedule alone")
        XCTAssertTrue(recipeStore.userRecipes.isEmpty, "the recipe this call created is compensated")
    }

    /// The library itself refused the recipe. The tool says so by name rather
    /// than reporting a generic failure, and writes no plan.
    func testARefusedRecipeSaveSurfacesAsItsOwnError() {
        let recipePersistence = ToggleableUserRecipePersistence()
        let store = makeStore()
        let recipeStore = makeRecipeStore(recipePersistence)
        let tools = makeTools(store, recipeStore)
        recipePersistence.shouldFail = true

        XCTAssertThrowsError(
            try tools.addRecipeToTonight(
                block(recipe(id: "ai-1", title: "冬瓜汤"), isTransient: true),
                now: day(2026, 3, 19)
            )
        ) { XCTAssertEqual($0 as? AIDomainToolError, .recipeSaveFailed(title: "冬瓜汤")) }

        XCTAssertTrue(store.plans.isEmpty, "no plan may reference a recipe that was never written")
        XCTAssertTrue(recipeStore.userRecipes.isEmpty)
    }

    /// A quantity of nothing, or one that is not a number, is not a shopping
    /// request. The merge would quietly coerce both to 1, so the receipt would
    /// claim a success covering an amount nobody asked for.
    func testAShoppingItemWithNoRealQuantityIsRefusedBeforeAnyWrite() {
        let persistence = ToggleableShoppingListPersistence()
        let store = makeStore(shoppingList: persistence)
        let tools = makeTools(store, makeRecipeStore())
        let writesBefore = persistence.replaceCallCount

        for quantity in [0, -1, Double.nan, .infinity] {
            XCTAssertThrowsError(
                try tools.addShoppingItems([AIShoppingItemProposal(name: "番茄", quantity: quantity, unit: "个")])
            ) { XCTAssertEqual($0 as? AIDomainToolError, .invalidShoppingQuantity) }
        }
        XCTAssertEqual(persistence.replaceCallCount, writesBefore)
        XCTAssertTrue(store.shoppingItems.isEmpty)
    }

    /// The adapter names the civil-day calendar it writes with, and the reads
    /// asked without one use that same calendar. A caller taking the obvious
    /// path cannot read a day the write did not land on.
    func testTheAdapterReadsTheSameCivilDayItWrites() throws {
        let store = makeStore()
        let tools = makeTools(store, makeRecipeStore())
        XCTAssertEqual(tools.calendar, calendar)

        let receipt = try tools.addRecipeToTonight(
            block(recipe(id: "ai-1", title: "冬瓜汤"), isTransient: true),
            now: day(2026, 3, 19)
        )

        guard case let .tonightPlan(plan, _) = receipt else {
            return XCTFail("expected a tonight-plan receipt, got \(receipt)")
        }
        XCTAssertEqual(
            tools.tonightPlanContext(now: day(2026, 3, 19)).meals.map(\.planID), [plan.id],
            "the read the adapter answers by default sees the day it just wrote"
        )
        XCTAssertEqual(tools.plannerWeekContext(weekStart: day(2026, 3, 16)).meals.map(\.planID), [plan.id])
    }

    /// The model restated the dish but said nothing about servings. The number
    /// the user chose for that slot is theirs, so it carries forward rather than
    /// being silently dropped.
    func testAReplacementWithoutStatedServingsKeepsTheUsersOwn() throws {
        let store = makeStore()
        let tools = makeTools(store, makeRecipeStore())
        let seeded = seedPlans(store)

        _ = try tools.replacePlannedMeals([
            AIPlannerMealChange(
                planID: seeded[2].id,
                replacement: block(recipe(id: "ai-1", title: "清蒸鲈鱼"), isTransient: true),
                plannedServings: nil
            )
        ])

        XCTAssertEqual(store.plans[2].plannedServings, 4)
    }

    /// A meal the user already cooked and consumed cannot be re-dished. The tool
    /// has to say that specifically: a generic failure would invite a retry that
    /// can never succeed.
    func testReplacingAConsumedMealSurfacesItsOwnRefusal() throws {
        let store = makeStore()
        let recipeStore = makeRecipeStore()
        let tools = makeTools(store, recipeStore)
        store.addInventory(name: "番茄", quantity: 5, unit: "个", expiryDate: nil)
        let seeded = seedPlans(store)
        let drafts = InventoryConsumptionPlanner().plan(
            for: [.init(recipe: recipe(id: "a", title: "宫保鸡丁"), servings: 2)],
            inventory: store.inventory
        )
        store.applyConsumption(drafts, planIDs: [seeded[0].id], recipeID: "a", recipeName: "宫保鸡丁")

        XCTAssertThrowsError(
            try tools.replacePlannedMeals([
                AIPlannerMealChange(
                    planID: seeded[0].id,
                    replacement: block(recipe(id: "ai-1", title: "清蒸鲈鱼"), isTransient: true),
                    plannedServings: nil
                )
            ])
        ) { XCTAssertEqual($0 as? AIDomainToolError, .consumedPlans([seeded[0].id])) }

        XCTAssertEqual(store.plans, seeded)
        XCTAssertTrue(recipeStore.userRecipes.isEmpty, "a refused replacement leaves no recipe behind")
    }

    func testReplacingAMissingPlannedMealNamesTheRowsItCouldNotFind() {
        let store = makeStore()
        let tools = makeTools(store, makeRecipeStore())
        _ = seedPlans(store)
        let missing = UUID()

        XCTAssertThrowsError(
            try tools.replacePlannedMeals([
                AIPlannerMealChange(
                    planID: missing,
                    replacement: block(recipe(id: "ai-1", title: "清蒸鲈鱼"), isTransient: false),
                    plannedServings: nil
                )
            ])
        ) { XCTAssertEqual($0 as? AIDomainToolError, .planNotFound([missing])) }
    }

    func testReplacingNoPlannedMealsIsRefusedBeforeAnyWrite() {
        let store = makeStore()
        let tools = makeTools(store, makeRecipeStore())

        XCTAssertThrowsError(try tools.replacePlannedMeals([])) {
            XCTAssertEqual($0 as? AIDomainToolError, .emptyRequest)
        }
    }

    /// A refusal current state already determines must cost the recipe library
    /// nothing at all.
    ///
    /// Every request here carries a TRANSIENT replacement — the only kind that
    /// gets materialized — so a canonical write would be observable. The
    /// assertion is on the write count rather than on the final library
    /// contents deliberately: "created, then rolled back" also ends with an
    /// empty library, and that is exactly the outcome this excludes. The
    /// rollback is a second write that can itself fail, and when it does the
    /// user is left holding a generated recipe from a request that was never
    /// valid in the first place.
    func testDeterminableRefusalsPerformNoRecipeWriteAtAll() {
        let recipePersistence = ToggleableUserRecipePersistence()
        let recipeStore = makeRecipeStore(recipePersistence)
        let store = makeStore()
        let tools = makeTools(store, recipeStore)
        store.addInventory(name: "番茄", quantity: 5, unit: "个", expiryDate: nil)
        let seeded = seedPlans(store)
        let drafts = InventoryConsumptionPlanner().plan(
            for: [.init(recipe: recipe(id: "a", title: "宫保鸡丁"), servings: 2)],
            inventory: store.inventory
        )
        store.applyConsumption(drafts, planIDs: [seeded[0].id], recipeID: "a", recipeName: "宫保鸡丁")
        let missing = UUID()
        func change(_ planID: UUID) -> AIPlannerMealChange {
            AIPlannerMealChange(
                planID: planID,
                replacement: block(recipe(id: "ai-1", title: "清蒸鲈鱼"), isTransient: true),
                plannedServings: nil
            )
        }
        let writesBefore = recipePersistence.replaceCallCount

        XCTAssertThrowsError(try tools.replacePlannedMeals([])) {
            XCTAssertEqual($0 as? AIDomainToolError, .emptyRequest)
        }
        XCTAssertThrowsError(try tools.replacePlannedMeals([change(seeded[1].id), change(seeded[1].id)])) {
            XCTAssertEqual($0 as? AIDomainToolError, .duplicateTargets([seeded[1].id]))
        }
        XCTAssertThrowsError(try tools.replacePlannedMeals([change(missing)])) {
            XCTAssertEqual($0 as? AIDomainToolError, .planNotFound([missing]))
        }
        XCTAssertThrowsError(try tools.replacePlannedMeals([change(seeded[0].id)])) {
            XCTAssertEqual($0 as? AIDomainToolError, .consumedPlans([seeded[0].id]))
        }

        XCTAssertEqual(
            recipePersistence.replaceCallCount,
            writesBefore,
            "a determinable refusal never reaches the recipe library"
        )
        XCTAssertTrue(recipeStore.userRecipes.isEmpty)
        XCTAssertEqual(store.plans, seeded, "and nothing in the schedule moved either")
    }

    // MARK: Special Plan dishes through the tool surface

    /// OB9: the store answers `.notFound` for a missing event and a missing dish
    /// alike. The user has to be told which one is actually gone.
    func testAMissingEventAndAMissingDishAreDifferentAnswers() throws {
        let store = makeStore()
        let tools = makeTools(store, makeRecipeStore())
        let plan = specialPlan(dishes: [SpecialPlanDish(recipeID: "s1", recipeName: "佛跳墙")])
        store.addSpecialPlan(plan)
        let goneEvent = UUID()
        let goneDish = UUID()
        let change = AISpecialPlanDishChange(
            dishID: goneDish,
            replacement: block(recipe(id: "ai-1", title: "白灼虾"), isTransient: true)
        )

        XCTAssertThrowsError(try tools.replaceSpecialPlanDishes(planID: goneEvent, changes: [change])) {
            XCTAssertEqual($0 as? AIDomainToolError, .specialPlanNotFound(goneEvent))
        }
        XCTAssertThrowsError(try tools.replaceSpecialPlanDishes(planID: plan.id, changes: [change])) {
            XCTAssertEqual($0 as? AIDomainToolError, .dishNotFound([goneDish]))
        }
    }

    /// One dish named twice describes no single outcome, and the store refuses
    /// it — but only after the tool has already materialized both replacements.
    /// Refused here, the library is never touched.
    func testDuplicateSpecialPlanDishesAreRefusedBeforeAnyRecipeIsCreated() {
        let recipePersistence = ToggleableUserRecipePersistence()
        let recipeStore = makeRecipeStore(recipePersistence)
        let store = makeStore()
        let tools = makeTools(store, recipeStore)
        let dish = SpecialPlanDish(recipeID: "s1", recipeName: "佛跳墙")
        let plan = specialPlan(dishes: [dish, SpecialPlanDish(recipeID: "s2", recipeName: "白灼虾")])
        store.addSpecialPlan(plan)
        let change = AISpecialPlanDishChange(
            dishID: dish.id,
            replacement: block(recipe(id: "ai-1", title: "清蒸鲈鱼"), isTransient: true)
        )
        let writesBefore = recipePersistence.replaceCallCount

        XCTAssertThrowsError(try tools.replaceSpecialPlanDishes(planID: plan.id, changes: [change, change])) {
            XCTAssertEqual($0 as? AIDomainToolError, .duplicateTargets([dish.id]))
        }

        XCTAssertEqual(
            recipePersistence.replaceCallCount,
            writesBefore,
            "a duplicate dish never reaches the recipe library"
        )
        XCTAssertTrue(recipeStore.userRecipes.isEmpty)
        XCTAssertEqual(store.specialPlans.first?.dishes, plan.dishes, "and the menu is untouched")
    }

    func testReplacingSpecialPlanDishesRecordsTheEventEitherSideAndUndoRestoresIt() throws {
        let store = makeStore()
        let recipeStore = makeRecipeStore()
        let tools = makeTools(store, recipeStore)
        let dish = SpecialPlanDish(recipeID: "s1", recipeName: "佛跳墙")
        let plan = specialPlan(dishes: [dish, SpecialPlanDish(recipeID: "s2", recipeName: "白灼虾")])
        store.addSpecialPlan(plan)

        let receipt = try tools.replaceSpecialPlanDishes(planID: plan.id, changes: [
            AISpecialPlanDishChange(
                dishID: dish.id,
                replacement: block(recipe(id: "ai-1", title: "清蒸鲈鱼"), isTransient: true)
            )
        ])

        guard case let .specialPlanMenu(before, after, createdRecipeIDs) = receipt else {
            return XCTFail("expected a special-plan receipt, got \(receipt)")
        }
        XCTAssertEqual(before.dishes, plan.dishes)
        XCTAssertEqual(after.dishes.map(\.recipeName), ["清蒸鲈鱼", "白灼虾"])
        XCTAssertEqual(after.dishes.map(\.id), plan.dishes.map(\.id), "a replaced dish keeps its id and its place")
        XCTAssertEqual(createdRecipeIDs, ["ai-1"])

        try tools.undo(receipt)

        XCTAssertEqual(store.specialPlans.first?.dishes, plan.dishes)
        XCTAssertTrue(recipeStore.userRecipes.isEmpty, "the recipe this action created goes back with the menu")
    }

    func testAFailedSpecialPlanWriteCompensatesTheRecipesItCreated() {
        let persistence = ToggleableSpecialPlanPersistence()
        let store = makeStore(specialPlan: persistence)
        let recipeStore = makeRecipeStore()
        let tools = makeTools(store, recipeStore)
        let dish = SpecialPlanDish(recipeID: "s1", recipeName: "佛跳墙")
        let plan = specialPlan(dishes: [dish])
        store.addSpecialPlan(plan)
        persistence.shouldFail = true

        XCTAssertThrowsError(
            try tools.replaceSpecialPlanDishes(planID: plan.id, changes: [
                AISpecialPlanDishChange(
                    dishID: dish.id,
                    replacement: block(recipe(id: "ai-1", title: "清蒸鲈鱼"), isTransient: true)
                )
            ])
        ) { XCTAssertEqual($0 as? AIDomainToolError, .persistenceFailed) }

        XCTAssertEqual(store.specialPlans.first?.dishes, [dish], "a menu the database refused is not published")
        XCTAssertTrue(recipeStore.userRecipes.isEmpty)
    }

    /// The event was deleted after the action ran. The restore cannot happen, and
    /// saying it did would be worse than refusing.
    func testUndoRefusesTruthfullyWhenTheEventIsGone() throws {
        let store = makeStore()
        let recipeStore = makeRecipeStore()
        let tools = makeTools(store, recipeStore)
        let dish = SpecialPlanDish(recipeID: "s1", recipeName: "佛跳墙")
        let plan = specialPlan(dishes: [dish])
        store.addSpecialPlan(plan)
        let receipt = try tools.replaceSpecialPlanDishes(planID: plan.id, changes: [
            AISpecialPlanDishChange(
                dishID: dish.id,
                replacement: block(recipe(id: "ai-1", title: "清蒸鲈鱼"), isTransient: true)
            )
        ])
        XCTAssertNotNil(store.removeSpecialPlan(id: plan.id))

        XCTAssertThrowsError(try tools.undo(receipt)) {
            XCTAssertEqual($0 as? AIDomainToolError, .undoTargetMissing)
        }
        XCTAssertEqual(
            recipeStore.userRecipes.map(\.id), ["ai-1"],
            "an Undo that did not happen must not delete anything either"
        )
    }

    // MARK: Shopping through the tool surface

    func testAddingShoppingItemsNormalizesTheSourceAndKeepsTheExistingMerge() throws {
        let store = makeStore()
        let tools = makeTools(store, makeRecipeStore())
        store.addShopping(name: "鸡蛋", quantity: 6, unit: "个", source: "手动添加")
        let before = store.shoppingItems

        let receipt = try tools.addShoppingItems([
            AIShoppingItemProposal(name: "鸡蛋", quantity: 4, unit: "个"),
            AIShoppingItemProposal(name: "番茄", quantity: 2, unit: "个", remark: "挑软一点的")
        ])

        guard case let .shoppingAdditions(receiptBefore, receiptAfter) = receipt else {
            return XCTFail("expected a shopping receipt, got \(receipt)")
        }
        XCTAssertEqual(receiptBefore, before)
        XCTAssertEqual(receiptAfter, store.shoppingItems)
        XCTAssertEqual(store.shoppingItems.count, 2, "the existing merge behavior is unchanged")
        XCTAssertEqual(store.shoppingItems[0].quantity, 10)
        XCTAssertEqual(store.shoppingItems[0].source, "手动添加", "a merged row keeps the source it already had")
        XCTAssertEqual(store.shoppingItems[1].source, "Kitchen AI")
        XCTAssertEqual(store.shoppingItems[1].remark, "挑软一点的")

        try tools.undo(receipt)

        XCTAssertEqual(store.shoppingItems, before)
    }

    func testAddingAnUnnamedOrEmptyShoppingBatchIsRefusedBeforeAnyWrite() {
        let persistence = ToggleableShoppingListPersistence()
        let store = makeStore(shoppingList: persistence)
        let tools = makeTools(store, makeRecipeStore())
        let writesBefore = persistence.replaceCallCount

        XCTAssertThrowsError(try tools.addShoppingItems([])) {
            XCTAssertEqual($0 as? AIDomainToolError, .emptyRequest)
        }
        XCTAssertThrowsError(
            try tools.addShoppingItems([AIShoppingItemProposal(name: "  ", quantity: 1, unit: "个")])
        ) { XCTAssertEqual($0 as? AIDomainToolError, .unnamedShoppingItem) }
        XCTAssertEqual(persistence.replaceCallCount, writesBefore)
        XCTAssertTrue(store.shoppingItems.isEmpty)
    }

    func testResolveRecipeQueryOnlyFindsExactChineseTitle() throws {
        let recipes = makeRecipeStore()
        let expected = recipe(id: "query-eggs")
        try recipes.saveUserRecipe(expected)
        let tools: any AIConversationDomainTooling = makeTools(makeStore(), recipes)
        XCTAssertEqual(tools.resolveRecipe(query: "番茄炒蛋", recipeID: nil), expected)
    }

    func testResolveRecipeNormalizesWhitespaceCaseAndCanonicalUnicode() throws {
        let recipes = makeRecipeStore()
        try recipes.saveUserRecipe(recipe(id: "query-unicode", title: "Café I SOUP"))
        let tools = makeTools(makeStore(), recipes)
        XCTAssertEqual(tools.resolveRecipe(query: "  CAFE\u{0301}\t i\n soup  ", recipeID: nil)?.id, "query-unicode")
    }

    func testResolveRecipeUnknownOrNonExactQueryDoesNotGuess() throws {
        let recipes = makeRecipeStore()
        try recipes.saveUserRecipe(recipe(id: "query-eggs"))
        try recipes.saveUserRecipe(recipe(id: "query-cafe", title: "Café Soup"))
        let tools = makeTools(makeStore(), recipes)
        for query in ["", " \n\t", "不存在的菜", "番茄", "番茄炒鸡蛋", "Cafe Soup"] {
            XCTAssertNil(tools.resolveRecipe(query: query, recipeID: nil), query)
        }
    }

    func testResolveRecipeAmbiguousNormalizedTitleReturnsNil() throws {
        let recipes = makeRecipeStore()
        try recipes.saveUserRecipe(recipe(id: "version-one", title: "Egg Soup", ingredients: ["鸡蛋 1 个"]))
        try recipes.saveUserRecipe(recipe(id: "version-two", title: "EGG SOUP", ingredients: ["鸡蛋 2 个"]))
        let tools = makeTools(makeStore(), recipes)
        XCTAssertNil(tools.resolveRecipe(query: "egg soup", recipeID: nil))
        XCTAssertEqual(tools.resolveRecipe(query: "egg soup", recipeID: "version-two")?.id, "version-two")
    }

    func testResolveRecipeQueryReadsCurrentStoreAfterSaveRenameAndDelete() throws {
        let recipes = makeRecipeStore()
        let tools = makeTools(makeStore(), recipes)
        XCTAssertNil(tools.resolveRecipe(query: "番茄炒蛋", recipeID: nil))
        try recipes.saveUserRecipe(recipe(id: "live-query"))
        XCTAssertEqual(tools.resolveRecipe(query: "番茄炒蛋", recipeID: nil)?.id, "live-query")
        try recipes.replaceUserRecipe(recipe(id: "live-query", title: "鸡蛋汤"))
        XCTAssertNil(tools.resolveRecipe(query: "番茄炒蛋", recipeID: nil))
        XCTAssertEqual(tools.resolveRecipe(query: "鸡蛋汤", recipeID: nil)?.id, "live-query")
        XCTAssertEqual(tools.resolveRecipe(query: "ignored with ID", recipeID: "live-query")?.title, "鸡蛋汤")
        try recipes.deleteUserRecipe(id: "live-query")
        XCTAssertNil(tools.resolveRecipe(query: "鸡蛋汤", recipeID: nil))
    }

    func testResolveRecipeEmptyIDUsesQueryButNonemptyIDRemainsAuthoritative() throws {
        let recipes = makeRecipeStore()
        try recipes.saveUserRecipe(recipe(id: "query-eggs"))
        let tools = makeTools(makeStore(), recipes)
        XCTAssertEqual(tools.resolveRecipe(query: "番茄炒蛋", recipeID: "")?.id, "query-eggs")
        XCTAssertNil(tools.resolveRecipe(query: "番茄炒蛋", recipeID: "missing"))
        XCTAssertNil(tools.resolveRecipe(query: "番茄炒蛋", recipeID: " query-eggs "), "IDs are canonical, never title-normalized")
    }

    func testResolveRecipeQueryDoesNotInventAnUnloadedSampleLibrary() throws {
        let recipes = makeRecipeStore()
        let tools = makeTools(makeStore(), recipes)
        let sample = try XCTUnwrap(Recipe.samples.first)
        XCTAssertTrue(recipes.recipes.isEmpty)
        XCTAssertNil(tools.resolveRecipe(query: sample.title, recipeID: nil))
        XCTAssertEqual(tools.resolveRecipe(query: sample.title, recipeID: sample.id), sample)
    }

    func testExactActionReadsAndPostStateRespectAffectedRowsOnly() throws {
        let store = makeStore(); let rows = seedPlans(store); let recipes = makeRecipeStore(); let tools = makeTools(store, recipes)
        XCTAssertEqual(tools.plannedMeal(id: rows[0].id), rows[0])
        let receipt = try tools.replacePlannedMeals([.init(planID: rows[0].id, replacement: .init(recipe: recipe(), isTransient: true))])
        XCTAssertTrue(tools.currentStateMatchesPostState(of: receipt))
        var unrelated = store.plans[1]; unrelated.plannedServings = 8; _ = store.restorePlanItems([unrelated])
        XCTAssertTrue(tools.currentStateMatchesPostState(of: receipt))
        var affected = store.plans[0]; affected.isCooked = true; _ = store.restorePlanItems([affected])
        XCTAssertFalse(tools.currentStateMatchesPostState(of: receipt))
    }
    func testMutationRecipePreviewResolvesCanonicalAndFingerprintWithoutWrites() throws {
        let store = makeStore(); let recipes = makeRecipeStore(); let tools = makeTools(store, recipes)
        let canonical = recipe(id: "canonical", title: "真实菜名"); try recipes.saveUserRecipe(canonical)
        let snapshot = AIRecipeBlock(recipe: recipe(id: "canonical", title: "旧菜名"), isTransient: false)
        XCTAssertEqual(tools.mutationRecipes([snapshot]), [canonical])
        let twin = AIRecipeBlock(recipe: recipe(id: "random", title: "真实菜名"), isTransient: true)
        XCTAssertEqual(tools.mutationRecipes([twin]), [canonical])
        let new = AIRecipeBlock(recipe: recipe(id: "new", title: "新菜"), isTransient: true)
        let second = AIRecipeBlock(recipe: recipe(id: "new2", title: "新菜"), isTransient: true)
        XCTAssertEqual(tools.mutationRecipes([new, second]), [new.recipe, new.recipe])
        XCTAssertEqual(recipes.userRecipes, [canonical]); XCTAssertEqual(store.plans, [])
    }

}

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
}

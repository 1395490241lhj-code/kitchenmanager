import XCTest
@testable import KitchenManager

@MainActor
final class InventoryConsumptionPlannerTests: XCTestCase {
    private let planner = InventoryConsumptionPlanner()

    private func recipe(title: String, ingredients: [String]) -> Recipe {
        Recipe(id: UUID().uuidString, title: title, cookingTime: nil, difficulty: nil, tags: [], ingredients: ingredients, steps: ["步骤"])
    }

    private func item(_ name: String, quantity: Double, unit: String, expiryDate: Date? = nil) -> InventoryItem {
        InventoryItem(name: name, quantity: quantity, unit: unit, expiryDate: expiryDate, createdAt: Date())
    }

    private func input(_ recipe: Recipe, servings: Int = 1) -> InventoryConsumptionPlanner.RecipeConsumptionInput {
        .init(recipe: recipe, servings: servings)
    }

    // MARK: - Normal deduction

    func test_singleRecipe_deductsSingleIngredient() {
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["番茄 2个"]))],
            inventory: [item("番茄", quantity: 5, unit: "个")]
        )
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].requiredQuantity, 2)
        XCTAssertEqual(drafts[0].currentQuantity, 5)
        XCTAssertEqual(drafts[0].consumedQuantity, 2)
        XCTAssertEqual(drafts[0].resultingQuantity, 3)
    }

    func test_singleRecipe_deductsMultipleIngredients() {
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["番茄 2个", "鸡蛋 3个"]))],
            inventory: [item("番茄", quantity: 5, unit: "个"), item("鸡蛋", quantity: 10, unit: "个")]
        )
        XCTAssertEqual(drafts.count, 2)
    }

    func test_directRecipeConfirmationUpdatesInventoryWithoutTodayPlan() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let kitchenStore = KitchenStore(userDefaults: defaults)
        let recipeStore = RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let directRecipe = recipe(title: "番茄料理", ingredients: ["番茄 2个"])
        kitchenStore.addInventory(name: "番茄", quantity: 5, unit: "个", expiryDate: nil)
        let store = CookConsumptionStore()

        store.buildDrafts(
            planIDs: [],
            recipe: directRecipe,
            kitchenStore: kitchenStore,
            recipeStore: recipeStore
        )
        XCTAssertTrue(store.confirm(
            planIDs: [],
            recipeID: directRecipe.id,
            recipeName: directRecipe.title,
            kitchenStore: kitchenStore,
            recipeStore: recipeStore
        ))

        XCTAssertEqual(try XCTUnwrap(kitchenStore.inventory.first).quantity, 3)
        XCTAssertEqual(try XCTUnwrap(kitchenStore.consumptionRecords.first).planIDs, [])
    }

    func test_todayPlanConsumptionResolvesBundledSampleWhenStoreIsEmpty() throws {
        let kitchenStore = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let recipeStore = RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let sample = Recipe.samples[0]
        kitchenStore.addPlan(recipe: sample)
        let planID = try XCTUnwrap(kitchenStore.plans.first?.id)
        let store = CookConsumptionStore()

        store.buildDrafts(planIDs: [planID], kitchenStore: kitchenStore, recipeStore: recipeStore)

        XCTAssertFalse(store.drafts.isEmpty)
        XCTAssertTrue(store.unresolvedPlanNames.isEmpty)
    }

    func test_multipleRecipes_shareDeductionOfSameIngredient() {
        let drafts = planner.plan(
            for: [
                input(recipe(title: "菜1", ingredients: ["鸡胸肉 300g"])),
                input(recipe(title: "菜2", ingredients: ["鸡胸肉 200g"]))
            ],
            inventory: [item("鸡胸肉", quantity: 1000, unit: "g")]
        )
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].requiredQuantity, 500)
        XCTAssertEqual(drafts[0].resultingQuantity, 500)
    }

    // MARK: - Unit conversion

    func test_inventoryInKg_recipeInGrams_convertsCorrectly() {
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["面粉 500g"]))],
            inventory: [item("面粉", quantity: 2, unit: "kg")]
        )
        XCTAssertEqual(drafts[0].currentQuantity ?? 0, 2000, accuracy: 0.001)
        XCTAssertEqual(drafts[0].consumedQuantity ?? 0, 500, accuracy: 0.001)
        XCTAssertEqual(drafts[0].resultingQuantity ?? 0, 1500, accuracy: 0.001)
    }

    func test_inventoryInLiters_recipeInMilliliters_convertsCorrectly() {
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["牛奶 250ml"]))],
            inventory: [item("牛奶", quantity: 1, unit: "l")]
        )
        XCTAssertEqual(drafts[0].currentQuantity ?? 0, 1000, accuracy: 0.001)
        XCTAssertEqual(drafts[0].resultingQuantity ?? 0, 750, accuracy: 0.001)
    }

    func test_sameUnit_noConversionNeeded() {
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["番茄 2个"]))],
            inventory: [item("番茄", quantity: 5, unit: "个")]
        )
        XCTAssertEqual(drafts[0].currentQuantity, 5)
    }

    func test_incompatibleUnits_treatedAsNoMatch_forQuantityPurposes() {
        // Inventory exists under the same normalized name but in an
        // unconvertible unit ("个" vs the recipe's "克"); availableQuantity
        // for that requirement's unit must come back nil rather than a wrong
        // number, and the item is still matched (so the UI can flag it) but
        // with no usable current quantity.
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["鸡蛋 300克"]))],
            inventory: [item("鸡蛋", quantity: 6, unit: "个")]
        )
        XCTAssertEqual(drafts.count, 1)
        XCTAssertNotNil(drafts[0].matchedInventoryID, "still matched by name even though units are incompatible")
        XCTAssertNil(drafts[0].currentQuantity, "no usable quantity when units cannot be converted")
    }

    func test_ingredientWithNoUnit_sumsRawQuantities() {
        // "生菜" (not "盐") on purpose: Recipe's own classifier reclassifies
        // seasoning names like 盐/鱼露 into `.seasonings`, which this planner
        // never reads (only `recipe.ingredients`) — 生菜 stays a normal
        // ingredient so this actually exercises the planner.
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["生菜 少许"]))],
            inventory: [item("生菜", quantity: 1, unit: "包")]
        )
        // "少许" has no numeric quantity/unit, so requiredUnit is nil and
        // availableQuantity sums raw inventory quantities directly.
        XCTAssertEqual(drafts[0].currentQuantity, 1)
    }

    // MARK: - Insufficient inventory

    func test_partialInventory_consumesWhatIsAvailable() {
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["番茄 10个"]))],
            inventory: [item("番茄", quantity: 3, unit: "个")]
        )
        XCTAssertEqual(drafts[0].consumedQuantity, 3)
        XCTAssertEqual(drafts[0].resultingQuantity, 0)
    }

    func test_noInventoryAtAll_setsNotFoundWarning_noMatchedID() {
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["番茄 2个"]))],
            inventory: []
        )
        XCTAssertNil(drafts[0].matchedInventoryID)
        XCTAssertNotNil(drafts[0].warning)
        XCTAssertTrue(drafts[0].warning?.contains("没有找到") ?? false)
    }

    func test_multipleBatches_combineToSatisfyRequirement() {
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["番茄 10个"]))],
            inventory: [
                item("番茄", quantity: 4, unit: "个", expiryDate: DateComponents(calendar: .current, year: 2026, month: 1, day: 5).date),
                item("番茄", quantity: 6, unit: "个", expiryDate: DateComponents(calendar: .current, year: 2026, month: 1, day: 10).date)
            ]
        )
        // `currentQuantity` sums matching batches for display purposes.
        XCTAssertEqual(drafts[0].currentQuantity, 10)
    }

    func test_matchingInventory_picksEarliestExpiringBatchFirst() {
        // InventoryConsumptionPlanner.matchingInventory sorts by remainingDays
        // ascending, so the first-matched (and thus displayed) batch id is
        // the earliest-expiring one — verified against the item ids directly.
        let soonest = item("番茄", quantity: 4, unit: "个", expiryDate: DateComponents(calendar: .current, year: 2026, month: 1, day: 3).date)
        let later = item("番茄", quantity: 6, unit: "个", expiryDate: DateComponents(calendar: .current, year: 2026, month: 1, day: 20).date)
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["番茄 2个"]))],
            inventory: [later, soonest]
        )
        XCTAssertEqual(drafts[0].matchedInventoryID, soonest.id, "the earliest-expiring batch must be the one referenced first")
    }

    // MARK: - Name matching (via IngredientNormalizer)

    func test_jiXiongRou_matchesJiXiongRouInventory_exactNormalizedName() {
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["鸡胸肉 200g"]))],
            inventory: [item("鸡胸肉", quantity: 500, unit: "g")]
        )
        XCTAssertNotNil(drafts[0].matchedInventoryID)
    }

    func test_fanQie_matchesXiHongShiInventory_viaAlias() {
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["番茄 2个"]))],
            inventory: [item("西红柿", quantity: 5, unit: "个")]
        )
        XCTAssertNotNil(drafts[0].matchedInventoryID, "西红柿 normalizes to 番茄, so it must match")
    }

    func test_niuRouJiang_doesNotMatchNiuRouInventory() {
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["牛肉酱 1勺"]))],
            inventory: [item("牛肉", quantity: 500, unit: "g")]
        )
        XCTAssertNil(drafts[0].matchedInventoryID, "牛肉酱 must not match 牛肉 inventory")
    }

    func test_xiaJiang_doesNotMatchXiaInventory() {
        // "虾酱" (not "鱼露"): "鱼露" is in Recipe's own directSeasoningNames
        // list and gets reclassified into `.seasonings` before this planner
        // ever sees it; "虾酱" is not, so it stays in `.ingredients` and
        // actually exercises the planner's name-matching guard.
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["虾酱 1勺"]))],
            inventory: [item("虾", quantity: 500, unit: "g")]
        )
        XCTAssertNil(drafts[0].matchedInventoryID, "虾酱 must not match 虾 inventory")
    }

    func test_cong_andXiaoCong_matchTheSameInventoryEntry() {
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["小葱 1根"]))],
            inventory: [item("葱", quantity: 3, unit: "根")]
        )
        XCTAssertNotNil(drafts[0].matchedInventoryID, "小葱 normalizes to 葱")
    }

    // MARK: - Abnormal input

    func test_recipeWithNoIngredients_producesNoDrafts() {
        let drafts = planner.plan(for: [input(recipe(title: "菜", ingredients: []))], inventory: [])
        XCTAssertTrue(drafts.isEmpty)
    }

    func test_inventoryWithZeroQuantity_isNotAvailable_treatedAsNotFound() {
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["番茄 2个"]))],
            inventory: [item("番茄", quantity: 0, unit: "个")]
        )
        XCTAssertNil(drafts[0].matchedInventoryID, "a zero-quantity item is not `isAvailable` and must not match")
    }

    func test_duplicateIngredientLines_mergeIntoOneRequirement() {
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["番茄 2个", "番茄 3个"]))],
            inventory: [item("番茄", quantity: 10, unit: "个")]
        )
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].requiredQuantity, 5)
    }

    func test_vagueQuantityIngredient_setsWarning() {
        let drafts = planner.plan(
            for: [input(recipe(title: "菜", ingredients: ["生菜 适量"]))],
            inventory: [item("生菜", quantity: 1, unit: "包")]
        )
        XCTAssertNotNil(drafts[0].warning)
    }

    // MARK: - Special Plan Dish Consumption

    func test_specialPlanDishDraft_usesRecipeQuantitiesAsWritten_notMultipliedByPeopleCount() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let kitchenStore = KitchenStore(userDefaults: defaults)
        let recipeStore = RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let specialRecipe = recipe(title: "大盘鸡", ingredients: ["鸡肉 500g", "土豆 2个"])
        kitchenStore.addInventory(name: "鸡肉", quantity: 1000, unit: "g", expiryDate: nil)
        kitchenStore.addInventory(name: "土豆", quantity: 5, unit: "个", expiryDate: nil)

        let specialPlanID = UUID()
        let dishID = UUID()
        let store = CookConsumptionStore()

        // Target with 10 people in the plan must STILL use exact recipe quantities (500g and 2个),
        // NOT multiplied by peopleCount (which would be 5000g and 20个).
        store.buildDrafts(
            target: .specialPlanDish(
                planID: specialPlanID,
                dishID: dishID,
                planTitleSnapshot: "十人聚餐",
                recipe: specialRecipe
            ),
            kitchenStore: kitchenStore,
            recipeStore: recipeStore
        )

        XCTAssertEqual(store.drafts.count, 2)
        let chicken = try XCTUnwrap(store.drafts.first { $0.ingredientName == "鸡肉" })
        XCTAssertEqual(chicken.requiredQuantity, 500)
        XCTAssertEqual(chicken.consumedQuantity, 500)

        let potato = try XCTUnwrap(store.drafts.first { $0.ingredientName == "土豆" })
        XCTAssertEqual(potato.requiredQuantity, 2)
        XCTAssertEqual(potato.consumedQuantity, 2)
    }

    func test_specialPlanDish_idempotencyPreventsDuplicateDeduction() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let kitchenStore = KitchenStore(userDefaults: defaults)
        let recipeStore = RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let dishRecipe = recipe(title: "麻婆豆腐", ingredients: ["豆腐 1盒"])
        kitchenStore.addInventory(name: "豆腐", quantity: 5, unit: "盒", expiryDate: nil)

        let specialPlanID = UUID()
        let dishID = UUID()
        let target = CookConsumptionTarget.specialPlanDish(
            planID: specialPlanID,
            dishID: dishID,
            planTitleSnapshot: "周末聚会",
            recipe: dishRecipe
        )

        let store1 = CookConsumptionStore()
        store1.buildDrafts(target: target, kitchenStore: kitchenStore, recipeStore: recipeStore)
        XCTAssertTrue(store1.confirm(
            target: target,
            recipeID: dishRecipe.id,
            recipeName: dishRecipe.title,
            kitchenStore: kitchenStore,
            recipeStore: recipeStore
        ))

        XCTAssertEqual(kitchenStore.inventory.first?.quantity, 4)
        XCTAssertTrue(kitchenStore.hasConsumedSpecialPlanDish(planID: specialPlanID, dishID: dishID))
        let firstRecord = try XCTUnwrap(kitchenStore.consumptionRecords.first)
        XCTAssertEqual(firstRecord.specialPlanID, specialPlanID)
        XCTAssertEqual(firstRecord.specialPlanDishID, dishID)
        XCTAssertEqual(firstRecord.specialPlanTitleSnapshot, "周末聚会")

        // Second attempt for the exact same special plan dish must NOT deduct again
        let store2 = CookConsumptionStore()
        store2.buildDrafts(target: target, kitchenStore: kitchenStore, recipeStore: recipeStore)
        XCTAssertTrue(store2.isTargetAlreadySatisfied(target: target, kitchenStore: kitchenStore))
        XCTAssertTrue(store2.confirm(
            target: target,
            recipeID: dishRecipe.id,
            recipeName: dishRecipe.title,
            kitchenStore: kitchenStore,
            recipeStore: recipeStore
        ))
        // Quantity remains 4, not 3
        XCTAssertEqual(kitchenStore.inventory.first?.quantity, 4)
        XCTAssertEqual(kitchenStore.consumptionRecords.count, 1)
    }

    func test_sameRecipeInDifferentSpecialPlansMayLegitimatelyDeductSeparately() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let kitchenStore = KitchenStore(userDefaults: defaults)
        let recipeStore = RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let dishRecipe = recipe(title: "麻婆豆腐", ingredients: ["豆腐 1盒"])
        kitchenStore.addInventory(name: "豆腐", quantity: 5, unit: "盒", expiryDate: nil)

        let plan1 = UUID(), dish1 = UUID()
        let plan2 = UUID(), dish2 = UUID()

        let target1 = CookConsumptionTarget.specialPlanDish(planID: plan1, dishID: dish1, planTitleSnapshot: "聚餐A", recipe: dishRecipe)
        let target2 = CookConsumptionTarget.specialPlanDish(planID: plan2, dishID: dish2, planTitleSnapshot: "聚餐B", recipe: dishRecipe)

        let store1 = CookConsumptionStore()
        store1.buildDrafts(target: target1, kitchenStore: kitchenStore, recipeStore: recipeStore)
        _ = store1.confirm(target: target1, recipeID: dishRecipe.id, recipeName: dishRecipe.title, kitchenStore: kitchenStore, recipeStore: recipeStore)
        XCTAssertEqual(kitchenStore.inventory.first?.quantity, 4)

        let store2 = CookConsumptionStore()
        store2.buildDrafts(target: target2, kitchenStore: kitchenStore, recipeStore: recipeStore)
        _ = store2.confirm(target: target2, recipeID: dishRecipe.id, recipeName: dishRecipe.title, kitchenStore: kitchenStore, recipeStore: recipeStore)
        // Deducts second time because it's a different event/dish target
        XCTAssertEqual(kitchenStore.inventory.first?.quantity, 3)
        XCTAssertEqual(kitchenStore.consumptionRecords.count, 2)
    }

    func test_undoneSpecialPlanReceiptAllowsLaterReDeduction() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let kitchenStore = KitchenStore(userDefaults: defaults)
        let recipeStore = RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let dishRecipe = recipe(title: "麻婆豆腐", ingredients: ["豆腐 1盒"])
        kitchenStore.addInventory(name: "豆腐", quantity: 5, unit: "盒", expiryDate: nil)

        let planID = UUID(), dishID = UUID()
        let target = CookConsumptionTarget.specialPlanDish(planID: planID, dishID: dishID, planTitleSnapshot: "聚会", recipe: dishRecipe)

        let store1 = CookConsumptionStore()
        store1.buildDrafts(target: target, kitchenStore: kitchenStore, recipeStore: recipeStore)
        _ = store1.confirm(target: target, recipeID: dishRecipe.id, recipeName: dishRecipe.title, kitchenStore: kitchenStore, recipeStore: recipeStore)
        XCTAssertEqual(kitchenStore.inventory.first?.quantity, 4)
        XCTAssertTrue(kitchenStore.hasConsumedSpecialPlanDish(planID: planID, dishID: dishID))

        // Undo receipt
        let record = try XCTUnwrap(kitchenStore.consumptionRecords.first)
        kitchenStore.undoConsumption(record)
        XCTAssertEqual(kitchenStore.inventory.first?.quantity, 5)
        XCTAssertFalse(kitchenStore.hasConsumedSpecialPlanDish(planID: planID, dishID: dishID), "undone receipt must not block subsequent consumption")

        // Now retry consumption
        let store2 = CookConsumptionStore()
        store2.buildDrafts(target: target, kitchenStore: kitchenStore, recipeStore: recipeStore)
        XCTAssertFalse(store2.isTargetAlreadySatisfied(target: target, kitchenStore: kitchenStore))
        _ = store2.confirm(target: target, recipeID: dishRecipe.id, recipeName: dishRecipe.title, kitchenStore: kitchenStore, recipeStore: recipeStore)
        XCTAssertEqual(kitchenStore.inventory.first?.quantity, 4)
    }

    func test_specialPlanDish_partialFailureRetainsInventoryAndAllowsRetryWithoutDoubleDeduction() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let kitchenStore = KitchenStore(userDefaults: defaults)
        let recipeStore = RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let dishRecipe = recipe(title: "麻婆豆腐", ingredients: ["豆腐 1盒"])
        kitchenStore.addInventory(name: "豆腐", quantity: 5, unit: "盒", expiryDate: nil)

        let planID = UUID(), dishID = UUID()
        let target = CookConsumptionTarget.specialPlanDish(planID: planID, dishID: dishID, planTitleSnapshot: "聚会", recipe: dishRecipe)

        let store = CookConsumptionStore()
        store.buildDrafts(target: target, kitchenStore: kitchenStore, recipeStore: recipeStore)

        // First confirmation succeeds on inventory deduction
        XCTAssertTrue(store.confirm(target: target, recipeID: dishRecipe.id, recipeName: dishRecipe.title, kitchenStore: kitchenStore, recipeStore: recipeStore))
        XCTAssertEqual(kitchenStore.inventory.first?.quantity, 4)
        XCTAssertTrue(kitchenStore.hasConsumedSpecialPlanDish(planID: planID, dishID: dishID))

        // Injected dish state failure outcome
        store.setCompletionOutcome(.dishStateSaveFailed(message: "菜品完成状态未保存，请重试。"))
        XCTAssertEqual(store.completionOutcome, .dishStateSaveFailed(message: "菜品完成状态未保存，请重试。"))

        // Inventory must remain deducted, receipt must remain active, NOT undone
        XCTAssertEqual(kitchenStore.inventory.first?.quantity, 4)
        XCTAssertEqual(kitchenStore.consumptionRecords.count, 1)
        XCTAssertFalse(kitchenStore.consumptionRecords[0].isUndone)

        // Retry attempt: is already satisfied, confirms without second deduction
        let retryStore = CookConsumptionStore()
        retryStore.buildDrafts(target: target, kitchenStore: kitchenStore, recipeStore: recipeStore)
        XCTAssertTrue(retryStore.isTargetAlreadySatisfied(target: target, kitchenStore: kitchenStore))
        XCTAssertTrue(retryStore.confirm(target: target, recipeID: dishRecipe.id, recipeName: dishRecipe.title, kitchenStore: kitchenStore, recipeStore: recipeStore))
        XCTAssertEqual(kitchenStore.inventory.first?.quantity, 4)
        XCTAssertEqual(kitchenStore.consumptionRecords.count, 1)
    }

    func test_specialPlanDish_withoutRecipeAndWithoutActiveReceipt_refusesConfirmation() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let kitchenStore = KitchenStore(userDefaults: defaults)
        let recipeStore = RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        kitchenStore.addInventory(name: "豆腐", quantity: 5, unit: "盒", expiryDate: nil)

        let planID = UUID(), dishID = UUID()
        // Target has recipe == nil and no active receipt exists
        let target = CookConsumptionTarget.specialPlanDish(planID: planID, dishID: dishID, planTitleSnapshot: "聚会", recipe: nil)

        let store = CookConsumptionStore()
        store.buildDrafts(target: target, kitchenStore: kitchenStore, recipeStore: recipeStore)
        XCTAssertFalse(store.confirm(target: target, recipeID: nil, recipeName: "未知菜品", kitchenStore: kitchenStore, recipeStore: recipeStore), "Must refuse confirmation when recipe is nil and no receipt exists")
        XCTAssertEqual(kitchenStore.inventory.first?.quantity, 5, "Inventory must remain unchanged")
        XCTAssertEqual(kitchenStore.consumptionRecords.count, 0, "No receipt must be fabricated")
    }

    func test_specialPlanDish_realPersistenceFailure_leavesReceiptAndDeductionActiveAndRetriesSuccessfully() throws {
        struct InjectedFailure: Error {}
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let inventory = InventoryPersistenceFactory.isolatedInMemory()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let kitchenStore = KitchenStore(
            userDefaults: defaults,
            inventoryPersistence: inventory,
            shoppingListPersistence: bundle.shoppingList,
            todayPlanPersistence: bundle.todayPlan,
            consumptionPersistence: bundle.consumption,
            specialPlanPersistence: bundle.specialPlans
        )
        let recipeStore = RecipeStore(userDefaults: defaults)
        let dishRecipe = recipe(title: "麻婆豆腐", ingredients: ["豆腐 1盒"])
        kitchenStore.addInventory(name: "豆腐", quantity: 5, unit: "盒", expiryDate: nil)

        let dish = SpecialPlanDish(recipeID: dishRecipe.id, recipeName: dishRecipe.title, isCooked: false)
        var plan = SpecialPlan(title: "家宴", scheduledAt: Date(), peopleCount: 4, usesHomeInventory: true, dishes: [dish])
        kitchenStore.addSpecialPlan(plan)
        let planID = plan.id
        let dishID = dish.id

        let target = CookConsumptionTarget.specialPlanDish(planID: planID, dishID: dishID, planTitleSnapshot: "家宴", recipe: dishRecipe)
        let store = CookConsumptionStore()
        store.buildDrafts(target: target, kitchenStore: kitchenStore, recipeStore: recipeStore)

        // 1. Consumption succeeds
        XCTAssertTrue(store.confirm(target: target, recipeID: dishRecipe.id, recipeName: dishRecipe.title, kitchenStore: kitchenStore, recipeStore: recipeStore))
        XCTAssertEqual(kitchenStore.inventory.first?.quantity, 4)
        XCTAssertTrue(kitchenStore.hasConsumedSpecialPlanDish(planID: planID, dishID: dishID))

        // 2. Inject one-shot save failure into SpecialPlanPersistence
        kitchenStore.injectSpecialPlanPersistenceFailureForTesting(InjectedFailure())

        // 3. Attempt persist-first dish completion
        let outcome = kitchenStore.setSpecialPlanDishCookedPersisted(planID: planID, dishID: dishID, isCooked: true)
        guard case .persistenceFailed = outcome else {
            return XCTFail("Expected .persistenceFailed, got \(outcome)")
        }
        // Dish must remain unfinished in published memory
        XCTAssertEqual(kitchenStore.specialPlans.first?.dishes.first?.isCooked, false)
        // Inventory remains deducted and receipt remains active
        XCTAssertEqual(kitchenStore.inventory.first?.quantity, 4)
        XCTAssertEqual(kitchenStore.consumptionRecords.count, 1)
        XCTAssertFalse(kitchenStore.consumptionRecords[0].isUndone)

        // 4. Retry after failure (failNextReplaceSaveForTesting was consumed, so next save succeeds)
        let retryStore = CookConsumptionStore()
        retryStore.buildDrafts(target: target, kitchenStore: kitchenStore, recipeStore: recipeStore)
        XCTAssertTrue(retryStore.isTargetAlreadySatisfied(target: target, kitchenStore: kitchenStore))
        XCTAssertTrue(retryStore.confirm(target: target, recipeID: dishRecipe.id, recipeName: dishRecipe.title, kitchenStore: kitchenStore, recipeStore: recipeStore))
        // No double deduction
        XCTAssertEqual(kitchenStore.inventory.first?.quantity, 4)
        XCTAssertEqual(kitchenStore.consumptionRecords.count, 1)

        // 5. Completion persistence now succeeds
        let retryOutcome = kitchenStore.setSpecialPlanDishCookedPersisted(planID: planID, dishID: dishID, isCooked: true)
        guard case .saved(let updatedPlan) = retryOutcome else {
            return XCTFail("Expected .saved on retry, got \(retryOutcome)")
        }
        XCTAssertEqual(updatedPlan.dishes.first?.isCooked, true)
        XCTAssertEqual(kitchenStore.specialPlans.first?.dishes.first?.isCooked, true)
    }

    func test_specialPlanDish_missingRecipeCompletesWithoutFabricatedDeduction() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let kitchenStore = KitchenStore(userDefaults: defaults)
        let plan = SpecialPlan(
            title: "家宴",
            scheduledAt: Date(),
            peopleCount: 4,
            usesHomeInventory: true,
            dishes: [
                SpecialPlanDish(recipeID: "missing-recipe-id", recipeName: "已删菜谱菜")
            ]
        )
        kitchenStore.addSpecialPlan(plan)
        kitchenStore.addInventory(name: "豆腐", quantity: 5, unit: "块", expiryDate: nil)

        let dishID = plan.dishes[0].id
        let outcome = kitchenStore.setSpecialPlanDishCookedPersisted(planID: plan.id, dishID: dishID, isCooked: true)
        guard case .saved(let updatedPlan) = outcome else {
            return XCTFail("Expected .saved, got \(outcome)")
        }
        XCTAssertEqual(updatedPlan.dishes[0].isCooked, true)
        // Inventory is completely untouched, no consumption record fabricated
        XCTAssertEqual(kitchenStore.inventory.first?.quantity, 5)
        XCTAssertEqual(kitchenStore.consumptionRecords.count, 0)
        XCTAssertFalse(kitchenStore.hasConsumedSpecialPlanDish(planID: plan.id, dishID: dishID))
    }
}

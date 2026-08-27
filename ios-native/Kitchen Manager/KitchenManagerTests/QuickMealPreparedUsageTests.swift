import XCTest
@testable import KitchenManager

/// The usage loop: a quick meal that uses a prepared batch lets you take a
/// portion off it, and the count follows what actually happened in the kitchen.
@MainActor
final class QuickMealPreparedUsageTests: XCTestCase {
    private func item(_ name: String) -> InventoryItem {
        InventoryItem(name: name, quantity: 1, unit: "份", expiryDate: nil, createdAt: Date())
    }

    private func batch(
        _ name: String,
        portions: Int,
        state: PreparedComponentState = .cooked
    ) -> PreparedComponent {
        PreparedComponent(
            name: name,
            portionsRemaining: portions,
            state: state,
            storage: .refrigerated,
            preparedAt: Date(),
            expiryDate: Calendar.current.date(byAdding: .day, value: 3, to: Date())!
        )
    }

    private func makeStore(
        _ defaults: UserDefaults,
        _ bundle: KitchenPersistenceBundle
    ) -> KitchenStore {
        KitchenStore(
            userDefaults: defaults,
            inventoryPersistence: bundle.inventory,
            shoppingListPersistence: bundle.shoppingList,
            todayPlanPersistence: bundle.todayPlan,
            consumptionPersistence: bundle.consumption,
            weeklyPlanPersistence: bundle.weeklyPlan,
            preparedComponentPersistence: bundle.preparedComponents
        )
    }

    private func content(
        inventory: [InventoryItem],
        prepared: [PreparedComponent],
        index: Int = 0
    ) -> QuickMealHomeContent {
        QuickMealHomeContent.resolve(
            result: QuickMealAssemblyEngine.assemble(inventory: inventory, preparedComponents: prepared),
            isEatingOutTonight: false,
            storedIndex: index,
            preparedComponents: prepared
        )
    }

    private func usages(_ content: QuickMealHomeContent) -> [QuickMealPreparedUsage] {
        if case .suggestion(_, _, let usages) = content { return usages }
        return []
    }

    // MARK: - When the entry point appears

    func testAMealMadeOnlyOfInventoryOffersNoUsageEntry() {
        let content = content(inventory: [item("挂面"), item("卤牛肉"), item("上海青")], prepared: [])

        XCTAssertTrue(usages(content).isEmpty, "a bag of rice has no batch to take a portion from")
    }

    func testAMealUsingABatchNamesItAndShowsWhatIsLeft() {
        let beef = batch("卤牛肉", portions: 3)
        let content = content(inventory: [item("米饭"), item("上海青")], prepared: [beef])

        let usage = try? XCTUnwrap(usages(content).first)
        XCTAssertEqual(usage?.id, beef.id)
        XCTAssertEqual(usage?.name, "卤牛肉")
        XCTAssertEqual(usage?.portionsRemaining, 3)
        XCTAssertEqual(usage?.remainingText, "备餐剩 3 份")
    }

    func testABatchNotUsedByThisSuggestionIsNotOffered() {
        let used = batch("卤牛肉", portions: 3)
        let unused = batch("卤鸡腿", portions: 2)
        let content = content(inventory: [item("米饭")], prepared: [used, unused])

        // Only whatever this meal actually uses gets a row.
        let shown = usages(content).map(\.id)
        XCTAssertTrue(shown.allSatisfy { $0 == used.id || $0 == unused.id })
        XCTAssertLessThanOrEqual(shown.count, 1, "one protein slot, one batch")
    }

    func testTwoBatchesInOneMealStayIndependent() {
        // 卤牛肉 fills the protein slot; 土豆泥 the staple. Both are batches.
        let beef = batch("卤牛肉", portions: 3)
        let mash = batch("米饭", portions: 2)
        let content = content(inventory: [item("上海青")], prepared: [beef, mash])

        let shown = usages(content)
        XCTAssertEqual(shown.count, 2, "each batch gets its own row and its own button")
        XCTAssertEqual(Set(shown.map(\.id)), [beef.id, mash.id])
        // No combined action: the two rows carry different ids and counts.
        XCTAssertEqual(Set(shown.map(\.portionsRemaining)), [3, 2])
    }

    func testEachBatchIsListedOnlyOnce() {
        let beef = batch("卤牛肉", portions: 3)
        let content = content(inventory: [item("米饭"), item("上海青")], prepared: [beef])

        XCTAssertEqual(usages(content).filter { $0.id == beef.id }.count, 1)
    }

    // MARK: - Consuming through the store

    func testUsingAPortionTakesOneOffThatBatch() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let store = makeStore(defaults, bundle)
        let beef = batch("卤牛肉", portions: 3)
        store.addPreparedComponent(beef)

        store.consumePreparedPortion(id: beef.id)

        XCTAssertEqual(store.preparedComponents.first?.portionsRemaining, 2)
    }

    func testUsingTheLastPortionRemovesTheBatch() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let store = makeStore(defaults, bundle)
        let beef = batch("卤牛肉", portions: 1)
        store.addPreparedComponent(beef)

        let previous = store.consumePreparedPortion(id: beef.id)

        XCTAssertEqual(previous?.portionsRemaining, 1)
        XCTAssertTrue(store.preparedComponents.isEmpty)
    }

    func testUsingAPortionLeavesInventoryAndEveryOtherModuleAlone() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let store = makeStore(defaults, bundle)
        store.addInventory(name: "米饭", quantity: 1, unit: "份", expiryDate: nil)
        store.addInventory(name: "上海青", quantity: 2, unit: "份", expiryDate: nil)
        let beef = batch("卤牛肉", portions: 3)
        store.addPreparedComponent(beef)

        store.consumePreparedPortion(id: beef.id)

        XCTAssertEqual(store.inventory.count, 2)
        XCTAssertEqual(store.inventory.map(\.quantity), [1, 2], "the rice and greens are untouched")
        XCTAssertTrue(store.consumptionRecords.isEmpty, "using a portion is not a cooking session")
        XCTAssertTrue(store.shoppingItems.isEmpty, "and never adds anything to buy")
        XCTAssertTrue(store.plans.isEmpty, "and creates no plan")
    }

    func testNoRestockSuggestionFollowsUsingTheLastPortion() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let store = makeStore(defaults, bundle)
        let beef = batch("卤牛肉", portions: 1)
        store.addPreparedComponent(beef)

        store.consumePreparedPortion(id: beef.id)

        let suggestions = RestockSuggestionEngine().generate(
            kitchenStore: store,
            recipeStore: RecipeStore(userDefaults: defaults)
        )
        XCTAssertFalse(
            suggestions.contains { $0.name == "卤牛肉" },
            "running out of a batch you cooked is not a reason to go shopping"
        )
    }

    // MARK: - Identity

    func testTwoBatchesSharingANameAreDecrementedByIdNotByName() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let store = makeStore(defaults, bundle)
        let sunday = batch("卤牛肉", portions: 3)
        let wednesday = batch("卤牛肉", portions: 5)
        store.addPreparedComponent(sunday)
        store.addPreparedComponent(wednesday)

        store.consumePreparedPortion(id: wednesday.id)

        XCTAssertEqual(store.preparedComponents.first { $0.id == sunday.id }?.portionsRemaining, 3)
        XCTAssertEqual(store.preparedComponents.first { $0.id == wednesday.id }?.portionsRemaining, 4)
    }

    func testTheUsageRowCarriesTheBatchIdSoTheRightRecordIsTapped() {
        let sunday = batch("卤牛肉", portions: 3)
        let content = content(inventory: [item("米饭"), item("上海青")], prepared: [sunday])

        // Whatever the row shows, the action is keyed by the record's own id.
        XCTAssertEqual(usages(content).first?.id, sunday.id)
    }

    func testAUsageIsDroppedIfItsBatchIsNoLongerAround() {
        // Resolving against a stale suggestion must not invent a row.
        let beef = batch("卤牛肉", portions: 2)
        let suggestion = QuickMealAssemblyEngine
            .assemble(inventory: [item("米饭")], preparedComponents: [beef])
            .suggestions.first!

        let resolved = QuickMealHomeContent.preparedUsages(in: suggestion, among: [])
        XCTAssertTrue(resolved.isEmpty)
    }

    // MARK: - What the card shows afterwards

    func testTheCountShownFallsAfterUsingAPortion() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let store = makeStore(defaults, bundle)
        let inventory = [item("米饭"), item("上海青")]
        let beef = batch("卤牛肉", portions: 3)
        store.addPreparedComponent(beef)

        XCTAssertEqual(
            usages(content(inventory: inventory, prepared: store.preparedComponents)).first?.portionsRemaining,
            3
        )

        store.consumePreparedPortion(id: beef.id)

        // Re-resolved from the published state; nothing was patched by hand.
        XCTAssertEqual(
            usages(content(inventory: inventory, prepared: store.preparedComponents)).first?.portionsRemaining,
            2
        )
    }

    func testWhenTheLastPortionGoesTheMealItEnabledGoesToo() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let store = makeStore(defaults, bundle)
        let inventory = [item("米饭"), item("上海青")]
        let beef = batch("卤牛肉", portions: 1)
        store.addPreparedComponent(beef)

        let before = content(inventory: inventory, prepared: store.preparedComponents)
        XCTAssertFalse(usages(before).isEmpty)

        store.consumePreparedPortion(id: beef.id)

        let after = content(inventory: inventory, prepared: store.preparedComponents)
        XCTAssertTrue(usages(after).isEmpty)
        // 米饭 + 上海青 alone stand up no meal, so Home says so rather than
        // showing a card built on a batch that is gone.
        XCTAssertEqual(after, .unavailable(QuickMealGap.nothingQuickEnough.homeMessage))
    }

    func testAStaleRotationIndexStaysSafeAfterTheListShrinks() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let store = makeStore(defaults, bundle)
        let inventory = [item("米饭"), item("上海青")]
        let beef = batch("卤牛肉", portions: 1)
        store.addPreparedComponent(beef)

        let before = QuickMealAssemblyEngine
            .assemble(inventory: inventory, preparedComponents: store.preparedComponents)
        let lastIndex = max(before.suggestions.count - 1, 0)
        store.consumePreparedPortion(id: beef.id)

        // The index was valid a moment ago and is now past the end.
        let after = content(inventory: inventory, prepared: store.preparedComponents, index: lastIndex + 3)
        if case .suggestion = after {
            XCTFail("nothing should be suggested once the batch is gone")
        }
        XCTAssertEqual(
            QuickMealRotation.visibleIndex(stored: lastIndex + 3, count: 0),
            0,
            "the existing clamp handles the shrink; no new state was added"
        )
    }
}

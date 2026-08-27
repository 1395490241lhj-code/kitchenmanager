import XCTest
@testable import KitchenManager

/// Taking a portion from a component meal, and the hint the editor shows when a
/// batch's name places nowhere.
@MainActor
final class ComponentMealUsageTests: XCTestCase {
    private func item(_ name: String) -> InventoryItem {
        InventoryItem(name: name, quantity: 2, unit: "份", expiryDate: nil, createdAt: Date())
    }

    private func batch(_ name: String, portions: Int) -> PreparedComponent {
        PreparedComponent(
            name: name,
            portionsRemaining: portions,
            state: .cooked,
            storage: .refrigerated,
            preparedAt: Date(),
            expiryDate: Calendar.current.date(byAdding: .day, value: 3, to: Date())!
        )
    }

    private func makeStore() -> KitchenStore {
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        return KitchenStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            inventoryPersistence: bundle.inventory,
            shoppingListPersistence: bundle.shoppingList,
            todayPlanPersistence: bundle.todayPlan,
            consumptionPersistence: bundle.consumption,
            weeklyPlanPersistence: bundle.weeklyPlan,
            preparedComponentPersistence: bundle.preparedComponents
        )
    }

    private func usages(_ store: KitchenStore) -> [PreparedPortionUsage] {
        let result = ComponentMealPolicy.assemble(
            inventory: store.inventory,
            preparedComponents: store.preparedComponents
        )
        guard let suggestion = result.suggestion else { return [] }
        return PreparedPortionUsage.resolve(
            sources: suggestion.componentSources,
            among: store.preparedComponents
        )
    }

    // MARK: - Only prepared batches are consumable

    func testOnlyThePreparedPartOfThePlateOffersAPortion() {
        let store = makeStore()
        store.addInventory(name: "红薯", quantity: 2, unit: "份", expiryDate: nil)
        store.addInventory(name: "西兰花", quantity: 2, unit: "份", expiryDate: nil)
        let thigh = batch("卤鸡腿", portions: 3)
        store.addPreparedComponent(thigh)

        let shown = usages(store)
        XCTAssertEqual(shown.count, 1, "the sweet potato and the broccoli have no portion model")
        XCTAssertEqual(shown.first?.id, thigh.id)
        XCTAssertEqual(shown.first?.remainingText, "备餐剩 3 份")
    }

    func testAPlateOfPureInventoryOffersNothing() {
        let store = makeStore()
        for name in ["米饭", "上海青", "卤牛肉"] {
            store.addInventory(name: name, quantity: 2, unit: "份", expiryDate: nil)
        }
        XCTAssertTrue(usages(store).isEmpty)
    }

    // MARK: - The one decrement

    func testUsingAPortionTakesOneOffAndLeavesTheRestOfThePlateAlone() {
        let store = makeStore()
        store.addInventory(name: "红薯", quantity: 2, unit: "份", expiryDate: nil)
        store.addInventory(name: "西兰花", quantity: 2, unit: "份", expiryDate: nil)
        let thigh = batch("卤鸡腿", portions: 3)
        store.addPreparedComponent(thigh)

        store.consumePreparedPortion(id: thigh.id)

        XCTAssertEqual(store.preparedComponents.first?.portionsRemaining, 2)
        XCTAssertEqual(usages(store).first?.portionsRemaining, 2)
        // Same store API Home uses; no second implementation exists.
        XCTAssertEqual(store.inventory.map(\.quantity), [2, 2], "inventory quantities are untouched")
        XCTAssertTrue(store.consumptionRecords.isEmpty)
        XCTAssertTrue(store.shoppingItems.isEmpty)
        XCTAssertTrue(store.plans.isEmpty)
    }

    func testUsingTheLastPortionRemovesTheBatchAndTheSuggestionWithIt() {
        let store = makeStore()
        store.addInventory(name: "红薯", quantity: 2, unit: "份", expiryDate: nil)
        store.addInventory(name: "西兰花", quantity: 2, unit: "份", expiryDate: nil)
        let thigh = batch("卤鸡腿", portions: 1)
        store.addPreparedComponent(thigh)
        XCTAssertFalse(usages(store).isEmpty)

        let previous = store.consumePreparedPortion(id: thigh.id)

        XCTAssertEqual(previous?.portionsRemaining, 1)
        XCTAssertTrue(store.preparedComponents.isEmpty)
        XCTAssertTrue(usages(store).isEmpty)
        // 红薯 + 西兰花 alone are not a plate, so the sheet falls to the gap.
        let after = ComponentMealPolicy.assemble(
            inventory: store.inventory,
            preparedComponents: store.preparedComponents
        )
        XCTAssertEqual(after.gaps, [.missingProtein])
    }

    func testTwoBatchesSharingANameAreStillToldApartById() {
        let store = makeStore()
        let sunday = batch("卤鸡腿", portions: 3)
        let wednesday = batch("卤鸡腿", portions: 5)
        store.addPreparedComponent(sunday)
        store.addPreparedComponent(wednesday)

        store.consumePreparedPortion(id: wednesday.id)

        XCTAssertEqual(store.preparedComponents.first { $0.id == sunday.id }?.portionsRemaining, 3)
        XCTAssertEqual(store.preparedComponents.first { $0.id == wednesday.id }?.portionsRemaining, 4)
    }

    // MARK: - The shared row's resolution rule

    func testTheSharedResolverIgnoresInventorySourcesAndDeduplicates() {
        let thigh = batch("卤鸡腿", portions: 2)
        let sources: [QuickMealCandidateSource] = [
            .inventory(UUID()),
            .preparedComponent(thigh.id),
            .preparedComponent(thigh.id)
        ]

        let resolved = PreparedPortionUsage.resolve(sources: sources, among: [thigh])
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.id, thigh.id)
    }

    func testASourceWhoseBatchIsGoneProducesNoRow() {
        let resolved = PreparedPortionUsage.resolve(
            sources: [.preparedComponent(UUID())],
            among: []
        )
        XCTAssertTrue(resolved.isEmpty)
    }

    func testQuickMealAndComponentMealResolveThroughTheSameRule() {
        let thigh = batch("卤鸡腿", portions: 4)
        let quick = QuickMealAssemblyEngine.assemble(
            inventory: [item("米饭")],
            preparedComponents: [thigh]
        )
        let fromQuick = QuickMealHomeContent.preparedUsages(in: quick.suggestions[0], among: [thigh])
        let direct = PreparedPortionUsage.resolve(
            sources: quick.suggestions[0].components.map(\.source),
            among: [thigh]
        )
        XCTAssertEqual(fromQuick, direct)
    }

    // MARK: - The editor's name hint

    func testANameThatPlacesNowhereGetsAHint() {
        XCTAssertTrue(PreparedComponentNameHint.needsHint(for: "周日备的那份"))
        XCTAssertTrue(PreparedComponentNameHint.needsHint(for: "那个"))
    }

    func testARecognisableNameGetsNoHint() {
        for name in ["鸡肉", "卤鸡腿", "腌鸡肉", "米饭", "西兰花"] {
            XCTAssertFalse(PreparedComponentNameHint.needsHint(for: name), "\(name) places fine")
        }
    }

    func testAFinishedDishNameGetsNoHintEvenWithoutARole() {
        // 剩菜 and 卤味 carry no role, but their form still lets Quick Meal use
        // them, so warning about them would be wrong.
        XCTAssertFalse(PreparedComponentNameHint.needsHint(for: "剩菜"))
        XCTAssertFalse(PreparedComponentNameHint.needsHint(for: "卤味"))
    }

    func testAnEmptyNameGetsNoHint() {
        XCTAssertFalse(PreparedComponentNameHint.needsHint(for: ""))
        XCTAssertFalse(PreparedComponentNameHint.needsHint(for: "   "))
    }

    func testTheHintNeverBlocksSaving() {
        // It is advisory: the record saves exactly as typed, with no role
        // invented on the user's behalf.
        let store = makeStore()
        let vague = batch("周日备的那份", portions: 2)
        store.addPreparedComponent(vague)

        XCTAssertEqual(store.preparedComponents.count, 1)
        XCTAssertEqual(store.preparedComponents.first?.name, "周日备的那份")
        XCTAssertTrue(PreparedComponentNameHint.needsHint(for: vague.name))
        XCTAssertFalse(PreparedComponentNameHint.message.isEmpty)
    }

    func testAnUnclassifiedBatchStillShowsOnTheMealPrepBoard() {
        // Being invisible to the assembling layers must not make it invisible
        // to the person who cooked it.
        let vague = batch("周日备的那份", portions: 2)
        let entries = MealPrepBoard.entries(from: [vague])
        XCTAssertEqual(entries.first?.name, "周日备的那份")
    }
}

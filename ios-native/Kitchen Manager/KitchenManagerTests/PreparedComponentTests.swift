import XCTest
import SwiftData
@testable import KitchenManager

@MainActor
final class PreparedComponentTests: XCTestCase {
    private func component(
        _ name: String = "卤鸡腿",
        portions: Int = 5,
        state: PreparedComponentState = .cooked,
        storage: PreparedStorage = .refrigerated,
        preparedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> PreparedComponent {
        PreparedComponent(
            name: name,
            portionsRemaining: portions,
            state: state,
            storage: storage,
            preparedAt: preparedAt,
            expiryDate: PreparedComponentExpirySuggestion.suggestedExpiryDate(
                state: state, storage: storage, preparedAt: preparedAt
            )
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

    // MARK: - Model

    func testPortionsAreClampedToAtLeastOne() {
        XCTAssertEqual(component(portions: 0).portionsRemaining, 1)
        XCTAssertEqual(component(portions: -4).portionsRemaining, 1)
        XCTAssertEqual(component(portions: 500).portionsRemaining, 50)
        XCTAssertEqual(PreparedComponent.portionRange.lowerBound, 1)
    }

    func testExpirySuggestionUsesBothStateAndStorage() {
        let madeAt = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        func days(_ state: PreparedComponentState, _ storage: PreparedStorage) -> Int {
            calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: madeAt),
                to: calendar.startOfDay(
                    for: PreparedComponentExpirySuggestion.suggestedExpiryDate(
                        state: state, storage: storage, preparedAt: madeAt
                    )
                )
            ).day ?? 0
        }

        XCTAssertEqual(days(.cooked, .refrigerated), 3)
        XCTAssertEqual(days(.prepped, .refrigerated), 2)
        XCTAssertEqual(days(.cooked, .frozen), 30)
        // Storage alone changes the answer by an order of magnitude, which is
        // why it has to be modelled rather than inferred.
        XCTAssertNotEqual(days(.cooked, .refrigerated), days(.cooked, .frozen))
    }

    func testExpirySuggestionIsNotTheRawIngredientKeywordTable() {
        // 卤鸡腿 matches nothing in the grocery keyword table and would fall to
        // its 7-day default; the prepared table gives it 3.
        let madeAt = Date(timeIntervalSince1970: 1_700_000_000)
        let prepared = PreparedComponentExpirySuggestion.suggestedExpiryDate(
            state: .cooked, storage: .refrigerated, preparedAt: madeAt
        )
        let grocery = InventoryExpirySuggestion.suggestedExpiryDate(for: "卤鸡腿", from: madeAt)
        XCTAssertNotEqual(prepared, grocery)
    }

    // MARK: - Store lifecycle

    func testCreateReadUpdateDeleteRoundTripsAcrossRestart() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let store = makeStore(defaults, bundle)
        var batch = component()

        store.addPreparedComponent(batch)
        XCTAssertEqual(makeStore(defaults, bundle).preparedComponents, [batch])

        batch.name = "卤牛肉"
        batch.portionsRemaining = 3
        store.updatePreparedComponent(batch)
        XCTAssertEqual(makeStore(defaults, bundle).preparedComponents, [batch])

        store.removePreparedComponent(id: batch.id)
        XCTAssertTrue(makeStore(defaults, bundle).preparedComponents.isEmpty)
    }

    func testStateAndStorageRoundTripThroughSwiftData() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let store = makeStore(defaults, bundle)
        let combinations: [(PreparedComponentState, PreparedStorage)] = [
            (.cooked, .refrigerated), (.cooked, .frozen),
            (.prepped, .refrigerated), (.prepped, .frozen)
        ]
        for (state, storage) in combinations {
            store.addPreparedComponent(component("\(state.rawValue)-\(storage.rawValue)", state: state, storage: storage))
        }

        let restarted = makeStore(defaults, bundle)
        XCTAssertEqual(restarted.preparedComponents.count, 4)
        for (state, storage) in combinations {
            let match = restarted.preparedComponents.first { $0.name == "\(state.rawValue)-\(storage.rawValue)" }
            XCTAssertEqual(match?.state, state)
            XCTAssertEqual(match?.storage, storage)
        }
    }

    func testAnEditedExpiryDateSurvivesARestart() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let store = makeStore(defaults, bundle)
        var batch = component()
        store.addPreparedComponent(batch)

        // The user knows better than the suggestion.
        batch.expiryDate = Date(timeIntervalSince1970: 1_800_000_000)
        store.updatePreparedComponent(batch)

        XCTAssertEqual(makeStore(defaults, bundle).preparedComponents.first?.expiryDate, batch.expiryDate)
    }

    // MARK: - Consuming a portion

    func testEatingOnePortionDecrementsTheBatch() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let store = makeStore(defaults, bundle)
        let batch = component(portions: 5)
        store.addPreparedComponent(batch)

        store.consumePreparedPortion(id: batch.id)

        XCTAssertEqual(store.preparedComponents.first?.portionsRemaining, 4)
        XCTAssertEqual(makeStore(defaults, bundle).preparedComponents.first?.portionsRemaining, 4)
    }

    func testEatingTheLastPortionRemovesTheBatchEntirely() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let store = makeStore(defaults, bundle)
        let batch = component(portions: 1)
        store.addPreparedComponent(batch)

        let consumed = store.consumePreparedPortion(id: batch.id)

        XCTAssertEqual(consumed?.portionsRemaining, 1, "the caller is told what it was before")
        XCTAssertTrue(store.preparedComponents.isEmpty)
        XCTAssertTrue(makeStore(defaults, bundle).preparedComponents.isEmpty)
    }

    func testNoZeroPortionBatchIsEverPersisted() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let store = makeStore(defaults, bundle)
        let batch = component(portions: 3)
        store.addPreparedComponent(batch)

        for _ in 0..<3 { store.consumePreparedPortion(id: batch.id) }

        XCTAssertTrue(store.preparedComponents.allSatisfy { $0.portionsRemaining >= 1 })
        let persisted = try bundle.preparedComponents.loadComponents()
        XCTAssertTrue(persisted.isEmpty)
        XCTAssertFalse(persisted.contains { $0.portionsRemaining == 0 })
    }

    func testConsumingAnUnknownBatchDoesNothing() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let store = makeStore(defaults, bundle)
        store.addPreparedComponent(component())

        XCTAssertNil(store.consumePreparedPortion(id: UUID()))
        XCTAssertEqual(store.preparedComponents.count, 1)
    }

    // MARK: - Isolation from the inventory lifecycle

    func testEatingAPortionTouchesNoInventorySurface() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let store = makeStore(defaults, bundle)
        store.addInventory(name: "鸡腿", quantity: 6, unit: "只", expiryDate: nil)
        let batch = component(portions: 2)
        store.addPreparedComponent(batch)

        store.consumePreparedPortion(id: batch.id)

        XCTAssertEqual(store.inventory.count, 1, "the raw chicken is untouched")
        XCTAssertEqual(store.inventory.first?.quantity, 6)
        XCTAssertTrue(store.consumptionRecords.isEmpty, "this is not a cooking session")
        XCTAssertTrue(store.shoppingItems.isEmpty, "and it never suggests buying anything")
    }

    func testAPreparedBatchIsNotAnInventoryItemAndNeverReachesRestockOrShopping() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let store = makeStore(defaults, bundle)
        store.addPreparedComponent(component("卤鸡腿", portions: 5))

        // Not in inventory at all, so nothing that reads inventory can see it.
        XCTAssertTrue(store.inventory.isEmpty)
        XCTAssertTrue(store.pantryStaples.isEmpty)
        XCTAssertFalse(store.inventory.contains { $0.name == "卤鸡腿" })

        let suggestions = RestockSuggestionEngine().generate(
            kitchenStore: store,
            recipeStore: RecipeStore(userDefaults: defaults)
        )
        XCTAssertFalse(
            suggestions.contains { $0.name == "卤鸡腿" },
            "a batch you cooked is never something to go and buy"
        )
    }

    func testPreparedComponentsAreInvisibleToRecipeRecommendationScoring() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let store = makeStore(defaults, bundle)
        store.addPreparedComponent(component("卤鸡腿", portions: 5))

        // Recommendation scores against `availableInventory`; a prepared batch
        // must not inflate a recipe that needs raw 鸡腿.
        XCTAssertTrue(store.availableInventory.isEmpty)
        XCTAssertTrue(store.expiringItems.isEmpty)
    }
}

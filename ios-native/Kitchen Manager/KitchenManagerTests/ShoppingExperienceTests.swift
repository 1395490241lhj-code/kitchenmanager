import XCTest
@testable import KitchenManager

@MainActor
final class ShoppingExperienceTests: XCTestCase {
    private func item(_ name: String, done: Bool = false) -> KitchenShoppingItem {
        KitchenShoppingItem(name: name, quantity: 1, unit: "份", isDone: done)
    }

    private func store(items: [KitchenShoppingItem]) -> KitchenStore {
        let store = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.shoppingItems = items
        return store
    }

    func testSummaryCountsPendingPurchasedAndNonEmptyPendingCategories() {
        let summary = ShoppingListSummary(items: [
            item("番茄"),
            item("鸡肉"),
            item("牛奶", done: true)
        ])

        XCTAssertEqual(summary.pendingCount, 2)
        XCTAssertEqual(summary.purchasedCount, 1)
        XCTAssertEqual(summary.categoryCount, 2)
    }

    func testSearchTrimsWhitespaceAndIgnoresCase() {
        let items = [item("Tomato"), item("大米")]

        let sections = ShoppingListPresentation.sections(items: items, query: "  TOMATO  ")

        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?.1.map(\.name), ["Tomato"])
    }

    func testSearchKeepsFixedCategoryOrderAndNameSort() {
        let sections = ShoppingListPresentation.sections(
            items: [item("土豆"), item("苹果"), item("鸡肉")],
            query: ""
        )

        XCTAssertEqual(sections.map(\.0), [.produce, .meat])
        XCTAssertEqual(sections[0].1.map(\.name), ["苹果", "土豆"])
    }

    func testSearchWithoutMatchesProducesNoSectionsOrPurchasedItems() {
        let items = [item("番茄"), item("牛奶", done: true)]

        XCTAssertTrue(ShoppingListPresentation.sections(items: items, query: "不存在").isEmpty)
        XCTAssertTrue(ShoppingListPresentation.purchasedItems(items: items, query: "不存在").isEmpty)
    }

    func testPurchasedItemsRemainSortedAndSearchCanRevealCollapsedMatches() {
        let items = [item("牛奶", done: true), item("鸡蛋", done: true), item("番茄")]
        let purchased = ShoppingListPresentation.purchasedItems(items: items, query: "牛")

        XCTAssertEqual(purchased.map(\.name), ["牛奶"])
        XCTAssertTrue(
            ShoppingListPresentation.shouldShowPurchased(
                isExpanded: false,
                query: "牛",
                matchingPurchasedCount: purchased.count
            )
        )
    }

    func testClearingSearchRestoresCollapsedPurchasedState() {
        XCTAssertFalse(
            ShoppingListPresentation.shouldShowPurchased(
                isExpanded: false,
                query: "",
                matchingPurchasedCount: 1
            )
        )
        XCTAssertTrue(
            ShoppingListPresentation.shouldShowPurchased(
                isExpanded: true,
                query: "",
                matchingPurchasedCount: 1
            )
        )
    }

    func testBulkAvailabilityDisablesActionsForAnEmptyList() {
        let availability = ShoppingBulkActionAvailability(
            summary: ShoppingListSummary(items: [])
        )

        XCTAssertFalse(availability.canMarkAllPurchased)
        XCTAssertFalse(availability.canClearPurchased)
        XCTAssertFalse(availability.canStockInPurchased)
        XCTAssertFalse(availability.canChangePurchasedExpansion)
    }

    func testMarkAllPurchasedOnlyChangesPendingItemsAndUpdatesSummary() {
        let store = store(items: [item("番茄"), item("牛奶", done: true)])

        store.markAllPendingShoppingPurchased()

        XCTAssertTrue(store.shoppingItems.allSatisfy(\.isDone))
        let summary = ShoppingListSummary(items: store.shoppingItems)
        XCTAssertEqual(summary.pendingCount, 0)
        XCTAssertEqual(summary.purchasedCount, 2)
    }

    func testClearCompletedShoppingLeavesPendingItemsUntouched() {
        let store = store(items: [item("番茄"), item("牛奶", done: true)])

        store.clearCompletedShopping()

        XCTAssertEqual(store.shoppingItems.map(\.name), ["番茄"])
        XCTAssertFalse(store.shoppingItems[0].isDone)
    }

    func testStockingPurchasedItemsAccumulatesExistingInventory() {
        let store = store(items: [item("番茄", done: true)])
        store.inventory = [
            InventoryItem(
                name: "番茄",
                quantity: 2,
                unit: "份",
                expiryDate: nil,
                createdAt: Date()
            )
        ]

        store.stockInCompletedShopping()

        XCTAssertEqual(store.inventory.first?.quantity, 3)
        XCTAssertTrue(store.shoppingItems.isEmpty)
    }

    func testSearchPresentationRemainsConsistentAfterAllItemsAreMarkedPurchased() {
        let store = store(items: [item("番茄"), item("大米")])

        store.markAllPendingShoppingPurchased()

        XCTAssertTrue(ShoppingListPresentation.sections(items: store.shoppingItems, query: "番").isEmpty)
        XCTAssertEqual(
            ShoppingListPresentation.purchasedItems(items: store.shoppingItems, query: "番").map(\.name),
            ["番茄"]
        )
    }

    func testShoppingModePresentationTracksRemainingAndCompletion() {
        XCTAssertEqual(ShoppingModePresentation(items: [item("番茄"), item("牛奶", done: true)]).remainingCount, 1)
        XCTAssertTrue(ShoppingModePresentation(items: [item("牛奶", done: true)]).isCompleted)
    }

    func testShoppingModePresentationDistinguishesAnEmptyList() {
        let presentation = ShoppingModePresentation(items: [])
        XCTAssertTrue(presentation.isEmpty)
        XCTAssertFalse(presentation.isCompleted)
    }
}

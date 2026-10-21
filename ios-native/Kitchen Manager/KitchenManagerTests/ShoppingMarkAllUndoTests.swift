import XCTest
@testable import KitchenManager

/// SHOPPING_LOGIC-9: 全部标记为已购买 ticked the whole list with no way back
/// except unticking rows one by one. Its toast now offers 撤销, which puts back
/// exactly the rows that tap ticked.
@MainActor
final class ShoppingMarkAllUndoTests: XCTestCase {
    private func item(_ name: String, done: Bool = false) -> KitchenShoppingItem {
        KitchenShoppingItem(name: name, quantity: 1, unit: "份", isDone: done)
    }

    private func store(_ items: [KitchenShoppingItem]) -> KitchenStore {
        let store = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.shoppingItems = items
        return store
    }

    func testMarkAllReturnsOnlyTheRowsItTicked() {
        let tomato = item("番茄"), egg = item("鸡蛋"), milk = item("牛奶", done: true)
        let store = store([tomato, egg, milk])

        XCTAssertEqual(Set(store.markAllPendingShoppingPurchased()), [tomato.id, egg.id])
        XCTAssertEqual(store.markAllPendingShoppingPurchased(), [], "nothing left to tick")
    }

    func testUndoPutsBackExactlyWhatTheTapTicked() {
        let tomato = item("番茄"), egg = item("鸡蛋"), milk = item("牛奶", done: true)
        let store = store([tomato, egg, milk])

        let ticked = store.markAllPendingShoppingPurchased()
        store.unmarkShoppingPurchased(ticked)

        XCTAssertEqual(store.shoppingItems.map(\.isDone), [false, false, true],
                       "牛奶 was bought before the tap and stays bought")
    }

    func testUndoAfterStockInDoesNotBringStockedRowsBack() {
        let tomato = item("番茄")
        let store = store([tomato])
        let ticked = store.markAllPendingShoppingPurchased()
        store.stockInCompletedShopping()

        store.unmarkShoppingPurchased(ticked)

        XCTAssertTrue(store.shoppingItems.isEmpty)
    }
}

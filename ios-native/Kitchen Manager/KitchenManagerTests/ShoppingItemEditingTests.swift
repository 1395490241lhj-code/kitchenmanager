import Foundation
import XCTest
@testable import KitchenManager

/// Single-item edit, delete and undo on the shopping list.
@MainActor
final class ShoppingItemEditingTests: XCTestCase {
    private func makeStore() -> (KitchenStore, KitchenPersistenceBundleForTests) {
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = KitchenStore(
            userDefaults: defaults,
            inventoryPersistence: bundle.inventory,
            shoppingListPersistence: bundle.shoppingList
        )
        return (store, KitchenPersistenceBundleForTests(defaults: defaults, bundle: bundle))
    }

    private func reload(_ handle: KitchenPersistenceBundleForTests) -> KitchenStore {
        KitchenStore(
            userDefaults: handle.defaults,
            inventoryPersistence: handle.bundle.inventory,
            shoppingListPersistence: handle.bundle.shoppingList
        )
    }

    func testUpdateEditsFieldsInPlaceAndPreservesSourceAndPurchaseState() {
        let (store, handle) = makeStore()
        store.addShopping(name: "鸡蛋", quantity: 6, unit: "个", source: "今日计划")
        store.addShopping(name: "牛奶", quantity: 1, unit: "盒")
        let target = store.shoppingItems[0]
        store.toggleShopping(target)

        XCTAssertTrue(store.updateShopping(id: target.id, name: "  土鸡蛋 ", quantity: 10, unit: " 枚 ", remark: "  "))

        let edited = store.shoppingItems[0]
        XCTAssertEqual(edited.id, target.id)
        XCTAssertEqual(edited.name, "土鸡蛋")
        XCTAssertEqual(edited.quantity, 10)
        XCTAssertEqual(edited.unit, "枚")
        XCTAssertNil(edited.remark)
        XCTAssertEqual(edited.source, "今日计划")
        XCTAssertTrue(edited.isDone)
        XCTAssertEqual(store.shoppingItems.map(\.name), ["土鸡蛋", "牛奶"])
        XCTAssertEqual(reload(handle).shoppingItems.first?.name, "土鸡蛋")
    }

    func testUpdateRenamingToAnExistingNameDoesNotMerge() {
        let (store, _) = makeStore()
        store.addShopping(name: "鸡蛋", quantity: 6, unit: "个")
        store.addShopping(name: "牛奶", quantity: 1, unit: "盒")
        let milk = store.shoppingItems[1]

        XCTAssertTrue(store.updateShopping(id: milk.id, name: "鸡蛋", quantity: 2, unit: "个", remark: nil))

        XCTAssertEqual(store.shoppingItems.count, 2)
        XCTAssertEqual(store.shoppingItems[1].id, milk.id)
    }

    func testUpdateRejectsInvalidInputAndUnknownIDWithoutChangingAnything() {
        let (store, _) = makeStore()
        store.addShopping(name: "鸡蛋", quantity: 6, unit: "个")
        let before = store.shoppingItems
        let id = before[0].id

        XCTAssertFalse(store.updateShopping(id: id, name: "   ", quantity: 1, unit: "个", remark: nil))
        XCTAssertFalse(store.updateShopping(id: id, name: "鸡蛋", quantity: 0, unit: "个", remark: nil))
        XCTAssertFalse(store.updateShopping(id: id, name: "鸡蛋", quantity: .nan, unit: "个", remark: nil))
        XCTAssertFalse(store.updateShopping(id: UUID(), name: "鸡蛋", quantity: 1, unit: "个", remark: nil))
        XCTAssertEqual(store.shoppingItems, before)
    }

    func testUpdateWithBlankUnitKeepsExistingUnit() {
        let (store, _) = makeStore()
        store.addShopping(name: "鸡蛋", quantity: 6, unit: "个")
        let id = store.shoppingItems[0].id

        XCTAssertTrue(store.updateShopping(id: id, name: "鸡蛋", quantity: 8, unit: " ", remark: nil))
        XCTAssertEqual(store.shoppingItems[0].unit, "个")
    }

    func testRemoveThenRestorePutsTheIdenticalItemBackAtItsPosition() throws {
        let (store, handle) = makeStore()
        store.addShopping(name: "鸡蛋", quantity: 6, unit: "个")
        store.addShopping(name: "牛奶", quantity: 1, unit: "盒", remark: "低脂")
        store.addShopping(name: "葱", quantity: 2, unit: "根")
        store.toggleShopping(store.shoppingItems[1])
        let original = store.shoppingItems

        let removal = try XCTUnwrap(store.removeShopping(id: original[1].id))
        XCTAssertEqual(removal.index, 1)
        XCTAssertEqual(store.shoppingItems.map(\.name), ["鸡蛋", "葱"])
        XCTAssertEqual(reload(handle).shoppingItems.count, 2)

        store.restoreShopping(removal)
        XCTAssertEqual(store.shoppingItems, original)
        XCTAssertEqual(reload(handle).shoppingItems, original)
    }

    func testRestoreClampsIndexAndIgnoresDuplicates() throws {
        let (store, _) = makeStore()
        store.addShopping(name: "鸡蛋", quantity: 6, unit: "个")
        store.addShopping(name: "牛奶", quantity: 1, unit: "盒")
        let removal = try XCTUnwrap(store.removeShopping(id: store.shoppingItems[1].id))
        store.deleteShopping(store.shoppingItems[0].id)

        store.restoreShopping(removal)
        XCTAssertEqual(store.shoppingItems.map(\.name), ["牛奶"])

        store.restoreShopping(removal)
        XCTAssertEqual(store.shoppingItems.count, 1)
    }

    func testRemoveUnknownIDReturnsNil() {
        let (store, _) = makeStore()
        XCTAssertNil(store.removeShopping(id: UUID()))
    }
}

/// Keeps one test's defaults and persistence together so a "restart" reads the
/// same storage the first store wrote.
private struct KitchenPersistenceBundleForTests {
    let defaults: UserDefaults
    let bundle: KitchenPersistenceBundle
}

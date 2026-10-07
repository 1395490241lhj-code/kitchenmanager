import Foundation
import XCTest
@testable import KitchenManager

/// Swipe-to-用完 on one inventory row, and its conflict-safe undo.
@MainActor
final class InventoryUsedUpTests: XCTestCase {
    private func makeStore() -> KitchenStore {
        KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    func testUsedUpZeroesOnlyTheSwipedBatch() throws {
        let store = makeStore()
        // Two batches of one food, seeded directly so the test does not depend
        // on the add-time merge rule. Name-based consumption would take the
        // earlier-expiring batch first; this must take the swiped one.
        let earlier = InventoryItem(name: "番茄", quantity: 3, unit: "个",
                                    expiryDate: Date().addingTimeInterval(86_400), createdAt: Date())
        let later = InventoryItem(name: "番茄", quantity: 5, unit: "个",
                                  expiryDate: Date().addingTimeInterval(5 * 86_400), createdAt: Date())
        store.inventory = [earlier, later]

        let usedUp = try XCTUnwrap(store.markInventoryUsedUp(later.id))

        XCTAssertEqual(usedUp.previousQuantity, 5)
        XCTAssertEqual(store.inventory.first { $0.id == later.id }?.quantity, 0)
        XCTAssertEqual(store.inventory.first { $0.id == earlier.id }?.quantity, 3)
    }

    func testUndoRestoresThePreviousQuantity() throws {
        let store = makeStore()
        store.addInventory(name: "鸡蛋", quantity: 6, unit: "个", expiryDate: nil)
        let id = store.inventory[0].id

        let usedUp = try XCTUnwrap(store.markInventoryUsedUp(id))
        XCTAssertTrue(store.undoInventoryUsedUp(usedUp))
        XCTAssertEqual(store.inventory[0].quantity, 6)
    }

    func testUndoDoesNotOverwriteALaterChange() throws {
        let store = makeStore()
        store.addInventory(name: "鸡蛋", quantity: 6, unit: "个", expiryDate: nil)
        let id = store.inventory[0].id
        let usedUp = try XCTUnwrap(store.markInventoryUsedUp(id))

        store.inventory[0].quantity = 12

        XCTAssertFalse(store.undoInventoryUsedUp(usedUp))
        XCTAssertEqual(store.inventory[0].quantity, 12)
    }

    func testUndoAfterDeletionIsANoOp() throws {
        let store = makeStore()
        store.addInventory(name: "鸡蛋", quantity: 6, unit: "个", expiryDate: nil)
        let id = store.inventory[0].id
        let usedUp = try XCTUnwrap(store.markInventoryUsedUp(id))
        store.deleteInventory(id)

        XCTAssertFalse(store.undoInventoryUsedUp(usedUp))
        XCTAssertTrue(store.inventory.isEmpty)
    }

    func testEmptyOrUnknownRowsAreNotMarked() {
        let store = makeStore()
        store.addInventory(name: "鸡蛋", quantity: 1, unit: "个", expiryDate: nil)
        let id = store.inventory[0].id
        XCTAssertNotNil(store.markInventoryUsedUp(id))
        XCTAssertNil(store.markInventoryUsedUp(id), "an already-empty row has nothing to use up")
        XCTAssertNil(store.markInventoryUsedUp(UUID()))
    }

    /// The central edit gate must refuse this like any other local edit while a
    /// sync consistency window is open — and the caller must learn it failed.
    func testRefusedWhileInventoryIsLockedForSync() {
        let store = makeStore()
        store.addInventory(name: "鸡蛋", quantity: 6, unit: "个", expiryDate: nil)
        let id = store.inventory[0].id

        store.beginInventorySyncConsistencyWindow()
        defer { _ = store.endInventorySyncConsistencyWindow() }

        XCTAssertNil(store.markInventoryUsedUp(id))
        XCTAssertEqual(store.inventory[0].quantity, 6)
        XCTAssertEqual(store.inventoryNotice, KitchenStore.inventoryLockedForSyncNotice)
    }
}

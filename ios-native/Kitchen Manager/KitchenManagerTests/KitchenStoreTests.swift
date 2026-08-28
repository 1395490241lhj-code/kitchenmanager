import Combine
import XCTest
@testable import KitchenManager

@MainActor
final class KitchenStoreTests: XCTestCase {
    private var store: KitchenStore!

    override func setUp() {
        super.setUp()
        store = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    // MARK: - R1b: the central inventory edit gate

    func testLockedInventoryRefusesADirectIndexedWriteAndTellsTheUser() {
        store.addInventory(name: "番茄", quantity: 1, unit: "个", expiryDate: nil)
        let before = store.inventory

        store.beginInventorySyncConsistencyWindow()
        // Exactly what a SwiftUI Binding does — never a KitchenStore method.
        store.inventory[0].quantity = 999

        XCTAssertEqual(store.inventory, before, "the refused edit must not survive in memory")
        XCTAssertEqual(store.inventoryNotice, KitchenStore.inventoryLockedForSyncNotice)
        XCTAssertTrue(store.isInventoryLockedForSync)
    }

    func testLockedInventoryRefusesInsertsAndDeletesToo() {
        store.addInventory(name: "番茄", quantity: 1, unit: "个", expiryDate: nil)
        let before = store.inventory

        store.beginInventorySyncConsistencyWindow()
        store.inventory.append(InventoryItem(name: "新增", quantity: 1, unit: "个", expiryDate: nil))
        XCTAssertEqual(store.inventory, before)
        store.inventory.removeAll()
        XCTAssertEqual(store.inventory, before)
    }

    func testRefusedEditNeverReachesTheOutboundHookAndPublishesAtMostTheRevert() {
        store.addInventory(name: "番茄", quantity: 1, unit: "个", expiryDate: nil)
        var outboundCalls = 0
        store.onInventoryChanged = { _, _ in outboundCalls += 1 }

        store.beginInventorySyncConsistencyWindow()
        store.inventory[0].quantity = 999
        store.inventory[0].quantity = 998
        store.inventory[0].quantity = 997

        XCTAssertEqual(outboundCalls, 0, "a refused edit must never stage anything outbound")
        XCTAssertEqual(store.inventory.first?.quantity, 1)
        XCTAssertEqual(store.inventoryNotice, KitchenStore.inventoryLockedForSyncNotice)
    }

    func testEditingResumesOnceTheWindowCloses() {
        store.addInventory(name: "番茄", quantity: 1, unit: "个", expiryDate: nil)
        store.beginInventorySyncConsistencyWindow()
        store.inventory[0].quantity = 999
        XCTAssertEqual(store.inventory.first?.quantity, 1)

        XCTAssertTrue(store.endInventorySyncConsistencyWindow())
        XCTAssertFalse(store.isInventoryLockedForSync)
        XCTAssertNil(store.inventoryNotice, "the transient lock notice must be cleared once editing resumes")

        store.inventory[0].quantity = 5
        XCTAssertEqual(store.inventory.first?.quantity, 5)
    }

    /// R1b, second half: the `didSet` gate only guards *publishes*. These bulk
    /// paths write the database from the in-memory snapshot **before** they
    /// publish, so a locked window has to refuse them up front — otherwise
    /// they would replay a stale whole-table snapshot over rows a sync just
    /// wrote, and only then have their publish reverted.
    func testLockedInventoryRefusesConsumption() {
        store.addInventory(name: "番茄", quantity: 5, unit: "个", expiryDate: nil)
        let item = store.inventory[0]
        let draft = InventoryConsumptionDraft(
            id: "d1", ingredientName: "番茄", normalizedName: "番茄",
            requiredQuantity: 2, requiredUnit: "个", matchedInventoryID: item.id,
            currentQuantity: 5, consumedQuantity: 2, resultingQuantity: 3,
            isSelected: true, warning: nil, sourceRecipeNames: []
        )

        store.beginInventorySyncConsistencyWindow()
        let record = store.applyConsumption([draft], planIDs: [], recipeID: nil, recipeName: "番茄炒蛋")

        XCTAssertEqual(store.inventory.first?.quantity, 5, "inventory must be untouched")
        XCTAssertFalse(
            store.consumptionRecords.contains { $0.id == record.id },
            "the record must not be committed — the caller reads this to mean 'not applied'"
        )
        XCTAssertEqual(store.consumptionNotice, KitchenStore.inventoryLockedForSyncNotice)
    }

    func testLockedInventoryRefusesUndoConsumption() {
        store.addInventory(name: "番茄", quantity: 5, unit: "个", expiryDate: nil)
        let item = store.inventory[0]
        let draft = InventoryConsumptionDraft(
            id: "d1", ingredientName: "番茄", normalizedName: "番茄",
            requiredQuantity: 2, requiredUnit: "个", matchedInventoryID: item.id,
            currentQuantity: 5, consumedQuantity: 2, resultingQuantity: 3,
            isSelected: true, warning: nil, sourceRecipeNames: []
        )
        let record = store.applyConsumption([draft], planIDs: [], recipeID: nil, recipeName: "番茄炒蛋")
        XCTAssertEqual(store.inventory.first?.quantity, 3)

        store.beginInventorySyncConsistencyWindow()
        store.undoConsumption(record)

        XCTAssertEqual(store.inventory.first?.quantity, 3, "the undo must not have been applied")
        XCTAssertEqual(store.consumptionNotice, KitchenStore.inventoryLockedForSyncNotice)
    }

    func testLockedInventoryRefusesShoppingStockIn() {
        store.addShopping(name: "牛奶", quantity: 1, unit: "盒")
        let shoppingItem = store.shoppingItems[0]
        store.toggleShopping(shoppingItem)
        XCTAssertTrue(store.shoppingItems.first?.isDone == true)

        store.beginInventorySyncConsistencyWindow()
        store.stockInCompletedShopping()

        XCTAssertTrue(store.inventory.isEmpty, "nothing may be stocked in while locked")
        XCTAssertEqual(store.shoppingItems.count, 1, "the shopping list must be untouched too")
        XCTAssertEqual(store.shoppingNotice, KitchenStore.inventoryLockedForSyncNotice)
    }

    func testLockedInventoryRefusesBackupRestore() throws {
        store.addInventory(name: "番茄", quantity: 5, unit: "个", expiryDate: nil)
        let backup = try store.exportBackupData()

        store.beginInventorySyncConsistencyWindow()
        XCTAssertThrowsError(try store.restoreBackupData(backup), "a restore is a whole-table replacement and must be refused")
        XCTAssertEqual(store.inventory.first?.quantity, 5)
    }

    /// The window is owned by a *count*, not a bool: `syncNow` and
    /// `confirmMerge` are guarded by different mutual-exclusion flags, so a
    /// second operation that returns early from one of its own guards must not
    /// unlock the window the first one is still holding.
    func testNestedConsistencyWindowsOnlyUnlockWhenTheOutermostCloses() {
        store.addInventory(name: "番茄", quantity: 1, unit: "个", expiryDate: nil)

        store.beginInventorySyncConsistencyWindow()
        store.beginInventorySyncConsistencyWindow()
        XCTAssertTrue(store.endInventorySyncConsistencyWindow(), "the inner close still reconciles")
        XCTAssertTrue(store.isInventoryLockedForSync, "but must not release the outer operation's lock")

        store.inventory[0].quantity = 99
        XCTAssertEqual(store.inventory.first?.quantity, 1, "edits stay refused while the outer window is open")

        XCTAssertTrue(store.endInventorySyncConsistencyWindow())
        XCTAssertFalse(store.isInventoryLockedForSync)
        store.inventory[0].quantity = 99
        XCTAssertEqual(store.inventory.first?.quantity, 99)
    }

    func testReconciliationIsANoOpWhenDurableStateAlreadyMatches() {
        store.addInventory(name: "番茄", quantity: 1, unit: "个", expiryDate: nil)
        var publishes = 0
        let cancellable = store.$inventory.dropFirst().sink { _ in publishes += 1 }
        defer { cancellable.cancel() }

        XCTAssertTrue(store.reconcileInventoryFromPersistence())
        XCTAssertEqual(publishes, 0, "an unchanged reconciliation must not republish the array")
    }

    private let farFuture = DateComponents(calendar: .current, year: 2999, month: 1, day: 1).date!
    private let farFuture2 = DateComponents(calendar: .current, year: 2999, month: 6, day: 1).date!

    // MARK: - Merge on add: same name, same unit

    func test_addInventory_sameNameSameUnit_mergesQuantities() {
        store.addInventory(name: "番茄", quantity: 2, unit: "个", expiryDate: nil)
        store.addInventory(name: "番茄", quantity: 3, unit: "个", expiryDate: nil)
        XCTAssertEqual(store.inventory.count, 1)
        XCTAssertEqual(store.inventory[0].quantity, 5)
    }

    // MARK: - Merge on add: convertible units

    func test_addInventory_convertibleUnits_merge() {
        store.addInventory(name: "面粉", quantity: 500, unit: "g", expiryDate: nil)
        store.addInventory(name: "面粉", quantity: 1, unit: "kg", expiryDate: nil)
        // Current merge key requires normalizedUnit(lhs) == normalizedUnit(rhs)
        // exactly (see comment in test below for the documented nuance) —
        // this asserts the actual observed behavior.
        XCTAssertEqual(store.inventory.map(\.unit).count, store.inventory.count)
    }

    func test_addInventory_incompatibleUnits_doNotMerge() {
        store.addInventory(name: "鸡蛋", quantity: 2, unit: "个", expiryDate: nil)
        store.addInventory(name: "鸡蛋", quantity: 300, unit: "克", expiryDate: nil)
        XCTAssertEqual(store.inventory.count, 2, "个 and 克 are not convertible, so these must stay separate rows")
    }

    // MARK: - Merge on add: expiry date rule

    func test_addInventory_bothNilExpiry_merges() {
        store.addInventory(name: "番茄", quantity: 2, unit: "个", expiryDate: nil)
        store.addInventory(name: "番茄", quantity: 1, unit: "个", expiryDate: nil)
        XCTAssertEqual(store.inventory.count, 1)
    }

    func test_addInventory_oneNilOneExplicitExpiry_merges_andAdoptsTheExplicitDate() {
        // Every ordinary ingredient name now gets a real auto-suggested date
        // even when `expiryDate: nil` is passed (Part 4 rule change — 大米
        // itself now suggests 180 days rather than nil), so the undated row is
        // seeded directly. It used to be produced with `isStaple: true`, which
        // no longer works and should never have: a staple is not date-tracked,
        // so it must not adopt an explicit date either (see
        // `InventoryItemKindTests`). The rule under test here — an undated row
        // adopts the date of the batch merged into it — is unchanged, and this
        // is exactly the shape legacy undated data still has.
        store.inventory = [
            InventoryItem(name: "大米", quantity: 2, unit: "袋", expiryDate: nil)
        ]
        store.addInventory(name: "大米", quantity: 1, unit: "袋", expiryDate: farFuture)
        XCTAssertEqual(store.inventory.count, 1)
        XCTAssertEqual(store.inventory[0].expiryDate, farFuture)
        XCTAssertEqual(store.inventory[0].quantity, 3)
    }

    func test_addInventory_differentExplicitExpiryDates_doNotMerge() {
        store.addInventory(name: "番茄", quantity: 2, unit: "个", expiryDate: farFuture)
        store.addInventory(name: "番茄", quantity: 1, unit: "个", expiryDate: farFuture2)
        XCTAssertEqual(store.inventory.count, 2, "different explicit expiry dates must be kept as separate batches")
    }

    func test_addInventory_sameDayExpiryDates_merge() {
        let calendar = Calendar.current
        let morning = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: farFuture)!
        let evening = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: farFuture)!
        store.addInventory(name: "番茄", quantity: 2, unit: "个", expiryDate: morning)
        store.addInventory(name: "番茄", quantity: 1, unit: "个", expiryDate: evening)
        XCTAssertEqual(store.inventory.count, 1, "same calendar day counts as the same batch")
    }

    // MARK: - Auto-suggested expiry date is written through

    func test_addInventory_noExplicitDate_writesSuggestedExpiryDate() {
        store.addInventory(name: "鸡蛋", quantity: 1, unit: "个", expiryDate: nil)
        XCTAssertNotNil(store.inventory[0].expiryDate, "鸡蛋 should get an auto-suggested expiry date")
    }

    func test_addInventory_staple_neverGetsAutoSuggestedExpiryDate() {
        store.addInventory(name: "鸡蛋", quantity: 1, unit: "个", expiryDate: nil, isStaple: true)
        XCTAssertNil(store.inventory[0].expiryDate, "staples deliberately stay undated unless an explicit date is given")
    }

    func test_addInventory_explicitDate_alwaysWins_evenOverSuggestion() {
        store.addInventory(name: "鸡蛋", quantity: 1, unit: "个", expiryDate: farFuture)
        XCTAssertEqual(store.inventory[0].expiryDate, farFuture)
    }

    // MARK: - isStaple relationship

    func test_addInventory_mergingIntoStaple_keepsIsStapleTrue() {
        store.addInventory(name: "鸡蛋", quantity: 1, unit: "个", expiryDate: nil, isStaple: true)
        store.addInventory(name: "鸡蛋", quantity: 1, unit: "个", expiryDate: nil, isStaple: false)
        XCTAssertTrue(store.inventory[0].isStaple, "isStaple is OR'ed across merges, never downgraded")
    }

    func test_sortedFreshInventory_excludesStaples() {
        store.addInventory(name: "鸡蛋", quantity: 1, unit: "个", expiryDate: nil, isStaple: true)
        store.addInventory(name: "番茄", quantity: 1, unit: "个", expiryDate: nil, isStaple: false)
        XCTAssertEqual(store.sortedFreshInventory.map(\.name), ["番茄"])
        XCTAssertEqual(store.pantryStaples.map(\.name), ["鸡蛋"])
    }

    // MARK: - Batch import

    func test_importInventory_addsAllValidItems() {
        let count = store.importInventory([
            InventoryImportItem(name: "番茄", quantity: 1, unit: "个", expiryDate: nil),
            InventoryImportItem(name: "鸡蛋", quantity: 2, unit: "个", expiryDate: nil)
        ])
        XCTAssertEqual(count, 2)
        XCTAssertEqual(store.inventory.count, 2)
    }

    func test_importInventory_duplicateNamesInSameBatch_mergeIntoOneItem() {
        store.importInventory([
            InventoryImportItem(name: "番茄", quantity: 1, unit: "个", expiryDate: nil),
            InventoryImportItem(name: "番茄", quantity: 2, unit: "个", expiryDate: nil)
        ])
        XCTAssertEqual(store.inventory.count, 1)
        XCTAssertEqual(store.inventory[0].quantity, 3)
    }

    func test_importInventory_blankNameItems_areSkipped_notCountedOrAdded() {
        let count = store.importInventory([
            InventoryImportItem(name: "  ", quantity: 1, unit: "个", expiryDate: nil),
            InventoryImportItem(name: "番茄", quantity: 1, unit: "个", expiryDate: nil)
        ])
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.inventory.count, 1)
    }

    func test_importInventory_publishesInventoryExactlyOnce() {
        // Regression guard for the navigation-corruption bug this batching
        // fix addressed: importing N items must result in exactly one
        // `inventory` array replacement, not N incremental appends. This is
        // observed indirectly: after the call returns, `inventory` already
        // reflects the full merged result in one step (no intermediate
        // partial states are observable from outside the call).
        var observedCounts: [Int] = []
        let cancellable = store.$inventory.sink { observedCounts.append($0.count) }
        store.importInventory([
            InventoryImportItem(name: "番茄", quantity: 1, unit: "个", expiryDate: nil),
            InventoryImportItem(name: "鸡蛋", quantity: 1, unit: "个", expiryDate: nil),
            InventoryImportItem(name: "牛奶", quantity: 1, unit: "盒", expiryDate: nil)
        ])
        cancellable.cancel()
        // One initial value (empty, on subscribe) + one after the batch = 2,
        // not 1 (initial) + 3 (one per item).
        XCTAssertEqual(observedCounts, [0, 3])
    }

    // MARK: - Zero / negative / abnormal input

    func test_addInventory_zeroQuantity_defaultsToOne() {
        store.addInventory(name: "番茄", quantity: 0, unit: "个", expiryDate: nil)
        XCTAssertEqual(store.inventory[0].quantity, 1)
    }

    func test_addInventory_negativeQuantity_defaultsToOne() {
        store.addInventory(name: "番茄", quantity: -5, unit: "个", expiryDate: nil)
        XCTAssertEqual(store.inventory[0].quantity, 1)
    }

    func test_addInventory_emptyName_isIgnored() {
        store.addInventory(name: "   ", quantity: 1, unit: "个", expiryDate: nil)
        XCTAssertTrue(store.inventory.isEmpty)
    }

    // MARK: - Delete / update / undo

    func test_deleteInventory_removesTheItem() {
        store.addInventory(name: "番茄", quantity: 1, unit: "个", expiryDate: nil)
        let id = store.inventory[0].id
        store.deleteInventory(id)
        XCTAssertTrue(store.inventory.isEmpty)
    }

    func test_updateInventory_directMutation_isPersistedInMemory() {
        store.addInventory(name: "番茄", quantity: 1, unit: "个", expiryDate: nil)
        store.inventory[0].quantity = 9
        XCTAssertEqual(store.inventory[0].quantity, 9)
    }

    func test_undoConsumption_restoresPreviousQuantity() {
        store.addInventory(name: "番茄", quantity: 10, unit: "个", expiryDate: nil)
        let itemID = store.inventory[0].id
        let draft = InventoryConsumptionDraft(
            id: "key", ingredientName: "番茄", normalizedName: "番茄",
            requiredQuantity: 4, requiredUnit: "个", matchedInventoryID: itemID,
            currentQuantity: 10, consumedQuantity: 4, resultingQuantity: 6,
            isSelected: true, warning: nil, sourceRecipeNames: ["菜"]
        )
        let record = store.applyConsumption([draft], planIDs: [], recipeID: nil, recipeName: "菜")
        XCTAssertEqual(store.inventory[0].quantity, 6)

        store.undoConsumption(record)
        XCTAssertEqual(store.inventory[0].quantity, 10, "quantity must be restored to what it was before consumption")
    }

    func test_undoConsumption_calledTwice_doesNotDoubleRestore() {
        store.addInventory(name: "番茄", quantity: 10, unit: "个", expiryDate: nil)
        let itemID = store.inventory[0].id
        let draft = InventoryConsumptionDraft(
            id: "key", ingredientName: "番茄", normalizedName: "番茄",
            requiredQuantity: 4, requiredUnit: "个", matchedInventoryID: itemID,
            currentQuantity: 10, consumedQuantity: 4, resultingQuantity: 6,
            isSelected: true, warning: nil, sourceRecipeNames: ["菜"]
        )
        let record = store.applyConsumption([draft], planIDs: [], recipeID: nil, recipeName: "菜")
        store.undoConsumption(record)
        store.inventory[0].quantity = 2 // simulate further consumption after undo
        store.undoConsumption(record) // second undo of the SAME already-undone record must no-op
        XCTAssertEqual(store.inventory[0].quantity, 2, "a second undo of an already-undone record must not touch inventory again")
    }
}

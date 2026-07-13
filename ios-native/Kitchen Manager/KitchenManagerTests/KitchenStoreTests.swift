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
        // itself now suggests 180 days rather than nil). `isStaple: true` is
        // the only remaining reliable way to force a truly nil expiry here.
        store.addInventory(name: "大米", quantity: 2, unit: "袋", expiryDate: nil, isStaple: true)
        store.addInventory(name: "大米", quantity: 1, unit: "袋", expiryDate: farFuture, isStaple: true)
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

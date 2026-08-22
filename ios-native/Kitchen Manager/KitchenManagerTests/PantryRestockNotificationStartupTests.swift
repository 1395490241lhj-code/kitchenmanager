import XCTest
@testable import KitchenManager

/// Phase B3: the staple-restock baseline sync used to run from
/// `KitchenStore.init`'s `inventory` didSet, on the pre-first-frame main
/// thread. These tests pin the two halves of the move: the startup load no
/// longer syncs, and everything that synced before still syncs.
///
/// `PantryRestockNotificationScheduler` reads and writes `UserDefaults.standard`
/// by design (unchanged by B3), so each test saves and restores the two keys it
/// touches rather than injecting a suite.
@MainActor
final class PantryRestockNotificationStartupTests: XCTestCase {
    private let stateKey = "native_km_staple_notification_states_v1"
    private let enabledKey = "stapleRestockNotificationsEnabled"
    private var savedState: Any?
    private var savedEnabled: Any?

    override func setUp() {
        super.setUp()
        savedState = UserDefaults.standard.object(forKey: stateKey)
        savedEnabled = UserDefaults.standard.object(forKey: enabledKey)
        UserDefaults.standard.removeObject(forKey: stateKey)
        PantryRestockNotificationScheduler.resetInitialSyncGateForTesting()
    }

    override func tearDown() {
        restore(savedState, forKey: stateKey)
        restore(savedEnabled, forKey: enabledKey)
        PantryRestockNotificationScheduler.resetInitialSyncGateForTesting()
        super.tearDown()
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private var storedBaseline: [String: Int]? {
        UserDefaults.standard.dictionary(forKey: stateKey) as? [String: Int]
    }

    private func makeStaple(name: String) -> InventoryItem {
        InventoryItem(
            name: name,
            quantity: 0,
            unit: "袋",
            expiryDate: nil,
            isStaple: true,
            lowStockThreshold: 1
        )
    }

    // MARK: - didSet no longer syncs during the startup load

    func test_storeInit_doesNotRunRestockSync() {
        _ = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        XCTAssertNil(
            storedBaseline,
            "KitchenStore.init must not touch the restock scheduler — that is the pre-first-frame path B3 removed"
        )
    }

    // MARK: - ordinary edits after the load still sync

    func test_inventoryMutationAfterInit_runsRestockSync() {
        let store = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let staple = makeStaple(name: "大米")
        store.inventory = [staple]
        XCTAssertEqual(
            storedBaseline?[staple.id.uuidString],
            staple.stapleStatus.rawValue,
            "a real inventory edit must still write the baseline exactly as before"
        )
    }

    // MARK: - the startup pass itself, and its one-shot gate

    func test_syncInitialIfNeeded_runsOnceAndWritesBaseline() {
        let first = makeStaple(name: "盐")
        PantryRestockNotificationScheduler.syncInitialIfNeeded(for: [first])
        XCTAssertEqual(
            storedBaseline?[first.id.uuidString],
            first.stapleStatus.rawValue,
            "the app-root startup pass must produce the same baseline the didSet used to"
        )

        UserDefaults.standard.removeObject(forKey: stateKey)
        PantryRestockNotificationScheduler.syncInitialIfNeeded(for: [makeStaple(name: "糖")])
        XCTAssertNil(
            storedBaseline,
            "the gate is per process: a .task restart must not rewrite the baseline and swallow a transition"
        )
    }
}

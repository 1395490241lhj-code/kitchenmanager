import XCTest
@testable import KitchenManager

/// Feature 005, Phase 4: before the first destructive restore write, a durable
/// copy of the current backup-scoped kitchen must exist — and if it cannot be
/// prepared, the restore must not begin.
///
/// The ordering assertions do not settle for "the file exists afterwards".
/// They check, from inside the first persistence write, that the copy was
/// already on disk at that moment.
@MainActor
final class RecoverySnapshotTests: XCTestCase {

    /// Records whether the recovery copy existed at the instant of the first
    /// whole-table inventory write — inventory is the first domain
    /// `restoreBackupData` replaces.
    private final class OrderingSpy: InventoryPersistenceProtocol {
        private let wrapped: InventoryPersistenceProtocol
        private let probe: () -> Bool
        private(set) var replaceCallCount = 0
        private(set) var snapshotExistedAtFirstWrite: Bool?

        init(wrapping wrapped: InventoryPersistenceProtocol, probe: @escaping () -> Bool) {
            self.wrapped = wrapped
            self.probe = probe
        }

        func loadInventory() throws -> [InventoryItem] { try wrapped.loadInventory() }
        func replaceInventory(with items: [InventoryItem]) throws {
            if replaceCallCount == 0 { snapshotExistedAtFirstWrite = probe() }
            replaceCallCount += 1
            try wrapped.replaceInventory(with: items)
        }
        func upsert(_ item: InventoryItem) throws { try wrapped.upsert(item) }
        func delete(id: UUID) throws { try wrapped.delete(id: id) }
        func deleteAll() throws { try wrapped.deleteAll() }
        func applyChanges(upserting items: [InventoryItem], deleting ids: [UUID]) throws {
            try wrapped.applyChanges(upserting: items, deleting: ids)
        }
    }

    private var directoryURL: URL!

    override func setUpWithError() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "recovery-slice-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directoryURL)
        directoryURL = nil
    }

    private func makeStore() -> KitchenRecoverySnapshotStore {
        KitchenRecoverySnapshotStore(directoryURL: directoryURL)
    }

    /// A real, current, canonical backup — the same bytes the exporter writes.
    private func canonicalBackup() throws -> Data {
        let source = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        source.addInventory(name: "番茄", quantity: 5, unit: "个", expiryDate: nil)
        source.addShopping(name: "牛奶", quantity: 1, unit: "盒")
        return try source.exportBackupData()
    }

    // MARK: - Slot semantics

    func testThereIsNoSnapshotUntilOneIsPrepared() {
        XCTAssertFalse(makeStore().hasOutstandingSnapshot)
    }

    func testPreparingWritesAnOutstandingSnapshotThatReadsBack() throws {
        let store = makeStore()
        let backup = try canonicalBackup()

        try store.prepare(backup)

        XCTAssertTrue(store.hasOutstandingSnapshot)
        XCTAssertEqual(try store.outstandingSnapshot(), backup)
    }

    func testResolvingReleasesTheSlotAndAllowsTheNextPreparation() throws {
        let store = makeStore()
        try store.prepare(try canonicalBackup())

        try store.resolve()

        XCTAssertFalse(store.hasOutstandingSnapshot)
        XCTAssertNil(try store.outstandingSnapshot())
        XCTAssertNoThrow(try store.prepare(try canonicalBackup()), "已处理的槽位可以被新的一次准备替换")
    }

    func testAnOutstandingSnapshotIsNeverSilentlyOverwritten() throws {
        let store = makeStore()
        let first = try canonicalBackup()
        try store.prepare(first)

        XCTAssertThrowsError(try store.prepare(try canonicalBackup())) { error in
            XCTAssertEqual(error as? KitchenRecoverySnapshotError, .outstandingSnapshotPresent)
        }
        XCTAssertEqual(try store.outstandingSnapshot(), first, "未处理的副本必须原样保留")
    }

    func testResolvingWithNoSnapshotIsHarmless() throws {
        XCTAssertNoThrow(try makeStore().resolve())
    }

    // MARK: - Durability across instances

    func testASnapshotSurvivesForANewlyConstructedStoreOverTheSameLocation() throws {
        let backup = try canonicalBackup()
        try makeStore().prepare(backup)

        // A second store object, as a relaunched process would build.
        let reopened = makeStore()

        XCTAssertTrue(reopened.hasOutstandingSnapshot, "副本必须是磁盘上的真相，而不是内存状态")
        let recovered = try XCTUnwrap(try reopened.outstandingSnapshot())
        XCTAssertEqual(recovered, backup)
        XCTAssertNoThrow(
            try KitchenBackupValidator.validate(recovered),
            "恢复出来的副本必须仍然通过与任何导入候选相同的校验"
        )
    }

    // MARK: - Preparation failures

    func testStorageThatCannotBeResolvedFailsPreparation() throws {
        let store = KitchenRecoverySnapshotStore(directoryURL: nil)
        XCTAssertThrowsError(try store.prepare(try canonicalBackup())) { error in
            XCTAssertEqual(error as? KitchenRecoverySnapshotError, .storageUnavailable)
        }
    }

    func testAnUnusableDirectoryFailsPreparation() throws {
        // A path whose parent is an existing regular file cannot be created.
        let blocker = FileManager.default.temporaryDirectory
            .appending(path: "recovery-blocker-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }

        let store = KitchenRecoverySnapshotStore(directoryURL: blocker.appending(path: "nested"))
        XCTAssertThrowsError(try store.prepare(try canonicalBackup())) { error in
            XCTAssertEqual(error as? KitchenRecoverySnapshotError, .writeFailed)
        }
        XCTAssertFalse(store.hasOutstandingSnapshot)
    }

    func testBytesThatCannotBeReadBackAsABackupAreNotAcceptedAsASnapshot() throws {
        let store = makeStore()

        // Writes fine, but is not a Kitchen Manager backup — the read-back gate
        // is what catches it, and the useless file must not be left behind.
        XCTAssertThrowsError(try store.prepare(Data("{}".utf8))) { error in
            XCTAssertEqual(error as? KitchenRecoverySnapshotError, .unreadableSnapshot)
        }
        XCTAssertFalse(store.hasOutstandingSnapshot, "读不回来的文件不得算作已准备好的副本")
    }

    // MARK: - The point of no return

    func testTheSnapshotExistsBeforeTheFirstDestructiveWrite() throws {
        let snapshot = makeStore()
        let base = KitchenPersistenceFactory.isolatedInMemory()
        let spy = OrderingSpy(wrapping: base.inventory) { snapshot.hasOutstandingSnapshot }
        let store = makeKitchenStore(base: base, inventory: spy, snapshot: snapshot)
        store.addInventory(name: "番茄", quantity: 5, unit: "个", expiryDate: nil)

        try store.restoreBackupData(try canonicalBackup())

        XCTAssertGreaterThan(spy.replaceCallCount, 0, "这次恢复确实写入了")
        XCTAssertEqual(
            spy.snapshotExistedAtFirstWrite, true,
            "第一次破坏性写入发生时，恢复副本必须已经在磁盘上"
        )
    }

    func testASuccessfulRestoreReleasesTheSlot() throws {
        let snapshot = makeStore()
        let store = KitchenStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            persistence: KitchenPersistenceFactory.isolatedInMemory(),
            recoverySnapshot: snapshot
        )

        try store.restoreBackupData(try canonicalBackup())

        XCTAssertFalse(snapshot.hasOutstandingSnapshot, "成功之后槽位应被显式释放")
    }

    func testPreparationFailureBlocksTheRestoreWithZeroWrites() throws {
        let snapshot = KitchenRecoverySnapshotStore(directoryURL: nil)
        let base = KitchenPersistenceFactory.isolatedInMemory()
        let spy = OrderingSpy(wrapping: base.inventory) { snapshot.hasOutstandingSnapshot }
        let store = makeKitchenStore(base: base, inventory: spy, snapshot: snapshot)
        store.addInventory(name: "番茄", quantity: 5, unit: "个", expiryDate: nil)
        let before = store.inventory

        XCTAssertThrowsError(try store.restoreBackupData(try canonicalBackup())) { error in
            XCTAssertEqual(error as? KitchenRecoverySnapshotError, .storageUnavailable)
        }

        XCTAssertEqual(spy.replaceCallCount, 0, "准备失败时不得发生任何破坏性写入")
        XCTAssertEqual(store.inventory, before, "本机状态必须保持原样")
    }

    func testValidationStillRunsBeforeAnySnapshotIsPrepared() throws {
        let snapshot = makeStore()
        let store = KitchenStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            persistence: KitchenPersistenceFactory.isolatedInMemory(),
            recoverySnapshot: snapshot
        )

        XCTAssertThrowsError(try store.restoreBackupData(Data("{}".utf8))) { error in
            XCTAssertTrue(error is KitchenBackupError, "校验仍然是第一道门")
        }
        XCTAssertFalse(snapshot.hasOutstandingSnapshot, "被校验拒绝的文件不应留下任何副本")
    }

    // MARK: - Helper

    private func makeKitchenStore(
        base: KitchenPersistenceBundle,
        inventory: InventoryPersistenceProtocol,
        snapshot: KitchenRecoverySnapshotStore
    ) -> KitchenStore {
        KitchenStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            inventoryPersistence: inventory,
            shoppingListPersistence: base.shoppingList,
            todayPlanPersistence: base.todayPlan,
            consumptionPersistence: base.consumption,
            weeklyPlanPersistence: base.weeklyPlan,
            preparedComponentPersistence: base.preparedComponents,
            specialPlanPersistence: base.specialPlans,
            recoverySnapshot: snapshot
        )
    }
}

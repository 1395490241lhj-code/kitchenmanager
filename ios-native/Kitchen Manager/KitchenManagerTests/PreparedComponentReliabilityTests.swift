import XCTest
import SwiftData
import Combine
@testable import KitchenManager

/// Real disk-backed persistence, with faults injected only at the read/save boundary.
@MainActor
final class PreparedComponentReliabilityTests: XCTestCase {
    private var directory: URL!
    private var suite: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "prepared-reliability-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "prepared-reliability-\(UUID())"
    }

    override func tearDownWithError() throws {
        UserDefaults().removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: directory)
    }

    private func bundle() throws -> KitchenPersistenceBundle {
        try KitchenPersistenceFactory.bundle(container: KitchenPersistenceFactory.makeContainer(
            configuration: ModelConfiguration(url: directory.appending(path: "kitchen.store"))
        ))
    }

    private func store(_ bundle: KitchenPersistenceBundle,
                       prepared: PreparedComponentPersistenceProtocol? = nil) -> KitchenStore {
        KitchenStore(userDefaults: UserDefaults(suiteName: suite)!,
                     inventoryPersistence: bundle.inventory, shoppingListPersistence: bundle.shoppingList,
                     todayPlanPersistence: bundle.todayPlan, consumptionPersistence: bundle.consumption,
                     weeklyPlanPersistence: bundle.weeklyPlan,
                     preparedComponentPersistence: prepared ?? bundle.preparedComponents,
                     specialPlanPersistence: bundle.specialPlans)
    }

    private func batch(_ name: String = "卤鸡腿", portions: Int = 3) -> PreparedComponent {
        PreparedComponent(name: name, portionsRemaining: portions, state: .cooked, storage: .refrigerated,
                          preparedAt: Date(timeIntervalSince1970: 1_700_000_000),
                          expiryDate: Date(timeIntervalSince1970: 1_700_300_000))
    }

    private func assertConsistent(_ expected: [PreparedComponent], store: KitchenStore,
                                  persistence: PreparedComponentPersistenceProtocol,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(store.preparedComponents, expected, "published state", file: file, line: line)
        XCTAssertEqual(try persistence.loadComponents(), expected, "same persistence context", file: file, line: line)
        XCTAssertEqual(try self.store(bundle()).preparedComponents, expected, "fresh disk reopen", file: file, line: line)
    }

    func testFailedAddKeepsMemoryAndDiskUnchanged() throws {
        let bundle = try bundle()
        let kept = batch("腌鸡胸")
        try bundle.preparedComponents.replaceComponents(with: [kept])
        let store = store(bundle)
        let persistence = try XCTUnwrap(bundle.preparedComponents as? SwiftDataPreparedComponentPersistence)
        persistence.failNextReplaceSaveForTesting = Fault.injected
        let added = batch()
        XCTAssertEqual(store.addPreparedComponent(added), .failure(.saveFailed))
        try assertConsistent([kept], store: store, persistence: persistence)
        XCTAssertEqual(store.addPreparedComponent(added), .success(added))
        try assertConsistent([kept, added], store: store, persistence: persistence)
    }

    func testFailedEditKeepsMemoryAndDiskUnchanged() throws {
        let bundle = try bundle()
        let original = batch()
        try bundle.preparedComponents.replaceComponents(with: [original])
        let store = store(bundle)
        var edited = original
        edited.name = "卤鸡翅"
        edited.portionsRemaining = 8
        let persistence = try XCTUnwrap(bundle.preparedComponents as? SwiftDataPreparedComponentPersistence)
        persistence.failNextReplaceSaveForTesting = Fault.injected
        XCTAssertEqual(store.updatePreparedComponent(edited), .failure(.saveFailed))
        try assertConsistent([original], store: store, persistence: persistence)
        XCTAssertEqual(store.updatePreparedComponent(edited), .success(edited))
        try assertConsistent([edited], store: store, persistence: persistence)
    }

    func testFailedDeleteKeepsMemoryAndDiskUnchanged() throws {
        let bundle = try bundle()
        let original = batch()
        try bundle.preparedComponents.replaceComponents(with: [original])
        let store = store(bundle)
        let persistence = try XCTUnwrap(bundle.preparedComponents as? SwiftDataPreparedComponentPersistence)
        persistence.failNextReplaceSaveForTesting = Fault.injected
        XCTAssertEqual(store.removePreparedComponent(id: original.id), .failure(.saveFailed))
        try assertConsistent([original], store: store, persistence: persistence)
        XCTAssertEqual(store.removePreparedComponent(id: original.id), .success(original))
        try assertConsistent([], store: store, persistence: persistence)
        XCTAssertEqual(store.removePreparedComponent(id: original.id), .failure(.missingRecord))
    }

    func testFailedConsumptionDoesNotReportSuccessOrChangeCounts() throws {
        try failedConsumption(portions: 3)
    }

    func testFailedFinalConsumptionDoesNotReportSuccessOrRemoveBatch() throws {
        try failedConsumption(portions: 1)
    }

    private func failedConsumption(portions: Int) throws {
        let bundle = try bundle()
        let original = batch(portions: portions)
        try bundle.preparedComponents.replaceComponents(with: [original])
        let store = store(bundle)
        let persistence = try XCTUnwrap(bundle.preparedComponents as? SwiftDataPreparedComponentPersistence)
        persistence.failNextReplaceSaveForTesting = Fault.injected
        XCTAssertEqual(store.consumePreparedPortion(id: original.id), .failure(.saveFailed))
        try assertConsistent([original], store: store, persistence: persistence)
        XCTAssertEqual(store.consumePreparedPortion(id: original.id), .success(original))
        var remaining = original
        remaining.portionsRemaining = 2
        try assertConsistent(portions == 1 ? [] : [remaining], store: store, persistence: persistence)
    }

    func testInitialLoadFailureCannotReplaceUnreadableDurableRecords() throws {
        let bundle = try bundle()
        let seeded = [batch(), batch("同名的另一批", portions: 1)]
        try bundle.preparedComponents.replaceComponents(with: seeded)
        let faulty = ReadFault(wrapping: bundle.preparedComponents)
        faulty.failReads = true
        let store = store(bundle, prepared: faulty)
        XCTAssertTrue(store.isPreparedComponentUnavailable)
        faulty.failReads = false
        XCTAssertEqual(store.addPreparedComponent(batch("后来添加")), .failure(.unavailable))
        XCTAssertEqual(store.updatePreparedComponent(seeded[0]), .failure(.unavailable))
        XCTAssertEqual(store.removePreparedComponent(id: seeded[0].id), .failure(.unavailable))
        XCTAssertEqual(store.consumePreparedPortion(id: seeded[0].id), .failure(.unavailable))
        XCTAssertEqual(store.consumePreparedPortion(id: seeded[1].id), .failure(.unavailable))
        XCTAssertTrue(store.preparedComponents.isEmpty)
        XCTAssertTrue(store.isPreparedComponentUnavailable, "successful reads outside the store cannot clear its guard")
        XCTAssertEqual(try faulty.loadComponents(), seeded, "unreadable is not empty; all original rows must survive")
        XCTAssertEqual(try self.store(self.bundle()).preparedComponents, seeded)
        XCTAssertEqual(faulty.replacements, 0)
    }

    func testFailedReloadRemainsBlockedAndSuccessfulReloadRecoversAllRecords() throws {
        let bundle = try bundle()
        let seeded = [batch(), batch("腌鸡胸", portions: 1)]
        try bundle.preparedComponents.replaceComponents(with: seeded)
        let faulty = ReadFault(wrapping: bundle.preparedComponents)
        faulty.failReads = true
        let store = store(bundle, prepared: faulty)
        XCTAssertThrowsError(try store.reloadPreparedComponents().get())
        XCTAssertTrue(store.isPreparedComponentUnavailable)
        XCTAssertEqual(store.removePreparedComponent(id: seeded[0].id), .failure(.unavailable))
        faulty.failReads = false
        try store.reloadPreparedComponents().get()
        XCTAssertFalse(store.isPreparedComponentUnavailable)
        XCTAssertNil(store.preparedComponentNotice)
        try assertConsistent(seeded, store: store, persistence: faulty)
        XCTAssertEqual(store.consumePreparedPortion(id: seeded[1].id), .success(seeded[1]))
        try assertConsistent([seeded[0]], store: store, persistence: faulty)
    }

    func testFailedReloadOfPreviouslyReadableCollectionPreservesPublishedStateAndBlocksWrites() throws {
        let bundle = try bundle()
        let original = batch()
        try bundle.preparedComponents.replaceComponents(with: [original])
        let faulty = ReadFault(wrapping: bundle.preparedComponents)
        let store = store(bundle, prepared: faulty)
        faulty.failReads = true
        XCTAssertThrowsError(try store.reloadPreparedComponents().get())
        XCTAssertEqual(store.preparedComponents, [original])
        XCTAssertEqual(store.consumePreparedPortion(id: original.id), .failure(.unavailable))
        faulty.failReads = false
        try assertConsistent([original], store: store, persistence: faulty)
    }

    func testUnavailableCollectionCannotBeClearedExportedOrUsedAsRestoreRollback() throws {
        let bundle = try bundle()
        let seeded = [batch(), batch("腌鸡胸")]
        try bundle.preparedComponents.replaceComponents(with: seeded)
        let backup = try store(bundle).exportBackupData()
        let faulty = ReadFault(wrapping: bundle.preparedComponents)
        faulty.failReads = true
        let store = store(bundle, prepared: faulty)
        store.clearAllLocalData()
        XCTAssertThrowsError(try store.exportBackupData())
        XCTAssertThrowsError(try store.restoreBackupData(backup))
        XCTAssertTrue(store.isPreparedComponentUnavailable, "failed recovery must never unlock writes")
        faulty.failReads = false
        XCTAssertEqual(try faulty.loadComponents(), seeded)
        XCTAssertEqual(try self.store(self.bundle()).preparedComponents, seeded)
        XCTAssertEqual(faulty.replacements, 0)
        try store.reloadPreparedComponents().get()
        try store.restoreBackupData(backup)
        try assertConsistent(seeded, store: store, persistence: faulty)
    }

    func testFailedRestoreWithUnreadableReconciliationBlocksUntilVerifiedReload() throws {
        let bundle = try bundle()
        let original = batch()
        let base = try XCTUnwrap(bundle.preparedComponents as? SwiftDataPreparedComponentPersistence)
        try base.replaceComponents(with: [original])
        let faulty = ReadFault(wrapping: base)
        let store = store(bundle, prepared: faulty)
        let backup = try store.exportBackupData()
        base.failNextReplaceSaveForTesting = Fault.injected
        faulty.failReads = true
        XCTAssertThrowsError(try store.restoreBackupData(backup))
        XCTAssertTrue(store.isPreparedComponentUnavailable)
        XCTAssertEqual(store.addPreparedComponent(batch("后来添加")), .failure(.unavailable))
        XCTAssertThrowsError(try store.reloadPreparedComponents().get())
        XCTAssertTrue(store.isPreparedComponentUnavailable)
        faulty.failReads = false
        try store.reloadPreparedComponents().get()
        try assertConsistent([original], store: store, persistence: faulty)
    }

    func testMissingDuplicateAndStaleRecordsAreExplicitFailures() throws {
        let bundle = try bundle()
        let original = batch()
        let store = store(bundle)
        XCTAssertEqual(store.updatePreparedComponent(original), .failure(.missingRecord))
        XCTAssertEqual(store.removePreparedComponent(id: original.id), .failure(.missingRecord))
        XCTAssertEqual(store.consumePreparedPortion(id: original.id), .failure(.missingRecord))
        XCTAssertEqual(store.addPreparedComponent(batch("   ")), .failure(.invalidComponent))
        XCTAssertEqual(store.addPreparedComponent(original), .success(original))
        XCTAssertEqual(store.addPreparedComponent(original), .failure(.duplicateID))
        XCTAssertEqual(store.consumePreparedPortion(id: original.id), .success(original))
        var edited = original
        edited.name = "旧编辑器的改名"
        XCTAssertEqual(store.updatePreparedComponent(edited, expected: original), .failure(.staleRecord))
        var remaining = original
        remaining.portionsRemaining = 2
        try assertConsistent([remaining], store: store, persistence: bundle.preparedComponents)
    }

    func testFailedWritePublishesNothingAndRetryPersistsAndPublishesExactlyOnce() throws {
        let bundle = try bundle()
        let base = try XCTUnwrap(bundle.preparedComponents as? SwiftDataPreparedComponentPersistence)
        let counting = ReadFault(wrapping: base)
        let store = store(bundle, prepared: counting)
        var observed: [[PreparedComponent]] = []
        var durableAtPublication: [[PreparedComponent]] = []
        let observation = store.$preparedComponents.dropFirst().sink { value in
            observed.append(value)
            durableAtPublication.append((try? base.loadComponents()) ?? [])
        }
        defer { observation.cancel() }
        let added = batch()
        base.failNextReplaceSaveForTesting = Fault.injected
        XCTAssertEqual(store.addPreparedComponent(added), .failure(.saveFailed))
        XCTAssertTrue(observed.isEmpty)
        XCTAssertEqual(store.addPreparedComponent(added), .success(added))
        XCTAssertEqual(observed, [[added]])
        XCTAssertEqual(durableAtPublication, [[added]], "persistence must precede the published success")
        XCTAssertEqual(counting.replacements, 2, "one failed attempt plus one retry; no didSet persistence")
        try assertConsistent([added], store: store, persistence: base)
    }

    private enum Fault: Error { case injected }

    private final class ReadFault: PreparedComponentPersistenceProtocol {
        let base: PreparedComponentPersistenceProtocol
        var failReads = false
        var replacements = 0
        init(wrapping base: PreparedComponentPersistenceProtocol) { self.base = base }
        func loadComponents() throws -> [PreparedComponent] {
            if failReads { throw Fault.injected }
            return try base.loadComponents()
        }
        func replaceComponents(with components: [PreparedComponent]) throws {
            replacements += 1
            try base.replaceComponents(with: components)
        }
        func upsert(_ component: PreparedComponent) throws { try base.upsert(component) }
        func delete(id: UUID) throws { try base.delete(id: id) }
        func deleteAll() throws { try base.deleteAll() }
    }
}

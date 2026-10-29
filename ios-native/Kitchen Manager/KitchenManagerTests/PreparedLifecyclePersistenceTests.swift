import XCTest
import SwiftData
@testable import KitchenManager

@MainActor
final class PreparedLifecyclePersistenceTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "pr3-mapping-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func container() throws -> ModelContainer {
        try KitchenPersistenceFactory.makeContainer(configuration: ModelConfiguration(url: directory.appending(path: "kitchen.store")))
    }
    private func lifeJSON(_ row: PreparedComponent) throws -> Any? {
        (try JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])?["lifecycle"]
    }
    func testEveryWriterAndReopenKeepsLifecycle() throws {
        let f = PreparedLifecycleBackupFixtures.self
        let legacy = f.row(storage: .refrigerated)
        let tracked = try f.tracked(legacy, f.thaw)
        XCTAssertNotEqual(tracked, legacy, "equality must include lifecycle")
        XCTAssertNotNil(try lifeJSON(tracked))
        let p = SwiftDataPreparedComponentPersistence(container: try container())
        try p.replaceComponents(with: [tracked])
        XCTAssertEqual(try p.loadComponents(), [tracked])
        let context = ModelContext(p.container)
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<PreparedComponentRecord>()).first)
        XCTAssertNotNil(record.lifecycleData, "init mapping cannot drop metadata")
        XCTAssertEqual(try record.decodeLifecycle(), f.thaw)
        var cooked = tracked; cooked.state = .cooked
        cooked = try f.tracked(cooked, f.cooked)
        try p.upsert(cooked)
        let fresh = SwiftDataPreparedComponentPersistence(container: try container())
        XCTAssertEqual(try fresh.loadComponents(), [cooked])
        let freshRecord = try XCTUnwrap(ModelContext(fresh.container).fetch(FetchDescriptor<PreparedComponentRecord>()).first)
        XCTAssertEqual(try freshRecord.decodeLifecycle(), f.cooked, "update mapping must replace the blob")
        try fresh.delete(id: cooked.id)
        XCTAssertTrue(try SwiftDataPreparedComponentPersistence(container: container()).loadComponents().isEmpty)
    }
    func testValidStagedLeafAttachesRatherThanDisappearing() throws {
        let f = PreparedLifecycleBackupFixtures.self
        let c = try container(); let context = ModelContext(c); context.autosaveEnabled = false
        let row = try PreparedComponentRecord(component: f.row(storage: .refrigerated), sortIndex: 0)
        row.lifecycleData = try JSONEncoder().encode(f.thaw); context.insert(row); try context.save()
        let loaded = try SwiftDataPreparedComponentPersistence(container: container()).loadComponents()
        XCTAssertEqual(loaded.count, 1)
        let json = try XCTUnwrap(lifeJSON(loaded[0]) as? [String: Any])
        XCTAssertEqual(json["thawPhase"] as? String, "thawing")
    }
    func testContextuallyInvalidLifecycleCannotDecodeAsLegacy() throws {
        let f = PreparedLifecycleBackupFixtures.self
        XCTAssertThrowsError(try f.tracked(f.row(), f.thaw), "thawing cannot remain frozen")
        XCTAssertThrowsError(try f.tracked(f.row(storage: .refrigerated), f.cooked), "known cook cannot remain prepped")
    }
    func testCorruptMetadataFencesLoadMutationAndExport() throws {
        let f = PreparedLifecycleBackupFixtures.self
        var future = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.thaw)) as! [String: Any]
        future["version"] = 2
        let cases = [(Data("broken".utf8), "prepped"),
                     (try JSONSerialization.data(withJSONObject: future), "prepped"),
                     (try JSONEncoder().encode(f.thaw), "future-state")]
        for (data, state) in cases {
            try autoreleasepool {
                let c = try KitchenPersistenceFactory.makeContainer(configuration: ModelConfiguration(url:
                    directory.appending(path: UUID().uuidString + ".store")))
                let context = ModelContext(c); context.autosaveEnabled = false
                let row = try PreparedComponentRecord(component: f.row(storage: .refrigerated), sortIndex: 0)
                row.lifecycleData = data; row.stateRawValue = state; context.insert(row); try context.save()
                let b = KitchenPersistenceFactory.bundle(container: c)
                let defaultsName = "pr3-corrupt-\(UUID())"; let defaults = UserDefaults(suiteName: defaultsName)!
                defer { defaults.removePersistentDomain(forName: defaultsName) }
                let store = KitchenStore(userDefaults: defaults, persistence: b)
                XCTAssertTrue(store.isPreparedComponentUnavailable)
                XCTAssertThrowsError(try store.exportBackupData())
                XCTAssertEqual(store.addPreparedComponent(f.row()), .failure(.unavailable))
                XCTAssertFalse(store.clearAllLocalData())
                XCTAssertThrowsError(try b.preparedComponents.replaceComponents(with: []))
                XCTAssertThrowsError(try store.reloadPreparedComponents().get())
                XCTAssertEqual(try context.fetchCount(FetchDescriptor<PreparedComponentRecord>()), 1)
                XCTAssertEqual(row.lifecycleData, data); XCTAssertEqual(row.stateRawValue, state)
            }
        }
    }
}

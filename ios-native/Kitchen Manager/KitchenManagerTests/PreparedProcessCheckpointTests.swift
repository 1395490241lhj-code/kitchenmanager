import XCTest
import SwiftData
@testable import KitchenManager

@MainActor
final class PreparedProcessCheckpointTests: XCTestCase {
    func testCheckpointsBracketCommitBeforeStorePublication() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "pr2-checkpoints-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "pr2-checkpoints-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bundle = KitchenPersistenceFactory.bundle(container: try KitchenPersistenceFactory.makeContainer(
            configuration: ModelConfiguration(url: directory.appending(path: "test.store"))))
        let persistence = try XCTUnwrap(bundle.preparedComponents as? SwiftDataPreparedComponentPersistence)
        let store = KitchenStore(userDefaults: defaults, persistence: bundle)
        let draft = PreparedSourceDraft(sourceID: UUID(), groupIDs: [UUID()], name: "鸡肉", massDecigrams: 8000,
            portionCount: 4, state: .cooked, storage: .frozen, preparedAt: Date(), expiryDate: Date())
        let original = try store.addPreparedSource(draft: draft).get()
        defer {
            persistence.beforeReplaceSaveForTesting = nil
            persistence.afterReplaceSaveForTesting = nil
        }
        var checkpoints: [String] = []
        persistence.beforeReplaceSaveForTesting = {
            checkpoints.append("before")
            XCTAssertEqual(store.preparedComponents, original)
            XCTAssertEqual(try? persistence.loadComponents(), original)
        }
        persistence.afterReplaceSaveForTesting = {
            checkpoints.append("after")
            XCTAssertEqual(store.preparedComponents, original)
            XCTAssertEqual(try? persistence.loadComponents().first?.portionsRemaining, 3)
        }
        _ = try store.consumePreparedPortion(id: original[0].id).get()
        XCTAssertEqual(checkpoints, ["before", "after"])
        XCTAssertEqual(store.preparedComponents.first?.portionsRemaining, 3)
    }
}

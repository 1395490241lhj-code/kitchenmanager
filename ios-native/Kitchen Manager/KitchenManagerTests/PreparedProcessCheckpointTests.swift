import XCTest
import SwiftData
import Combine
@testable import KitchenManager

@MainActor
final class PreparedProcessCheckpointTests: XCTestCase {
    func testPR3ProcessSeedsAndOriginalHistoricalCopiesAreQualified() throws {
        for operation in ["begin-thaw", "complete-thaw", "mark-cooked", "split-thawing", "consume-final"] {
            let payload = try PreparedProcessInterruptionFixture.pr3Payload(operation: operation)
            let bytes = try KitchenBackupValidator.encodeV3(payload)
            let decoded = try KitchenBackupValidator.validate(bytes)
            XCTAssertEqual(decoded.preparedComponents, payload.preparedComponents)
            let selected = try XCTUnwrap(decoded.preparedComponents.first)
            XCTAssertEqual(selected.portionsRemaining, operation == "split-thawing" ? 2 : 1)
            XCTAssertEqual(selected.grouping?.source.initialMassDecigrams, 8000)
            XCTAssertEqual(selected.grouping?.massPerPortionDecigrams, 2000)
            XCTAssertEqual(selected.lifecycle == nil, operation == "begin-thaw")
        }
        for version in [1, 2] {
            var payload = try PreparedProcessInterruptionFixture.pr3Payload(operation: "begin-thaw")
            if version == 1 { payload.preparedComponents = payload.preparedComponents.map { var row = $0; row.grouping = nil; return row } }
            let bytes = try PreparedProcessInterruptionFixture.historicalData(payload, version: version)
            let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let rows = try XCTUnwrap(raw["preparedComponents"] as? [[String: Any]])
            XCTAssertEqual(raw["version"] as? Int, version)
            XCTAssertTrue(rows.allSatisfy { $0["lifecycle"] == nil })
            XCTAssertEqual(try KitchenBackupValidator.validate(bytes).preparedComponents, payload.preparedComponents)
            XCTAssertEqual(rows.contains { $0["grouping"] != nil }, version == 2)
        }
        let tracked = try PreparedProcessInterruptionFixture.pr3Payload(operation: "mark-cooked")
        XCTAssertThrowsError(try PreparedProcessInterruptionFixture.historicalData(tracked, version: 2))
        XCTAssertThrowsError(try PreparedProcessInterruptionFixture.historicalData(tracked, version: 1))
    }

    func testPR3CheckpointsKeepOldPublicationUntilCompleteDurableCollection() throws {
        // Moving the after-save hook before save must fail every operation's disk assertion.
        for operation in ["begin-thaw", "complete-thaw", "mark-cooked", "split-thawing", "consume-final"] {
            let directory = FileManager.default.temporaryDirectory.appending(path: "pr3-checkpoints-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let suite = "pr3-checkpoints-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            try autoreleasepool {
            let bundle = KitchenPersistenceFactory.bundle(container: try KitchenPersistenceFactory.makeContainer(
                configuration: ModelConfiguration(url: directory.appending(path: "test.store"))))
            let persistence = try XCTUnwrap(bundle.preparedComponents as? SwiftDataPreparedComponentPersistence)
            let date: (Double) -> Date = { Date(timeIntervalSince1970: $0) }
            let source = try PreparedSourceSnapshot(id: UUID(), name: "鸡肉", initialMassDecigrams: 8000, initialPortionCount: 4)
            let grouping = try PreparedPortionGrouping(source: source, massPerPortionDecigrams: 2000)
            var selected = PreparedComponent(name: "鸡肉", portionsRemaining: operation == "split-thawing" ? 2 : 1,
                state: .prepped, storage: .frozen, preparedAt: date(100), expiryDate: date(100000), grouping: grouping)
            if operation != "begin-thaw" {
                selected.storage = .refrigerated
                selected.lifecycle = PreparedLifecycle(version: 1, thawPhase: .thawing,
                    thawStartedAt: date(110), thawCompletedAt: nil, cookedAt: nil)
            }
            if operation == "mark-cooked" || operation == "consume-final" {
                selected.lifecycle = PreparedLifecycle(version: 1, thawPhase: .inactive,
                    thawStartedAt: date(110), thawCompletedAt: date(150), cookedAt: nil)
            }
            if operation == "consume-final" {
                selected.state = .cooked
                selected.lifecycle = PreparedLifecycle(version: 1, thawPhase: .inactive,
                    thawStartedAt: date(110), thawCompletedAt: date(150), cookedAt: date(200))
            }
            let sibling = PreparedComponent(name: "鸡肉", portionsRemaining: 4 - selected.portionsRemaining,
                state: .prepped, storage: .frozen, preparedAt: date(100), expiryDate: date(100000), grouping: grouping)
            let old = [selected, sibling]
            try persistence.replaceComponents(with: old)
            let store = KitchenStore(userDefaults: defaults, persistence: bundle)
            var changed = selected
            let newID = UUID()
            var expected = old
            switch operation {
            case "begin-thaw":
                changed.storage = .refrigerated
                changed.lifecycle = PreparedLifecycle(version: 1, thawPhase: .thawing,
                    thawStartedAt: date(300), thawCompletedAt: nil, cookedAt: nil)
            case "complete-thaw":
                changed.lifecycle = PreparedLifecycle(version: 1, thawPhase: .inactive,
                    thawStartedAt: date(110), thawCompletedAt: date(300), cookedAt: nil)
            case "mark-cooked":
                changed.state = .cooked
                changed.lifecycle = PreparedLifecycle(version: 1, thawPhase: .inactive,
                    thawStartedAt: date(110), thawCompletedAt: date(150), cookedAt: date(300))
            case "split-thawing": changed.portionsRemaining = 1
            default: break
            }
            expected[0] = changed
            if operation == "split-thawing" { var split = changed; split.id = newID; expected.insert(split, at: 1) }
            if operation == "consume-final" { expected.removeFirst() }
            var checkpoints = [String](); var publications = [[PreparedComponent]]()
            let subscription = store.$preparedComponents.dropFirst().sink { publications.append($0) }
            defer { subscription.cancel(); persistence.beforeReplaceSaveForTesting = nil; persistence.afterReplaceSaveForTesting = nil }
            persistence.beforeReplaceSaveForTesting = {
                checkpoints.append("before")
                XCTAssertEqual(store.preparedComponents, old, operation)
                XCTAssertEqual(try? persistence.loadComponents(), old, operation)
                XCTAssertTrue(publications.isEmpty, operation)
            }
            persistence.afterReplaceSaveForTesting = {
                checkpoints.append("after")
                XCTAssertEqual(store.preparedComponents, old, operation)
                XCTAssertEqual(try? persistence.loadComponents(), expected, operation)
                XCTAssertTrue(publications.isEmpty, operation)
            }
            if operation == "split-thawing" {
                _ = try store.splitPreparedComponent(id: selected.id, taking: 1, newGroupID: newID, expected: selected).get()
            } else if operation == "consume-final" {
                _ = try store.consumePreparedPortion(id: selected.id, expected: selected, context: .immediateMeal).get()
            } else {
                let action: PreparedLifecycleAction = operation == "begin-thaw" ? .beginThaw : operation == "complete-thaw" ? .completeThaw : .markCooked
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                let intent = PreparedLifecycleIntent(action: action, eventAt: date(300), calendar: calendar,
                    expiryReview: PreparedExpiryReview(action: action, existingExpiryDate: selected.expiryDate,
                        selectedExpiryDate: selected.expiryDate, explicitlyEdited: false))
                _ = try store.transitionPreparedComponent(id: selected.id, expected: selected, intent: intent).get()
            }
            XCTAssertEqual(checkpoints, ["before", "after"], operation)
            XCTAssertEqual(publications, [expected], operation)
            XCTAssertEqual(store.preparedComponents, expected, operation)
            XCTAssertEqual(try persistence.loadComponents(), expected, operation)
            }
        }
    }

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

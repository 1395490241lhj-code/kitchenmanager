import XCTest
import SwiftData
import Combine
@testable import KitchenManager

@MainActor
final class PreparedPortionGroupingStoreTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "pr2-store-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "pr2-store-\(UUID())"; defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: directory)
    }
    private func bundle() throws -> KitchenPersistenceBundle {
        KitchenPersistenceFactory.bundle(container: try KitchenPersistenceFactory.makeContainer(
            configuration: ModelConfiguration(url: directory.appending(path: "test.store"))
        ))
    }
    private func draft(mass: Int64 = 8000, count: Int = 4) -> PreparedSourceDraft {
        PreparedSourceDraft(sourceID: UUID(), groupIDs: (0..<(mass % Int64(max(count, 1)) == 0 ? 1 : 2)).map { _ in UUID() },
            name: "鸡肉", massDecigrams: mass, portionCount: count, state: .cooked, storage: .frozen,
            preparedAt: Date(timeIntervalSince1970: 100), expiryDate: Date(timeIntervalSince1970: 200))
    }
    private func store(_ b: KitchenPersistenceBundle) -> KitchenStore {
        KitchenStore(userDefaults: defaults, persistence: b)
    }
    private func assertDisk(_ expected: [PreparedComponent], _ s: KitchenStore, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(s.preparedComponents, expected, file: file, line: line)
        XCTAssertEqual(try bundle().preparedComponents.loadComponents(), expected, file: file, line: line)
    }
    func testCreationAllocatesExactlyAndSplitPreservesIdentityFieldsOrderAndDisk() throws {
        for d in [draft(), draft(mass: 1000, count: 3)] {
            let b = try bundle(); let s = store(b)
            let before = s.preparedComponents
            let created = try s.addPreparedSource(draft: d).get()
            XCTAssertEqual(created.map(\.id), d.groupIDs)
            XCTAssertEqual(created.reduce(Int64(0)) { $0 + Int64($1.portionsRemaining) * $1.grouping!.massPerPortionDecigrams }, d.massDecigrams)
            XCTAssertEqual(created.reduce(0) { $0 + $1.portionsRemaining }, d.portionCount)
            let original = try XCTUnwrap(created.last)
            let newID = UUID()
            let split = try s.splitPreparedComponent(id: original.id, taking: 1, newGroupID: newID, expected: original).get()
            var remainder = original; remainder.portionsRemaining -= 1
            var separated = original; separated.id = newID; separated.portionsRemaining = 1
            XCTAssertEqual(split, [remainder, separated])
            try assertDisk(before + Array(created.dropLast()) + split, s)
        }
    }
    func testCreationAndSplitSaveFailureKeepDiskAndPublicationThenRetrySameIDs() throws {
        let b = try bundle(); let s = store(b)
        let p = try XCTUnwrap(b.preparedComponents as? SwiftDataPreparedComponentPersistence)
        var events = [[PreparedComponent]]()
        let subscription = s.$preparedComponents.dropFirst().sink { events.append($0) }
        defer { subscription.cancel() }
        let d = draft(mass: 1000, count: 3)
        p.failNextReplaceSaveForTesting = Fault.injected
        XCTAssertEqual(s.addPreparedSource(draft: d), .failure(.saveFailed))
        try assertDisk([], s); XCTAssertTrue(events.isEmpty)
        let added = try s.addPreparedSource(draft: d).get()
        XCTAssertEqual(added.map(\.id), d.groupIDs); XCTAssertEqual(events, [added])
        let target = added[1]; let sibling = UUID()
        p.failNextReplaceSaveForTesting = Fault.injected
        XCTAssertEqual(s.splitPreparedComponent(id: target.id, taking: 1, newGroupID: sibling, expected: target), .failure(.saveFailed))
        try assertDisk(added, s); XCTAssertEqual(events, [added])
        let split = try s.splitPreparedComponent(id: target.id, taking: 1, newGroupID: sibling, expected: target).get()
        try assertDisk([added[0]] + split, s); XCTAssertEqual(events.count, 2)
        XCTAssertEqual(s.addPreparedSource(draft: d), .failure(.duplicateID))
        XCTAssertEqual(events.count, 2)
    }
    func testDurableSavePrecedesSinglePublication() throws {
        let b = try bundle(); let s = store(b)
        var durable = [[PreparedComponent]]()
        let subscription = s.$preparedComponents.dropFirst().sink { _ in durable.append(try! b.preparedComponents.loadComponents()) }
        defer { subscription.cancel() }
        let created = try s.addPreparedSource(draft: draft()).get()
        let split = try s.splitPreparedComponent(id: created[0].id, taking: 1, newGroupID: UUID(), expected: created[0]).get()
        XCTAssertEqual(durable, [created, split])
    }
    func testInvalidDraftsAndAllIdentityCollisionsNeverWrite() throws {
        let b = try bundle(); let s = store(b)
        let d = draft(); let rows = try s.addPreparedSource(draft: d).get()
        for bad in [draft(mass: 2, count: 3), draft(mass: 0), draft(count: 51), draft(count: 0)] {
            XCTAssertEqual(s.addPreparedSource(draft: bad), .failure(.invalidComponent))
        }
        let collisionDrafts = [
            PreparedSourceDraft(sourceID: d.sourceID, groupIDs: [UUID()], name: d.name, massDecigrams: 8000, portionCount: 4, state: d.state, storage: d.storage, preparedAt: d.preparedAt, expiryDate: d.expiryDate),
            PreparedSourceDraft(sourceID: rows[0].id, groupIDs: [UUID()], name: d.name, massDecigrams: 8000, portionCount: 4, state: d.state, storage: d.storage, preparedAt: d.preparedAt, expiryDate: d.expiryDate),
            PreparedSourceDraft(sourceID: UUID(), groupIDs: [d.sourceID], name: d.name, massDecigrams: 8000, portionCount: 4, state: d.state, storage: d.storage, preparedAt: d.preparedAt, expiryDate: d.expiryDate),
            PreparedSourceDraft(sourceID: UUID(), groupIDs: [rows[0].id], name: d.name, massDecigrams: 8000, portionCount: 4, state: d.state, storage: d.storage, preparedAt: d.preparedAt, expiryDate: d.expiryDate)
        ]
        for bad in collisionDrafts { XCTAssertEqual(s.addPreparedSource(draft: bad), .failure(.duplicateID)) }
        for id in [d.sourceID, rows[0].id] {
            XCTAssertEqual(s.splitPreparedComponent(id: rows[0].id, taking: 1, newGroupID: id, expected: rows[0]), .failure(.duplicateID))
        }
        for n in [0, -1, 4, Int.max] {
            XCTAssertEqual(s.splitPreparedComponent(id: rows[0].id, taking: n, newGroupID: UUID(), expected: rows[0]), .failure(.invalidComponent))
        }
        try assertDisk(rows, s)
    }
    func testGenericAddCannotMintOrReattachGroupedRowsAndGroupedEditNeedsExpectedSnapshot() throws {
        let b = try bundle(); let s = store(b)
        let source = try PreparedSourceSnapshot(id: UUID(), name: "鸡肉", initialMassDecigrams: 8000, initialPortionCount: 4)
        let row = PreparedComponent(name: "鸡肉", portionsRemaining: 1, state: .cooked, storage: .frozen,
            preparedAt: Date(), expiryDate: Date(), grouping: try PreparedPortionGrouping(source: source, massPerPortionDecigrams: 2000))
        XCTAssertEqual(s.addPreparedComponent(row), .failure(.invalidComponent))
        try b.preparedComponents.replaceComponents(with: [row]); try s.reloadPreparedComponents().get()
        var edit = row; edit.name = "改名"
        XCTAssertEqual(s.updatePreparedComponent(edit), .failure(.staleRecord))
        XCTAssertEqual(s.updatePreparedComponent(edit, expected: row), .success(edit))
        try assertDisk([edit], s)
    }
    func testStaleSplitAfterConsumptionOrAnotherWriterCannotResurrectPortions() throws {
        let b = try bundle(); let s = store(b)
        let row = try XCTUnwrap(s.addPreparedSource(draft: draft()).get().first)
        _ = try s.consumePreparedPortion(id: row.id).get()
        XCTAssertEqual(s.splitPreparedComponent(id: row.id, taking: 1, newGroupID: UUID(), expected: row), .failure(.staleRecord))
        let stale = s.preparedComponents[0]
        let other = store(try bundle()); _ = try other.consumePreparedPortion(id: row.id).get()
        XCTAssertEqual(s.splitPreparedComponent(id: row.id, taking: 1, newGroupID: UUID(), expected: stale), .failure(.saveFailed))
        XCTAssertEqual(s.preparedComponents, [stale])
        XCTAssertEqual(try bundle().preparedComponents.loadComponents().first?.portionsRemaining, 2)
    }
    func testConsumeFinalSiblingAndDeleteUseGroupUUIDAndLeaveInventoryAlone() throws {
        let b = try bundle(); let s = store(b)
        s.addInventory(name: "鸡肉", quantity: 8, unit: "份", expiryDate: nil)
        let inventory = s.inventory
        let row = try XCTUnwrap(s.addPreparedSource(draft: draft()).get().first)
        let split = try s.splitPreparedComponent(id: row.id, taking: 1, newGroupID: UUID(), expected: row).get()
        XCTAssertEqual(s.consumePreparedPortion(id: row.grouping!.source.id), .failure(.missingRecord))
        XCTAssertEqual(s.consumePreparedPortion(id: split[1].id), .success(split[1]))
        try assertDisk([split[0]], s)
        XCTAssertEqual(s.removePreparedComponent(id: split[0].id), .success(split[0]))
        try assertDisk([], s); XCTAssertEqual(s.inventory, inventory)
    }
    private enum Fault: Error { case injected }
}

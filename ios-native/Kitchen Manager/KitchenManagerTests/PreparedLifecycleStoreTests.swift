import XCTest
import SwiftData
import Combine
@testable import KitchenManager

@MainActor
final class PreparedLifecycleStoreTests: XCTestCase {
    private var directory: URL!
    private var suite: String!
    private let f = PreparedLifecycleBackupFixtures.self
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "pr3-store-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "pr3-store-\(UUID())"
    }
    override func tearDownWithError() throws {
        UserDefaults().removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: directory)
    }
    private func bundle() throws -> KitchenPersistenceBundle {
        KitchenPersistenceFactory.bundle(container: try KitchenPersistenceFactory.makeContainer(
            configuration: ModelConfiguration(url: directory.appending(path: "kitchen.store"))))
    }
    private func store(_ b: KitchenPersistenceBundle, prepared: PreparedComponentPersistenceProtocol? = nil) -> KitchenStore {
        KitchenStore(userDefaults: UserDefaults(suiteName: suite)!, inventoryPersistence: b.inventory,
            shoppingListPersistence: b.shoppingList, todayPlanPersistence: b.todayPlan,
            consumptionPersistence: b.consumption, weeklyPlanPersistence: b.weeklyPlan,
            preparedComponentPersistence: prepared ?? b.preparedComponents, specialPlanPersistence: b.specialPlans,
            recoverySnapshot: KitchenRecoverySnapshotStore(directoryURL: directory.appending(path: "recovery")))
    }
    private func transition(_ s: KitchenStore, _ row: PreparedComponent, _ action: PreparedLifecycleAction,
                            at: Date? = nil) throws -> PreparedComponent {
        try s.transitionPreparedComponent(id: row.id, expected: row,
            intent: f.intent(action, row: row, eventAt: at ?? f.at)).get()
    }
    func testLegacyAndMeasuredProtectionMatrix() throws {
        let b = try bundle(); let s = store(b); let row = f.row()
        _ = try s.addPreparedComponent(row).get()
        var edit = row; edit.storage = .refrigerated; edit.state = .cooked; edit.portionsRemaining = 8
        _ = try s.updatePreparedComponent(edit).get()
        XCTAssertNil(s.preparedComponents[0].lifecycle)
        edit.storage = .frozen; edit.state = .prepped
        _ = try s.updatePreparedComponent(edit).get()
        let p = try XCTUnwrap(b.preparedComponents as? SwiftDataPreparedComponentPersistence)
        p.failNextReplaceSaveForTesting = Fault.injected
        XCTAssertEqual(s.transitionPreparedComponent(id: edit.id, expected: edit,
            intent: try f.intent(.beginThaw, row: edit)), .failure(.saveFailed))
        XCTAssertEqual(s.preparedComponents, [edit])
        let thawed = try transition(s, edit, .beginThaw)
        XCTAssertNotNil(thawed.lifecycle)
        var countCorrection = thawed; countCorrection.portionsRemaining = 7
        _ = try s.updatePreparedComponent(countCorrection, expected: thawed).get()
        for change in 0..<3 {
            var bad = countCorrection
            if change == 0 { bad.storage = .frozen }
            if change == 1 { bad.state = .cooked }
            if change == 2 { bad.lifecycle = nil }
            XCTAssertThrowsError(try s.updatePreparedComponent(bad, expected: countCorrection).get())
        }
        let source = try PreparedSourceSnapshot(id: UUID(), name: "鸡肉", initialMassDecigrams: 2000, initialPortionCount: 1)
        let measured = PreparedComponent(name: "鸡肉", portionsRemaining: 1, state: .prepped, storage: .frozen,
            preparedAt: f.at, expiryDate: f.expiry,
            grouping: try PreparedPortionGrouping(source: source, massPerPortionDecigrams: 2000))
        try b.preparedComponents.replaceComponents(with: [measured]); try s.reloadPreparedComponents().get()
        for change in 0..<3 {
            var bad = measured
            if change == 0 { bad.storage = .refrigerated }
            if change == 1 { bad.state = .cooked }
            if change == 2 { bad.portionsRemaining = 2 }
            XCTAssertThrowsError(try s.updatePreparedComponent(bad, expected: measured).get())
        }
        XCTAssertEqual(s.preparedComponents, [measured])
    }
    func testPreOptInEditorCannotStripCommittedLifecycle() throws {
        let b = try bundle(); let s = store(b); let row = f.row()
        _ = try s.addPreparedComponent(row).get()
        var draft = PreparedComponentFormDraft(existing: row); draft.name = "保留更名"; draft.state = .cooked
        let thaw = try transition(s, row, .beginThaw)
        XCTAssertEqual(draft.save(in: s), .failure(.staleRecord))
        XCTAssertTrue(draft.acceptCurrent(thaw)); XCTAssertEqual(draft.state, thaw.state)
        XCTAssertEqual(draft.storage, thaw.storage)
        let saved = try draft.save(in: s).get()[0]
        XCTAssertEqual(saved.lifecycle, thaw.lifecycle); XCTAssertEqual(saved.expiryDate, thaw.expiryDate)
        var stripped = saved; stripped.lifecycle = nil
        XCTAssertThrowsError(try s.updatePreparedComponent(stripped).get())
        var injected = row; injected.id = UUID(); injected.storage = .refrigerated; injected.lifecycle = f.thaw
        XCTAssertThrowsError(try s.addPreparedComponent(injected).get())
        XCTAssertThrowsError(try s.updatePreparedComponent(injected, expected: saved).get())
    }
    func testTransitionSavesBeforeSinglePublicationAndRetryKeepsIntent() throws {
        let b = try bundle(); let s = store(b); let row = f.row()
        _ = try s.addPreparedComponent(row).get()
        let p = try XCTUnwrap(b.preparedComponents as? SwiftDataPreparedComponentPersistence)
        defer { p.beforeReplaceSaveForTesting = nil; p.afterReplaceSaveForTesting = nil }
        let intent = try f.intent(.beginThaw, row: row)
        var events = [[PreparedComponent]](); var saves = 0
        let sub = s.$preparedComponents.dropFirst().sink { value in
            events.append(value)
            XCTAssertEqual(try! self.bundle().preparedComponents.loadComponents(), value)
        }; defer { sub.cancel() }
        p.beforeReplaceSaveForTesting = { XCTAssertEqual(s.preparedComponents, [row]) }
        p.afterReplaceSaveForTesting = { saves += 1; XCTAssertEqual(s.preparedComponents, [row]) }
        p.failNextReplaceSaveForTesting = Fault.injected
        XCTAssertEqual(s.transitionPreparedComponent(id: row.id, expected: row, intent: intent), .failure(.saveFailed))
        XCTAssertTrue(events.isEmpty); XCTAssertEqual(saves, 0)
        XCTAssertEqual(try bundle().preparedComponents.loadComponents(), [row])
        let result = try s.transitionPreparedComponent(id: row.id, expected: row, intent: intent).get()
        XCTAssertEqual(result.lifecycle?.thawStartedAt, intent.eventAt)
        XCTAssertEqual(result.expiryDate, intent.expiryReview.selectedExpiryDate)
        XCTAssertEqual(events, [[result]]); XCTAssertEqual(saves, 1)
        XCTAssertEqual(s.transitionPreparedComponent(id: row.id, expected: row, intent: intent), .failure(.staleRecord))
        XCTAssertEqual(events.count, 1)
    }
    func testStaleInMemoryAndDurableWriterNeverCommitProposal() throws {
        let b = try bundle(); try b.preparedComponents.replaceComponents(with: [f.row()])
        let s = store(b); let row = s.preparedComponents[0]
        let second = store(try bundle()); let thaw = try transition(second, row, .beginThaw)
        XCTAssertEqual(s.transitionPreparedComponent(id: row.id, expected: row,
            intent: try f.intent(.beginThaw, row: row)), .failure(.saveFailed))
        XCTAssertEqual(s.preparedComponents, [row])
        XCTAssertEqual(try bundle().preparedComponents.loadComponents(), [thaw])
        try s.reloadPreparedComponents().get()
        XCTAssertEqual(s.transitionPreparedComponent(id: row.id, expected: row,
            intent: try f.intent(.beginThaw, row: row)), .failure(.staleRecord))
        XCTAssertThrowsError(try transition(s, thaw, .markCooked))
    }
    func testActiveThawSplitAndConsumptionKeepExactMetadata() throws {
        for (mass, count) in [(8000 as Int64, 4), (1000, 3)] {
            let b = try bundle(); let s = store(b)
            let draft = PreparedSourceDraft(sourceID: UUID(), groupIDs: (0..<(mass % Int64(count) == 0 ? 1 : 2)).map { _ in UUID() },
                name: "鸡肉", massDecigrams: mass, portionCount: count, state: .prepped, storage: .frozen,
                preparedAt: f.at, expiryDate: f.expiry)
            let added = try s.addPreparedSource(draft: draft).get()
            let target = try XCTUnwrap(added.last)
            let thaw = try transition(s, target, .beginThaw)
            let before = s.preparedComponents; let newID = UUID()
            let p = try XCTUnwrap(b.preparedComponents as? SwiftDataPreparedComponentPersistence)
            p.failNextReplaceSaveForTesting = Fault.injected
            XCTAssertEqual(s.splitPreparedComponent(id: thaw.id, taking: 1, newGroupID: newID, expected: thaw), .failure(.saveFailed))
            XCTAssertEqual(s.preparedComponents, before)
            let split = try s.splitPreparedComponent(id: thaw.id, taking: 1, newGroupID: newID, expected: thaw).get()
            XCTAssertEqual(split.map(\.lifecycle), [thaw.lifecycle, thaw.lifecycle])
            XCTAssertEqual(split.map(\.expiryDate), [thaw.expiryDate, thaw.expiryDate])
            XCTAssertEqual(split[0].id, thaw.id); XCTAssertEqual(split[1].id, newID)
            let completed = try transition(s, split[1], .completeThaw)
            let cooked = try transition(s, completed, .markCooked)
            XCTAssertEqual(cooked.id, newID); XCTAssertEqual(cooked.grouping, target.grouping)
            XCTAssertEqual(s.preparedComponents.first { $0.id == split[0].id }, split[0])
            _ = try s.consumePreparedPortion(id: cooked.id, expected: cooked, context: .immediateMeal).get()
            XCTAssertNil(s.preparedComponents.first { $0.id == newID })
            let remaining = s.preparedComponents.filter { $0.grouping?.source.id == draft.sourceID }
            XCTAssertEqual(remaining.reduce(0) { $0 + $1.portionsRemaining }, count - 1)
            XCTAssertEqual(remaining.reduce(Int64(0)) { $0 + Int64($1.portionsRemaining) * $1.grouping!.massPerPortionDecigrams }, mass - target.grouping!.massPerPortionDecigrams)
            let previous = try s.consumePreparedPortion(id: split[0].id).get()
            if previous.portionsRemaining > 1 {
                XCTAssertEqual(s.preparedComponents.first { $0.id == previous.id }?.lifecycle, thaw.lifecycle)
            }
            XCTAssertTrue(s.inventory.isEmpty); XCTAssertTrue(s.plans.isEmpty); XCTAssertTrue(s.consumptionRecords.isEmpty)
            for row in s.preparedComponents { _ = try s.removePreparedComponent(id: row.id).get() }
        }
    }
    func testImmediateMealRequiresExpectedEligibleLiveRow() throws {
        let b = try bundle(); let s = store(b)
        let rows = [f.row(), f.row(state: .cooked), f.row(storage: .refrigerated),
                    try f.tracked(f.row(storage: .refrigerated), f.thaw)]
        try b.preparedComponents.replaceComponents(with: rows); try s.reloadPreparedComponents().get()
        for row in rows {
            let eligible = row.storage == .refrigerated && row.lifecycle?.thawPhase != .thawing
            XCTAssertEqual(PreparedMealAvailability.isEligible(row), eligible)
            XCTAssertThrowsError(try s.consumePreparedPortion(id: row.id, context: .immediateMeal).get())
            if !eligible { XCTAssertThrowsError(try s.consumePreparedPortion(id: row.id, expected: row, context: .immediateMeal).get()) }
        }
        let row = rows[2]
        _ = try s.consumePreparedPortion(id: row.id, expected: row, context: .immediateMeal).get()
        XCTAssertEqual(s.consumePreparedPortion(id: row.id, expected: row, context: .immediateMeal), .failure(.staleRecord))
        _ = try s.consumePreparedPortion(id: rows[0].id).get()
    }
    func testInvalidAndStaleRequestsNeverReachPersistence() throws {
        let b = try bundle(); let s = store(b); let row = f.row()
        _ = try s.addPreparedComponent(row).get()
        let p = try XCTUnwrap(b.preparedComponents as? SwiftDataPreparedComponentPersistence)
        var saves = 0; p.beforeReplaceSaveForTesting = { saves += 1 }
        defer { p.beforeReplaceSaveForTesting = nil }
        XCTAssertEqual(s.transitionPreparedComponent(id: row.id, expected: row,
            intent: try f.intent(.markCooked, row: row)), .failure(.invalidTransition))
        var stale = row; stale.portionsRemaining -= 1
        XCTAssertEqual(s.transitionPreparedComponent(id: row.id, expected: stale,
            intent: try f.intent(.beginThaw, row: row)), .failure(.staleRecord))
        let valid = try f.intent(.beginThaw, row: row)
        let badReview = PreparedLifecycleIntent(action: .beginThaw, eventAt: valid.eventAt, calendar: valid.calendar,
            expiryReview: PreparedExpiryReview(action: .markCooked, existingExpiryDate: row.expiryDate,
                selectedExpiryDate: valid.expiryReview.selectedExpiryDate, explicitlyEdited: true))
        XCTAssertEqual(s.transitionPreparedComponent(id: row.id, expected: row, intent: badReview), .failure(.expiryReviewRequired))
        var injected = row; injected.storage = .refrigerated; injected.lifecycle = f.thaw
        XCTAssertEqual(s.updatePreparedComponent(injected, expected: row), .failure(.staleRecord))
        XCTAssertEqual(saves, 0); XCTAssertEqual(try bundle().preparedComponents.loadComponents(), [row])
    }
    func testChickenSelectedGroupJourneyKeepsThreeFrozenPortions() throws {
        let b = try bundle(); let s = store(b)
        let d = PreparedSourceDraft(sourceID: UUID(), groupIDs: [UUID()], name: "鸡肉", massDecigrams: 8000,
            portionCount: 4, state: .prepped, storage: .frozen, preparedAt: f.at, expiryDate: f.expiry)
        let group = try s.addPreparedSource(draft: d).get()[0]
        let split = try s.splitPreparedComponent(id: group.id, taking: 1, newGroupID: UUID(), expected: group).get()
        let frozen = split[0]; var selected = split[1]
        for action in [PreparedLifecycleAction.beginThaw, .completeThaw, .markCooked] {
            selected = try transition(s, selected, action)
            XCTAssertEqual(s.preparedComponents.first { $0.id == frozen.id }, frozen)
            XCTAssertEqual(selected.grouping, group.grouping); XCTAssertEqual(selected.portionsRemaining, 1)
        }
        _ = try s.consumePreparedPortion(id: selected.id, expected: selected, context: .immediateMeal).get()
        XCTAssertEqual(s.preparedComponents, [frozen]); XCTAssertEqual(frozen.portionsRemaining, 3)
        XCTAssertEqual(frozen.grouping!.source.initialMassDecigrams, 8000)
        XCTAssertEqual(frozen.grouping!.massPerPortionDecigrams * Int64(frozen.portionsRemaining), 6000)
        XCTAssertEqual(try bundle().preparedComponents.loadComponents(), [frozen])
    }
    private enum Fault: Error { case injected }
}

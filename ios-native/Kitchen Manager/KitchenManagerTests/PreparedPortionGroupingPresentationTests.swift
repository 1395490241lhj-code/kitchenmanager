import XCTest
import SwiftData
@testable import KitchenManager

@MainActor
final class PreparedPortionGroupingPresentationTests: XCTestCase {
    func testDecimalParsingIsExactOptionalAndLocaleSeparatorAware() throws {
        for (text, expected) in [("800", Int64(8000)), ("100.0", 1000), ("0.1", 1), (".5", 5), ("1,5", 15), (" 002.3 ", 23), ("922337203685477580.7", Int64.max)] {
            XCTAssertEqual(try PreparedMassInput.parse(text), expected, text)
        }
        XCTAssertNil(try PreparedMassInput.parse("  "))
    }
    func testParserRejectsPrecisionOverflowNonNumbersAndUnitsWithoutRounding() {
        for text in ["0", "-1", "+1", "800.05", "800.00", ".", "NaN", "Inf", "1e3", "1 g", "1,000.0", "1 000", "1.2.3", "922337203685477580.8", "99999999999999999999999999999999"] {
            XCTAssertThrowsError(try PreparedMassInput.parse(text), text)
        }
    }
    func testMassFormattingDoesNotUseFloatingPoint() {
        XCTAssertEqual(PreparedMassInput.grams(2000), "200g")
        XCTAssertEqual(PreparedMassInput.grams(334), "33.4g")
        XCTAssertEqual(PreparedMassInput.grams(Int64.max), "922337203685477580.7g")
    }
    func testDraftKeepsReservedIDsAcrossOneTwoOneBucketsAndInvalidEdits() throws {
        var draft = PreparedComponentFormDraft(); draft.name = "鸡肉"; draft.massText = "800"
        let ids = draft.reservedGroupIDs; let source = draft.sourceID
        XCTAssertEqual(try draft.allocation()?.groups.map(\.id), Array(ids.prefix(1)))
        XCTAssertEqual(try draft.allocation()?.groups.map(\.massPerPortionDecigrams), [2000])
        draft.massText = "100"; draft.portions = 3
        XCTAssertEqual(try draft.allocation()?.groups.map(\.id), ids)
        XCTAssertEqual(try draft.allocation()?.groups.map(\.massPerPortionDecigrams), [334, 333])
        draft.massText = "100.01"; XCTAssertThrowsError(try draft.allocation())
        draft.massText = "800"; draft.portions = 4
        XCTAssertEqual(try draft.measuredDraft()?.groupIDs, Array(ids.prefix(1)))
        XCTAssertEqual(draft.sourceID, source); XCTAssertEqual(draft.reservedGroupIDs, ids)
    }
    func testInvalidCountAndImpossibleAllocationDoNotClampOrWrite() throws {
        let store = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        for (mass, count) in [("0.2", 3), ("800", 0), ("800", 51), ("", 51)] {
            var d = PreparedComponentFormDraft(); d.name = "鸡肉"; d.massText = mass; d.portions = count
            XCTAssertThrowsError(try d.allocation())
            XCTAssertEqual(d.save(in: store), .failure(.invalidComponent)); XCTAssertTrue(store.preparedComponents.isEmpty)
        }
    }
    func testMeasuredDraftRetryKeepsIDsAfterRealSaveFailureAndLegacyStillWorks() throws {
        let b = KitchenPersistenceFactory.isolatedInMemory()
        let store = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!, persistence: b)
        let p = try XCTUnwrap(b.preparedComponents as? SwiftDataPreparedComponentPersistence)
        var d = PreparedComponentFormDraft(); d.name = "鸡肉"; d.massText = "100"; d.portions = 3
        p.failNextReplaceSaveForTesting = NSError(domain: "synthetic", code: 1)
        XCTAssertEqual(d.save(in: store), .failure(.saveFailed)); XCTAssertTrue(store.preparedComponents.isEmpty)
        let rows = try d.save(in: store).get(); XCTAssertEqual(rows.map(\.id), d.reservedGroupIDs)
        XCTAssertEqual(d.save(in: store), .failure(.duplicateID))
        var legacy = PreparedComponentFormDraft(); legacy.name = "卤鸡腿"
        let row = try XCTUnwrap(legacy.save(in: store).get().first)
        XCTAssertEqual(row.id, legacy.legacyID); XCTAssertNil(row.grouping)
    }
    func testGroupedEditPreservesMetadataAndExplicitRecheckKeepsDraftAfterStaleConsume() throws {
        let store = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        var add = PreparedComponentFormDraft(); add.name = "鸡肉"; add.massText = "800"
        let original = try XCTUnwrap(add.save(in: store).get().first)
        var edit = PreparedComponentFormDraft(existing: original); edit.name = "改名"
        _ = try store.consumePreparedPortion(id: original.id).get()
        XCTAssertEqual(edit.save(in: store), .failure(.staleRecord)); XCTAssertEqual(edit.name, "改名")
        let current = try XCTUnwrap(store.preparedComponents.first)
        XCTAssertTrue(edit.acceptCurrent(current)); XCTAssertEqual(edit.name, "改名")
        let saved = try XCTUnwrap(edit.save(in: store).get().first)
        XCTAssertEqual(saved.grouping, original.grouping); XCTAssertEqual(saved.portionsRemaining, 3)
        XCTAssertEqual(saved.id, original.id)
        XCTAssertTrue(edit.acceptCurrent(saved), "quantity protection must be tested with a current expected row")
        edit.portions = saved.portionsRemaining + 1 // Within original allocation capacity; still immutable in PR2.
        XCTAssertEqual(edit.save(in: store), .failure(.staleRecord))
    }
    func testProjectionPreservesFirstSourceOrderAndMapsGroupActionsToUUIDs() throws {
        let store = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        var d = PreparedComponentFormDraft(); d.name = "鸡肉"; d.massText = "800"
        let row = try XCTUnwrap(d.save(in: store).get().first)
        let split = try store.splitPreparedComponent(id: row.id, taking: 2, newGroupID: UUID(), expected: row).get()
        var legacy = split[0]; legacy.id = UUID(); legacy.grouping = nil
        var other = PreparedComponentFormDraft(); other.name = "鸡肉"; other.massText = "100"; other.portions = 3
        let independent = try other.save(in: store).get()
        let sections = try PreparedSourceSection.make([split[0], legacy] + independent + [split[1]])
        XCTAssertEqual(sections.map(\.id), [d.sourceID, legacy.id, other.sourceID])
        XCTAssertEqual(sections[0].components.map(\.id), split.map(\.id))
        XCTAssertEqual(sections[0].remainingMassDecigrams, 8000)
        XCTAssertEqual(sections[0].remainingPortionCount, 4)
        XCTAssertNotEqual(sections[0].groupLabel(for: split[0]), sections[0].groupLabel(for: split[1]))
        XCTAssertNil(sections[1].remainingMassDecigrams)
        _ = try store.removePreparedComponent(id: sections[0].components[1].id).get()
        XCTAssertEqual(store.preparedComponents.filter { $0.grouping?.source.id == d.sourceID }.map(\.id), [split[0].id])
    }
}

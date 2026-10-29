import XCTest
@testable import KitchenManager

@MainActor
final class PreparedPortionGroupingValidationTests: XCTestCase {
    let sourceID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    func source(mass: Int64 = 8_000, count: Int = 4, name: String = "鸡肉") throws -> PreparedSourceSnapshot {
        try PreparedSourceSnapshot(id: sourceID, name: name, initialMassDecigrams: mass, initialPortionCount: count)
    }
    func component(_ source: PreparedSourceSnapshot? = nil, mass: Int64 = 2_000, count: Int = 1) throws -> PreparedComponent {
        PreparedComponent(name: "鸡肉", portionsRemaining: count, state: .prepped, storage: .frozen,
            preparedAt: Date(timeIntervalSince1970: 100), expiryDate: Date(timeIntervalSince1970: 200),
            grouping: try source.map { try PreparedPortionGrouping(source: $0, massPerPortionDecigrams: mass) })
    }
    func testValidLinkedAndLegacyCollectionAndDepletedBuckets() throws {
        let s = try source(mass: 1_000, count: 3)
        let values = try [component(s, mass: 334), component(s, mass: 333, count: 2), component()]
        XCTAssertNoThrow(try PreparedComponentCollectionValidator.validate(values))
        XCTAssertNoThrow(try PreparedComponentCollectionValidator.validate(Array(values.dropFirst())))
        XCTAssertNoThrow(try PreparedComponentCollectionValidator.validate([]))
    }
    func testDuplicateIDsIncludingLegacyAreRejected() throws {
        let c = try component()
        XCTAssertThrowsError(try PreparedComponentCollectionValidator.validate([c, c]))
    }
    func testSourceIDCannotCollideWithAnyGroupIncludingLegacy() throws {
        var legacy = try component(); legacy.id = sourceID
        XCTAssertThrowsError(try PreparedComponentCollectionValidator.validate([legacy, component(source())]))
    }
    func testConflictingSourceSnapshotsAreRejected() throws {
        XCTAssertThrowsError(try PreparedComponentCollectionValidator.validate([
            component(source()), component(source(name: "不同原名"))
        ]))
    }
    func testSourceAllocationCannotBeExceededAcrossGroups() throws {
        XCTAssertThrowsError(try PreparedComponentCollectionValidator.validate([
            component(source(), count: 3), component(source(), count: 2)
        ]))
    }
    func testTooManyLargerRemainderPortionsAreRejectedDespiteInBoundsTotals() throws {
        let s = try source(mass: 1_000, count: 3)
        XCTAssertThrowsError(try PreparedComponentCollectionValidator.validate([
            component(s, mass: 334), component(s, mass: 334)
        ]))
    }
    func testUnreachableMassIsRejectedDespiteInBoundsTotals() throws {
        XCTAssertThrowsError(try PreparedComponentCollectionValidator.validate([component(source(), mass: 4_000)]))
    }
    func testInvalidMutableCountsAndBlankNamesAreRejectedWithoutClamping() throws {
        for count in [0, -1, 51, Int.max] {
            var c = try component(source()); c.portionsRemaining = count
            XCTAssertThrowsError(try PreparedComponentCollectionValidator.validate([c]))
        }
        var c = try component(); c.name = " "
        XCTAssertThrowsError(try PreparedComponentCollectionValidator.validate([c]))
    }
    func testAggregateOverflowIsRejectedRatherThanTrapping() throws {
        let s = try source(mass: .max, count: 1)
        XCTAssertThrowsError(try PreparedComponentCollectionValidator.validate([
            component(s, mass: .max), component(s, mass: .max)
        ]))
    }
    func testGroupedInitializationCannotClampZeroToOne() throws {
        let c = try component(source(), count: 0)
        XCTAssertEqual(c.portionsRemaining, 0)
        XCTAssertThrowsError(try PreparedComponentCollectionValidator.validate([c]))
    }
    func testLegacyCodableOmitsGroupingAndPreservesAllValues() throws {
        let old = try component()
        let data = try JSONEncoder().encode(old)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["grouping"])
        XCTAssertEqual(try JSONDecoder().decode(PreparedComponent.self, from: data), old)
    }
    func testGroupedCodableRoundTripPreservesSourceAndMass() throws {
        let c = try component(source(), count: 4)
        let data = try JSONEncoder().encode(c)
        XCTAssertEqual(try JSONDecoder().decode(PreparedComponent.self, from: data), c)
        XCTAssertNotNil((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["grouping"])
    }
    func testUnsupportedMetadataVersionAndMalformedPayloadsAreRejected() throws {
        let metadata = try PreparedPortionGrouping(source: source(), massPerPortionDecigrams: 2_000)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
        for version in [0, 2, -1] {
            object["version"] = version
            XCTAssertThrowsError(try JSONDecoder().decode(PreparedPortionGrouping.self, from: JSONSerialization.data(withJSONObject: object)))
        }
        for text in ["null", "{}", "[]", "broken"] {
            XCTAssertThrowsError(try JSONDecoder().decode(PreparedPortionGrouping.self, from: Data(text.utf8)))
        }
    }
    func testDecodedSourceAndComponentCountsMustNotBypassValidation() throws {
        let c = try component(source())
        let encoded = try JSONEncoder().encode(c)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["portionsRemaining"] = 0
        XCTAssertThrowsError(try JSONDecoder().decode(PreparedComponent.self, from: JSONSerialization.data(withJSONObject: object)))
        var metadata = try XCTUnwrap(object["grouping"] as? [String: Any])
        var snapshot = try XCTUnwrap(metadata["source"] as? [String: Any])
        snapshot["initialMassDecigrams"] = -1; metadata["source"] = snapshot
        object["grouping"] = metadata; object["portionsRemaining"] = 1
        XCTAssertThrowsError(try JSONDecoder().decode(PreparedComponent.self, from: JSONSerialization.data(withJSONObject: object)))
    }
}

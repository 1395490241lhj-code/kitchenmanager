import XCTest
@testable import KitchenManager

@MainActor
final class PreparedPortionGroupingTests: XCTestCase {
    private let sourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let thirdID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

    private func source(mass: Int64 = 8_000, portions: Int = 4) throws -> PreparedSourceSnapshot {
        try PreparedSourceSnapshot(
            id: sourceID, name: "鸡肉", initialMassDecigrams: mass, initialPortionCount: portions
        )
    }

    private func group(count: Int = 4, mass: Int64 = 2_000) throws -> PreparedAllocatedGroup {
        try PreparedAllocatedGroup(
            id: firstID, sourceID: sourceID, count: count, massPerPortionDecigrams: mass
        )
    }

    private func assertError<T>(
        _ expected: PreparedPortionGroupingError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> T
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? PreparedPortionGroupingError, expected, file: file, line: line)
        }
    }

    func testSnapshotPreservesIdentityAndOriginalQuantity() throws {
        let snapshot = try PreparedSourceSnapshot(
            id: sourceID, name: "  鸡肉\n", initialMassDecigrams: 8_000, initialPortionCount: 4
        )
        XCTAssertEqual(snapshot.id, sourceID)
        XCTAssertEqual(snapshot.name, "鸡肉")
        XCTAssertEqual(snapshot.initialMassDecigrams, 8_000)
        XCTAssertEqual(snapshot.initialPortionCount, 4)
    }

    func test800GramsIntoFourPortionsMakesOne200GramGroup() throws {
        let snapshot = try source()
        let plan = try PreparedPortionAllocator.allocate(source: snapshot, groupIDs: [firstID])
        XCTAssertEqual(plan.source, snapshot)
        XCTAssertEqual(plan.groups.count, 1)
        let allocated = try XCTUnwrap(plan.groups.first)
        XCTAssertEqual(allocated.id, firstID)
        XCTAssertEqual(allocated.sourceID, sourceID)
        XCTAssertNotEqual(allocated.id, allocated.sourceID)
        XCTAssertEqual(allocated.count, 4)
        XCTAssertEqual(allocated.massPerPortionDecigrams, 2_000)
        XCTAssertEqual(allocated.totalMassDecigrams, 8_000)
        XCTAssertEqual(plan.totalMassDecigrams, 8_000)
        XCTAssertEqual(plan.portionCount, 4)
    }

    func test100GramsIntoThreePortionsAllocatesExactRemainderFirst() throws {
        let plan = try PreparedPortionAllocator.allocate(
            source: source(mass: 1_000, portions: 3), groupIDs: [firstID, secondID]
        )
        XCTAssertEqual(plan.groups.map(\.id), [firstID, secondID])
        XCTAssertEqual(plan.groups.map(\.sourceID), [sourceID, sourceID])
        XCTAssertEqual(plan.groups.map(\.count), [1, 2])
        XCTAssertEqual(plan.groups.map(\.massPerPortionDecigrams), [334, 333])
        XCTAssertEqual(plan.groups.map(\.totalMassDecigrams), [334, 666])
        XCTAssertEqual(plan.totalMassDecigrams, 1_000)
        XCTAssertEqual(plan.portionCount, 3)
    }

    func testOneGramIntoThreeIncludesSmallerWholePhysicalPortions() throws {
        let plan = try PreparedPortionAllocator.allocate(
            source: source(mass: 10, portions: 3), groupIDs: [firstID, secondID]
        )
        XCTAssertEqual(plan.groups.map(\.massPerPortionDecigrams), [4, 3])
        XCTAssertEqual(plan.groups.map(\.count), [1, 2])
        XCTAssertEqual(plan.totalMassDecigrams, 10)
        XCTAssertEqual(plan.portionCount, 3)
    }

    func testMinimumMassAndSinglePortionHaveNoEmptyRemainderGroup() throws {
        let plan = try PreparedPortionAllocator.allocate(
            source: source(mass: 1, portions: 1), groupIDs: [firstID]
        )
        XCTAssertEqual(plan.groups.count, 1)
        XCTAssertEqual(plan.groups.first?.count, 1)
        XCTAssertEqual(plan.groups.first?.massPerPortionDecigrams, 1)
        XCTAssertEqual(plan.totalMassDecigrams, 1)
    }

    func testFiftyPortionBoundaryIsAcceptedWithoutClamping() throws {
        let plan = try PreparedPortionAllocator.allocate(
            source: source(mass: 50, portions: 50), groupIDs: [firstID]
        )
        XCTAssertEqual(plan.groups.first?.count, 50)
        XCTAssertEqual(plan.groups.first?.massPerPortionDecigrams, 1)
        XCTAssertEqual(plan.portionCount, 50)
    }

    func testSourceRejectsZeroAndNegativeMass() {
        for mass: Int64 in [0, -1, .min] {
            assertError(.invalidMass) { try source(mass: mass) }
        }
    }

    func testSourceRejectsOutOfRangeCountsRatherThanClamping() {
        for count in [Int.min, -1, 0, 51, Int.max] {
            assertError(.invalidPortionCount) { try source(portions: count) }
        }
    }

    func testSourceRejectsImpossibleSubDecigramPortions() {
        assertError(.insufficientMass) { try source(mass: 2, portions: 3) }
    }

    func testSourceRejectsBlankName() {
        assertError(.invalidName) {
            try PreparedSourceSnapshot(
                id: sourceID, name: " \n ", initialMassDecigrams: 10, initialPortionCount: 1
            )
        }
    }

    func testAllocationRequiresExactlyOneIDForEvenAllocation() throws {
        let snapshot = try source()
        for ids in [[], [firstID, secondID]] {
            assertError(.invalidGroupIDCount) {
                try PreparedPortionAllocator.allocate(source: snapshot, groupIDs: ids)
            }
        }
    }

    func testAllocationRequiresExactlyTwoIDsForUnevenAllocation() throws {
        let snapshot = try source(mass: 1_000, portions: 3)
        for ids in [[], [firstID], [firstID, secondID, thirdID]] {
            assertError(.invalidGroupIDCount) {
                try PreparedPortionAllocator.allocate(source: snapshot, groupIDs: ids)
            }
        }
    }

    func testAllocationRejectsDuplicateGroupIDs() throws {
        let snapshot = try source(mass: 1_000, portions: 3)
        assertError(.duplicateID) {
            try PreparedPortionAllocator.allocate(source: snapshot, groupIDs: [firstID, firstID])
        }
    }

    func testAllocationRejectsSourceIDAsAnyGroupID() throws {
        assertError(.duplicateID) {
            try PreparedPortionAllocator.allocate(source: source(), groupIDs: [sourceID])
        }
        let snapshot = try source(mass: 1_000, portions: 3)
        for ids in [[sourceID, firstID], [firstID, sourceID]] {
            assertError(.duplicateID) {
                try PreparedPortionAllocator.allocate(source: snapshot, groupIDs: ids)
            }
        }
    }

    func testSameDraftIDsProduceExactlyTheSamePlanOnRetry() throws {
        let snapshot = try source(mass: 1_000, portions: 3)
        let first = try PreparedPortionAllocator.allocate(source: snapshot, groupIDs: [firstID, secondID])
        let retry = try PreparedPortionAllocator.allocate(source: snapshot, groupIDs: [firstID, secondID])
        XCTAssertEqual(first, retry)
        XCTAssertEqual(retry.groups.map(\.id), [firstID, secondID])
    }

    func testSameNameDoesNotLinkIndependentSources() throws {
        let first = try PreparedPortionAllocator.allocate(source: source(), groupIDs: [firstID])
        let otherSource = try PreparedSourceSnapshot(
            id: secondID, name: "鸡肉", initialMassDecigrams: 8_000, initialPortionCount: 4
        )
        let second = try PreparedPortionAllocator.allocate(source: otherSource, groupIDs: [thirdID])
        XCTAssertEqual(first.source.name, second.source.name)
        XCTAssertNotEqual(first.source.id, second.source.id)
        XCTAssertEqual(second.groups.first?.sourceID, secondID)
    }

    func testMaximumInt64MassDoesNotOverflowWhenThereIsNoRemainder() throws {
        let plan = try PreparedPortionAllocator.allocate(
            source: source(mass: .max, portions: 1), groupIDs: [firstID]
        )
        XCTAssertEqual(plan.groups.first?.massPerPortionDecigrams, Int64.max)
        XCTAssertEqual(plan.totalMassDecigrams, Int64.max)
    }

    func testMaximumInt64MassIntoFiftyIsConservedWithoutOverflow() throws {
        let plan = try PreparedPortionAllocator.allocate(
            source: source(mass: .max, portions: 50), groupIDs: [firstID, secondID]
        )
        XCTAssertEqual(plan.groups.map(\.count), [7, 43])
        XCTAssertEqual(plan.groups.map(\.massPerPortionDecigrams), [Int64.max / 50 + 1, Int64.max / 50])
        XCTAssertEqual(plan.totalMassDecigrams, Int64.max)
        XCTAssertEqual(plan.portionCount, 50)
    }

    func testGroupRejectsMultiplicationOverflow() {
        assertError(.arithmeticOverflow) { try group(count: 2, mass: .max) }
        assertError(.arithmeticOverflow) { try group(count: 50, mass: Int64.max / 50 + 1) }
    }

    func testGroupRejectsInvalidCountMassAndIdentity() {
        for count in [Int.min, -1, 0, 51, Int.max] {
            assertError(.invalidPortionCount) { try group(count: count) }
        }
        for mass: Int64 in [.min, -1, 0] {
            assertError(.invalidMass) { try group(mass: mass) }
        }
        assertError(.duplicateID) {
            try PreparedAllocatedGroup(id: sourceID, sourceID: sourceID, count: 1, massPerPortionDecigrams: 1)
        }
    }

    func testSplitFourIntoThreeAndOnePreservesMassAndIdentities() throws {
        let original = try group()
        let split = try PreparedPortionAllocator.split(group: original, taking: 1, newGroupID: secondID)
        XCTAssertEqual(split.remaining.id, firstID)
        XCTAssertEqual(split.separated.id, secondID)
        XCTAssertEqual(split.remaining.sourceID, sourceID)
        XCTAssertEqual(split.separated.sourceID, sourceID)
        XCTAssertEqual(split.remaining.count, 3)
        XCTAssertEqual(split.separated.count, 1)
        XCTAssertEqual(split.remaining.massPerPortionDecigrams, 2_000)
        XCTAssertEqual(split.separated.massPerPortionDecigrams, 2_000)
        XCTAssertEqual(split.remaining.totalMassDecigrams, 6_000)
        XCTAssertEqual(split.separated.totalMassDecigrams, 2_000)
        XCTAssertEqual(split.remaining.totalMassDecigrams + split.separated.totalMassDecigrams, original.totalMassDecigrams)
        XCTAssertEqual(original.count, 4, "Splitting builds new values; the input remains unchanged")
    }

    func testSplitRejectsZeroNegativeFullAndExcessCounts() throws {
        let original = try group()
        for count in [Int.min, -1, 0, 4, 5, Int.max] {
            assertError(.invalidSplitCount) {
                try PreparedPortionAllocator.split(group: original, taking: count, newGroupID: secondID)
            }
        }
    }

    func testSinglePortionCannotBeSplitIntoFractionalPortions() throws {
        let original = try group(count: 1)
        assertError(.invalidSplitCount) {
            try PreparedPortionAllocator.split(group: original, taking: 1, newGroupID: secondID)
        }
    }

    func testSplitRejectsExistingGroupAndSourceIDs() throws {
        let original = try group()
        for id in [firstID, sourceID] {
            assertError(.duplicateID) {
                try PreparedPortionAllocator.split(group: original, taking: 1, newGroupID: id)
            }
        }
    }

    func testRepeatedSplitsPreserveAllMassCountAndUniqueIDs() throws {
        let original = try group()
        let first = try PreparedPortionAllocator.split(group: original, taking: 1, newGroupID: secondID)
        let second = try PreparedPortionAllocator.split(group: first.remaining, taking: 1, newGroupID: thirdID)
        let groups = [second.remaining, second.separated, first.separated]
        XCTAssertEqual(groups.map(\.count), [2, 1, 1])
        XCTAssertEqual(groups.reduce(0) { $0 + $1.totalMassDecigrams }, 8_000)
        XCTAssertEqual(groups.reduce(0) { $0 + $1.count }, 4)
        XCTAssertEqual(Set(groups.map(\.id)).count, 3)
        XCTAssertTrue(groups.allSatisfy { $0.sourceID == sourceID && $0.massPerPortionDecigrams == 2_000 })
    }

    func testSplitOfSmallerRoundingGroupDoesNotRedistributeItsMass() throws {
        let plan = try PreparedPortionAllocator.allocate(
            source: source(mass: 1_000, portions: 3), groupIDs: [firstID, secondID]
        )
        let smaller = try XCTUnwrap(plan.groups.last)
        let split = try PreparedPortionAllocator.split(group: smaller, taking: 1, newGroupID: thirdID)
        XCTAssertEqual(split.remaining.massPerPortionDecigrams, 333)
        XCTAssertEqual(split.separated.massPerPortionDecigrams, 333)
        XCTAssertEqual(plan.groups.first?.totalMassDecigrams, 334)
        XCTAssertEqual(split.remaining.totalMassDecigrams + split.separated.totalMassDecigrams, 666)
        XCTAssertEqual(split.remaining.id, secondID)
    }

    func testFiftyPortionsSplitIntoFortyNineAndOneNearInt64Limit() throws {
        let original = try group(count: 50, mass: Int64.max / 50)
        let split = try PreparedPortionAllocator.split(group: original, taking: 49, newGroupID: secondID)
        XCTAssertEqual(split.remaining.count, 1)
        XCTAssertEqual(split.separated.count, 49)
        XCTAssertEqual(split.remaining.id, firstID)
        XCTAssertEqual(split.separated.id, secondID)
        XCTAssertEqual(split.remaining.sourceID, sourceID)
        XCTAssertEqual(split.separated.massPerPortionDecigrams, original.massPerPortionDecigrams)
        XCTAssertEqual(split.remaining.totalMassDecigrams + split.separated.totalMassDecigrams, original.totalMassDecigrams)
    }

    func testValidAllocationGridConservesEveryDecigramAndPhysicalPortion() throws {
        for count in 1...50 {
            for mass in [Int64(count), Int64(count + 1), 1_000, Int64.max] {
                let snapshot = try source(mass: mass, portions: count)
                let ids = mass % Int64(count) == 0 ? [firstID] : [firstID, secondID]
                let plan = try PreparedPortionAllocator.allocate(source: snapshot, groupIDs: ids)
                XCTAssertEqual(plan.totalMassDecigrams, mass)
                XCTAssertEqual(plan.portionCount, count)
                XCTAssertEqual(plan.groups.map(\.id), ids)
                XCTAssertTrue(plan.groups.allSatisfy { $0.count > 0 && $0.massPerPortionDecigrams > 0 })
                XCTAssertLessThanOrEqual(
                    (plan.groups.map(\.massPerPortionDecigrams).max() ?? 0)
                    - (plan.groups.map(\.massPerPortionDecigrams).min() ?? 0), 1
                )
            }
        }
    }
}

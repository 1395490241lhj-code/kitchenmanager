import XCTest
@testable import KitchenManager

@MainActor
final class SafeRestoreFixtureTests: XCTestCase {
    func testLiteralHistoricalAndCurrentCandidateShapes() throws {
        for state in [SafeRestoreFixture.State.legacy, .dated, .v2, .mixedV3, .missingLifecycleV3] {
            let bytes = try SafeRestoreFixture.candidateData(state: state)
            let evidence = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.json")
            evidence.name = "safe-restore-" + state.rawValue; evidence.lifetime = .keepAlways; add(evidence)
            let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let expectedVersion = state == .legacy || state == .dated ? 1 : state == .v2 ? 2 : 3
            XCTAssertEqual(raw["version"] as? Int, expectedVersion)
            if state == .missingLifecycleV3 {
                XCTAssertThrowsError(try KitchenBackupValidator.validateCandidate(bytes)); continue
            }
            let candidate = try KitchenBackupValidator.validateCandidate(bytes)
            XCTAssertEqual(candidate.version, expectedVersion); XCTAssertEqual(candidate.payload.version, 3)
            XCTAssertEqual(candidate.exportedAt == nil, state == .legacy)
            if state == .legacy { XCTAssertNil(raw["preparedComponents"]) }
            else if state == .dated {
                XCTAssertEqual(candidate.payload.inventory.count, 2); XCTAssertEqual(candidate.payload.shoppingItems.count, 1)
            } else {
                let rows = try XCTUnwrap(raw["preparedComponents"] as? [[String: Any]])
                XCTAssertFalse(rows.isEmpty)
                XCTAssertTrue(rows.allSatisfy { state == .v2 ? $0["lifecycle"] == nil : $0["lifecycle"] != nil })
                if state == .mixedV3 {
                    XCTAssertTrue(candidate.payload.preparedComponents.contains { $0.lifecycle != nil })
                    XCTAssertTrue(candidate.payload.preparedComponents.contains { $0.lifecycle == nil })
                }
            }
            let confirmed = try KitchenBackupValidator.encodeV3(candidate.payload)
            XCTAssertEqual(try KitchenBackupValidator.validateCandidate(confirmed).version, 3)
        }
    }
    func testProcessHistoricalSeedUsesOriginalV1RowVocabulary() throws {
        let payload = PreparedLifecycleBackupFixtures.payload([PreparedLifecycleBackupFixtures.row()])
        let bytes = try PreparedProcessInterruptionFixture.historicalV1Data(payload)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(raw["version"] as? Int, 1)
        let rows = try XCTUnwrap(raw["preparedComponents"] as? [[String: Any]])
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0["lifecycle"] == nil && $0["grouping"] == nil })
        let candidate = try KitchenBackupValidator.validateCandidate(bytes)
        XCTAssertTrue(candidate.payload.preparedComponents.allSatisfy { $0.lifecycle == nil && $0.grouping == nil })
    }
}

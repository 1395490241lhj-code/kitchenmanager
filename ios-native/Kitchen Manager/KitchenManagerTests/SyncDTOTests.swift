import XCTest
@testable import KitchenManager

final class SyncDTOTests: XCTestCase {
    private let userID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let householdID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let entityID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    func testBootstrapDecodePreservesScopesAndFractionalDate() throws {
        let json = """
        {"schemaVersion":1,"user":{"id":"\(userID)","email":"cook@example.com"},
        "households":[{"id":"\(householdID)","role":"owner"}],"defaultHouseholdId":"\(householdID)",
        "syncScopes":[{"type":"household","id":"\(householdID)","cursor":"900719925474099312345"}],
        "serverTime":"2026-07-13T12:00:00.123Z","capabilities":{"push":true,"pull":true,"maxBatchSize":100}}
        """
        let value = try SyncCoding.decoder().decode(SyncBootstrapResponse.self, from: Data(json.utf8))
        XCTAssertEqual(value.user.id, userID)
        XCTAssertEqual(value.syncScopes.first?.cursor.rawValue, "900719925474099312345")
        XCTAssertEqual(value.defaultHouseholdId, householdID)
    }

    func testChangeDecodePreservesBigIntAndPayload() throws {
        let json = """
        {"scopeType":"household","scopeId":"\(householdID)","cursor":"999999999999999999999","hasMore":false,
        "changes":[{"sequence":"999999999999999999999","entityType":"inventory_item","entityId":"\(entityID)",
        "operation":"upsert","version":"4","changedAt":"2026-07-13T12:00:00Z","data":{"name":"鸡蛋","quantity":6}}]}
        """
        let value = try SyncCoding.decoder().decode(SyncChangesResponse.self, from: Data(json.utf8))
        XCTAssertEqual(value.cursor.rawValue, "999999999999999999999")
        XCTAssertEqual(value.changes.first?.data["name"], .string("鸡蛋"))
    }

    func testMutationEncodeUsesStringBaseVersionAndNoDeleteData() throws {
        let mutation = SyncMutation(
            mutationId: UUID(), entityType: .inventoryItem, entityId: entityID,
            operation: .delete, baseVersion: try SyncCursorValue("9007199254740993"),
            clientUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000), data: nil
        )
        let data = try SyncCoding.encoder().encode(SyncMutationBatchRequest(
            scope: SyncScope(type: .household, id: householdID), mutations: [mutation]
        ))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let mutations = try XCTUnwrap(object["mutations"] as? [[String: Any]])
        XCTAssertEqual(mutations[0]["baseVersion"] as? String, "9007199254740993")
        XCTAssertNil(mutations[0]["data"])
    }

    func testMutationResultAndConflictDecode() throws {
        let mutationID = UUID()
        let json = """
        {"mutationId":"\(mutationID)","entityId":"\(entityID)","status":"conflict","version":"8",
        "sequence":null,"errorCode":"stale_version","originalStatus":null,"serverRecord":{"name":"云端鸡蛋"}}
        """
        let result = try SyncCoding.decoder().decode(SyncMutationResult.self, from: Data(json.utf8))
        let conflict = try XCTUnwrap(SyncConflict(result: result))
        XCTAssertEqual(conflict.remoteVersion?.rawValue, "8")
        XCTAssertEqual(conflict.serverRecord?["name"], .string("云端鸡蛋"))
    }

    func testTombstoneDecode() throws {
        let json = #"{"id":"\#(entityID)","deletedAt":"2026-07-13T12:00:00Z","version":"12"}"#
        let value = try SyncCoding.decoder().decode(SyncTombstone.self, from: Data(json.utf8))
        XCTAssertEqual(value.id, entityID)
        XCTAssertEqual(value.version.rawValue, "12")
    }

    func testUnknownEntityFailsSafely() {
        let json = """
        {"sequence":"1","entityType":"future_entity","entityId":"\(entityID)","operation":"upsert",
        "version":"1","changedAt":"2026-07-13T12:00:00Z","data":{}}
        """
        XCTAssertThrowsError(try SyncCoding.decoder().decode(SyncChangeEnvelope.self, from: Data(json.utf8)))
    }

    func testUnknownMutationStatusFailsSafely() {
        let json = """
        {"mutationId":"\(UUID())","entityId":"\(entityID)","status":"future_status",
        "version":null,"sequence":null,"errorCode":null,"originalStatus":null,"serverRecord":null}
        """
        XCTAssertThrowsError(try SyncCoding.decoder().decode(SyncMutationResult.self, from: Data(json.utf8)))
    }

    func testMalformedDateFails() {
        let json = """
        {"sequence":"1","entityType":"inventory_item","entityId":"\(entityID)","operation":"upsert",
        "version":"1","changedAt":"not-a-date","data":{}}
        """
        XCTAssertThrowsError(try SyncCoding.decoder().decode(SyncChangeEnvelope.self, from: Data(json.utf8)))
    }

    func testCursorValidationAndArbitraryPrecisionOrdering() throws {
        XCTAssertThrowsError(try SyncCursorValue("-1"))
        XCTAssertThrowsError(try SyncCursorValue("1.2"))
        XCTAssertThrowsError(try SyncCursorValue("1e9"))
        XCTAssertThrowsError(try SyncCursorValue("١"))
        XCTAssertThrowsError(try SyncCursorValue(""))
        XCTAssertThrowsError(try SyncCursorValue("01"))
        XCTAssertLessThan(try SyncCursorValue("99999999999999999999"), try SyncCursorValue("100000000000000000000"))
    }
}

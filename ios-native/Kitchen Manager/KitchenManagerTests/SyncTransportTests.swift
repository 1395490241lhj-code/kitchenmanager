import XCTest
@testable import KitchenManager

final class SyncTransportTests: NetworkTestCase {
    private let userID = UUID()
    private let scope = SyncScope(type: .household, id: UUID())

    func testFeatureFlagDefaultsAndMissingConfigurationAreDisabled() {
        XCTAssertFalse(SyncConfiguration().isEnabled)
        XCTAssertFalse(SyncConfiguration.load(from: Bundle(for: SyncTransportTests.self)).isEnabled)
    }

    func testBootstrapUsesBearerTokenWithoutPuttingItInURL() async throws {
        let token = "sensitive-test-token"
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data(self.bootstrapJSON.utf8)) }
        let transport = ExpressSyncTransport(client: apiClient, tokenProvider: FixedSyncTokenProvider(token: token))
        let response = try await transport.bootstrap()
        XCTAssertEqual(response.user.id, userID)
        let request = try XCTUnwrap(MockURLProtocol.capturedRequests().first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertFalse(request.url!.absoluteString.contains(token))
        XCTAssertEqual(request.url?.path, "/api/sync/bootstrap")
    }

    func testMissingTokenFailsBeforeNetwork() async {
        let transport = ExpressSyncTransport(client: apiClient, tokenProvider: FixedSyncTokenProvider(token: nil))
        await XCTAssertThrowsSyncError(.notAuthenticated) { _ = try await transport.bootstrap() }
        XCTAssertTrue(MockURLProtocol.capturedRequests().isEmpty)
    }

    func testChangesRequestUsesPerScopeCursorLimitAndInventoryFilter() async throws {
        let json = """
        {"scopeType":"household","scopeId":"\(scope.id)","cursor":"123","hasMore":false,"changes":[]}
        """
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data(json.utf8)) }
        let transport = ExpressSyncTransport(client: apiClient, tokenProvider: FixedSyncTokenProvider(token: "token"))
        _ = try await transport.fetchChanges(scope: scope, after: try SyncCursorValue("123"), limit: 50)
        let request = try XCTUnwrap(MockURLProtocol.capturedRequests().first)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first(where: { $0.name == "scopeType" })?.value, "household")
        XCTAssertEqual(query.first(where: { $0.name == "scopeId" })?.value, scope.id.uuidString.lowercased())
        XCTAssertEqual(query.first(where: { $0.name == "cursor" })?.value, "123")
        XCTAssertEqual(query.first(where: { $0.name == "limit" })?.value, "50")
        XCTAssertEqual(query.first(where: { $0.name == "entityTypes" })?.value, "inventory_item")
    }

    func testMutationRequestEncodesContract() async throws {
        let mutationID = UUID(), entityID = UUID()
        let response = """
        {"results":[{"mutationId":"\(mutationID)","entityId":"\(entityID)","status":"applied",
        "version":"1","sequence":"2","errorCode":null,"originalStatus":null,"serverRecord":null}],"cursor":"2"}
        """
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data(response.utf8)) }
        let transport = ExpressSyncTransport(client: apiClient, tokenProvider: FixedSyncTokenProvider(token: "token"))
        _ = try await transport.sendMutations(scope: scope, mutations: [SyncMutation(
            mutationId: mutationID, entityType: .inventoryItem, entityId: entityID,
            operation: .upsert, baseVersion: .zero, clientUpdatedAt: Date(),
            data: ["name": .string("鸡蛋")]
        )])
        let request = try XCTUnwrap(MockURLProtocol.capturedRequests().first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/sync/mutations")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["scopeType"] as? String, "household")
        XCTAssertEqual(body["scopeId"] as? String, scope.id.uuidString.uppercased())
        let mutations = try XCTUnwrap(body["mutations"] as? [[String: Any]])
        XCTAssertEqual(mutations.first?["mutationId"] as? String, mutationID.uuidString.uppercased())
    }

    func testHTTPStatusMappingsAreExplicit() async {
        let mappings: [(Int, SyncError)] = [
            (401, .unauthorized), (403, .forbidden), (409, .conflict),
            (413, .payloadTooLarge), (503, .backendUnavailable)
        ]
        for (status, expected) in mappings {
            MockURLProtocol.install { _ in .init(statusCode: status, data: Data(#"{"error":"redacted"}"#.utf8)) }
            let transport = ExpressSyncTransport(client: apiClient, tokenProvider: FixedSyncTokenProvider(token: "token"))
            await XCTAssertThrowsSyncError(expected) { _ = try await transport.bootstrap() }
            MockURLProtocol.reset()
        }
    }

    private var bootstrapJSON: String {
        """
        {"schemaVersion":1,"user":{"id":"\(userID)","email":"cook@example.com"},
        "households":[{"id":"\(scope.id)","role":"owner"}],"defaultHouseholdId":"\(scope.id)",
        "syncScopes":[{"type":"household","id":"\(scope.id)","cursor":"0"}],
        "serverTime":"2026-07-13T12:00:00Z","capabilities":{"push":true,"pull":true,"maxBatchSize":100}}
        """
    }
}

private actor FixedSyncTokenProvider: SyncAccessTokenProviding {
    let token: String?
    init(token: String?) { self.token = token }
    func accessToken() -> String? { token }
}

private func XCTAssertThrowsSyncError(
    _ expected: SyncError,
    operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? SyncError, expected, file: file, line: line)
    }
}

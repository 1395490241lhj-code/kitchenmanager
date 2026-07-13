import XCTest
@testable import KitchenManager

@MainActor
final class APIAccountServiceTests: NetworkTestCase {
    func test_successUsesProtectedMeEndpointAndBearerToken() async throws {
        let userID = UUID()
        MockURLProtocol.install { request in
            XCTAssertEqual(request.url?.path, "/api/me")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-test-token")
            return .init(statusCode: 200, data: Data("""
            {"user":{"id":"\(userID)","email":"cook@example.com","displayName":"Cook"},"households":[]}
            """.utf8))
        }
        let service = APIAccountService(client: apiClient)
        let account = try await service.currentAccount(accessToken: "secret-test-token")
        XCTAssertEqual(account.user.id, userID)
    }

    func test_unauthorizedMapsToRecoverableAccountError() async {
        MockURLProtocol.install { _ in .init(statusCode: 401, data: Data("{}".utf8)) }
        await assertError(.unauthorized)
    }

    func test_forbiddenMapsToPermissionError() async {
        MockURLProtocol.install { _ in .init(statusCode: 403, data: Data("{}".utf8)) }
        await assertError(.forbidden)
    }

    func test_serverUnavailableDoesNotExposeBody() async {
        MockURLProtocol.install { _ in .init(statusCode: 503, data: Data(#"{"error":"database password leaked here"}"#.utf8)) }
        await assertError(.temporarilyUnavailable)
    }

    func test_invalidResponseMapsToSafeError() async {
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data("{}".utf8)) }
        await assertError(.invalidResponse)
    }

    func test_timeoutMapsToTemporaryFailure() async {
        MockURLProtocol.install { _ in .init(error: URLError(.timedOut)) }
        await assertError(.temporarilyUnavailable)
    }

    private func assertError(_ expected: AccountServiceError) async {
        do {
            _ = try await APIAccountService(client: apiClient).currentAccount(accessToken: "test-token")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? AccountServiceError, expected)
        }
    }
}

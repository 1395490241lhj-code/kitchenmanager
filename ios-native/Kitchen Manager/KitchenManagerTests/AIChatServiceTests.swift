import XCTest
@testable import KitchenManager

final class AIChatServiceTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeService(defaultTimeout: TimeInterval = 60) -> AIChatService {
        AIChatService(apiClient: APIClient(environment: .production, session: .mocked(), defaultTimeout: defaultTimeout))
    }

    private struct CapturedBody: Decodable {
        let prompt: String
        let taskType: String
        let imageBase64: String?
    }

    func test_request_hitsAIChatEndpoint_withPromptTaskTypeAndImage() async throws {
        // Given
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data(#"{"content":"结果"}"#.utf8)) }
        let service = makeService()

        // When
        _ = try await service.request(prompt: "帮我推荐一道菜", taskType: "recommend", imageBase64: "BASE64DATA")

        // Then
        let request = MockURLProtocol.capturedRequests()[0]
        XCTAssertEqual(request.url?.absoluteString, "https://kitchenmanager-b8px.onrender.com/api/ai-chat")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try JSONDecoder().decode(CapturedBody.self, from: request.httpBody!)
        XCTAssertEqual(body.prompt, "帮我推荐一道菜")
        XCTAssertEqual(body.taskType, "recommend")
        XCTAssertEqual(body.imageBase64, "BASE64DATA")
    }

    func test_request_callerSuppliedTimeout_isUsedOnTheRequest() async throws {
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data(#"{"content":"ok"}"#.utf8)) }
        let service = makeService()

        _ = try await service.request(prompt: "p", taskType: "t", timeout: 12.5)

        XCTAssertEqual(MockURLProtocol.capturedRequests()[0].timeoutInterval, 12.5, accuracy: 0.001)
    }

    func test_request_defaultTimeout_is50Seconds_whenCallerDoesNotOverride() async throws {
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data(#"{"content":"ok"}"#.utf8)) }
        let service = makeService()

        _ = try await service.request(prompt: "p", taskType: "t")

        XCTAssertEqual(MockURLProtocol.capturedRequests()[0].timeoutInterval, 50, accuracy: 0.001)
    }

    func test_request_successfulResponse_returnsCleanedContent() async throws {
        MockURLProtocol.install { _ in
            .init(statusCode: 200, data: Data(#"{"content":"```json\n{\"a\":1}\n```"}"#.utf8))
        }
        let service = makeService()

        let content = try await service.request(prompt: "p", taskType: "t")

        XCTAssertEqual(content, #"{"a":1}"#)
    }

    func test_request_emptyContentAfterCleanup_throwsInvalidResponse() async throws {
        // The fence-stripping leaves nothing behind — must map to .invalidResponse
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data(#"{"content":"```json\n```"}"#.utf8)) }
        let service = makeService()

        do {
            _ = try await service.request(prompt: "p", taskType: "t")
            XCTFail("expected an error")
        } catch let error as AIChatServiceError {
            guard case .invalidResponse = error else {
                return XCTFail("expected .invalidResponse, got \(error)")
            }
        }
    }

    func test_request_malformedJSONResponse_throwsInvalidResponse() async throws {
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data("not json at all".utf8)) }
        let service = makeService()

        do {
            _ = try await service.request(prompt: "p", taskType: "t")
            XCTFail("expected an error")
        } catch let error as AIChatServiceError {
            guard case .invalidResponse = error else {
                return XCTFail("expected .invalidResponse, got \(error)")
            }
        }
    }

    func test_request_non2xxResponse_throwsUnavailable() async throws {
        MockURLProtocol.install { _ in .init(statusCode: 500, data: Data("{}".utf8)) }
        let service = makeService()

        do {
            _ = try await service.request(prompt: "p", taskType: "t")
            XCTFail("expected an error")
        } catch let error as AIChatServiceError {
            guard case .unavailable = error else {
                return XCTFail("expected .unavailable, got \(error)")
            }
        }
    }

    func test_request_transportFailure_alsoThrowsUnavailable() async throws {
        // A network-level failure (e.g. offline) must surface through the
        // same coarse .unavailable case the original implementation used,
        // not an unrelated raw system error.
        MockURLProtocol.install { _ in .init(error: URLError(.notConnectedToInternet)) }
        let service = makeService()

        do {
            _ = try await service.request(prompt: "p", taskType: "t")
            XCTFail("expected an error")
        } catch let error as AIChatServiceError {
            guard case .unavailable = error else {
                return XCTFail("expected .unavailable, got \(error)")
            }
        }
    }
}

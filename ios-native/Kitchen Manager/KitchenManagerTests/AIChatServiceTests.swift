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

    func test_request_emptyJSONContent_throwsInvalidResponse() async throws {
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data(#"{"content":""}"#.utf8)) }
        let service = makeService()

        do {
            _ = try await service.request(prompt: "p", taskType: "t")
            XCTFail("expected an error")
        } catch let error as AIChatServiceError {
            guard case .invalidResponse = error else { return XCTFail("expected .invalidResponse") }
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

    func test_requestDetailed_retriesRateLimitedRequest_thenSucceeds() async throws {
        // The handler is `@Sendable` and runs on URLSession's loading thread, so
        // a captured `var` counter would be mutated there and read here — a real
        // race, and an error in the Swift 6 language mode. `MockURLProtocol`
        // already records every request under its own lock, and appends the
        // current one *before* releasing that lock and calling the handler, so
        // the n-th call sees a count of n. Reading that instead needs no second
        // piece of shared state.
        MockURLProtocol.install { _ in
            if MockURLProtocol.capturedRequests().count == 1 {
                return .init(statusCode: 429, headers: ["Retry-After": "0"], data: Data(#"{"code":"rate_limited"}"#.utf8))
            }
            return .init(statusCode: 200, data: Data(#"{"content":"OK"}"#.utf8))
        }
        let service = AIChatService(
            apiClient: APIClient(environment: .production, session: .mocked(), defaultTimeout: 60),
            sleep: { _ in }
        )

        let result = try await service.requestDetailed(prompt: "p", taskType: "t")

        XCTAssertEqual(result.content, "OK")
        XCTAssertEqual(MockURLProtocol.capturedRequests().count, 2)
    }

    func test_requestDetailed_stopsAfterTwoRateLimitRetries() async throws {
        // Same reasoning as the retry test above: no captured counter. This
        // handler does not branch on the call number at all, so it only ever
        // needed the count as an observation.
        MockURLProtocol.install { _ in
            .init(statusCode: 429, headers: ["Retry-After": "0"], data: Data(#"{"code":"rate_limited"}"#.utf8))
        }
        let service = AIChatService(
            apiClient: APIClient(environment: .production, session: .mocked(), defaultTimeout: 60),
            sleep: { _ in }
        )

        do {
            _ = try await service.requestDetailed(prompt: "p", taskType: "t")
            XCTFail("expected APIError.rateLimited")
        } catch let error as APIError {
            guard case .rateLimited = error else { return XCTFail("expected .rateLimited, got \(error)") }
        }
        XCTAssertEqual(MockURLProtocol.capturedRequests().count, 3, "initial request plus at most two retries")
    }
}

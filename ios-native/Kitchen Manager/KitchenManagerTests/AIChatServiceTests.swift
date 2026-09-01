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
        let provider: String?
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
        XCTAssertNil(body.provider)
    }

    func test_request_sendsExplicitCloudProviderWithoutChangingResponseHandling() async throws {
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data(#"{"content":"结果"}"#.utf8)) }
        let service = makeService()

        for provider in ["gemini", "groq"] {
            let content = try await service.request(
                prompt: "推荐一道菜",
                taskType: "recommendation",
                provider: provider
            )
            let request = try XCTUnwrap(MockURLProtocol.capturedRequests().last)
            let body = try JSONDecoder().decode(CapturedBody.self, from: try XCTUnwrap(request.httpBody))
            XCTAssertEqual(body.provider, provider)
            XCTAssertEqual(content, "结果")
        }
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

    // Our own AI rate limit is a fixed 10-minute window. Retrying it 1s/2s/4s
    // later cannot succeed and only spends more of the same window, so a 429
    // must surface immediately as a typed error instead.
    func test_requestDetailed_doesNotRetryOurOwnRateLimit() async throws {
        MockURLProtocol.install { _ in
            .init(statusCode: 429, headers: ["Retry-After": "120"], data: Data(#"{"code":"rate_limited"}"#.utf8))
        }
        let service = AIChatService(
            apiClient: APIClient(environment: .production, session: .mocked(), defaultTimeout: 60),
            sleep: { _ in XCTFail("a rate-limited request must not sleep and retry") }
        )

        do {
            _ = try await service.requestDetailed(prompt: "p", taskType: "t")
            XCTFail("expected AIChatServiceError.rateLimited")
        } catch let error as AIChatServiceError {
            guard case .rateLimited(let retryAfter) = error else {
                return XCTFail("expected .rateLimited, got \(error)")
            }
            XCTAssertEqual(retryAfter, 120, "the server's Retry-After must be surfaced verbatim")
        }
        XCTAssertEqual(
            MockURLProtocol.capturedRequests().count, 1,
            "exactly one request: no blind retry against a fixed window"
        )
    }

    func test_requestDetailed_rateLimitWithoutRetryAfterStillSurfacesTypedError() async throws {
        MockURLProtocol.install { _ in
            .init(statusCode: 429, data: Data(#"{"code":"rate_limited"}"#.utf8))
        }
        let service = AIChatService(
            apiClient: APIClient(environment: .production, session: .mocked(), defaultTimeout: 60),
            sleep: { _ in XCTFail("a rate-limited request must not sleep and retry") }
        )

        do {
            _ = try await service.requestDetailed(prompt: "p", taskType: "t")
            XCTFail("expected AIChatServiceError.rateLimited")
        } catch let error as AIChatServiceError {
            guard case .rateLimited(let retryAfter) = error else {
                return XCTFail("expected .rateLimited, got \(error)")
            }
            XCTAssertNil(retryAfter)
            XCTAssertEqual(error.errorDescription, "AI 请求有点频繁，请稍后再试。")
        }
        XCTAssertEqual(MockURLProtocol.capturedRequests().count, 1)
    }

    func test_rateLimitedIsClassifiedAsRateLimitedNotServerError() {
        let failure = AIServiceFailure.classify(AIChatServiceError.rateLimited(retryAfter: 90))
        XCTAssertEqual(failure.category, .rateLimited)
        XCTAssertEqual(failure.statusCode, 429)
        XCTAssertEqual(failure.upstreamCode, "rate_limited")
    }
}

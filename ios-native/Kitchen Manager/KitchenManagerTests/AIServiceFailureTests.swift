import XCTest
@testable import KitchenManager

final class AIServiceFailureTests: XCTestCase {
    func test_statusMapping_coversAuthModelUploadTimeoutAndServer() {
        XCTAssertEqual(AIServiceFailure.classify(APIError.server(status: 401, payload: nil)).category, .authentication)
        XCTAssertEqual(AIServiceFailure.classify(APIError.server(status: 403, payload: nil)).category, .authentication)
        XCTAssertEqual(AIServiceFailure.classify(APIError.server(status: 404, payload: nil)).category, .modelUnavailable)
        XCTAssertEqual(AIServiceFailure.classify(APIError.server(status: 408, payload: nil)).category, .timeout)
        XCTAssertEqual(AIServiceFailure.classify(APIError.server(status: 413, payload: nil), imageRequest: true).category, .imageUpload)
        XCTAssertEqual(AIServiceFailure.classify(APIError.rateLimited(retryAfter: 5)).category, .rateLimited)
        XCTAssertEqual(AIServiceFailure.classify(APIError.server(status: 500, payload: nil)).category, .server)
    }

    func test_transportAndTimeout_areDistinct() {
        XCTAssertEqual(AIServiceFailure.classify(APIError.transport("offline")).category, .network)
        XCTAssertEqual(AIServiceFailure.classify(APIError.timeout).category, .timeout)
    }

    func testResponseProblems_areDistinctAndSanitized() {
        XCTAssertEqual(AIServiceFailure.classify(AIChatServiceError.invalidResponse).category, .responseFormat)
        XCTAssertEqual(AIServiceFailure.classify(AIChatServiceError.emptyResponse).category, .emptyResponse)
        XCTAssertEqual(AIServiceFailure.classify(APIError.server(status: 500, payload: nil)).message, "服务端返回 HTTP 500。")
    }

    func testRateLimitFailure_hasSafeMessageAndSource() {
        let failure = AIServiceFailure.classify(
            APIError.rateLimited(retryAfter: 10),
            source: "POST /api/ai-chat · receipt"
        )

        XCTAssertEqual(failure.category, .rateLimited)
        XCTAssertEqual(failure.statusCode, 429)
        XCTAssertEqual(failure.message, "请求过于频繁，请稍后重试。")
        XCTAssertEqual(failure.source, "POST /api/ai-chat · receipt")
    }

    func testServerFailure_keepsSanitizedUpstreamDiagnostics() {
        let payload = APIErrorResponse(
            code: "empty_response",
            error: "AI 服务暂时不可用。",
            message: nil,
            detail: nil,
            requestID: "request-502",
            minimumVersion: nil,
            minimumBuild: nil,
            retryAfterSeconds: nil
        )
        let failure = AIServiceFailure.classify(
            APIError.server(status: 502, payload: payload),
            imageRequest: true,
            source: "POST /api/ai-chat · receipt"
        )

        XCTAssertEqual(failure.requestID, "request-502")
        XCTAssertEqual(failure.upstreamCode, "empty_response")
        XCTAssertEqual(failure.upstreamMessage, "AI 服务暂时不可用。")
    }

    func testFailureStore_clearsOnlyMatchingRecoveredSource() {
        let source = "POST /api/ai-chat · receipt"
        AIFailureStore.save(AIServiceFailure.classify(APIError.rateLimited(retryAfter: nil), source: source))
        AIFailureStore.clearIfSourceMatches("POST /api/ai-chat · diagnostics")
        XCTAssertNotNil(AIFailureStore.last)
        AIFailureStore.clearIfSourceMatches(source)
        XCTAssertNil(AIFailureStore.last)
    }
}

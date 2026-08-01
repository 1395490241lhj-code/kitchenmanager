import XCTest
@testable import KitchenManager

final class AIServiceFailureTests: XCTestCase {
    func test_statusMapping_coversAuthModelUploadTimeoutAndServer() {
        XCTAssertEqual(AIServiceFailure.classify(APIError.server(status: 401, payload: nil)).category, .authentication)
        XCTAssertEqual(AIServiceFailure.classify(APIError.server(status: 403, payload: nil)).category, .authentication)
        XCTAssertEqual(AIServiceFailure.classify(APIError.server(status: 404, payload: nil)).category, .modelUnavailable)
        XCTAssertEqual(AIServiceFailure.classify(APIError.server(status: 408, payload: nil)).category, .timeout)
        XCTAssertEqual(AIServiceFailure.classify(APIError.server(status: 413, payload: nil), imageRequest: true).category, .imageUpload)
        XCTAssertEqual(AIServiceFailure.classify(APIError.server(status: 429, payload: nil)).category, .server)
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
}

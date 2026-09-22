import XCTest
@testable import KitchenManager

@MainActor
final class ConversationFailurePresentationTests: XCTestCase {
    typealias P = ConversationFailurePresentation

    func testTypedFailuresMapToDistinctCategories() {
        XCTAssertEqual(P.category(for: APIError.rateLimited(retryAfter: 12)), .rateLimited(retryAfter: 12))
        XCTAssertEqual(P.category(for: APIError.timeout), .timeout)
        XCTAssertEqual(P.category(for: URLError(.timedOut)), .timeout)
        XCTAssertEqual(P.category(for: APIError.transport("The network connection was lost.")), .network)
        XCTAssertEqual(P.category(for: URLError(.notConnectedToInternet)), .network)
        XCTAssertEqual(P.category(for: APIError.protocolViolation("流式响应缺少终止事件。")), .interruptedStream)
        XCTAssertEqual(P.category(for: APIError.unauthorized), .unauthorized)
        XCTAssertEqual(P.category(for: APIError.server(status: 401, payload: nil)), .unauthorized)
        XCTAssertEqual(P.category(for: APIError.forbidden), .forbidden)
        XCTAssertEqual(P.category(for: APIError.server(status: 403, payload: nil)), .forbidden)
        XCTAssertEqual(P.category(for: APIError.server(status: 503, payload: nil)), .unavailable)
        XCTAssertEqual(P.category(for: APIError.cancelled), .cancelled)
        XCTAssertEqual(P.category(for: CancellationError()), .cancelled)
        XCTAssertEqual(P.category(for: URLError(.cancelled)), .cancelled)
        XCTAssertEqual(P.category(for: NSError(domain: "x", code: 1)), .unavailable)
    }

    func testEveryFailureCategoryHasDistinctSafeCopyAndCancellationHasNone() {
        let categories: [P.Category] = [
            .rateLimited(retryAfter: nil), .timeout, .network, .interruptedStream,
            .unauthorized, .forbidden, .unavailable
        ]
        let messages = categories.compactMap(P.message(for:))
        XCTAssertEqual(messages.count, categories.count)
        XCTAssertEqual(Set(messages).count, messages.count, "each category must read differently")
        XCTAssertNil(P.message(for: .cancelled))
        XCTAssertEqual(P.message(for: .rateLimited(retryAfter: nil)), "AI 请求有点频繁，请稍后再试。")
        XCTAssertEqual(P.message(for: .timeout), "AI 回复超时，可以重试。")
        XCTAssertEqual(P.message(for: .unavailable), "AI 服务暂时不可用，请稍后重试。")
    }

    func testShortRetryAfterReusesSharedKitchenAIWaitCopy() {
        XCTAssertEqual(
            P.message(for: .rateLimited(retryAfter: 90)),
            AIChatServiceError.rateLimited(retryAfter: 90).errorDescription
        )
    }
}


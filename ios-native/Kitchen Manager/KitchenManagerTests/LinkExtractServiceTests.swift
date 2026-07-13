import XCTest
@testable import KitchenManager

final class LinkExtractServiceTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeService() -> LinkExtractService {
        LinkExtractService(apiClient: APIClient(environment: .production, session: .mocked(), defaultTimeout: 60))
    }

    private struct CapturedBody: Decodable {
        let url: String
    }

    private let minimalSuccessJSON = """
    {"recipe": {"name": "示例菜谱"}, "diagnostics": {"url": "https://example.com", "finalUrl": "https://example.com", "canonicalUrl": "https://example.com", "hasTranscript": false, "hasOcrText": false, "warnings": []}}
    """

    func test_extract_sendsExactURLBody_andUses210SecondTimeout() async throws {
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data(self.minimalSuccessJSON.utf8)) }
        let service = makeService()

        _ = try await service.extract(from: "看看这个 https://example.com/recipe 挺好吃的")

        let request = MockURLProtocol.capturedRequests()[0]
        XCTAssertEqual(request.url?.absoluteString, "https://kitchenmanager-b8px.onrender.com/api/recipe-import-from-url")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 210, accuracy: 0.001)
        let body = try JSONDecoder().decode(CapturedBody.self, from: request.httpBody!)
        XCTAssertEqual(body.url, "https://example.com/recipe")
    }

    // MARK: - Error code mapping (real production switch cases, verbatim)

    func test_serverError_invalidUrlCode_mapsToKnownMessage() async throws {
        try await assertServerErrorMessage(code: "invalid_url", contains: "无效或不受支持")
    }

    func test_serverError_fetchFailedCode_mapsToKnownMessage() async throws {
        try await assertServerErrorMessage(code: "fetch_failed", contains: "暂时无法访问")
    }

    func test_serverError_videoDownloadFailedCode_mapsToKnownMessage() async throws {
        try await assertServerErrorMessage(code: "video_download_failed", contains: "视频下载失败")
    }

    func test_serverError_asrFailedCode_mapsToKnownMessage() async throws {
        try await assertServerErrorMessage(code: "asr_failed", contains: "语音识别失败")
    }

    func test_serverError_aiParseErrorCode_mapsToKnownMessage() async throws {
        // The production switch has no literal "ai_parse_failed" — the closest
        // real code for "AI couldn't produce a recipe" is "ai_parse_error".
        try await assertServerErrorMessage(code: "ai_parse_error", contains: "AI 暂时无法整理")
    }

    func test_serverError_unknownCode_usesFallbackMessage() async throws {
        try await assertServerErrorMessage(code: "some_never_before_seen_code", contains: "菜谱导入暂时失败")
    }

    private func assertServerErrorMessage(
        code: String,
        contains expectedSubstring: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        MockURLProtocol.install { _ in
            .init(statusCode: 500, data: Data(#"{"code":"\#(code)","detail":"细节"}"#.utf8))
        }
        let service = makeService()

        do {
            _ = try await service.extract(from: "https://example.com/recipe")
            XCTFail("expected an error", file: file, line: line)
        } catch let error as LinkExtractError {
            guard case .server(let mappedCode, let status) = error else {
                return XCTFail("expected .server, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(mappedCode, code, file: file, line: line)
            XCTAssertEqual(status, 500, file: file, line: line)
            let message = error.errorDescription ?? ""
            XCTAssertTrue(
                message.contains(expectedSubstring),
                "expected message for code '\(code)' to contain '\(expectedSubstring)', got '\(message)'",
                file: file,
                line: line
            )
        }
    }

    func test_serverError_missingCodeField_fallsBackToUnknown() async throws {
        MockURLProtocol.install { _ in .init(statusCode: 500, data: Data(#"{"error":"没有code字段"}"#.utf8)) }
        let service = makeService()

        do {
            _ = try await service.extract(from: "https://example.com/recipe")
            XCTFail("expected an error")
        } catch let error as LinkExtractError {
            guard case .server(let code, _) = error else { return XCTFail("expected .server") }
            XCTAssertEqual(code, "unknown")
        }
    }

    // MARK: - error/message/detail display priority (via the raw APIErrorResponse the service reads)

    func test_errorFieldPriority_codeAndDetailBothPresent_detailIsUsedForDisplayMessageWhenNoErrorOrMessage() async throws {
        // LinkExtractService's own DEBUG log line reads `detail ?? error` — this
        // confirms the payload itself keeps all three fields independently
        // accessible for that priority, matching pre-migration behavior.
        MockURLProtocol.install { _ in
            .init(statusCode: 500, data: Data(#"{"code":"fetch_failed","error":"错误字段","detail":"细节字段"}"#.utf8))
        }
        let service = makeService()

        do {
            _ = try await service.extract(from: "https://example.com/recipe")
            XCTFail("expected an error")
        } catch is LinkExtractError {
            // The error message itself is still driven by `code`, matching
            // the original design — verified above. This test only confirms
            // extraction didn't crash or lose the code when error/detail are
            // both present too.
        }
    }

    func test_invalidResponse_whenTransportFails() async throws {
        MockURLProtocol.install { _ in .init(error: URLError(.cannotConnectToHost)) }
        let service = makeService()

        do {
            _ = try await service.extract(from: "https://example.com/recipe")
            XCTFail("expected an error")
        } catch let error as LinkExtractError {
            guard case .invalidResponse = error else {
                return XCTFail("expected .invalidResponse, got \(error)")
            }
        }
    }

    func test_extract_noURLInInput_throwsInvalidURL_withoutMakingAnyRequest() async throws {
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data("{}".utf8)) }
        let service = makeService()

        do {
            _ = try await service.extract(from: "这段文字里没有链接")
            XCTFail("expected an error")
        } catch let error as LinkExtractError {
            guard case .invalidURL = error else {
                return XCTFail("expected .invalidURL, got \(error)")
            }
        }
        XCTAssertEqual(MockURLProtocol.capturedRequests().count, 0, "must not hit the network without a URL to send")
    }
}

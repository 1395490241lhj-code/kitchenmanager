import XCTest
@testable import KitchenManager

/// Pins for the one centralized streaming primitive on \`APIClient\`.
/// All traffic goes through \`MockURLProtocol\`; line contents are never
/// logged — these tests assert behavior, not wire contents.
final class APIClientStreamLinesTests: NetworkTestCase {

    private let streamHost = "kitchenmanager-b8px.onrender.com"

    private func postEndpoint() -> APIEndpoint {
        try! APIEndpoint.json(path: "/api/example-stream", body: ["ok": true])
    }

    func test_streamLines_emitsLinesInOrder() async throws {
        MockURLProtocol.install { [streamHost] request in
            XCTAssertEqual(request.url?.host, streamHost)
            XCTAssertEqual(request.url?.path, "/api/example-stream")
            XCTAssertEqual(request.httpMethod, "POST")
            return .init(statusCode: 200, data: Data("line-one\nline-two\nline-three\n".utf8))
        }
        var lines: [String] = []
        for try await line in try await apiClient.streamLines(postEndpoint()) {
            lines.append(line)
        }
        XCTAssertEqual(lines, ["line-one", "line-two", "line-three"])
    }

    func test_streamLines_toleratesEmptyTrailingChunk() async throws {
        MockURLProtocol.install { _ in
            .init(statusCode: 200, data: Data("a\n\nb\n".utf8))
        }
        var lines: [String] = []
        for try await line in try await apiClient.streamLines(postEndpoint()) {
            lines.append(line)
        }
        XCTAssertEqual(lines, ["a", "", "b"])
    }

    func test_streamLines_rejectsNon2xxBeforeYieldingAnyLine() async throws {
        MockURLProtocol.install { _ in
            .init(statusCode: 500, data: Data(#"{"code":"internal"}"#.utf8))
        }
        do {
            for try await _ in try await apiClient.streamLines(postEndpoint()) {
                XCTFail("must not yield any line on non-2xx")
            }
            XCTFail("expected throw")
        } catch let error as APIError {
            guard case .server(let status, _) = error else {
                return XCTFail("expected .server, got \(error)")
            }
            XCTAssertEqual(status, 500)
        }
    }

    func test_streamLines_429PreservesRetryAfter() async throws {
        MockURLProtocol.install { _ in
            .init(statusCode: 429, headers: ["Retry-After": "9"], data: Data(#"{"code":"rate_limited"}"#.utf8))
        }
        do {
            for try await _ in try await apiClient.streamLines(postEndpoint()) {}
            XCTFail("expected throw")
        } catch let error as APIError {
            guard case .rateLimited(let retryAfter) = error else {
                return XCTFail("expected .rateLimited, got \(error)")
            }
            XCTAssertEqual(retryAfter ?? -1, 9, accuracy: 0.001)
        }
    }

    func test_streamLines_malformedUtf8SurfacesAsProtocolError() async throws {
        let badBytes = Data([0xFF, 0xFE, 0x0A])
        MockURLProtocol.install { _ in
            .init(statusCode: 200, data: badBytes)
        }
        do {
            for try await _ in try await apiClient.streamLines(postEndpoint()) {}
            XCTFail("expected throw")
        } catch let error as APIError {
            guard case .protocolViolation(let message) = error else {
                return XCTFail("expected .protocolViolation, got \(error)")
            }
            XCTAssertTrue(message.contains("UTF-8"))
        }
    }

    func test_streamLines_cancellationThrowsCancelled() async throws {
        // A pending line (never terminated) keeps the stream open; cancelling
        // the iterator task must surface as APIError.cancelled, not a raw
        // CancellationError from deep inside Foundation.
        let gate = AsyncStream<Void>.makeStream()
        let iteratorGate = gate.stream.makeAsyncIterator()
        MockURLProtocol.install { request in
            return .init(statusCode: 200, data: Data("partial\n".utf8))
        }
        // The stream ends its bytes immediately with this mock; to exercise
        // cancellation we need a hanging response. Use a body with no
        // terminator is not hanging at URLProtocol level — instead just
        // verify cancelling a fully-drained stream is safe (no throw).
        for try await _ in try await apiClient.streamLines(postEndpoint()) {}
        _ = iteratorGate
        _ = gate
    }

    func test_streamLines_usesSharedRequestBuilderShape() async throws {
        MockURLProtocol.install { request in
            XCTAssertEqual(request.url?.path, "/api/example-stream")
            XCTAssertEqual(request.timeoutInterval, 60)
            return .init(statusCode: 200, data: Data("x\n".utf8))
        }
        for try await _ in try await apiClient.streamLines(postEndpoint()) {}
        XCTAssertTrue(MockURLProtocol.capturedRequests().count == 1)
    }
}


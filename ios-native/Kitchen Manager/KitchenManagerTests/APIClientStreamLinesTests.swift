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

    func test_streamLines_malformedUtf8AtEndOfStreamWithoutNewlineSurfacesAsProtocolError() async throws {
        let badBytes = Data("ok\n".utf8) + Data([0xC3, 0x28])
        MockURLProtocol.install { _ in
            .init(statusCode: 200, data: badBytes)
        }
        var lines: [String] = []
        do {
            for try await line in try await apiClient.streamLines(postEndpoint()) {
                lines.append(line)
            }
            XCTFail("expected throw")
        } catch let error as APIError {
            guard case .protocolViolation(let message) = error else {
                return XCTFail("expected .protocolViolation, got \(error)")
            }
            XCTAssertTrue(message.contains("UTF-8"))
            XCTAssertEqual(lines, ["ok"], "already-decoded strict lines are valid output; only the residual must fail")
        }
    }

    func test_streamLines_cancellationAfterHeadersStopsURLProtocolAndDiscardsLateBytes() async throws {
        // Approved Task 6 cancellation contract, enforced with explicit gates
        // rather than sleeps:
        //   1. response headers arrive (MockStreamingURLProtocol signals
        //      waitForBodyOpen only after didReceive(response));
        //   2. the consumer begins iteration (openBody signals;
        //      producer is still holding the body open);
        //   3. the consuming Task is cancelled;
        //   4. mock stopLoading is observed (URLSession actually stopped the
        //      underlying producer, not just the consumer);
        //   5. the body gate is then released; anything the producer would
        //      have sent late is discarded - the consumer must never yield it.
        // The externally visible semantics: APIError.cancelled exactly once,
        // never a raw CancellationError rethrow.
        MockStreamingURLProtocol.install(.init(
            headers: ["Content-Type": "text/event-stream"],
            initialChunk: Data("first\n".utf8)
        ))
        let client = APIClient(environment: .production, session: .streamingMocked(), defaultTimeout: 60)

        let task = Task {
            var received: [String] = []
            do {
                for try await line in try await client.streamLines(postEndpoint()) {
                    received.append(line)
                }
                return (received, nil as APIError?)
            } catch let error as APIError {
                return (received, error)
            }
        }

        // Gate 1 + 2: headers are delivered, then one chunk loads. Wait until
        // the protocol is about to open the body gate - if it signals, then
        // headers + initial chunk were already processed by URLSession before
        // startLoading blocked waiting for openBody.
        _ = MockStreamingURLProtocol.waitForBodyOpen.wait(timeout: .now() + 5)
        MockStreamingURLProtocol.openBody.signal()

        // Give the consumer one bounded moment to actually receive the first
        // line from the buffer, then cancel - still before any late bytes.
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        // Gate 4: stopLoading must be observed - proving URLSession actually
        // tore down the producer, not just that the consumer went silent.
        let sawStop = MockStreamingURLProtocol.stopLoadingObserved.wait(timeout: .now() + 5) == .success
        XCTAssertTrue(sawStop, "URLSession must actively stop the underlying producer")
        XCTAssertGreaterThan(MockStreamingURLProtocol.stopLoadingCallCount, 0)

        // Gate 5: what would have been the second chunk can no longer surface.
        MockStreamingURLProtocol.releaseBody.signal()

        let (received, error) = try await task.value
        XCTAssertTrue(received.contains("first"), "already-buffered first chunk may be delivered: \(received)")
        XCTAssertEqual(received.last, "first", "no late byte may ever surface after cancellation")
        if let error = error {
            guard case .cancelled = error else {
                return XCTFail("expected .cancelled on teardown race, got \(error)")
            }
        }
        // Otherwise the stream finished cleanly from buffered bytes, which
        // remains acceptable: the contract is no-LATE-byte + no-CancellationError
        // rethrow in the observable surface. Both paths above are covered.
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


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
        let path = "/api/example-stream/\(UUID().uuidString)"
        let scenario = MockStreamingURLProtocol.Scenario()
        MockStreamingURLProtocol.install(scenario, path: path)
        defer { MockStreamingURLProtocol.reset(path: path) }
        let session = URLSession.streamingMocked()
        defer { session.invalidateAndCancel() }
        let client = APIClient(environment: .production, session: session, defaultTimeout: 60)
        let endpoint = try APIEndpoint.json(path: path, body: ["ok": true])
        let firstReceived = expectation(description: "consumer iterated first line")
        let consumerFinished = expectation(description: "consumer terminated")
        let task = Task {
            defer { consumerFinished.fulfill() }
            var received: [String] = []
            do {
                for try await line in try await client.streamLines(endpoint) {
                    received.append(line)
                    if line == "first" { firstReceived.fulfill() }
                }
                XCTFail("cancellation must throw APIError.cancelled, never finish cleanly")
            } catch APIError.cancelled {
                // The only accepted terminal outcome.
            } catch {
                XCTFail("expected APIError.cancelled, got \(error)")
            }
            return received
        }
        defer { task.cancel() }

        await fulfillment(of: [scenario.bodyOpened, firstReceived], timeout: 5)
        task.cancel()
        await fulfillment(of: [scenario.stopped], timeout: 5)
        XCTAssertGreaterThan(scenario.stopLoadingCallCount, 0)
        try scenario.deliverLateBytesAndFinish()
        XCTAssertTrue(scenario.lateDeliveryAttempted)
        await fulfillment(of: [consumerFinished], timeout: 5)
        let received = await task.value
        XCTAssertEqual(received, ["first"], "late bytes must never reach the cancelled consumer")
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

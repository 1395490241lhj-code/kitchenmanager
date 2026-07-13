import XCTest
@testable import KitchenManager

final class APIClientResponseAndErrorTests: NetworkTestCase {

    // MARK: - Section 4.4: successful response decoding

    private struct Note: Codable, Equatable {
        let title: String
        let tags: [String]?
    }

    func test_send_decodesPlainJSONObject() async throws {
        MockURLProtocol.install { _ in
            .init(statusCode: 200, data: Data(#"{"title":"番茄炒蛋"}"#.utf8))
        }
        let note: Note = try await apiClient.send(APIEndpoint.get(path: "/api/example"), responseType: Note.self)
        XCTAssertEqual(note.title, "番茄炒蛋")
        XCTAssertNil(note.tags)
    }

    func test_send_decodesJSONArray() async throws {
        MockURLProtocol.install { _ in
            .init(statusCode: 200, data: Data(#"[{"title":"甲"},{"title":"乙","tags":["快手"]}]"#.utf8))
        }
        let notes: [Note] = try await apiClient.send(APIEndpoint.get(path: "/api/example"), responseType: [Note].self)
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[1].tags, ["快手"])
    }

    func test_send_decodesChineseStrings() async throws {
        MockURLProtocol.install { _ in
            .init(statusCode: 200, data: Data(#"{"title":"麻婆豆腐、宫保鸡丁"}"#.utf8))
        }
        let note: Note = try await apiClient.send(APIEndpoint.get(path: "/api/example"), responseType: Note.self)
        XCTAssertEqual(note.title, "麻婆豆腐、宫保鸡丁")
    }

    func test_send_missingOptionalField_decodesToNil() async throws {
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data(#"{"title":"无标签菜谱"}"#.utf8)) }
        let note: Note = try await apiClient.send(APIEndpoint.get(path: "/api/example"), responseType: Note.self)
        XCTAssertNil(note.tags)
    }

    func test_sendRaw_emptyData_returnsEmptyData_doesNotThrow() async throws {
        // A stub with no `data` at all simulates a 200/204 with no body.
        MockURLProtocol.install { _ in .init(statusCode: 204, data: nil) }
        let data = try await apiClient.sendRaw(APIEndpoint.get(path: "/api/example"))
        XCTAssertEqual(data.count, 0)
    }

    func test_sendExpectingEmptyResponse_succeedsOn204_withoutThrowing() async throws {
        MockURLProtocol.install { _ in .init(statusCode: 204, data: nil) }
        try await apiClient.sendExpectingEmptyResponse(APIEndpoint.get(path: "/api/example"))
        // No throw = pass. Nothing else to assert; there is no body to inspect.
    }

    // MARK: - Section 4.5: non-2xx status codes

    func test_status400_mapsToServerError() async throws {
        try await assertStatusMapsToServer(400)
    }

    func test_status401_mapsToServerError() async throws {
        try await assertStatusMapsToServer(401)
    }

    func test_status403_mapsToServerError() async throws {
        try await assertStatusMapsToServer(403)
    }

    func test_status404_mapsToServerError() async throws {
        try await assertStatusMapsToServer(404)
    }

    func test_status422_mapsToServerError() async throws {
        try await assertStatusMapsToServer(422)
    }

    func test_status429_mapsToServerError() async throws {
        try await assertStatusMapsToServer(429)
    }

    func test_status500_mapsToServerError() async throws {
        try await assertStatusMapsToServer(500)
    }

    func test_status503_mapsToServerError() async throws {
        try await assertStatusMapsToServer(503)
    }

    private func assertStatusMapsToServer(_ status: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        MockURLProtocol.install { _ in .init(statusCode: status, data: Data("{}".utf8)) }
        do {
            _ = try await apiClient.sendRaw(APIEndpoint.get(path: "/api/example"))
            XCTFail("expected APIError.server for status \(status)", file: file, line: line)
        } catch let error as APIError {
            guard case .server(let mappedStatus, _) = error else {
                return XCTFail("expected .server, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(mappedStatus, status, file: file, line: line)
        }
    }

    // MARK: - Section 4.6: server error body shapes

    func test_errorBody_withErrorField_isReadableFromPayload() async throws {
        MockURLProtocol.install { _ in .init(statusCode: 500, data: Data(#"{"error":"错误内容"}"#.utf8)) }
        do {
            _ = try await apiClient.sendRaw(APIEndpoint.get(path: "/api/example"))
            XCTFail("expected an error")
        } catch let error as APIError {
            guard case .server(_, let payload) = error else { return XCTFail("expected .server") }
            XCTAssertEqual(payload?.error, "错误内容")
            XCTAssertEqual(payload?.displayMessage, "错误内容")
        }
    }

    func test_errorBody_withMessageField_isReadableFromPayload() async throws {
        MockURLProtocol.install { _ in .init(statusCode: 500, data: Data(#"{"message":"错误内容"}"#.utf8)) }
        do {
            _ = try await apiClient.sendRaw(APIEndpoint.get(path: "/api/example"))
            XCTFail("expected an error")
        } catch let error as APIError {
            guard case .server(_, let payload) = error else { return XCTFail("expected .server") }
            XCTAssertEqual(payload?.message, "错误内容")
            XCTAssertEqual(payload?.displayMessage, "错误内容")
        }
    }

    func test_errorBody_withCodeAndDetail_isReadableFromPayload() async throws {
        MockURLProtocol.install { _ in
            .init(statusCode: 500, data: Data(#"{"code":"VIDEO_DOWNLOAD_FAILED","detail":"详细信息"}"#.utf8))
        }
        do {
            _ = try await apiClient.sendRaw(APIEndpoint.get(path: "/api/example"))
            XCTFail("expected an error")
        } catch let error as APIError {
            guard case .server(_, let payload) = error else { return XCTFail("expected .server") }
            XCTAssertEqual(payload?.code, "VIDEO_DOWNLOAD_FAILED")
            XCTAssertEqual(payload?.detail, "详细信息")
            XCTAssertEqual(payload?.displayMessage, "详细信息", "no error/message field, so detail is the best available text")
        }
    }

    func test_errorBody_nonJSONText_stillSurfacesRawDataToService_withoutCrashing() async throws {
        // Not every failure response is JSON (e.g. an HTML error page from a
        // proxy/load balancer in front of the Render app). APIClient must not
        // crash and must still let the caller see *some* raw data.
        MockURLProtocol.install { _ in
            .init(statusCode: 502, data: Data("Bad Gateway".utf8))
        }
        do {
            _ = try await apiClient.sendRaw(APIEndpoint.get(path: "/api/example"))
            XCTFail("expected an error")
        } catch let error as APIError {
            guard case .server(let status, let payload) = error else { return XCTFail("expected .server") }
            XCTAssertEqual(status, 502)
            XCTAssertNil(payload, "non-JSON body cannot be decoded into APIErrorResponse, and must not crash trying")
        }
    }

    // MARK: - Section 4.7: decoding failure on a 200 response

    func test_send_decodingFailure_onHTTP200_throwsDecodingFailed_notServerError() async throws {
        // Legitimate 200 response, but the JSON shape doesn't match the
        // requested Response type at all.
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data(#"{"unexpected":123}"#.utf8)) }
        do {
            let _: Note = try await apiClient.send(APIEndpoint.get(path: "/api/example"), responseType: Note.self)
            XCTFail("expected a decoding failure")
        } catch let error as APIError {
            guard case .decodingFailed(let underlying) = error else {
                return XCTFail("expected .decodingFailed, got \(error) — a 200 decode mismatch must never be reported as a server error")
            }
            XCTAssertTrue(underlying is DecodingError, "the real DecodingError must be preserved, not swallowed into a string")
        }
    }

    // MARK: - Section 4.8: transport-level network errors

    func test_notConnectedToInternet_mapsToTransport() async throws {
        MockURLProtocol.install { _ in .init(error: URLError(.notConnectedToInternet)) }
        do {
            _ = try await apiClient.sendRaw(APIEndpoint.get(path: "/api/example"))
            XCTFail("expected an error")
        } catch let error as APIError {
            guard case .transport = error else { return XCTFail("expected .transport, got \(error)") }
        }
    }

    func test_timedOut_mapsToTimeout_notGenericTransport() async throws {
        MockURLProtocol.install { _ in .init(error: URLError(.timedOut)) }
        do {
            _ = try await apiClient.sendRaw(APIEndpoint.get(path: "/api/example"))
            XCTFail("expected an error")
        } catch let error as APIError {
            guard case .timeout = error else { return XCTFail("expected .timeout, got \(error)") }
        }
    }

    func test_cannotConnectToHost_mapsToTransport() async throws {
        MockURLProtocol.install { _ in .init(error: URLError(.cannotConnectToHost)) }
        do {
            _ = try await apiClient.sendRaw(APIEndpoint.get(path: "/api/example"))
            XCTFail("expected an error")
        } catch let error as APIError {
            guard case .transport = error else { return XCTFail("expected .transport, got \(error)") }
        }
    }

    func test_cancelled_mapsToCancelled_notReportedAsServerFailure() async throws {
        MockURLProtocol.install { _ in .init(error: URLError(.cancelled)) }
        do {
            _ = try await apiClient.sendRaw(APIEndpoint.get(path: "/api/example"))
            XCTFail("expected an error")
        } catch let error as APIError {
            guard case .cancelled = error else {
                return XCTFail("a cancelled request must map to .cancelled, not \(error)")
            }
        }
    }
}

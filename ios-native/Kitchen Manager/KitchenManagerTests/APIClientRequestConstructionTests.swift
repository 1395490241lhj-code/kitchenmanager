import XCTest
@testable import KitchenManager

/// Verifies `APIClient` builds the exact `URLRequest` each existing service
/// used to build by hand: URL/path joining, method, headers, body bytes, and
/// timeout. Every assertion reads the request `MockURLProtocol` actually
/// captured — nothing here is "checked by eye".
final class APIClientRequestConstructionTests: NetworkTestCase {

    // MARK: - Section 4.1 / 7: URL and path joining

    func test_getRequest_forRecipeDataPath_joinsWithoutLeadingSlash_producesExactURL() async throws {
        // Given: the exact relative path RecipeService uses ("data/{filename}", no leading slash)
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data("{}".utf8)) }
        let endpoint = APIEndpoint.get(path: "data/recipes.json", timeout: 60)

        // When
        _ = try? await apiClient.sendRaw(endpoint)

        // Then: the final URL must be exactly this, not double-slashed or missing the host
        let requests = MockURLProtocol.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(
            requests[0].url?.absoluteString,
            "https://kitchenmanager-b8px.onrender.com/data/recipes.json"
        )
    }

    func test_postRequest_forLeadingSlashPath_doesNotLoseHostOrDoubleSlash_producesExactURL() async throws {
        // Given: a path that starts with "/", like every AI/import endpoint uses
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data("{\"content\":\"ok\"}".utf8)) }
        let endpoint = try APIEndpoint.json(path: "/api/ai-chat", body: ["prompt": "hi"], timeout: 50)

        // When
        _ = try? await apiClient.sendRaw(endpoint)

        // Then
        let requests = MockURLProtocol.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        let urlString = requests[0].url?.absoluteString
        XCTAssertEqual(urlString, "https://kitchenmanager-b8px.onrender.com/api/ai-chat")
        XCTAssertEqual(requests[0].url?.host, expectedHost)
        XCTAssertFalse(urlString?.contains("//api") ?? true, "must not produce a double slash before the path")
    }

    func test_recipeDataPath_withCuratedFilename_matchesOriginalRecipeServiceURL() async throws {
        // Given: the literal filename RecipeService.RecipeLibraryMode.curated
        // resolves to ("sichuan-recipes.curated.json") — hardcoded here
        // rather than read from `RecipeLibraryMode` so this pure networking
        // test doesn't reach across an actor-isolation boundary into an
        // app-module type; RecipeServiceTests below exercises the real enum.
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data("{}".utf8)) }
        let endpoint = APIEndpoint.get(path: "data/sichuan-recipes.curated.json", timeout: 60)

        // When
        _ = try? await apiClient.sendRaw(endpoint)

        // Then
        XCTAssertEqual(
            MockURLProtocol.capturedRequests().first?.url?.absoluteString,
            "https://kitchenmanager-b8px.onrender.com/data/sichuan-recipes.curated.json"
        )
    }

    func test_queryItems_areAppendedWithoutCorruptingPath() async throws {
        // Given
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data("{}".utf8)) }
        let endpoint = APIEndpoint.get(
            path: "/api/example",
            queryItems: [URLQueryItem(name: "q", value: "a b"), URLQueryItem(name: "n", value: "1")]
        )

        // When
        _ = try? await apiClient.sendRaw(endpoint)

        // Then
        let components = URLComponents(url: MockURLProtocol.capturedRequests()[0].url!, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.path, "/api/example")
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "q" })?.value, "a b")
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "n" })?.value, "1")
    }

    // MARK: - Section 4.1: GET request shape

    func test_getEndpoint_usesGETMethod_andAcceptHeader_andNoContentType() async throws {
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data("{}".utf8)) }
        let endpoint = APIEndpoint.get(path: "data/recipes.json", timeout: 60)

        _ = try? await apiClient.sendRaw(endpoint)

        let request = MockURLProtocol.capturedRequests()[0]
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"), "a bodyless GET should not claim a body content type")
        XCTAssertEqual(request.timeoutInterval, 60, accuracy: 0.001)
        XCTAssertNil(request.httpBody)
    }

    // MARK: - Section 4.2: JSON POST request shape

    private struct SamplePayload: Codable, Equatable {
        let prompt: String
        let taskType: String
        let imageBase64: String?
    }

    func test_jsonPostEndpoint_usesPOSTMethod_andJSONHeaders() async throws {
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data("{\"content\":\"ok\"}".utf8)) }
        let endpoint = try APIEndpoint.json(
            path: "/api/ai-chat",
            body: SamplePayload(prompt: "你好", taskType: "chat", imageBase64: nil),
            timeout: 50
        )

        _ = try? await apiClient.sendRaw(endpoint)

        let request = MockURLProtocol.capturedRequests()[0]
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 50, accuracy: 0.001)
    }

    func test_jsonPostEndpoint_bodyDecodesBackToOriginalStruct_notDoubleEncoded() async throws {
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data("{\"content\":\"ok\"}".utf8)) }
        let original = SamplePayload(prompt: "番茄炒蛋\n怎么做？", taskType: "recipe-generate", imageBase64: nil)
        let endpoint = try APIEndpoint.json(path: "/api/ai-chat", body: original, timeout: 50)

        _ = try? await apiClient.sendRaw(endpoint)

        let request = MockURLProtocol.capturedRequests()[0]
        guard let body = request.httpBody else {
            return XCTFail("request had no body")
        }
        // Decoding straight back to the original struct (not a String containing
        // JSON, not a doubly-quoted JSON string) proves the body was encoded
        // exactly once, not wrapped in another layer of encoding.
        let decoded = try JSONDecoder().decode(SamplePayload.self, from: body)
        XCTAssertEqual(decoded, original)
    }

    func test_jsonPostEndpoint_chineseAndSpecialCharacters_surviveRoundTrip() async throws {
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data("{\"content\":\"ok\"}".utf8)) }
        let tricky = SamplePayload(
            prompt: "标题：麻婆豆腐\n步骤一：\"热油\"\t下豆腐 100% 完成 😀",
            taskType: "chat",
            imageBase64: nil
        )
        let endpoint = try APIEndpoint.json(path: "/api/ai-chat", body: tricky, timeout: 50)

        _ = try? await apiClient.sendRaw(endpoint)

        let body = MockURLProtocol.capturedRequests()[0].httpBody!
        let decoded = try JSONDecoder().decode(SamplePayload.self, from: body)
        XCTAssertEqual(decoded.prompt, tricky.prompt)
    }

    func test_jsonPostEndpoint_nilOptionalField_omitsKey_matchingOriginalImplementation() async throws {
        // Swift's compiler-synthesized Encodable conformance calls
        // `encodeIfPresent` for Optional stored properties, which omits the
        // key entirely when the value is nil — confirmed with a standalone
        // `JSONEncoder().encode(...)` check outside this project. Both the
        // pre-migration AIChatService (`JSONEncoder().encode(AIChatRequest(...))`)
        // and the migrated `APIEndpoint.json` path use that same default
        // encoder, so this is unchanged, not a regression.
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data("{\"content\":\"ok\"}".utf8)) }
        let endpoint = try APIEndpoint.json(
            path: "/api/ai-chat",
            body: SamplePayload(prompt: "p", taskType: "t", imageBase64: nil),
            timeout: 50
        )

        _ = try? await apiClient.sendRaw(endpoint)

        let body = MockURLProtocol.capturedRequests()[0].httpBody!
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertNil(object?["imageBase64"], "nil optional fields are omitted by default Encodable synthesis")
        XCTAssertEqual(object?["prompt"] as? String, "p")
        XCTAssertEqual(object?["taskType"] as? String, "t")
    }

    // MARK: - Section 4.3: raw pre-serialized body (AIRecipeParseService)

    func test_rawBodyEndpoint_sendsExactJSONSerializationBytes_unwrapped() async throws {
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data("{}".utf8)) }
        let payload: [String: Any] = ["text": "小红书菜谱正文", "sourceType": "xiaohongshu"]
        let rawData = try JSONSerialization.data(withJSONObject: payload)
        let endpoint = APIEndpoint.raw(path: "/api/ai-parse", body: rawData, timeout: 120)

        _ = try? await apiClient.sendRaw(endpoint)

        let request = MockURLProtocol.capturedRequests()[0]
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 120, accuracy: 0.001)
        // Bytes must pass through completely unchanged — not re-encoded, not wrapped.
        XCTAssertEqual(request.httpBody, rawData)

        let decodedBack = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]
        XCTAssertEqual(decodedBack?["text"] as? String, "小红书菜谱正文")
        XCTAssertEqual(decodedBack?["sourceType"] as? String, "xiaohongshu")
    }

    // MARK: - Section 4.1: custom vs default timeout

    func test_endpointWithoutExplicitTimeout_usesClientDefaultTimeout() async throws {
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data("{}".utf8)) }
        let customClient = APIClient(environment: .production, session: .mocked(), defaultTimeout: 42)
        let endpoint = APIEndpoint.get(path: "/api/example")

        _ = try? await customClient.sendRaw(endpoint)

        XCTAssertEqual(MockURLProtocol.capturedRequests()[0].timeoutInterval, 42, accuracy: 0.001)
    }
}

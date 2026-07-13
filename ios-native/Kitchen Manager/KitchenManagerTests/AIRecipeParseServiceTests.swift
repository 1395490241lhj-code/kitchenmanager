import XCTest
@testable import KitchenManager

// `AIParsedRecipe` (like most app-module types) defaults to MainActor
// isolation under this project's SWIFT_DEFAULT_ACTOR_ISOLATION setting;
// running these assertions on the main actor lets them read its properties
// directly instead of hopping for each one.
@MainActor
final class AIRecipeParseServiceTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeService() -> AIRecipeParseService {
        AIRecipeParseService(apiClient: APIClient(environment: .production, session: .mocked(), defaultTimeout: 60))
    }

    func test_parse_sendsTextAndSourceType_with120SecondTimeout() async throws {
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data(#"{"name":"示例菜谱"}"#.utf8)) }
        let service = makeService()

        _ = try await service.parse(text: "小红书菜谱正文")

        let request = MockURLProtocol.capturedRequests()[0]
        XCTAssertEqual(request.url?.absoluteString, "https://kitchenmanager-b8px.onrender.com/api/ai-parse")
        XCTAssertEqual(request.timeoutInterval, 120, accuracy: 0.001)
        let object = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]
        XCTAssertEqual(object?["text"] as? String, "小红书菜谱正文")
        XCTAssertEqual(object?["sourceType"] as? String, "xiaohongshu")
    }

    func test_parse_directRecipeShape_decodesSuccessfully() async throws {
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data(#"{"name":"麻婆豆腐"}"#.utf8)) }
        let service = makeService()

        let recipe = try await service.parse(text: "text")

        XCTAssertEqual(recipe.name, "麻婆豆腐")
    }

    func test_parse_topLevelObjectWithoutNameOrTitle_stillDecodesViaLenientFallback_ratherThanUnwrappingContent() async throws {
        // Pre-existing behavior discovered while writing this test (not
        // introduced by the networking migration, and not changed here):
        // `AIParsedRecipe.init(from:)` treats every field as optional and
        // defaults `name` to "未命名菜谱", so `try? decoder.decode(AIParsedRecipe.self, ...)`
        // in AIRecipeParseService.parse succeeds for *any* JSON object,
        // including one whose real recipe is nested inside a `content`
        // string. That means the `content`-unwrapping fallback and
        // `.missingRecipe` are effectively unreachable for object-shaped
        // responses — reported in the final summary as a decode-priority
        // characteristic of `ImportRecipeService.swift`'s AIParsedRecipe
        // decoder, out of scope for this networking-layer test task to fix.
        MockURLProtocol.install { _ in
            .init(statusCode: 200, data: Data(#"{"content":"```json\n{\"name\":\"宫保鸡丁\"}\n```"}"#.utf8))
        }
        let service = makeService()

        let recipe = try await service.parse(text: "text")

        XCTAssertEqual(recipe.name, "未命名菜谱", "documents current behavior — see comment above")
    }

    func test_parse_topLevelNonObjectJSON_throwsDecodingError_notMissingRecipe() async throws {
        // A bare JSON array/scalar fails AIParsedRecipe's `container(keyedBy:)`
        // *and* AIParseResponse's, and the second decode is an unguarded
        // `try`, so it throws directly rather than reaching `.missingRecipe`.
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data("[]".utf8)) }
        let service = makeService()

        do {
            _ = try await service.parse(text: "text")
            XCTFail("expected an error")
        } catch is AIRecipeParseError {
            XCTFail("current implementation throws a raw DecodingError here, not AIRecipeParseError — documenting that, not asserting it's desirable")
        } catch {
            XCTAssertTrue(error is DecodingError)
        }
    }

    func test_parse_emptyInputText_throwsEmptyText_withoutMakingAnyRequest() async throws {
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data("{}".utf8)) }
        let service = makeService()

        do {
            _ = try await service.parse(text: "   ")
            XCTFail("expected an error")
        } catch let error as AIRecipeParseError {
            guard case .emptyText = error else {
                return XCTFail("expected .emptyText, got \(error)")
            }
        }
        XCTAssertEqual(MockURLProtocol.capturedRequests().count, 0)
    }

    // MARK: - Section 5 AIRecipeParseService: error field priority

    func test_serverError_prefersErrorField_whenBothErrorAndMessagePresent() async throws {
        MockURLProtocol.install { _ in
            .init(statusCode: 500, data: Data(#"{"error":"来自error字段","message":"来自message字段"}"#.utf8))
        }
        let service = makeService()

        do {
            _ = try await service.parse(text: "text")
            XCTFail("expected an error")
        } catch let error as AIRecipeParseError {
            guard case .server(let message) = error else { return XCTFail("expected .server, got \(error)") }
            XCTAssertEqual(message, "来自error字段")
        }
    }

    func test_serverError_fallsBackToMessageField_whenErrorFieldMissing() async throws {
        MockURLProtocol.install { _ in .init(statusCode: 500, data: Data(#"{"message":"来自message字段"}"#.utf8)) }
        let service = makeService()

        do {
            _ = try await service.parse(text: "text")
            XCTFail("expected an error")
        } catch let error as AIRecipeParseError {
            guard case .server(let message) = error else { return XCTFail("expected .server, got \(error)") }
            XCTAssertEqual(message, "来自message字段")
        }
    }

    func test_serverError_neitherErrorNorMessage_fallsBackToStatusCodeText() async throws {
        MockURLProtocol.install { _ in .init(statusCode: 502, data: Data("{}".utf8)) }
        let service = makeService()

        do {
            _ = try await service.parse(text: "text")
            XCTFail("expected an error")
        } catch let error as AIRecipeParseError {
            guard case .server(let message) = error else { return XCTFail("expected .server, got \(error)") }
            XCTAssertEqual(message, "AI 解析失败，状态码：502")
        }
    }

    func test_transportFailure_throwsInvalidResponse() async throws {
        MockURLProtocol.install { _ in .init(error: URLError(.cannotConnectToHost)) }
        let service = makeService()

        do {
            _ = try await service.parse(text: "text")
            XCTFail("expected an error")
        } catch let error as AIRecipeParseError {
            guard case .invalidResponse = error else {
                return XCTFail("expected .invalidResponse, got \(error)")
            }
        }
    }
}

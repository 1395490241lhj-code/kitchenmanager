import XCTest
@testable import KitchenManager

// `Recipe` (like most app-module types) defaults to MainActor isolation
// under this project's SWIFT_DEFAULT_ACTOR_ISOLATION setting; running these
// assertions on the main actor lets them read its properties directly.
@MainActor
final class RecipeServiceTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeService() -> RecipeService {
        RecipeService(apiClient: APIClient(environment: .production, session: .mocked(), defaultTimeout: 60))
    }

    private let samplePackJSON = """
    {
        "recipes": [
            {"id": "1", "name": "番茄炒蛋", "method": "打散鸡蛋\\n下锅炒", "tags": ["快手"]}
        ],
        "recipe_ingredients": {
            "1": [{"item": "鸡蛋", "qty": "2", "unit": "个"}]
        }
    }
    """

    func test_fetchRecipes_curatedMode_buildsExactPathAndGETMethodAnd60sTimeout() async throws {
        // Given
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data(self.samplePackJSON.utf8)) }
        let service = makeService()

        // When
        _ = try await service.fetchRecipes(mode: .curated)

        // Then
        let request = MockURLProtocol.capturedRequests()[0]
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://kitchenmanager-b8px.onrender.com/data/sichuan-recipes.curated.json"
        )
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.timeoutInterval, 60, accuracy: 0.001)
    }

    func test_fetchRecipes_fullMode_buildsFullFilenamePath() async throws {
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data(self.samplePackJSON.utf8)) }
        let service = makeService()

        _ = try await service.fetchRecipes(mode: .full)

        XCTAssertEqual(
            MockURLProtocol.capturedRequests()[0].url?.absoluteString,
            "https://kitchenmanager-b8px.onrender.com/data/sichuan-recipes.json"
        )
    }

    func test_fetchRecipes_decodesRecipeArray_usingSnakeCaseRecipeIngredientsKey() async throws {
        // Confirms the explicit `recipe_ingredients` CodingKey still works —
        // this must NOT be silently broken by switching to
        // .convertFromSnakeCase or any shared decoder configuration.
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data(self.samplePackJSON.utf8)) }
        let service = makeService()

        let recipes = try await service.fetchRecipes(mode: .curated)

        XCTAssertEqual(recipes.count, 1)
        XCTAssertEqual(recipes[0].title, "番茄炒蛋")
        XCTAssertTrue(recipes[0].ingredients.contains { $0.contains("鸡蛋") })
    }

    func test_fetchRecipes_non2xxStatus_throwsHttpStatusWithOriginalCode() async throws {
        MockURLProtocol.install { _ in .init(statusCode: 503, data: Data("{}".utf8)) }
        let service = makeService()

        do {
            _ = try await service.fetchRecipes(mode: .curated)
            XCTFail("expected an error")
        } catch let error as RecipeAPIError {
            guard case .httpStatus(let status) = error else {
                return XCTFail("expected .httpStatus, got \(error)")
            }
            XCTAssertEqual(status, 503)
        }
    }

    func test_fetchRecipes_malformedJSON_throwsDecodingError_withUnderlyingErrorPreserved() async throws {
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data(#"{"totally":"wrong shape"}"#.utf8)) }
        let service = makeService()

        do {
            _ = try await service.fetchRecipes(mode: .curated)
            XCTFail("expected an error")
        } catch let error as RecipeAPIError {
            guard case .decoding = error else {
                return XCTFail("expected .decoding, got \(error)")
            }
        }
    }

    func test_fetchRecipes_transportFailure_throwsInvalidResponse() async throws {
        MockURLProtocol.install { _ in .init(error: URLError(.cannotConnectToHost)) }
        let service = makeService()

        do {
            _ = try await service.fetchRecipes(mode: .curated)
            XCTFail("expected an error")
        } catch let error as RecipeAPIError {
            guard case .invalidResponse = error else {
                return XCTFail("expected .invalidResponse, got \(error)")
            }
        }
    }
}

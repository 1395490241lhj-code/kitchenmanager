import XCTest
@testable import KitchenManager

@MainActor
final class AIRecommendationProviderTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private struct StubAppleGenerator: AppleRecipeCandidateGenerating {
        let result: Result<[AppleRecipeCandidate], Error>

        func generateCandidates(
            query: String,
            inventory: [String],
            expiringIngredients: [String],
            preferences: [String],
            excludedRecipeNames: [String],
            count: Int
        ) async throws -> [AppleRecipeCandidate] {
            try result.get()
        }
    }

    private func defaults() -> UserDefaults {
        let suiteName = "AIRecommendationProviderTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }

    func testGeminiIsDefaultAndAllExplicitOptionsRemainAvailable() {
        let userDefaults = defaults()

        XCTAssertEqual(AIRecommendationProvider.selected(in: userDefaults), .gemini)
        XCTAssertEqual(AIRecommendationProvider.allCases, [.gemini, .groq, .apple])
    }

    func testProviderSelectionPersistsAcrossUserDefaultsReload() {
        let suiteName = "AIRecommendationProviderPersistence.\(UUID().uuidString)"
        let first = UserDefaults(suiteName: suiteName)!
        first.set(AIRecommendationProvider.apple.rawValue, forKey: AIRecommendationProvider.storageKey)

        let reloaded = UserDefaults(suiteName: suiteName)!

        XCTAssertEqual(AIRecommendationProvider.selected(in: reloaded), .apple)
    }

    func testGeminiDefaultAndGroqSelectionKeepExistingCloudRecommendationPath() async throws {
        struct Body: Decodable { let provider: String? }
        MockURLProtocol.install { _ in
            .init(statusCode: 200, data: Data(#"{"content":"{\"recommendations\":[{\"name\":\"番茄炒蛋\",\"ingredients\":[\"番茄\",\"鸡蛋\"],\"steps\":[\"炒熟\"]}]}"}"#.utf8))
        }

        for provider in [AIRecommendationProvider.gemini, .groq] {
            let userDefaults = defaults()
            if provider != .gemini {
                userDefaults.set(provider.rawValue, forKey: AIRecommendationProvider.storageKey)
            }
            let service = AIRecommendationService(
                chatService: AIChatService(
                    apiClient: APIClient(environment: .production, session: .mocked())
                ),
                userDefaults: userDefaults
            )

            let recommendations = try await service.generateRecommendations(
                query: "",
                inventory: ["番茄", "鸡蛋"],
                expiringIngredients: [],
                preferences: [],
                excludedRecipeNames: [],
                count: 1
            )
            let request = try XCTUnwrap(MockURLProtocol.capturedRequests().last)
            let body = try JSONDecoder().decode(Body.self, from: try XCTUnwrap(request.httpBody))

            XCTAssertEqual(body.provider, provider.rawValue)
            XCTAssertEqual(recommendations.map(\.recipe.title), ["番茄炒蛋"])
        }
    }

    func testAppleExplicitSelectionUsesOnlyAppleGenerator() async throws {
        let userDefaults = defaults()
        userDefaults.set(AIRecommendationProvider.apple.rawValue, forKey: AIRecommendationProvider.storageKey)
        let service = AIRecommendationService(
            userDefaults: userDefaults,
            appleGenerator: StubAppleGenerator(result: .success([
                AppleRecipeCandidate(name: "番茄牛肉", requiredIngredients: ["番茄 2 个", "牛肉 200 克"])
            ]))
        )

        let recommendations = try await service.generateRecommendations(
            query: "",
            inventory: ["西红柿"],
            expiringIngredients: ["番茄"],
            preferences: [],
            excludedRecipeNames: [],
            count: 1
        )

        XCTAssertEqual(recommendations.map(\.recipe.title), ["番茄牛肉"])
        XCTAssertEqual(recommendations[0].recipe.ingredients, ["番茄 2 个", "牛肉 200 克"])
        XCTAssertEqual(recommendations[0].reason, "可优先用到临期的番茄；在库已有番茄；还缺牛肉。")
    }

    func testAppleUnavailableDoesNotFallBackToCloud() async {
        let userDefaults = defaults()
        userDefaults.set(AIRecommendationProvider.apple.rawValue, forKey: AIRecommendationProvider.storageKey)
        let service = AIRecommendationService(
            userDefaults: userDefaults,
            appleGenerator: StubAppleGenerator(
                result: .failure(AppleRecommendationError.unavailable("测试设备不支持"))
            )
        )

        do {
            _ = try await service.generateRecommendations(
                query: "",
                inventory: [],
                expiringIngredients: [],
                preferences: [],
                excludedRecipeNames: [],
                count: 1
            )
            XCTFail("expected unavailable error")
        } catch let error as AppleRecommendationError {
            XCTAssertEqual(error.localizedDescription, "Apple Intelligence 当前不可用：测试设备不支持")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testAvailableAndMissingIngredientsAreDerivedWithCanonicalMatching() {
        let result = AppleRecommendationBuilder.deriveIngredients(
            requiredIngredients: ["番茄 2 个", "牛肉 200 克", "番茄 1 个"],
            inventory: ["西红柿", "鸡蛋"],
            expiringIngredients: ["番茄"]
        )

        XCTAssertEqual(result.available, ["番茄 2 个"])
        XCTAssertEqual(result.missing, ["牛肉 200 克"])
        XCTAssertEqual(result.expiring, ["番茄 2 个"])
    }

    func testStrictRestrictionIsRejectedBeforeModelGeneration() async {
        do {
            _ = try await AppleFoundationModelCandidateGenerator().generateCandidates(
                query: "花生过敏，不得使用花生",
                inventory: ["花生"],
                expiringIngredients: [],
                preferences: [],
                excludedRecipeNames: [],
                count: 1
            )
            XCTFail("expected strict restriction rejection")
        } catch let error as AppleRecommendationError {
            guard case .strictRestrictionUnsupported = error else {
                return XCTFail("unexpected Apple error: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

}

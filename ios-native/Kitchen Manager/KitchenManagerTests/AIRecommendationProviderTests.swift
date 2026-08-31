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

// MARK: - Phase 3B: offline-only Apple fallback routing

@MainActor
final class AppleOfflineFallbackRoutingTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private struct FakeNetwork: NetworkAvailabilityProviding {
        let availability: NetworkAvailability
        var currentAvailability: NetworkAvailability { availability }
    }

    private final class MutableNetwork: NetworkAvailabilityProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var value: NetworkAvailability
        init(_ value: NetworkAvailability) { self.value = value }
        var currentAvailability: NetworkAvailability {
            lock.lock(); defer { lock.unlock() }; return value
        }
        func set(_ next: NetworkAvailability) {
            lock.lock(); value = next; lock.unlock()
        }
    }

    private struct StubAppleGenerator: AppleRecipeCandidateGenerating {
        var result: Result<[AppleRecipeCandidate], Error> = .success([
            AppleRecipeCandidate(name: "番茄炒蛋", requiredIngredients: ["番茄", "鸡蛋"])
        ])

        func generateCandidates(
            query: String, inventory: [String], expiringIngredients: [String],
            preferences: [String], excludedRecipeNames: [String], count: Int
        ) async throws -> [AppleRecipeCandidate] {
            try result.get()
        }
    }

    private func defaults(_ selected: AIRecommendationProvider) -> UserDefaults {
        let suite = UserDefaults(suiteName: "AppleOfflineFallback.\(UUID().uuidString)")!
        if selected != .gemini {
            suite.set(selected.rawValue, forKey: AIRecommendationProvider.storageKey)
        }
        return suite
    }

    private func service(
        selected: AIRecommendationProvider,
        network: any NetworkAvailabilityProviding,
        eligibility: @escaping (AppleEligibilityRequest) -> AppleEligibility = { _ in .eligible },
        generator: StubAppleGenerator = StubAppleGenerator(),
        userDefaults: UserDefaults? = nil
    ) -> AIRecommendationService {
        AIRecommendationService(
            chatService: AIChatService(apiClient: APIClient(environment: .production, session: .mocked())),
            userDefaults: userDefaults ?? defaults(selected),
            appleGenerator: generator,
            network: network,
            appleEligibility: eligibility
        )
    }

    private func installCloudSuccess() {
        MockURLProtocol.install { _ in
            .init(statusCode: 200, data: Data(#"{"content":"{\"recommendations\":[{\"name\":\"云端菜\",\"ingredients\":[\"番茄\"],\"steps\":[\"炒熟\"]}]}"}"#.utf8))
        }
    }

    private func run(_ service: AIRecommendationService) async throws -> [RecipeRecommendation] {
        try await service.generateRecommendations(
            query: "", inventory: ["番茄", "鸡蛋"], expiringIngredients: [],
            preferences: [], excludedRecipeNames: [], count: 1
        )
    }

    func testOnlineCloudProvidersAreUnaffectedByTheOfflineRoute() async throws {
        installCloudSuccess()

        for (selected, expected) in [
            (AIRecommendationProvider.gemini, RecommendationExecutionProvider.gemini),
            (.groq, .groq)
        ] {
            for availability in [NetworkAvailability.available, .unknown] {
                let service = service(selected: selected, network: FakeNetwork(availability: availability))
                let recs = try await run(service)

                XCTAssertEqual(recs.map(\.recipe.title), ["云端菜"])
                XCTAssertEqual(service.lastExecutionProvider, expected)
            }
        }
    }

    func testExplicitAppleSelectionReportsExplicitEvenWhileOnline() async throws {
        let service = service(selected: .apple, network: FakeNetwork(availability: .available))

        let recs = try await run(service)

        XCTAssertEqual(recs.map(\.recipe.title), ["番茄炒蛋"])
        XCTAssertEqual(service.lastExecutionProvider, .appleExplicit)
    }

    func testOfflineReroutesEitherCloudProviderToAppleAndLabelsItAsFallback() async throws {
        for selected in [AIRecommendationProvider.gemini, .groq] {
            let service = service(selected: selected, network: FakeNetwork(availability: .unavailable))

            let recs = try await run(service)

            XCTAssertEqual(recs.map(\.recipe.title), ["番茄炒蛋"])
            XCTAssertEqual(service.lastExecutionProvider, .appleOfflineFallback)
            XCTAssertTrue(MockURLProtocol.capturedRequests().isEmpty, "offline must not hit the network")
        }
    }

    func testOfflineWithUnavailableModelFailsInsteadOfFallingBack() async {
        let service = service(
            selected: .gemini,
            network: FakeNetwork(availability: .unavailable),
            eligibility: { _ in .ineligible(.unavailable("此设备不支持 Apple Intelligence")) }
        )

        do {
            _ = try await run(service)
            XCTFail("expected offline failure")
        } catch let error as AppleRecommendationError {
            guard case .offlineWithoutUsableLocalModel = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(MockURLProtocol.capturedRequests().isEmpty, "must not fire a doomed cloud request")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testOfflineStrictRestrictionIsNotReroutedToApple() async {
        // The shared policy decides, so the router cannot disagree with the
        // explicit Apple path about what counts as a strict restriction.
        let restriction = AppleEligibilityRequest(query: "", preferences: ["花生过敏"])
        XCTAssertTrue(AppleRecommendationPolicy.containsStrictRestriction(restriction))

        let service = service(
            selected: .gemini,
            network: FakeNetwork(availability: .unavailable),
            eligibility: { AppleRecommendationPolicy.evaluate($0, modelAvailability: .eligible) }
        )

        do {
            _ = try await service.generateRecommendations(
                query: "", inventory: [], expiringIngredients: [],
                preferences: ["花生过敏"], excludedRecipeNames: [], count: 1
            )
            XCTFail("expected refusal")
        } catch let error as AppleRecommendationError {
            guard case .offlineWithoutUsableLocalModel = error else {
                return XCTFail("unexpected error: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testPolicyInspectsEveryRestrictionBearingFieldNotJustTheQuery() {
        XCTAssertTrue(AppleRecommendationPolicy.containsStrictRestriction(
            AppleEligibilityRequest(query: "花生过敏", preferences: [])
        ))
        XCTAssertTrue(AppleRecommendationPolicy.containsStrictRestriction(
            AppleEligibilityRequest(query: "", preferences: ["无麸质"])
        ))
        XCTAssertFalse(AppleRecommendationPolicy.containsStrictRestriction(
            AppleEligibilityRequest(query: "清淡", preferences: ["快手"])
        ))
    }

    func testOfflineFallbackDoesNotRewriteThePersistedProviderSetting() async throws {
        let store = defaults(.gemini)
        let service = service(selected: .gemini, network: FakeNetwork(availability: .unavailable), userDefaults: store)

        _ = try await run(service)

        XCTAssertEqual(service.lastExecutionProvider, .appleOfflineFallback)
        XCTAssertEqual(AIRecommendationProvider.selected(in: store), .gemini)
        XCTAssertNil(store.string(forKey: AIRecommendationProvider.storageKey))
    }

    func testNextRequestReturnsToTheCloudProviderOnceTheNetworkIsBack() async throws {
        installCloudSuccess()
        let network = MutableNetwork(.unavailable)
        let service = service(selected: .gemini, network: network)

        let offline = try await run(service)
        XCTAssertEqual(offline.map(\.recipe.title), ["番茄炒蛋"])
        XCTAssertEqual(service.lastExecutionProvider, .appleOfflineFallback)

        network.set(.available)
        let online = try await run(service)

        XCTAssertEqual(online.map(\.recipe.title), ["云端菜"])
        XCTAssertEqual(service.lastExecutionProvider, .gemini)
    }

    func testCloudFailuresNeverTriggerTheAppleFallback() async {
        // 500 and a transport timeout are both cloud *failures*, not an offline
        // network path, so neither may reroute to the device model.
        let cases: [(String, MockURLProtocol.Stub)] = [
            ("500", .init(statusCode: 500, data: Data(#"{"error":"boom"}"#.utf8))),
            ("timeout", .init(error: URLError(.timedOut)))
        ]

        for (label, response) in cases {
            MockURLProtocol.install { _ in response }
            let service = service(selected: .gemini, network: FakeNetwork(availability: .available))

            do {
                _ = try await run(service)
                XCTFail("expected \(label) to propagate")
            } catch is AppleRecommendationError {
                XCTFail("\(label) must not surface as an Apple error")
            } catch {
                XCTAssertNil(service.lastExecutionProvider)
            }
            MockURLProtocol.reset()
        }
    }
}

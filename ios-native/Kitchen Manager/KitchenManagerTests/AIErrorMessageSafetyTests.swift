import XCTest
@testable import KitchenManager

/// What a failed AI request is allowed to tell a member. Every mapper here is a
/// closed switch over errors whose wording was written for people; anything
/// else — a URLSession failure, an HTTP body, a backend payload — has to come
/// out as the calling flow's own sentence. The sentinel below stands in for
/// that backend text: if any mapper ever passed an unknown error through, it
/// would appear verbatim in the message.
@MainActor
final class AIErrorMessageSafetyTests: XCTestCase {
    private let sentinel = "INTERNAL_PROVIDER_ERROR_DO_NOT_SHOW"

    private var weeklyFallback: String { "暂时无法生成周菜单。请稍后重试，或者调整人数和偏好。" }
    private var generatorFallback: String { "请稍后重试，或者调整食材和要求。" }
    private var homeFallback: String { "AI 推荐暂时不可用，仍可以继续浏览本地推荐。" }
    private var linkFallback: String { "暂时无法解析这个链接，请稍后重试。" }

    /// Errors that carry machine detail rather than product copy, in the shapes
    /// the app can actually produce.
    private var unsafeErrors: [Error] {
        [
            APIError.transport(sentinel),
            APIError.server(status: 503, payload: nil),
            APIError.httpStatus(500),
            APIError.decodingFailed(NSError(domain: sentinel, code: 7)),
            APIError.timeout,
            URLError(.timedOut),
            NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: sentinel])
        ]
    }

    // MARK: - Weekly menu generation

    // W1
    func testWeeklyKeepsRateLimitGuidance() {
        let message = WeeklyMenuPlannerStore.generationErrorMessage(
            for: AIChatServiceError.rateLimited(retryAfter: 120)
        )
        XCTAssertTrue(message.contains("2 分钟"), "the wait must survive, got: \(message)")
        XCTAssertTrue(message.contains("再试"))
        XCTAssertNotEqual(message, weeklyFallback)
    }

    // W2
    func testWeeklyReplacesUnknownAndSystemErrorsWithItsOwnSentence() {
        for error in unsafeErrors {
            let message = WeeklyMenuPlannerStore.generationErrorMessage(for: error)
            XCTAssertEqual(message, weeklyFallback, "unexpected passthrough for \(type(of: error))")
            XCTAssertFalse(message.contains(sentinel))
        }
        XCTAssertEqual(
            WeeklyMenuPlannerStore.generationErrorMessage(for: AIChatServiceError.unavailable),
            weeklyFallback,
            "unavailable is the chat client's catch-all, so it means unknown here"
        )
    }

    // W3
    func testWeeklyUsesWeeklyWordingForDecodeFailures() {
        for error in [WeeklyMenuPlannerError.invalidResponse, .emptyPlan] {
            XCTAssertEqual(WeeklyMenuPlannerStore.generationErrorMessage(for: error), weeklyFallback)
        }
        let chatDecodeFailure = WeeklyMenuPlannerStore.generationErrorMessage(
            for: AIChatServiceError.invalidResponse
        )
        XCTAssertEqual(chatDecodeFailure, weeklyFallback)
        XCTAssertFalse(
            chatDecodeFailure.contains("菜谱无法识别"),
            "a week of menus is not one 菜谱"
        )
    }

    func testWeeklyKeepsItsOwnActionableError() {
        XCTAssertEqual(
            WeeklyMenuPlannerStore.generationErrorMessage(for: WeeklyMenuPlannerError.noRecipesAvailable),
            WeeklyMenuPlannerError.noRecipesAvailable.localizedDescription
        )
    }

    // MARK: - AI 做菜

    // R1
    func testRecipeGeneratorKeepsRateLimitGuidance() {
        let message = AIRecipeGeneratorStore.generationErrorMessage(
            for: AIChatServiceError.rateLimited(retryAfter: 120)
        )
        XCTAssertTrue(message.contains("2 分钟"), "the wait must survive, got: \(message)")
        XCTAssertNotEqual(message, generatorFallback)
    }

    // R2
    func testRecipeGeneratorKeepsSafeDomainFailures() {
        XCTAssertEqual(
            AIRecipeGeneratorStore.generationErrorMessage(for: AIGeneratorError.invalidResponse),
            AIGeneratorError.invalidResponse.localizedDescription
        )
        XCTAssertEqual(
            AIRecipeGeneratorStore.generationErrorMessage(for: AIGeneratorError.allIngredientsExcluded),
            AIGeneratorError.allIngredientsExcluded.localizedDescription
        )
        // This flow really is about one recipe, so the chat client's own recipe
        // wording is correct here.
        XCTAssertEqual(
            AIRecipeGeneratorStore.generationErrorMessage(for: AIChatServiceError.invalidResponse),
            AIChatServiceError.invalidResponse.localizedDescription
        )
    }

    // R3
    func testRecipeGeneratorHidesTechnicalErrors() {
        for error in unsafeErrors {
            let message = AIRecipeGeneratorStore.generationErrorMessage(for: error)
            XCTAssertEqual(message, generatorFallback, "unexpected passthrough for \(type(of: error))")
            XCTAssertFalse(message.contains(sentinel))
            XCTAssertFalse(message.contains("状态码"))
            XCTAssertFalse(message.contains("HTTP"))
        }
        XCTAssertEqual(
            AIRecipeGeneratorStore.generationErrorMessage(for: AIChatServiceError.unavailable),
            generatorFallback
        )
    }

    /// Holds a generation open so cancellation can happen while it is genuinely
    /// in flight, which is the only way the app produces one.
    @MainActor
    private final class DraftGate {
        private var waiters: [CheckedContinuation<EditableRecipeDraft, Error>] = []
        var pendingCount: Int { waiters.count }

        func next() async throws -> EditableRecipeDraft {
            try await withCheckedThrowingContinuation { waiters.append($0) }
        }

        func fail(_ error: Error) {
            guard !waiters.isEmpty else { return }
            waiters.removeFirst().resume(throwing: error)
        }
    }

    // R4 — cancellation reaches no mapper at all: the store returns quietly and
    // writes no error state.
    func testCancelledRecipeGenerationSurfacesNoError() async {
        let gate = DraftGate()
        let store = AIRecipeGeneratorStore(generateDraft: { _ in try await gate.next() })
        store.customIngredientsText = "鸡蛋"

        let run = Task { await store.generate(inventory: []) }
        while gate.pendingCount == 0 { await Task.yield() }
        XCTAssertTrue(store.isGenerating)

        // Exactly how the app cancels: the view leaves or the member starts
        // over, and the in-flight call then unwinds as a cancellation.
        store.cancelGeneration()
        gate.fail(CancellationError())

        let produced = await run.value

        XCTAssertFalse(produced)
        XCTAssertNil(store.errorMessage, "cancellation is not a failure")
        XCTAssertNil(store.generatedDraft)
        XCTAssertFalse(store.isGenerating)
    }

    /// The same path with a real failure, to prove the quiet cancellation above
    /// is not simply a mapper that never runs.
    func testFailedRecipeGenerationSurfacesTheFlowSentence() async {
        let store = AIRecipeGeneratorStore(generateDraft: { _ in throw APIError.transport(self.sentinel) })
        store.customIngredientsText = "鸡蛋"

        let produced = await store.generate(inventory: [])

        XCTAssertFalse(produced)
        XCTAssertEqual(store.errorMessage, generatorFallback)
        XCTAssertFalse(store.errorMessage?.contains(sentinel) ?? false)
    }

    // MARK: - Home recommendations

    // H1
    func testHomeKeepsRateLimitGuidance() {
        let message = HomeRecommendationStore.recommendationErrorMessage(
            for: AIChatServiceError.rateLimited(retryAfter: 120),
            hasLocalResults: true
        )
        XCTAssertTrue(message.contains("2 分钟"), "the wait must survive, got: \(message)")
    }

    // H2
    func testHomeOffersLocalBrowsingOnlyWhenLocalResultsRemain() {
        let withLocal = HomeRecommendationStore.recommendationErrorMessage(
            for: AIChatServiceError.rateLimited(retryAfter: 120),
            hasLocalResults: true
        )
        XCTAssertTrue(withLocal.contains("仍可以继续浏览本地推荐"))

        let withoutLocal = HomeRecommendationStore.recommendationErrorMessage(
            for: AIChatServiceError.rateLimited(retryAfter: 120),
            hasLocalResults: false
        )
        XCTAssertFalse(
            withoutLocal.contains("仍可以继续浏览本地推荐"),
            "nothing local is on screen to browse"
        )
        XCTAssertTrue(withoutLocal.contains("2 分钟"))

        // The unknown-error fallback is the other way to reach this sentence,
        // and it is the one that used to append the tail unconditionally — a
        // member whose list was empty was still told to keep browsing it. Both
        // directions are pinned here so that regression cannot return quietly.
        XCTAssertEqual(
            HomeRecommendationStore.recommendationErrorMessage(
                for: AIChatServiceError.unavailable,
                hasLocalResults: true
            ),
            homeFallback
        )
        XCTAssertEqual(
            HomeRecommendationStore.recommendationErrorMessage(
                for: AIChatServiceError.unavailable,
                hasLocalResults: false
            ),
            "AI 推荐暂时不可用。",
            "with nothing on screen the fallback drops the local-browsing clause"
        )
    }

    func testHomeKeepsTheOnDevicePolicyMessage() {
        let message = HomeRecommendationStore.recommendationErrorMessage(
            for: AppleRecommendationError.strictRestrictionUnsupported,
            hasLocalResults: false
        )
        XCTAssertEqual(message, AppleRecommendationError.strictRestrictionUnsupported.localizedDescription)
    }

    // H3
    func testHomeHidesTechnicalErrors() {
        for error in unsafeErrors {
            let message = HomeRecommendationStore.recommendationErrorMessage(for: error, hasLocalResults: true)
            XCTAssertEqual(message, homeFallback, "unexpected passthrough for \(type(of: error))")
            XCTAssertFalse(message.contains(sentinel))
        }
        XCTAssertEqual(
            HomeRecommendationStore.recommendationErrorMessage(
                for: AIChatServiceError.unavailable,
                hasLocalResults: true
            ),
            homeFallback
        )
    }

    // MARK: - Link import

    // L1
    func testLinkImportHidesBackendAndStatusDetail() {
        for error in [LinkExtractError.invalidResponse, .invalidJSON, .invalidEndpoint, .invalidURL] {
            let message = ImportRecipeView.importErrorMessage(for: error)
            XCTAssertEqual(message, linkFallback, "unexpected passthrough for \(error)")
            XCTAssertFalse(message.contains("服务器"), "the backend is not the member's problem")
            XCTAssertFalse(message.contains("接口"))
        }
        for error in unsafeErrors {
            let message = ImportRecipeView.importErrorMessage(for: error)
            XCTAssertEqual(message, linkFallback, "unexpected passthrough for \(type(of: error))")
            XCTAssertFalse(message.contains("状态码"))
        }
    }

    // L2
    func testLinkImportKeepsActionableLinkErrors() {
        // Already translated from the backend's code into product copy, and it
        // carries this flow's own rate-limit guidance.
        XCTAssertEqual(
            ImportRecipeView.importErrorMessage(for: LinkExtractError.server(code: "rate_limited", status: 429)),
            LinkExtractError.server(code: "rate_limited", status: 429).localizedDescription
        )
        XCTAssertEqual(
            ImportRecipeView.importErrorMessage(for: LinkExtractError.server(code: "login_required", status: 403)),
            LinkExtractError.server(code: "login_required", status: 403).localizedDescription
        )
        XCTAssertEqual(
            ImportRecipeView.importErrorMessage(for: LinkExtractError.emptyInput),
            LinkExtractError.emptyInput.localizedDescription
        )
        XCTAssertEqual(
            ImportRecipeView.importErrorMessage(for: AIRecipeParseError.missingRecipe),
            AIRecipeParseError.missingRecipe.localizedDescription
        )
        XCTAssertEqual(
            ImportRecipeView.importErrorMessage(for: UserRecipeSaveError.sourceAlreadyImported),
            UserRecipeSaveError.sourceAlreadyImported.localizedDescription
        )
    }

    // L3 — the one case that carries the backend's own words.
    func testLinkImportNeverRepeatsABackendPayload() {
        let message = ImportRecipeView.importErrorMessage(for: AIRecipeParseError.server(sentinel))
        XCTAssertEqual(message, linkFallback)
        XCTAssertFalse(message.contains(sentinel))
    }

    // MARK: - One payload, every mapper

    func testNoMapperEverRepeatsABackendPayload() {
        let carriers: [Error] = unsafeErrors + [
            AIRecipeParseError.server(sentinel),
            APIError.validation(sentinel)
        ]
        for error in carriers {
            let messages = [
                WeeklyMenuPlannerStore.generationErrorMessage(for: error),
                AIRecipeGeneratorStore.generationErrorMessage(for: error),
                HomeRecommendationStore.recommendationErrorMessage(for: error, hasLocalResults: true),
                HomeRecommendationStore.recommendationErrorMessage(for: error, hasLocalResults: false),
                ImportRecipeView.importErrorMessage(for: error)
            ]
            for message in messages {
                XCTAssertFalse(message.contains(sentinel), "leaked through \(type(of: error)): \(message)")
                XCTAssertFalse(message.contains("状态码"))
                XCTAssertFalse(message.isEmpty)
            }
        }
    }
}

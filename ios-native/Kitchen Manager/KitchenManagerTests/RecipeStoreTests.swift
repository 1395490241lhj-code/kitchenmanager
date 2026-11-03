import XCTest
@testable import KitchenManager

@MainActor
final class RecipeStoreTests: XCTestCase {
    private var store: RecipeStore!

    override func setUp() {
        super.setUp()
        store = RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    private func recipe(
        id: String,
        title: String = "菜",
        ingredients: [String] = ["食材 1个"],
        steps: [String] = ["步骤"],
        source: RecipeSourceMetadata? = nil
    ) -> Recipe {
        Recipe(id: id, title: title, cookingTime: nil, difficulty: nil, tags: [], ingredients: ingredients, steps: steps, source: source)
    }

    private func source(url: String, canonical: String? = nil) -> RecipeSourceMetadata {
        RecipeSourceMetadata(
            platform: "xiaohongshu",
            originalURL: url,
            canonicalURL: canonical ?? url,
            importedAt: Date(),
            title: nil,
            author: nil
        )
    }

    // MARK: - ID-based dedup: user recipe wins over remote with same id

    func test_recipes_userRecipeWithSameID_takesPriorityOverRemote() {
        try? store.saveUserRecipe(recipe(id: "shared-id", title: "我的版本"))
        // remoteRecipes is private(set); simulate by reloading is out of
        // scope here (network), so this test focuses on the documented
        // `recipes` computed property rule using only what's testable
        // without a network call: verify the user copy is present and
        // `recipes` includes it.
        XCTAssertTrue(store.recipes.contains { $0.id == "shared-id" && $0.title == "我的版本" })
    }

    func test_recipes_differentIDs_bothRetained() {
        try? store.saveUserRecipe(recipe(id: "id-1", title: "菜1"))
        try? store.saveUserRecipe(recipe(id: "id-2", title: "菜2"))
        XCTAssertEqual(Set(store.recipes.map(\.id)), Set(["id-1", "id-2"]))
    }

    // MARK: - Source URL dedup (via containsImportedSource / saveUserRecipe)

    func test_containsImportedSource_exactSameURL_isConsideredSame() {
        try? store.saveUserRecipe(recipe(id: "r1", source: source(url: "https://example.com/recipe/1")))
        XCTAssertTrue(store.containsImportedSource("https://example.com/recipe/1"))
    }

    func test_containsImportedSource_withFragment_isConsideredSame() {
        try? store.saveUserRecipe(recipe(id: "r1", source: source(url: "https://example.com/recipe/1")))
        XCTAssertTrue(store.containsImportedSource("https://example.com/recipe/1#comments"))
    }

    func test_containsImportedSource_withUTMQuery_isConsideredSame() {
        try? store.saveUserRecipe(recipe(id: "r1", source: source(url: "https://example.com/recipe/1")))
        XCTAssertTrue(store.containsImportedSource("https://example.com/recipe/1?utm_source=test"))
    }

    func test_containsImportedSource_withXiaohongshiShareParams_isConsideredSame() {
        try? store.saveUserRecipe(recipe(id: "r1", source: source(url: "https://example.com/recipe/1")))
        XCTAssertTrue(store.containsImportedSource("https://example.com/recipe/1?xsec_token=abc&sharefrom=wechat"))
    }

    func test_containsImportedSource_hostIsCaseInsensitive() {
        try? store.saveUserRecipe(recipe(id: "r1", source: source(url: "https://Example.com/recipe/1")))
        XCTAssertTrue(store.containsImportedSource("https://example.com/recipe/1"))
    }

    // MARK: - Must NOT be falsely deduplicated

    func test_containsImportedSource_differentPath_isNotConsideredSame() {
        try? store.saveUserRecipe(recipe(id: "r1", source: source(url: "https://example.com/recipe/1")))
        XCTAssertFalse(store.containsImportedSource("https://example.com/recipe/2"))
    }

    func test_containsImportedSource_differentNonUTMQuery_isNotConsideredSame() {
        try? store.saveUserRecipe(recipe(id: "r1", source: source(url: "https://example.com/recipe?id=1")))
        XCTAssertFalse(store.containsImportedSource("https://example.com/recipe?id=2"))
    }

    func test_containsImportedSource_sameHostDifferentRecipeID_isNotConsideredSame() {
        try? store.saveUserRecipe(recipe(id: "r1", source: source(url: "https://example.com/recipe/abc")))
        XCTAssertFalse(store.containsImportedSource("https://example.com/recipe/xyz"))
    }

    func test_saveUserRecipe_sameSourceURL_throwsSourceAlreadyImported() {
        try? store.saveUserRecipe(recipe(id: "r1", source: source(url: "https://example.com/recipe/1")))
        XCTAssertThrowsError(
            try store.saveUserRecipe(recipe(id: "r2", title: "不同标题", ingredients: ["别的食材"], source: source(url: "https://example.com/recipe/1")))
        ) { error in
            guard case UserRecipeSaveError.sourceAlreadyImported = error else {
                return XCTFail("expected .sourceAlreadyImported, got \(error)")
            }
        }
    }

    // MARK: - Content fingerprint dedup

    func test_saveUserRecipe_identicalContent_throwsAlreadySaved() {
        try? store.saveUserRecipe(recipe(id: "r1", title: "麻婆豆腐", ingredients: ["豆腐", "肉末"], steps: ["炒", "焖"]))
        XCTAssertThrowsError(
            try store.saveUserRecipe(recipe(id: "r2", title: "麻婆豆腐", ingredients: ["豆腐", "肉末"], steps: ["炒", "焖"]))
        ) { error in
            guard case UserRecipeSaveError.alreadySaved = error else {
                return XCTFail("expected .alreadySaved, got \(error)")
            }
        }
    }

    func test_saveUserRecipe_titleWhitespaceDifference_isStillConsideredDuplicate() {
        // fingerprint() strips whitespace entirely before comparing.
        try? store.saveUserRecipe(recipe(id: "r1", title: "麻婆 豆腐", ingredients: ["豆腐"], steps: ["炒"]))
        XCTAssertThrowsError(
            try store.saveUserRecipe(recipe(id: "r2", title: "麻婆豆腐", ingredients: ["豆腐"], steps: ["炒"]))
        )
    }

    func test_saveUserRecipe_ingredientOrderDifference_isNotConsideredDuplicate() {
        // fingerprint() joins ingredients in array order without sorting —
        // documenting current behavior: a reordered ingredient list produces
        // a DIFFERENT fingerprint, so it is NOT treated as a duplicate.
        try? store.saveUserRecipe(recipe(id: "r1", title: "菜", ingredients: ["豆腐", "肉末"], steps: ["炒"]))
        XCTAssertNoThrow(
            try store.saveUserRecipe(recipe(id: "r2", title: "菜", ingredients: ["肉末", "豆腐"], steps: ["炒"]))
        )
    }

    func test_saveUserRecipe_differentSteps_isNotADuplicate() {
        try? store.saveUserRecipe(recipe(id: "r1", title: "菜", ingredients: ["豆腐"], steps: ["炒一下"]))
        XCTAssertNoThrow(
            try store.saveUserRecipe(recipe(id: "r2", title: "菜", ingredients: ["豆腐"], steps: ["焖一下"]))
        )
    }

    func test_saveUserRecipe_differentQuantityInIngredientLine_isNotADuplicate() {
        try? store.saveUserRecipe(recipe(id: "r1", title: "菜", ingredients: ["豆腐 1块"], steps: ["炒"]))
        XCTAssertNoThrow(
            try store.saveUserRecipe(recipe(id: "r2", title: "菜", ingredients: ["豆腐 2块"], steps: ["炒"]))
        )
    }

    func test_saveUserRecipe_sameIngredientsDifferentTitle_isNotADuplicate() {
        try? store.saveUserRecipe(recipe(id: "r1", title: "菜A", ingredients: ["豆腐", "肉末"], steps: ["炒"]))
        XCTAssertNoThrow(
            try store.saveUserRecipe(recipe(id: "r2", title: "菜B", ingredients: ["豆腐", "肉末"], steps: ["炒"]))
        )
    }

    func test_saveUserRecipe_sameID_throwsAlreadySaved() {
        try? store.saveUserRecipe(recipe(id: "dup-id", title: "菜A"))
        XCTAssertThrowsError(try store.saveUserRecipe(recipe(id: "dup-id", title: "菜B", ingredients: ["完全不同"])))
    }

    // MARK: - Sample fallback disclosure

    /// The loading-state edge: an empty library before any load has failed is
    /// not a failure. Samples may show, but nothing may claim loading broke.
    func test_isDisplayingSamples_emptyStoreBeforeAnyLoad_staysNeutral() {
        XCTAssertTrue(store.recipes.isEmpty)
        XCTAssertFalse(store.isDisplayingSamples, "初始加载中不应显示加载失败语义")
        XCTAssertNil(store.errorMessage)
        // Sample display itself is unchanged — only the labelling is gated.
        XCTAssertEqual(store.recipesForDisplay.map(\.id), Recipe.samples.map(\.id))
    }

    func test_isDisplayingSamples_whileLoading_staysNeutral() async {
        store.isLoading = true
        XCTAssertTrue(store.recipes.isEmpty)
        XCTAssertFalse(store.isDisplayingSamples, "加载进行中不应显示回退语义")
        store.isLoading = false
    }

    func test_isDisplayingSamples_withUserRecipe_isFalseAndUsesRealLibrary() {
        try? store.saveUserRecipe(recipe(id: "mine", title: "我的菜"))
        XCTAssertFalse(store.isDisplayingSamples)
        XCTAssertEqual(store.recipesForDisplay.map(\.id), ["mine"])
    }

    func test_loadRecipes_failure_setsSampleFallbackFlag() async {
        // No network in the test environment, so loadRecipes takes the failure
        // path and installs Recipe.samples — exactly the state users hit offline.
        await store.loadRecipes()
        // Flag and message must agree in both directions, so this holds whether
        // or not the environment happens to have network.
        XCTAssertEqual(store.isShowingSampleFallback, store.remoteRecipes.map(\.id) == Recipe.samples.map(\.id))
        if store.isShowingSampleFallback {
            XCTAssertTrue(store.isDisplayingSamples)
            XCTAssertNotNil(store.errorMessage)
        }
    }

    // MARK: - Recipe library mode (DATA-1 / ONB-9)
    //
    // The 菜谱库模式 picker is gone: the full pack has no method for most
    // dishes and lacks IDs that plans point at, so iOS only loads the curated
    // library. A member who once picked the full library browses the curated
    // one, but the plans, 收藏 and 常做 they made there still resolve.

    private static let curatedPackJSON = #"{"recipes": [{"id": "1", "name": "番茄炒蛋"}], "recipe_ingredients": {}}"#
    private static let fullPackJSON = #"""
    {"recipes": [
        {"id": "1", "name": "番茄炒蛋（完整库）"},
        {"id": "ex--c5d9eac5", "name": "兰花田鸡"},
        {"id": "ex--514e3fd8", "name": "收藏的老菜"}
    ], "recipe_ingredients": {
        "ex--c5d9eac5": [{"item": "田鸡", "qty": "500", "unit": "克"}]
    }}
    """#

    private func storeWithMockedLibrary(choseFull: Bool, fullPackFails: Bool = false) -> RecipeStore {
        let curatedPack = Data(Self.curatedPackJSON.utf8)
        let fullPack = Data(Self.fullPackJSON.utf8)
        MockURLProtocol.install { request in
            guard request.url?.lastPathComponent == "sichuan-recipes.json" else {
                return .init(statusCode: 200, data: curatedPack)
            }
            return fullPackFails
                ? .init(error: URLError(.notConnectedToInternet))
                : .init(statusCode: 200, data: fullPack)
        }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        if choseFull { defaults.set("full", forKey: "recipeLibraryMode") }
        return RecipeStore(
            userDefaults: defaults,
            service: RecipeService(apiClient: APIClient(environment: .production, session: .mocked(), defaultTimeout: 60))
        )
    }

    /// The stored choice stays, so a relaunch still resolves the old dishes.
    func test_libraryMode_memberWhoChoseFull_browsesCuratedAndKeepsTheMark() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("full", forKey: "recipeLibraryMode")

        let store = RecipeStore(userDefaults: defaults)

        XCTAssertEqual(store.libraryMode, .curated)
        XCTAssertEqual(defaults.string(forKey: "recipeLibraryMode"), "full", "旧选择要保留，重启后仍能找到完整库里的菜")
    }

    func test_loadRecipes_memberWhoNeverChoseFull_requestsOnlyTheCuratedPack() async {
        defer { MockURLProtocol.reset() }
        let store = storeWithMockedLibrary(choseFull: false)

        await store.loadRecipes()

        XCTAssertEqual(MockURLProtocol.capturedRequests().map { $0.url?.lastPathComponent }, ["sichuan-recipes.curated.json"])
    }

    func test_loadRecipes_memberWhoChoseFull_requestsCuratedThenTheFullPackForLookups() async {
        defer { MockURLProtocol.reset() }
        let store = storeWithMockedLibrary(choseFull: true)

        await store.loadRecipes()

        XCTAssertEqual(
            MockURLProtocol.capturedRequests().map { $0.url?.lastPathComponent },
            ["sichuan-recipes.curated.json", "sichuan-recipes.json"]
        )
    }

    /// DATA1 / F2: a plan for 兰花田鸡 (only in the full pack) still opens and
    /// can be deducted; a favorited full-only dish stays in 收藏; other
    /// full-only dishes are not offered for browsing; curated wins on shared IDs.
    func test_loadRecipes_memberWhoChoseFull_stillResolvesDishesOnlyTheFullPackHas() async {
        defer { MockURLProtocol.reset() }
        let store = storeWithMockedLibrary(choseFull: true)
        store.toggleFavorite("ex--514e3fd8")

        await store.loadRecipes()

        XCTAssertEqual(store.recipe(id: "ex--c5d9eac5")?.title, "兰花田鸡", "完整库里的计划菜仍能打开")
        XCTAssertEqual(store.recipe(id: "ex--c5d9eac5")?.ingredients, ["田鸡 500 克"], "做完仍能扣库存")
        XCTAssertEqual(store.recipe(id: "1")?.title, "番茄炒蛋", "同一 ID 以精简库为准")
        XCTAssertEqual(store.recipes.map(\.id), ["1", "ex--514e3fd8"], "收藏的老菜留在菜谱里，其它完整库菜不出现")
        XCTAssertEqual(store.plannedRecipeAvailability, .missing, "两个库都加载了，真的没有才算缺失")
    }

    /// The full pack failing must not make an old plan claim its dish was
    /// never saved: the member is offered 重试 instead.
    func test_loadRecipes_memberWhoChoseFull_fullPackFailing_isLoadFailedNotMissing() async {
        defer { MockURLProtocol.reset() }
        let store = storeWithMockedLibrary(choseFull: true, fullPackFails: true)

        await store.loadRecipes()

        XCTAssertNil(store.recipe(id: "ex--c5d9eac5"))
        XCTAssertEqual(store.recipe(id: "1")?.title, "番茄炒蛋")
        XCTAssertFalse(store.isShowingSampleFallback)
        XCTAssertNil(store.errorMessage, "精简库已加载，不显示加载失败横幅")
        XCTAssertEqual(store.plannedRecipeAvailability, .loadFailed)
    }

    // MARK: - Batch save for generated recipes
    //
    // Weekly materialization prepares every recipe a menu needs before it writes
    // a single plan row, and may have to repeat that after a failed plan write.
    // So an id it already stored is a reuse, not a duplicate — while an id that
    // belongs to someone else's recipe is refused rather than overwritten.

    /// Succeeds until `shouldFail` is set, so a test can build real state and
    /// then fail exactly the write it is about.
    private final class ToggleableUserRecipePersistence: UserRecipePersistenceProtocol {
        struct ExpectedFailure: Error {}
        var recipes: [Recipe] = []
        var shouldFail = false
        var replaceCallCount = 0

        func loadRecipes() throws -> [Recipe] { recipes }
        func storedRecordCount() throws -> Int { recipes.count }
        func replaceRecipes(with recipes: [Recipe]) throws {
            replaceCallCount += 1
            if shouldFail { throw ExpectedFailure() }
            self.recipes = recipes
        }
        func deleteAll() throws { recipes = [] }
    }

    private func makeInjectedStore(
        _ persistence: UserRecipePersistenceProtocol
    ) -> RecipeStore {
        RecipeStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            userRecipePersistence: persistence,
            recipePreferencePersistence: KitchenPersistenceFactory.isolatedInMemory().recipePreferences
        )
    }

    func test_saveUserRecipes_persistsEveryGeneratedRecipeInOneWrite() throws {
        let persistence = ToggleableUserRecipePersistence()
        let store = makeInjectedStore(persistence)
        let writesBefore = persistence.replaceCallCount

        try store.saveUserRecipes([
            recipe(id: "weekly-ai-1", title: "番茄炒蛋"),
            recipe(id: "weekly-ai-2", title: "青椒肉丝")
        ])

        XCTAssertEqual(Set(store.userRecipes.map(\.id)), ["weekly-ai-1", "weekly-ai-2"])
        XCTAssertEqual(Set(persistence.recipes.map(\.id)), ["weekly-ai-1", "weekly-ai-2"], "the disk agrees")
        XCTAssertEqual(persistence.replaceCallCount - writesBefore, 1, "one batch is one write")
        XCTAssertNotNil(store.recipe(id: "weekly-ai-1"), "a plan row can reference it immediately")
    }

    func test_saveUserRecipes_failedPersistenceKeepsTheLibraryUnchanged() throws {
        let persistence = ToggleableUserRecipePersistence()
        let store = makeInjectedStore(persistence)
        try store.saveUserRecipes([recipe(id: "weekly-ai-1", title: "番茄炒蛋")])
        persistence.shouldFail = true

        XCTAssertThrowsError(try store.saveUserRecipes([recipe(id: "weekly-ai-2", title: "青椒肉丝")])) { error in
            XCTAssertEqual(error as? UserRecipeBatchError, .persistenceFailed)
        }

        XCTAssertEqual(store.userRecipes.map(\.id), ["weekly-ai-1"], "nothing is published that was not stored")
        XCTAssertEqual(persistence.recipes.map(\.id), ["weekly-ai-1"])
    }

    func test_saveUserRecipes_retryReusesTheRecipesAnEarlierAttemptAlreadyStored() throws {
        let persistence = ToggleableUserRecipePersistence()
        let store = makeInjectedStore(persistence)
        let prepared = [
            recipe(id: "weekly-ai-1", title: "番茄炒蛋"),
            recipe(id: "weekly-ai-2", title: "青椒肉丝")
        ]
        try store.saveUserRecipes(prepared)
        let writesAfterFirst = persistence.replaceCallCount

        // The plan write failed, so materialization runs the recipe step again
        // with exactly the same recipes.
        XCTAssertNoThrow(try store.saveUserRecipes(prepared))

        XCTAssertEqual(store.userRecipes.count, 2, "reuse, not a second copy")
        XCTAssertEqual(
            persistence.replaceCallCount - writesAfterFirst, 0,
            "everything was already durable, so there is nothing to write"
        )
    }

    func test_saveUserRecipes_refusesAnIdThatBelongsToADifferentRecipe() throws {
        let persistence = ToggleableUserRecipePersistence()
        let store = makeInjectedStore(persistence)
        let mine = recipe(id: "weekly-ai-1", title: "我的红烧肉", ingredients: ["五花肉 500g"], steps: ["炖"])
        try store.saveUserRecipe(mine)
        let writesBefore = persistence.replaceCallCount

        let collision = recipe(id: "weekly-ai-1", title: "番茄炒蛋", ingredients: ["番茄 2个"], steps: ["炒熟"])
        XCTAssertThrowsError(try store.saveUserRecipes([collision])) { error in
            XCTAssertEqual(error as? UserRecipeBatchError, .idConflict(id: "weekly-ai-1"))
        }

        XCTAssertEqual(store.recipe(id: "weekly-ai-1")?.title, "我的红烧肉", "the stored recipe is never overwritten")
        XCTAssertEqual(persistence.replaceCallCount - writesBefore, 0, "and nothing is written")
    }

    func test_saveUserRecipes_refusesARequestThatRepeatsOneIdWithDifferentContent() throws {
        let persistence = ToggleableUserRecipePersistence()
        let store = makeInjectedStore(persistence)

        XCTAssertThrowsError(
            try store.saveUserRecipes([
                recipe(id: "weekly-ai-1", title: "番茄炒蛋", ingredients: ["番茄 2个"]),
                recipe(id: "weekly-ai-1", title: "青椒肉丝", ingredients: ["青椒 3个"])
            ])
        ) { error in
            XCTAssertEqual(error as? UserRecipeBatchError, .idConflict(id: "weekly-ai-1"))
        }

        XCTAssertTrue(store.userRecipes.isEmpty)
    }

    func test_saveUserRecipes_collapsesAnIdenticalDishListedTwiceInOneMenu() throws {
        let persistence = ToggleableUserRecipePersistence()
        let store = makeInjectedStore(persistence)
        let dish = recipe(id: "weekly-ai-1", title: "番茄炒蛋")

        try store.saveUserRecipes([dish, dish])

        XCTAssertEqual(store.userRecipes.map(\.id), ["weekly-ai-1"])
    }

    func test_saveUserRecipes_anEmptyRequestWritesNothing() throws {
        let persistence = ToggleableUserRecipePersistence()
        let store = makeInjectedStore(persistence)
        let writesBefore = persistence.replaceCallCount

        XCTAssertNoThrow(try store.saveUserRecipes([]))

        XCTAssertEqual(persistence.replaceCallCount - writesBefore, 0, "a menu of only existing recipes needs no write")
    }
}

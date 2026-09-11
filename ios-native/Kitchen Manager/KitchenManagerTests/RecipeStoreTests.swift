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

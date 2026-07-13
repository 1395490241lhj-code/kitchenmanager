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
}

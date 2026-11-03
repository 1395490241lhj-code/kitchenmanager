import XCTest
@testable import KitchenManager

/// ONB-M1: a planned meal whose recipe cannot be resolved yet must not claim
/// the dish is gone from the library while that library is still loading or
/// failed to load. Only a library that actually loaded may say so.
@MainActor
final class PlannedRecipeAvailabilityTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Classification

    func test_whileLoading_isLoading() {
        XCTAssertEqual(
            PlannedRecipeAvailability.classify(isLoading: true, hasRemoteRecipes: false, isShowingSampleFallback: false, errorMessage: nil),
            .loading
        )
    }

    /// 重试 after a failure: the samples are still installed while the new
    /// request runs, and that request is what the member is waiting on.
    func test_retryingAfterFailure_isLoading() {
        XCTAssertEqual(
            PlannedRecipeAvailability.classify(isLoading: true, hasRemoteRecipes: true, isShowingSampleFallback: true, errorMessage: nil),
            .loading
        )
    }

    /// Cold start before the first request resolves: nothing has failed, so
    /// nothing may say the recipe is missing.
    func test_neverLoadedAndNothingFailed_isLoading() {
        XCTAssertEqual(
            PlannedRecipeAvailability.classify(isLoading: false, hasRemoteRecipes: false, isShowingSampleFallback: false, errorMessage: nil),
            .loading
        )
    }

    func test_sampleFallback_isLoadFailed() {
        XCTAssertEqual(
            PlannedRecipeAvailability.classify(isLoading: false, hasRemoteRecipes: true, isShowingSampleFallback: true, errorMessage: "暂时无法加载线上菜谱"),
            .loadFailed
        )
    }

    func test_errorWithoutAnyLoadedLibrary_isLoadFailed() {
        XCTAssertEqual(
            PlannedRecipeAvailability.classify(isLoading: false, hasRemoteRecipes: false, isShowingSampleFallback: false, errorMessage: "暂时无法加载线上菜谱"),
            .loadFailed
        )
    }

    func test_loadedLibrary_isMissing() {
        XCTAssertEqual(
            PlannedRecipeAvailability.classify(isLoading: false, hasRemoteRecipes: true, isShowingSampleFallback: false, errorMessage: nil),
            .missing
        )
    }

    /// A later refresh failed, but the library from the earlier success is
    /// still the one being shown, so the recipe really is not in it.
    func test_loadedLibraryWithLaterRefreshError_isMissing() {
        XCTAssertEqual(
            PlannedRecipeAvailability.classify(isLoading: false, hasRemoteRecipes: true, isShowingSampleFallback: false, errorMessage: "暂时无法加载线上菜谱"),
            .missing
        )
    }

    /// A member who once used 完整菜谱库: until that pack also loads, an old
    /// plan's dish may still be in it.
    func test_loadedLibraryButRetiredFullLibraryFailed_isLoadFailed() {
        XCTAssertEqual(
            PlannedRecipeAvailability.classify(isLoading: false, hasRemoteRecipes: true, isShowingSampleFallback: false, errorMessage: nil, retiredLibraryFailed: true),
            .loadFailed
        )
    }

    // MARK: - RecipeStore

    private let packJSON = """
    {
        "recipes": [
            {"id": "1", "name": "番茄炒蛋", "method": "打散鸡蛋\\n下锅炒", "tags": ["快手"]}
        ],
        "recipe_ingredients": {
            "1": [{"item": "鸡蛋", "qty": "2", "unit": "个"}]
        }
    }
    """

    private func makeStore() -> RecipeStore {
        RecipeStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            service: RecipeService(apiClient: APIClient(environment: .production, session: .mocked(), defaultTimeout: 60))
        )
    }

    func test_store_beforeFirstLoad_isLoading() {
        let store = makeStore()
        XCTAssertNil(store.recipe(id: "1"))
        XCTAssertEqual(store.plannedRecipeAvailability, .loading)
    }

    func test_store_whileLoading_isLoading() {
        let store = makeStore()
        store.isLoading = true
        XCTAssertEqual(store.plannedRecipeAvailability, .loading)
    }

    func test_store_failedLoad_isLoadFailed() async {
        MockURLProtocol.install { _ in .init(error: URLError(.notConnectedToInternet)) }
        let store = makeStore()

        await store.loadRecipes()

        XCTAssertTrue(store.isShowingSampleFallback)
        XCTAssertNil(store.recipe(id: "1"), "离线时这道菜还没加载出来")
        XCTAssertEqual(store.plannedRecipeAvailability, .loadFailed, "加载失败不能说成菜谱库里没有")
    }

    func test_store_retryAfterFailure_resolvesThePlannedRecipe() async {
        MockURLProtocol.install { _ in .init(error: URLError(.notConnectedToInternet)) }
        let store = makeStore()
        await store.loadRecipes()
        XCTAssertEqual(store.plannedRecipeAvailability, .loadFailed)

        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data(self.packJSON.utf8)) }
        await store.loadRecipes()

        XCTAssertEqual(store.recipe(id: "1")?.title, "番茄炒蛋", "重试成功后计划里的菜能直接打开")
        XCTAssertFalse(store.isShowingSampleFallback)
    }

    func test_store_loadedLibraryWithoutThePlannedID_isMissing() async {
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data(self.packJSON.utf8)) }
        let store = makeStore()

        await store.loadRecipes()

        XCTAssertNil(store.recipe(id: "gone"))
        XCTAssertEqual(store.plannedRecipeAvailability, .missing)
    }

    /// An empty pack is a failed load (`RecipeAPIError.emptyData`), so the
    /// planned meal offers 重试 instead of waiting on a load that has ended.
    func test_store_emptyPack_isLoadFailedNotLoadingForever() async {
        MockURLProtocol.install { _ in .init(statusCode: 200, data: Data(#"{"recipes": [], "recipe_ingredients": {}}"#.utf8)) }
        let store = makeStore()

        await store.loadRecipes()

        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(store.plannedRecipeAvailability, .loadFailed, "空菜谱包不能让计划里的菜一直转圈")
    }
}

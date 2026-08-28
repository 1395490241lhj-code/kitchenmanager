import XCTest
@testable import KitchenManager

/// Covers the two rules `InventoryItemKind` exists to hold:
///
/// 1. a staple is stock-tracked, so nothing may give it an expiry date or put
///    it on an expiry surface;
/// 2. a ready-to-cook row (腌好的冷冻鱼柳, 调味鸡翅, 包好的饺子) is kept, counted and
///    date-tracked exactly like ordinary inventory, but is never handed to a
///    recipe-creation request as raw material.
///
/// Plus the compatibility rule that matters most: old data carries no kind and
/// must keep behaving exactly as it did.
@MainActor
final class InventoryItemKindTests: XCTestCase {
    private var store: KitchenStore!

    override func setUp() {
        super.setUp()
        store = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    private func item(named name: String) -> InventoryItem? {
        store.inventory.first { $0.name == name }
    }

    // MARK: - 1. Ordinary items keep the existing expiry behaviour

    func testOrdinaryItemStillGetsAnExpiryDate() throws {
        store.addInventory(name: "番茄", quantity: 2, unit: "个", expiryDate: nil)

        let tomato = try XCTUnwrap(item(named: "番茄"))
        XCTAssertEqual(tomato.kind, .ordinary)
        XCTAssertNotNil(tomato.expiryDate, "普通食材必须仍然自动获得保质期")
    }

    func testOrdinaryItemKeepsAnExplicitExpiryDate() {
        let explicit = Calendar.current.date(byAdding: .day, value: 4, to: Date())!
        store.addInventory(name: "牛奶", quantity: 1, unit: "盒", expiryDate: explicit)

        XCTAssertEqual(item(named: "牛奶")?.expiryDate, explicit)
    }

    // MARK: - 2. A new staple is not expiry-tracked

    func testNewStapleHasNoExpiryDate() throws {
        try store.saveStaple(
            id: nil,
            name: "生抽",
            quantity: 1,
            unit: "瓶",
            minimumQuantity: 1,
            defaultRestockQuantity: 1,
            autoSuggestRestock: true,
            note: nil,
            category: nil
        )

        let soySauce = try XCTUnwrap(item(named: "生抽"))
        XCTAssertEqual(soySauce.kind, .staple)
        XCTAssertNil(soySauce.expiryDate, "常备食材默认不跟踪保质期")
    }

    func testStapleImportDropsASuppliedExpiryDate() throws {
        store.importInventory([
            InventoryImportItem(
                name: "盐",
                quantity: 1,
                unit: "袋",
                expiryDate: Date(),
                kind: .staple
            )
        ])

        XCTAssertNil(try XCTUnwrap(item(named: "盐")).expiryDate,
                     "常备食材不应通过写入一个日期来伪装成“不跟踪”")
    }

    /// The concrete bug: an ordinary row already carrying a date, promoted to
    /// the pantry shelf, used to keep that date and go on firing expiry alerts.
    func testPromotingAnExistingItemToStapleClearsItsExpiryDate() throws {
        store.addInventory(name: "食用油", quantity: 1, unit: "瓶", expiryDate: Date())
        XCTAssertNotNil(item(named: "食用油")?.expiryDate)

        try store.saveStaple(
            id: nil,
            name: "食用油",
            quantity: 1,
            unit: "瓶",
            minimumQuantity: 1,
            defaultRestockQuantity: nil,
            autoSuggestRestock: false,
            note: nil,
            category: nil
        )

        let oil = try XCTUnwrap(item(named: "食用油"))
        XCTAssertEqual(oil.kind, .staple)
        XCTAssertNil(oil.expiryDate)
    }

    // MARK: - 3. Staples never reach an expiry surface

    func testStapleWithALegacyExpiryDateStaysOutOfExpiryLists() {
        // Simulates data written before staples stopped being date-tracked:
        // the row is not rewritten, it is simply never shown as expiring.
        store.inventory = [
            InventoryItem(
                name: "陈年生抽",
                quantity: 1,
                unit: "瓶",
                expiryDate: Calendar.current.date(byAdding: .day, value: -3, to: Date()),
                kind: .staple
            )
        ]

        XCTAssertTrue(store.expiringItems.isEmpty, "常备食材不应进入即将过期 / 已过期列表")

        let dashboard = HomeDashboardSummary(
            inventory: store.inventory,
            todayPlans: [],
            shoppingItems: []
        )
        XCTAssertEqual(dashboard.expiredCount, 0)
        XCTAssertEqual(dashboard.expiringSoonCount, 0)
        XCTAssertFalse(
            dashboard.attentionItems.contains { $0.kind == .expiredInventory || $0.kind == .expiringInventory },
            "Home 的需要处理列表不应因为常备食材的历史日期而报过期"
        )
    }

    // MARK: - 4. Ready-to-cook items are ordinary inventory in every other way

    func testReadyToCookItemKeepsQuantityAndExpiryTracking() throws {
        let expiry = Calendar.current.date(byAdding: .day, value: 2, to: Date())!
        store.importInventory([
            InventoryImportItem(
                name: "腌好的鱼柳",
                quantity: 3,
                unit: "块",
                expiryDate: expiry,
                kind: .readyToCook
            )
        ])

        let fish = try XCTUnwrap(item(named: "腌好的鱼柳"))
        XCTAssertEqual(fish.kind, .readyToCook)
        XCTAssertEqual(fish.quantity, 3)
        XCTAssertEqual(fish.expiryDate, expiry)
        XCTAssertTrue(store.availableInventory.contains { $0.id == fish.id },
                      "预制食材仍然是正常库存")
        XCTAssertTrue(store.expiringItems.contains { $0.id == fish.id },
                      "预制食材仍然要正常参与过期提醒")
    }

    func testReadyToCookItemWithoutAnExplicitDateStillGetsOne() throws {
        store.addInventory(name: "调味鸡翅", quantity: 6, unit: "只", expiryDate: nil, kind: .readyToCook)

        XCTAssertNotNil(try XCTUnwrap(item(named: "调味鸡翅")).expiryDate)
    }

    // MARK: - 5. Ready-to-cook items never reach a recipe-creation request

    func testRecipeCreationPoolExcludesReadyToCookItems() {
        seedOneOfEachKind()

        let names = store.recipeCreationInventory.map(\.name)
        XCTAssertEqual(Set(names), ["番茄", "生抽"])
        XCTAssertFalse(names.contains("包好的饺子"), "预制食材不得进入 AI 候选食材列表")
    }

    func testRecipeCreationExpiringPoolExcludesReadyToCookItems() {
        let soon = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        store.inventory = [
            InventoryItem(name: "番茄", quantity: 1, unit: "个", expiryDate: soon, kind: .ordinary),
            InventoryItem(name: "包好的饺子", quantity: 20, unit: "个", expiryDate: soon, kind: .readyToCook)
        ]

        XCTAssertEqual(store.expiringItems.map(\.name), ["番茄", "包好的饺子"],
                       "两者都仍然是真实的临期库存")
        XCTAssertEqual(store.recipeCreationExpiringItems.map(\.name), ["番茄"],
                       "但只有普通食材可以驱动 AI 去创造一道新菜")
    }

    /// The filter has to happen while the candidate list is being built, not by
    /// asking the model to please ignore something: whatever the store hands
    /// the AI provider is all the provider ever sees.
    func testAIRequestPayloadNeverCarriesAReadyToCookItem() async {
        seedOneOfEachKind()

        let spy = InventoryCapturingRecommendationService()
        let recommendationStore = HomeRecommendationStore(aiService: spy)
        await recommendationStore.generateNewRecommendations(
            inventory: store.recipeCreationInventory.map(\.name),
            expiringIngredients: store.recipeCreationExpiringItems.map(\.name)
        )

        XCTAssertEqual(spy.capturedInventory, ["番茄", "生抽"])
        XCTAssertFalse(spy.capturedInventory.contains("包好的饺子"))
    }

    // MARK: - 6. Ordinary and staple items still reach the AI chain

    func testStaplesRemainAvailableToTheAIChain() {
        seedOneOfEachKind()

        XCTAssertTrue(store.recipeCreationInventory.contains { $0.name == "生抽" },
                      "常备食材可以作为调味 / 辅助食材参与 AI")
    }

    func testLocalRecommendationRankingSeesOnlyTheRecipeCreationPool() async {
        seedOneOfEachKind()

        let dumplingRecipe = Recipe(
            id: "dumpling",
            title: "饺子宴",
            cookingTime: 10,
            difficulty: "简单",
            tags: [],
            ingredients: ["包好的饺子"],
            seasonings: [],
            steps: ["煮"]
        )
        let tomatoRecipe = Recipe(
            id: "tomato",
            title: "番茄炒蛋",
            cookingTime: 10,
            difficulty: "简单",
            tags: [],
            ingredients: ["番茄"],
            seasonings: [],
            steps: ["炒"]
        )

        let recommendationStore = HomeRecommendationStore()
        recommendationStore.loadDefaultRecommendations(
            recipes: [dumplingRecipe, tomatoRecipe],
            inventory: store.recipeCreationInventory.map(\.name),
            expiringIngredients: store.recipeCreationExpiringItems.map(\.name)
        )

        XCTAssertEqual(
            recommendationStore.recommendedRecipes.first?.recipe.id,
            "tomato",
            "本地推荐排序也只能看到 AI 候选池，预制食材不应把饺子顶到第一位"
        )
    }

    // MARK: - 7. Editing the kind updates the dependent behaviour

    func testSwitchingToStapleClearsTheDateAndSwitchingBackRestoresOne() throws {
        store.addInventory(name: "大米", quantity: 1, unit: "袋", expiryDate: nil)
        let id = try XCTUnwrap(item(named: "大米")).id
        XCTAssertNotNil(item(named: "大米")?.expiryDate)

        store.setInventoryKind(id, to: .staple)
        XCTAssertNil(item(named: "大米")?.expiryDate)
        XCTAssertTrue(store.expiringItems.isEmpty)

        store.setInventoryKind(id, to: .ordinary)
        let rice = try XCTUnwrap(item(named: "大米"))
        XCTAssertEqual(rice.kind, .ordinary)
        XCTAssertNotNil(rice.expiryDate, "回到普通食材后重新开始跟踪保质期")
    }

    func testSwitchingToReadyToCookRemovesItFromTheAIPoolButKeepsItsDate() throws {
        store.addInventory(name: "鸡翅", quantity: 6, unit: "只", expiryDate: nil)
        let id = try XCTUnwrap(item(named: "鸡翅")).id
        let originalExpiry = item(named: "鸡翅")?.expiryDate
        XCTAssertTrue(store.recipeCreationInventory.contains { $0.id == id })

        store.setInventoryKind(id, to: .readyToCook)

        XCTAssertEqual(item(named: "鸡翅")?.expiryDate, originalExpiry, "类型切换不改动保质期")
        XCTAssertFalse(store.recipeCreationInventory.contains { $0.id == id })
        XCTAssertTrue(store.availableInventory.contains { $0.id == id })
    }

    func testLeavingStapleClearsTheShelfOnlySettings() throws {
        try store.saveStaple(
            id: nil,
            name: "黑胡椒",
            quantity: 1,
            unit: "瓶",
            minimumQuantity: 1,
            defaultRestockQuantity: 2,
            autoSuggestRestock: true,
            note: "研磨",
            category: "调味"
        )
        let id = try XCTUnwrap(item(named: "黑胡椒")).id

        store.setInventoryKind(id, to: .readyToCook)

        let pepper = try XCTUnwrap(item(named: "黑胡椒"))
        XCTAssertEqual(pepper.kind, .readyToCook)
        XCTAssertNil(pepper.lowStockThreshold)
        XCTAssertNil(pepper.defaultRestockQuantity)
        XCTAssertFalse(pepper.autoSuggestRestock)
        XCTAssertNil(pepper.stapleNote)
        XCTAssertNil(pepper.stapleCategory)
        XCTAssertTrue(store.pantryStaples.isEmpty)
    }

    // MARK: - 8. Legacy data compatibility

    func testPayloadWrittenBeforeKindsDecodesToItsOldBehaviour() throws {
        let legacyOrdinary = """
        {"id":"\(UUID().uuidString)","name":"番茄","quantity":2,"unit":"个","isStaple":false,"autoSuggestRestock":false,"stapleTrackingMode":"quantity","stapleAvailabilityStatus":"available"}
        """
        let legacyStaple = """
        {"id":"\(UUID().uuidString)","name":"大米","quantity":1,"unit":"袋","isStaple":true,"autoSuggestRestock":false,"stapleTrackingMode":"quantity","stapleAvailabilityStatus":"available"}
        """

        let ordinary = try JSONDecoder().decode(InventoryItem.self, from: Data(legacyOrdinary.utf8))
        let staple = try JSONDecoder().decode(InventoryItem.self, from: Data(legacyStaple.utf8))

        XCTAssertEqual(ordinary.kind, .ordinary)
        XCTAssertTrue(ordinary.kind.canInspireRecipeCreation, "旧数据默认保持普通食材行为")
        XCTAssertEqual(staple.kind, .staple)
        XCTAssertTrue(staple.isStaple)
    }

    /// Nothing may look at 饺子 / 腌 / 卤 in a name and decide the row is
    /// prepared — the classification is stored, or it is `.ordinary`.
    func testLegacyItemWithAPreparedSoundingNameIsNotReclassified() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","name":"腌好的冷冻鱼柳","quantity":3,"unit":"块","isStaple":false,"autoSuggestRestock":false,"stapleTrackingMode":"quantity","stapleAvailabilityStatus":"available"}
        """

        let decoded = try JSONDecoder().decode(InventoryItem.self, from: Data(legacy.utf8))

        XCTAssertEqual(decoded.kind, .ordinary, "不得根据名称把旧库存批量判定成预制")
    }

    func testEncodingStillEmitsIsStapleForOlderReaders() throws {
        let staple = InventoryItem(name: "盐", quantity: 1, unit: "袋", expiryDate: nil, kind: .staple)

        let json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(staple)
        ) as? [String: Any]

        XCTAssertEqual(json?["isStaple"] as? Bool, true)
        XCTAssertEqual(json?["kind"] as? String, "staple")
    }

    /// A store created before `kindRawValue` existed migrates it in as nil.
    /// Such a row must resolve from `isStaple`, never to `.readyToCook`.
    func testRecordWrittenWithoutAKindResolvesFromIsStaple() {
        let stapleRecord = InventoryRecord(
            item: InventoryItem(name: "大米", quantity: 1, unit: "袋", expiryDate: nil, isStaple: true)
        )
        let ordinaryRecord = InventoryRecord(
            item: InventoryItem(name: "番茄", quantity: 1, unit: "个", expiryDate: nil)
        )
        stapleRecord.kindRawValue = nil
        ordinaryRecord.kindRawValue = nil

        XCTAssertEqual(stapleRecord.inventoryItem.kind, .staple)
        XCTAssertEqual(ordinaryRecord.inventoryItem.kind, .ordinary)
    }

    func testKindRoundTripsThroughPersistence() throws {
        let persistence = try SwiftDataInventoryPersistence(isStoredInMemoryOnly: true)
        let items = InventoryItemKind.allCases.map {
            InventoryItem(name: $0.rawValue, quantity: 1, unit: "份", expiryDate: nil, kind: $0)
        }
        try persistence.replaceInventory(with: items)

        let loaded = try persistence.loadInventory().sorted { $0.name < $1.name }
        XCTAssertEqual(loaded.map(\.kind), items.sorted { $0.name < $1.name }.map(\.kind))
    }

    // MARK: - Helpers

    private func seedOneOfEachKind() {
        store.inventory = [
            InventoryItem(name: "番茄", quantity: 2, unit: "个", expiryDate: nil, kind: .ordinary),
            InventoryItem(name: "生抽", quantity: 1, unit: "瓶", expiryDate: nil, kind: .staple),
            InventoryItem(name: "包好的饺子", quantity: 20, unit: "个", expiryDate: nil, kind: .readyToCook)
        ]
    }
}

/// Records exactly what the recipe-creation request was given, so the test can
/// assert on the payload rather than on prompt wording.
private final class InventoryCapturingRecommendationService: AIRecommendationProviding, @unchecked Sendable {
    private(set) var capturedInventory: [String] = []
    private(set) var capturedExpiring: [String] = []

    func generateRecommendations(
        query: String,
        inventory: [String],
        expiringIngredients: [String],
        preferences: [String],
        excludedRecipeNames: [String],
        count: Int
    ) async throws -> [RecipeRecommendation] {
        capturedInventory = inventory
        capturedExpiring = expiringIngredients
        return []
    }
}

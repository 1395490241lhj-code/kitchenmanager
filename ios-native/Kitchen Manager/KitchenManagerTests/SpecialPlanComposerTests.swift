import XCTest
import SwiftData
@testable import KitchenManager

/// The AI composer: one natural-language request → one AI round trip →
/// derived plan fields + menu draft, with the home-inventory switch gating
/// both what the model sees and what shopping subtracts.
@MainActor
final class SpecialPlanComposerTests: XCTestCase {
    private var storeURL: URL!
    private var defaultsSuiteName: String!

    override func setUpWithError() throws {
        storeURL = FileManager.default.temporaryDirectory
            .appending(path: "specialplan-composer-\(UUID().uuidString).store")
        defaultsSuiteName = "specialplan-composer-\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
        }
        UserDefaults().removePersistentDomain(forName: defaultsSuiteName)
        storeURL = nil
        defaultsSuiteName = nil
    }

    // MARK: - Fixtures

    private final class FakeMenuResponder: SpecialPlanMenuRequesting, @unchecked Sendable {
        private(set) var requests: [AIWeeklyMenuRequest] = []
        var responses: [AIWeeklyMenuResponse]
        struct TransportFailure: Error {}

        init(responses: [AIWeeklyMenuResponse]) { self.responses = responses }

        func generatePlan(request: AIWeeklyMenuRequest) async throws -> AIWeeklyMenuResponse {
            requests.append(request)
            guard !responses.isEmpty else { throw TransportFailure() }
            return responses.removeFirst()
        }
    }

    private let sampleRequest = "这周六去朋友家做饭，7 个人，1 个人不吃辣，想做 6 道左右中式家常菜，不要太复杂，最好有鱼和牛肉。"

    private func aiDish(_ name: String, ingredients: [String] = ["牛腩 500 克"]) -> [String: Any] {
        [
            "name": name, "ingredients": ingredients, "steps": ["炖煮"],
            "source": "ai", "reason": "适合聚餐",
            "baseServings": SpecialPlanMenuBounds.aiRecipeBaseServings
        ]
    }

    private func response(_ dishes: [[String: Any]], event: [String: Any]? = nil) throws -> AIWeeklyMenuResponse {
        var payload: [String: Any] = [
            "days": [["dayIndex": 0, "meals": [["mealIndex": 0, "title": "晚餐", "recipes": dishes]]]],
            "shoppingItems": [], "warnings": []
        ]
        if let event { payload["event"] = event }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(AIWeeklyMenuResponse.self, from: data)
    }

    private func sixDishes() -> [[String: Any]] {
        ["红烧牛腩", "清蒸鲈鱼", "蒜蓉虾", "白灼菜心", "番茄蛋汤", "凉拌黄瓜"].map { aiDish($0) }
    }

    private let sampleEvent: [String: Any] = [
        "title": "周六朋友聚餐",
        "scheduledAt": "2026-09-05 18:30",
        "peopleCount": 7,
        "constraintNotes": ["1 人不吃辣"],
        "notes": "想吃鱼和牛肉，不要太复杂"
    ]

    private func makeKitchenStore() throws -> KitchenStore {
        KitchenStore(
            userDefaults: UserDefaults(suiteName: defaultsSuiteName)!,
            persistence: try KitchenPersistenceFactory.bundle(
                container: KitchenPersistenceFactory.makeContainer(
                    configuration: ModelConfiguration(url: storeURL)
                )
            )
        )
    }

    private func makeRecipeStore() -> RecipeStore {
        RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    private func generator(_ responder: FakeMenuResponder) -> SpecialPlanMenuGenerator {
        var generator = SpecialPlanMenuGenerator(service: responder)
        generator.calendar = Calendar(identifier: .gregorian)
        generator.now = { Date(timeIntervalSince1970: 1_788_000_000) }
        return generator
    }

    private func input(_ text: String? = nil, usesHomeInventory: Bool = false) -> SpecialPlanMenuGenerator.Input {
        SpecialPlanMenuGenerator.Input(requestText: text ?? sampleRequest, usesHomeInventory: usesHomeInventory)
    }

    // MARK: - Deterministic reading of the request

    func testReadingExtractsStatedDishCountAndHeadcount() {
        let reading = SpecialPlanRequestReading(requestText: "周六7个人1人不吃辣中式6道")
        XCTAssertEqual(reading.peopleCount, 7, "the constraint's 1 人 is not the table")
        XCTAssertEqual(reading.requestedDishCount, 6)
        XCTAssertEqual(reading.dishesToRequest, 6)
    }

    func testReadingHandlesRangesChineseNumeralsAndAbsence() {
        XCTAssertEqual(SpecialPlanRequestReading(requestText: "想做 5–6 道中式家常菜").requestedDishCount, 6)
        XCTAssertEqual(SpecialPlanRequestReading(requestText: "做六道菜").requestedDishCount, 6)
        XCTAssertEqual(SpecialPlanRequestReading(requestText: "做 4 个菜就够").requestedDishCount, 4)
        XCTAssertEqual(SpecialPlanRequestReading(requestText: "我们家三口人").peopleCount, 3)
        XCTAssertEqual(SpecialPlanRequestReading(requestText: "十二个人一起").peopleCount, 12)

        let bare = SpecialPlanRequestReading(requestText: "随便做点好吃的")
        XCTAssertNil(bare.requestedDishCount)
        XCTAssertNil(bare.peopleCount)
        XCTAssertNil(bare.dishesToRequest, "nothing stated: the model chooses")

        let constraintOnly = SpecialPlanRequestReading(requestText: "1 人不吃辣")
        XCTAssertNil(constraintOnly.peopleCount, "a constraint headcount never becomes the table")

        XCTAssertNil(SpecialPlanRequestReading(requestText: "第 2 道菜换成鱼").requestedDishCount, "an ordinal is not a count")
        XCTAssertNil(SpecialPlanRequestReading(requestText: "100 人的宴席").peopleCount, "no digit-boundary false match")
    }

    func testHeadcountAloneSizesTheMenuThroughTheExistingSuggestion() {
        XCTAssertEqual(
            SpecialPlanRequestReading(requestText: "这周六 7 个人吃饭").dishesToRequest,
            SpecialPlanMenuBounds.suggestedDishCount(peopleCount: 7)
        )
    }

    func testHardNonSpicyConstraintIsReadFromTheRawRequest() {
        XCTAssertTrue(SpecialPlanConstraintPolicy(requestText: sampleRequest, constraintNotes: []).requiresNonSpicyFood)
        XCTAssertFalse(SpecialPlanConstraintPolicy(requestText: "7 个人吃火锅", constraintNotes: []).requiresNonSpicyFood)
    }

    // MARK: - One round trip

    func testComposeIsOneAICallThatReturnsBothReadingAndMenu() async throws {
        let responder = FakeMenuResponder(responses: [try response(sixDishes(), event: sampleEvent)])
        let composition = try await generator(responder).composeMenu(input(), inventory: [], existingRecipes: [])

        XCTAssertEqual(responder.requests.count, 1, "interpretation and menu come from one round trip")
        XCTAssertEqual(composition.dishes.count, 6)
        let reading = composition.interpretation
        XCTAssertEqual(reading.title, "周六朋友聚餐")
        XCTAssertEqual(reading.peopleCount, 7)
        XCTAssertEqual(reading.constraintNotes, ["1 人不吃辣"])
        XCTAssertEqual(reading.notes, "想吃鱼和牛肉，不要太复杂")
        let expected = DateComponents(
            calendar: Calendar(identifier: .gregorian), timeZone: .current,
            year: 2026, month: 9, day: 5, hour: 18, minute: 30
        ).date
        XCTAssertEqual(reading.scheduledAt, expected)
    }

    func testRequestCarriesTheUsersWordsVerbatimAndTheDateAnchor() async throws {
        let responder = FakeMenuResponder(responses: [try response(sixDishes(), event: sampleEvent)])
        _ = try await generator(responder).composeMenu(input(), inventory: [], existingRecipes: [])

        let request = try XCTUnwrap(responder.requests.first)
        XCTAssertEqual(request.eventRequest?.request, sampleRequest)
        XCTAssertEqual(request.eventRequest?.today.count, "2026-09-05 星期六".count)
        XCTAssertEqual(request.dishesPerMeal, 6, "the stated 6 道 is the exact count asked for")
        XCTAssertEqual(request.servings, 1)
        XCTAssertNil(request.eventRequest?.fallbackDate)
    }

    func testStructuredMenuSchemaCarriesNoServingsTarget() throws {
        let request = SpecialPlanMenuGenerator.makeRequest(
            input(), dishCount: 6, inventory: [], existingRecipes: [], excludedRecipeNames: []
        )
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        XCTAssertFalse(json.contains("targetServings"))
        XCTAssertFalse(json.contains("suggestedPlannedServings"))
        XCTAssertFalse(json.contains("plannedServings"))
        // The prompt block the weekly service adds for events asks for the
        // reading, never for portions.
        let instructions = WeeklyMenuPlannerService.eventInstructions(for: request)
        XCTAssertTrue(instructions.contains("peopleCount"))
        XCTAssertFalse(instructions.contains("份量"))
    }

    // MARK: - Prompt bytes

    /// Asserted on the real prompt, not on a fragment: the count the prompt
    /// states, the shape it shows and the count the client validates all have
    /// to agree in the bytes that actually reach the model.
    private func prompt(for text: String) throws -> String {
        let reading = SpecialPlanRequestReading(requestText: text)
        return try WeeklyMenuPlannerService.prompt(for: SpecialPlanMenuGenerator.makeRequest(
            input(text), dishCount: reading.dishesToRequest,
            inventory: [], existingRecipes: [], excludedRecipeNames: []
        ))
    }

    func testPromptStatesOneDishCountAndShowsTheRequiredBaseYield() throws {
        let text = "这周六 7 个人一起吃饭，1 人不吃辣"
        let prompt = try prompt(for: text)
        XCTAssertTrue(prompt.contains("\"dishesPerMeal\":6"), "the fixed target travels in the condition JSON")
        XCTAssertTrue(prompt.contains("必须恰好生成 6 道菜"))
        XCTAssertTrue(prompt.contains("\"baseServings\": 4"), "the response shape declares the required yield")
        XCTAssertFalse(prompt.contains("菜系、菜数"))
        XCTAssertFalse(prompt.contains("请按场合安排菜品数量"))
        XCTAssertFalse(prompt.contains("3 到 8 道"))
        XCTAssertEqual(
            SpecialPlanMenuBounds.minimumDishes(requested: SpecialPlanRequestReading(requestText: text).dishesToRequest),
            5
        )
    }

    func testWeeklyPromptShowsNeitherEventFieldNorBaseYield() throws {
        let weekly = AIWeeklyMenuRequest(
            numberOfDays: 7, mealsPerDay: 1, dishesPerMeal: 2, servings: 2,
            cuisines: [], flavors: [], maxCookingTime: nil,
            prioritizeExpiringIngredients: true, avoidRepeatedMainIngredients: true,
            excludedIngredients: [], allowNewAIRecipes: true, additionalRequest: nil,
            inventory: [], existingRecipes: [], excludedRecipeNames: []
        )
        let prompt = try WeeklyMenuPlannerService.prompt(for: weekly)
        XCTAssertFalse(prompt.contains("baseServings"), "weekly never asks for the Special Plan yield")
        XCTAssertFalse(prompt.contains("\"event\""))
        XCTAssertFalse(prompt.contains("必须恰好生成"))
        // The weekly planner always fixes a count, so its cardinality sentence
        // stays byte-for-byte what it was before the zero-dish clause fix.
        XCTAssertTrue(prompt.contains("- 每天恰好生成 mealsPerDay 顿，每顿恰好 dishesPerMeal 道菜，mealIndex 从 0 开始。"))
        // The weekly response shape keeps its single merged recipe example: it
        // has no strict schema and no base-yield contract to describe.
        XCTAssertTrue(prompt.contains("\"existingRecipeID\": \"已有菜谱的 id 或 null\""))
        XCTAssertFalse(prompt.contains("\"source\": \"ai\""))
    }

    // MARK: - Dish-count contract: prompt target == validated target

    /// The number the prompt asks for and the number the cardinality check
    /// enforces come from one reading of the request, and the prompt no longer
    /// grants the raw request authority over the count on top of it. A model
    /// obeying the prompt therefore cannot answer with a count the client
    /// deterministically rejects.
    private func dishCountContract(for text: String) -> (target: Int?, prompt: String, minimum: Int) {
        let reading = SpecialPlanRequestReading(requestText: text)
        let request = SpecialPlanMenuGenerator.makeRequest(
            input(text), dishCount: reading.dishesToRequest,
            inventory: [], existingRecipes: [], excludedRecipeNames: []
        )
        return (
            reading.dishesToRequest,
            WeeklyMenuPlannerService.eventInstructions(for: request)
                + SpecialPlanMenuGenerator.eventBrief(
                    for: input(text),
                    policy: SpecialPlanConstraintPolicy(requestText: text, constraintNotes: [])
                ),
            SpecialPlanMenuBounds.minimumDishes(requested: reading.dishesToRequest)
        )
    }

    func testHeadcountOnlyRequestAsksThePromptForTheSameCountItValidates() {
        let contract = dishCountContract(for: "这周六 7 个人一起吃饭，1 人不吃辣")
        XCTAssertEqual(contract.target, 6, "7 people sizes the menu at 6")
        XCTAssertTrue(contract.prompt.contains("必须恰好生成 6 道菜"))
        XCTAssertEqual(contract.minimum, 5, "one short of the asked-for 6 stays tolerated")
    }

    func testExplicitDishCountOverridesTheHeadcountSuggestionOnBothSides() {
        let contract = dishCountContract(for: "这周六 7 个人一起吃饭，1 人不吃辣，做 4 道菜")
        XCTAssertEqual(contract.target, 4, "the stated count wins over suggestedDishCount(7)")
        XCTAssertTrue(contract.prompt.contains("必须恰好生成 4 道菜"))
        XCTAssertEqual(contract.minimum, 3)

        let six = dishCountContract(for: "这周六 7 个人一起吃饭，1 人不吃辣，做 6 道中式家常菜")
        XCTAssertEqual(six.target, 6)
        XCTAssertTrue(six.prompt.contains("必须恰好生成 6 道菜"))
        XCTAssertEqual(six.minimum, 5)
    }

    /// The regression this contract exists for: the prompt used to name 菜数
    /// among the fields the raw request decided, while the client rejected any
    /// count below `minimumDishes`. A model could obey the prompt and still be
    /// rejected.
    func testPromptNeverLetsTheRawRequestOverrideAFixedDishCount() {
        let contract = dishCountContract(for: "这周六 7 个人一起吃饭，1 人不吃辣")
        XCTAssertFalse(
            contract.prompt.contains("菜系、菜数"),
            "the raw request is no longer authoritative for the count"
        )
        XCTAssertFalse(
            contract.prompt.contains("请按场合安排菜品数量"),
            "the brief no longer invites the model to choose its own count"
        )
        XCTAssertFalse(
            contract.prompt.contains("3 到 8 道"),
            "the model-chooses rule must not fire when the app fixed a count"
        )
    }

    func testModelChoosesTheCountOnlyWhenNothingSizesTheMenu() {
        let contract = dishCountContract(for: "随便做点好吃的")
        XCTAssertNil(contract.target)
        XCTAssertTrue(contract.prompt.contains("3 到 8 道"), "nothing stated: the model still chooses")
        XCTAssertFalse(contract.prompt.contains("必须恰好生成"))
        XCTAssertEqual(contract.minimum, 2, "only the absolute floor applies")
    }

    func testReplacementAsksForExactlyOneDishRegardlessOfTheStatedMenuSize() throws {
        // The plan's own request says 6 道; a replacement must still be one dish.
        let request = SpecialPlanMenuGenerator.makeRequest(
            input(), dishCount: 1, inventory: [], existingRecipes: [], excludedRecipeNames: []
        )
        let instructions = WeeklyMenuPlannerService.eventInstructions(for: request)
        XCTAssertTrue(instructions.contains("必须恰好生成 1 道菜"))
        XCTAssertFalse(instructions.contains("菜系、菜数"))
    }

    /// The two dish shapes are disjoint, and the response schema accepts only
    /// those two. A merged example — `existingRecipeID` beside a recipe body,
    /// labelled `source: "existing"` — describes a dish neither branch allows
    /// and steers the model toward the branch that cannot carry a recipe.
    func testEventResponseShapeShowsTheTwoDishShapesSeparately() throws {
        let prompt = try prompt(for: sampleRequest)
        XCTAssertTrue(prompt.contains("\"source\": \"ai\""))
        XCTAssertTrue(prompt.contains("\"source\": \"existing\""))
        XCTAssertTrue(prompt.contains("\"existingRecipeID\": \"existingRecipes 中真实存在的 id\""))
        XCTAssertFalse(
            prompt.contains("\"existingRecipeID\": \"已有菜谱的 id 或 null\""),
            "the merged weekly example must not be shown for an event request"
        )
        // The reused shape carries no recipe body and no yield claim.
        let existing = try XCTUnwrap(prompt.range(of: "\"source\": \"existing\""))
        let tail = prompt[existing.upperBound...]
        let block = tail[..<(tail.range(of: "}")?.lowerBound ?? tail.endIndex)]
        XCTAssertFalse(block.contains("baseServings"))
        XCTAssertFalse(block.contains("ingredients"))
    }

    /// Asserted on the generated prompt, not on the constant that feeds it:
    /// removing the interpolation at the response-shape line must fail this.
    func testEventResponseShapeDeclaresTheContractedBaseYield() throws {
        let prompt = try prompt(for: sampleRequest)
        XCTAssertTrue(
            prompt.contains("\"baseServings\": \(SpecialPlanMenuBounds.aiRecipeBaseServings)"),
            "the field the client hard-rejects on is declared in the model-facing response shape"
        )
        // Inside the recipe object of the response shape, not loose in the prose.
        let shape = try XCTUnwrap(prompt.range(of: "严格 JSON 格式：")).upperBound
        XCTAssertTrue(
            prompt[shape...].contains("\"baseServings\": \(SpecialPlanMenuBounds.aiRecipeBaseServings)"),
            "declared in the JSON shape block the model copies, not only in the condition prose"
        )
    }

    // MARK: - The schema-shaped response is the one the client can use

    /// The end-to-end version of the prompt/schema agreement: a response built
    /// to satisfy the strict schema exactly must decode and map. If the schema
    /// demanded a shape the client cannot read, structured output would turn
    /// every generation into an empty menu — the failure the merged response
    /// example would have caused.
    func testAResponseShapedExactlyLikeTheStrictSchemaDecodesAndMaps() throws {
        let json = """
        {"event":{"title":"周六聚餐","scheduledAt":"2026-09-05 18:00","peopleCount":7,        "constraintNotes":["1 人不吃辣"],"notes":""},        "days":[{"dayIndex":0,"meals":[{"mealIndex":0,"title":"晚餐","recipes":[        {"source":"ai","name":"清蒸鲈鱼","ingredients":["鲈鱼 600 g"],"steps":["蒸 8 分钟"],        "tags":["家常"],"cookingTime":20,"difficulty":"简单","reason":"清淡","baseServings":4},        {"source":"existing","existingRecipeID":"r-1","name":"番茄炒蛋","reason":"家常"}]}]}],        "shoppingItems":[{"name":"鲈鱼","quantity":1,"unit":"条","reason":"缺"}],"warnings":[]}
        """
        let existing = Recipe(
            id: "r-1", title: "番茄炒蛋", cookingTime: nil, difficulty: nil, tags: [],
            ingredients: ["鸡蛋 3 个"], seasonings: [], steps: ["炒"]
        )
        let decoded = try JSONDecoder().decode(
            AIWeeklyMenuResponse.self, from: Data(json.utf8)
        )
        let dishes = SpecialPlanMenuGenerator.dishes(from: decoded, existingRecipes: [existing])

        XCTAssertEqual(dishes.count, 2, "both schema variants must survive mapping")

        let written = try XCTUnwrap(dishes.first { !$0.isExistingRecipe })
        XCTAssertEqual(written.title, "清蒸鲈鱼")
        XCTAssertEqual(written.baseServings, SpecialPlanMenuBounds.aiRecipeBaseServings)
        XCTAssertFalse(written.ingredients.isEmpty)
        XCTAssertFalse(written.steps.isEmpty)

        let reused = try XCTUnwrap(dishes.first { $0.isExistingRecipe })
        XCTAssertEqual(reused.existingRecipeID, "r-1")
        XCTAssertNil(reused.baseServings, "a reused recipe keeps its own yield, never a stamped 4")

        // The whole draft passes the validator the schema is meant to satisfy.
        XCTAssertNoThrow(try SpecialPlanMenuGenerator.validateBaseYield(dishes))

        // The event reading survives too, including the date the prompt formats.
        let interpretation = SpecialPlanInterpretation(event: decoded.event)
        XCTAssertEqual(interpretation.peopleCount, 7)
        XCTAssertEqual(interpretation.constraintNotes, ["1 人不吃辣"])
        XCTAssertNotNil(interpretation.scheduledAt)
    }

    // MARK: - Schema cardinality handed to the server

    /// The count the server may pin in the response schema is the same fixed
    /// count the prompt states and the client validates — never a third number,
    /// and never present when the model is the one choosing.
    func testSchemaDishCountIsSentOnlyForAFixedSpecialPlanCount() {
        let fixed = SpecialPlanMenuGenerator.makeRequest(
            input("这周六 7 个人一起吃饭，1 人不吃辣"), dishCount: 6,
            inventory: [], existingRecipes: [], excludedRecipeNames: []
        )
        XCTAssertEqual(WeeklyMenuPlannerService.schemaDishCount(for: fixed), 6)
        XCTAssertEqual(WeeklyMenuPlannerService.schemaDishCount(for: fixed), fixed.dishesPerMeal)

        let modelChooses = SpecialPlanMenuGenerator.makeRequest(
            input("随便做点好吃的"), dishCount: nil,
            inventory: [], existingRecipes: [], excludedRecipeNames: []
        )
        XCTAssertEqual(modelChooses.dishesPerMeal, 0)
        XCTAssertNil(
            WeeklyMenuPlannerService.schemaDishCount(for: modelChooses),
            "no fixed count means no cardinality to enforce, never an exact-zero schema"
        )

        let replacement = SpecialPlanMenuGenerator.makeRequest(
            input(), dishCount: 1,
            inventory: [], existingRecipes: [], excludedRecipeNames: []
        )
        XCTAssertEqual(WeeklyMenuPlannerService.schemaDishCount(for: replacement), 1)
    }

    func testOrdinaryWeeklyRequestsNeverAskForTheSpecialPlanSchema() {
        let weekly = AIWeeklyMenuRequest(
            numberOfDays: 7, mealsPerDay: 1, dishesPerMeal: 2, servings: 2,
            cuisines: [], flavors: [], maxCookingTime: nil,
            prioritizeExpiringIngredients: true, avoidRepeatedMainIngredients: true,
            excludedIngredients: [], allowNewAIRecipes: true, additionalRequest: nil,
            inventory: [], existingRecipes: [], excludedRecipeNames: []
        )
        XCTAssertEqual(weekly.dishesPerMeal, 2)
        XCTAssertNil(
            WeeklyMenuPlannerService.schemaDishCount(for: weekly),
            "the weekly planner keeps its tolerant JSON-object format"
        )
    }

    // MARK: - shoppingItems is a weekly-only field

    /// `WeeklyMenuPlannerStore.makePlan` is the only consumer of
    /// `response.shoppingItems`, and Special Plan never reads it: shopping for
    /// a Special Plan is derived by `ShoppingListGenerator` from the accepted
    /// recipes' own ingredients. Asking the model for quantities nothing reads
    /// would put a second, untrusted source of shopping numbers in the answer.
    func testSpecialPlanPromptNeverAsksForShoppingItems() throws {
        let prompt = try prompt(for: sampleRequest)
        XCTAssertFalse(prompt.contains("shoppingItems"))
        XCTAssertFalse(prompt.contains("缺少的食材列在"))
    }

    func testWeeklyPromptStillAsksForShoppingItems() throws {
        let weekly = AIWeeklyMenuRequest(
            numberOfDays: 7, mealsPerDay: 1, dishesPerMeal: 2, servings: 2,
            cuisines: [], flavors: [], maxCookingTime: nil,
            prioritizeExpiringIngredients: true, avoidRepeatedMainIngredients: true,
            excludedIngredients: [], allowNewAIRecipes: true, additionalRequest: nil,
            inventory: [], existingRecipes: [], excludedRecipeNames: []
        )
        let prompt = try WeeklyMenuPlannerService.prompt(for: weekly)
        XCTAssertTrue(prompt.contains("\n- 缺少的食材列在 shoppingItems 中，数量按 servings 估算，未知时可以省略数量或填“适量”。\n"))
        XCTAssertTrue(prompt.contains("\"shoppingItems\": ["))
        XCTAssertTrue(prompt.contains("{\"name\": \"鸡胸肉\", \"quantity\": 2, \"unit\": \"块\", \"reason\": \"还缺 1 块\"}"))
    }

    /// The weekly response shape, byte-for-byte as `3c786b0` emitted it.
    ///
    /// Splitting the shape into interpolated pieces is exactly the kind of
    /// change that silently reindents a prompt: an interpolation result lands
    /// in the finished string, where the outer literal's indentation has
    /// already been stripped, so a nested literal that looks aligned in the
    /// source is not. This pins the bytes rather than the intent.
    func testWeeklyResponseShapeKeepsItsExactIndentation() throws {
        let weekly = AIWeeklyMenuRequest(
            numberOfDays: 7, mealsPerDay: 1, dishesPerMeal: 2, servings: 2,
            cuisines: [], flavors: [], maxCookingTime: nil,
            prioritizeExpiringIngredients: true, avoidRepeatedMainIngredients: true,
            excludedIngredients: [], allowNewAIRecipes: true, additionalRequest: nil,
            inventory: [], existingRecipes: [], excludedRecipeNames: []
        )
        let prompt = try WeeklyMenuPlannerService.prompt(for: weekly)
        // Written as explicit lines: a nested multi-line literal strips its own
        // indentation, which is precisely the trap being guarded against.
        let recipeShape = [
            #"          "recipes": ["#,
            #"            {"#,
            #"              "existingRecipeID": "已有菜谱的 id 或 null","#,
            #"              "name": "菜名","#,
            #"              "ingredients": ["食材 1"],"#,
            #"              "steps": ["步骤 1"],"#,
            #"              "tags": ["标签"],"#,
            #"              "cookingTime": 30,"#,
            #"              "difficulty": "简单","#,
            #"              "reason": "推荐原因","#,
            #"              "source": "existing""#,
            #"            }"#,
            #"          ]"#
        ].joined(separator: "\n")
        XCTAssertTrue(prompt.contains(recipeShape), "weekly recipe shape reindented")

        let shoppingShape = [
            #"  "shoppingItems": ["#,
            #"    {"name": "鸡胸肉", "quantity": 2, "unit": "块", "reason": "还缺 1 块"}"#,
            #"  ],"#
        ].joined(separator: "\n")
        XCTAssertTrue(prompt.contains(shoppingShape), "weekly shopping shape reindented")
    }

    /// A Special Plan response that omits shoppingItems entirely still decodes:
    /// the field is optional in the shared DTO, so dropping it from the
    /// contract cannot break mapping.
    func testSpecialPlanResponseWithoutShoppingItemsStillDecodes() throws {
        let json = """
        {"event":{"title":"周六聚餐","scheduledAt":"2026-09-05 18:00","peopleCount":7,        "constraintNotes":[],"notes":""},        "days":[{"dayIndex":0,"meals":[{"mealIndex":0,"title":"晚餐","recipes":[        {"source":"ai","name":"清蒸鲈鱼","ingredients":["鲈鱼 600 g"],"steps":["蒸 8 分钟"],        "tags":[],"cookingTime":20,"difficulty":"简单","reason":"清淡","baseServings":4}]}]}],        "warnings":[]}
        """
        let decoded = try JSONDecoder().decode(AIWeeklyMenuResponse.self, from: Data(json.utf8))
        XCTAssertNil(decoded.shoppingItems)
        let dishes = SpecialPlanMenuGenerator.dishes(from: decoded, existingRecipes: [])
        XCTAssertEqual(dishes.count, 1)
        XCTAssertNoThrow(try SpecialPlanMenuGenerator.validateBaseYield(dishes))
    }

    // MARK: - Dish-count cardinality wording

    func testFixedCountPromptDemandsExactlyThatCountAndNothingElse() throws {
        let prompt = try prompt(for: "这周六 7 个人一起吃饭，1 人不吃辣")
        XCTAssertTrue(prompt.contains("每顿恰好 dishesPerMeal 道菜，"))
        XCTAssertTrue(prompt.contains("\"dishesPerMeal\":6"))
        XCTAssertTrue(prompt.contains("必须恰好生成 6 道菜"))
        XCTAssertFalse(prompt.contains("3 到 8 道"), "the model must not also be told to choose")
    }

    /// `dishesPerMeal == 0` means "you choose", never "produce zero dishes".
    /// The exact-count clause used to be stated unconditionally, so this prompt
    /// demanded 恰好 0 道菜 while also asking for 3 to 8.
    func testModelChoosesPromptNeverDemandsZeroDishes() throws {
        let prompt = try prompt(for: "随便做点好吃的")
        XCTAssertTrue(prompt.contains("\"dishesPerMeal\":0"))
        XCTAssertFalse(prompt.contains("恰好 0"))
        XCTAssertFalse(prompt.contains("每顿恰好 dishesPerMeal 道菜"))
        XCTAssertFalse(prompt.contains("必须恰好生成"))
        XCTAssertTrue(prompt.contains("3 到 8 道"), "the intended model-choice policy is retained")
        XCTAssertTrue(prompt.contains("每天恰好生成 mealsPerDay 顿，mealIndex 从 0 开始。"))
    }

    func testWeeklyPlannerRequestsAreUntouched() throws {
        let weekly = AIWeeklyMenuRequest(
            numberOfDays: 7, mealsPerDay: 1, dishesPerMeal: 2, servings: 2,
            cuisines: [], flavors: [], maxCookingTime: nil,
            prioritizeExpiringIngredients: true, avoidRepeatedMainIngredients: true,
            excludedIngredients: [], allowNewAIRecipes: true, additionalRequest: nil,
            inventory: [], existingRecipes: [], excludedRecipeNames: []
        )
        let json = String(decoding: try JSONEncoder().encode(weekly), as: UTF8.self)
        XCTAssertFalse(json.contains("eventRequest"), "a nil event request is omitted from the weekly JSON")
        XCTAssertEqual(WeeklyMenuPlannerService.eventInstructions(for: weekly), "")
    }

    // MARK: - Derived plan fields

    func testMakePlanPersistsTheRawRequestAndTheInventorySwitch() async throws {
        let responder = FakeMenuResponder(responses: [try response(sixDishes(), event: sampleEvent)])
        let composition = try await generator(responder).composeMenu(input(), inventory: [], existingRecipes: [])
        let plan = composition.interpretation.makePlan(
            requestText: sampleRequest, usesHomeInventory: false, contextDate: nil
        )

        XCTAssertEqual(plan.requestText, sampleRequest)
        XCTAssertFalse(plan.usesHomeInventory)
        XCTAssertEqual(plan.title, "周六朋友聚餐")
        XCTAssertEqual(plan.peopleCount, 7)
        XCTAssertEqual(plan.constraintNotes, ["1 人不吃辣"])
        XCTAssertEqual(plan.scheduledAt, composition.interpretation.scheduledAt)
        XCTAssertTrue(plan.dishes.isEmpty, "the menu stays a draft until saved")
    }

    func testMissingReadingFallsBackWithoutAForm() {
        let calendar = Calendar(identifier: .gregorian)
        let now = DateComponents(calendar: calendar, timeZone: .current, year: 2026, month: 9, day: 2, hour: 10).date!
        let empty = SpecialPlanInterpretation.empty

        // Title: the opening words of the request. Headcount: the number the
        // request states. Date: tonight, because it is still morning.
        let plan = empty.makePlan(
            requestText: "周六 7 个人吃饭，1 人不吃辣", usesHomeInventory: false,
            contextDate: nil, now: now, calendar: calendar
        )
        XCTAssertEqual(plan.title, "周六 7 个人吃饭")
        XCTAssertEqual(plan.peopleCount, 7)
        XCTAssertEqual(calendar.component(.hour, from: plan.scheduledAt), 18)
        XCTAssertTrue(calendar.isDate(plan.scheduledAt, inSameDayAs: now))

        // Opened from a Planner day: that day at 18:00 wins over tonight.
        let saturday = calendar.date(byAdding: .day, value: 3, to: now)!
        let contextual = empty.makePlan(
            requestText: "随便", usesHomeInventory: false,
            contextDate: saturday, now: now, calendar: calendar
        )
        XCTAssertTrue(calendar.isDate(contextual.scheduledAt, inSameDayAs: saturday))
        XCTAssertEqual(calendar.component(.hour, from: contextual.scheduledAt), 18)
        XCTAssertEqual(contextual.peopleCount, 2, "nothing stated anywhere: the smallest table")

        // Evening already: tomorrow night.
        let evening = calendar.date(bySettingHour: 21, minute: 0, second: 0, of: now)!
        let late = empty.makePlan(
            requestText: "", usesHomeInventory: false, contextDate: nil, now: evening, calendar: calendar
        )
        XCTAssertEqual(late.title, "特殊安排")
        XCTAssertTrue(calendar.isDate(late.scheduledAt, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: now)!))
    }

    func testDateParsingAcceptsTheShapesAModelProduces() {
        let calendar = Calendar(identifier: .gregorian)
        let full = SpecialPlanInterpretation.date(from: "2026-09-05 18:30", calendar: calendar)
        XCTAssertEqual(full.map { calendar.component(.minute, from: $0) }, 30)
        let dayOnly = SpecialPlanInterpretation.date(from: "2026-09-05", calendar: calendar)
        XCTAssertEqual(dayOnly.map { calendar.component(.hour, from: $0) }, 18)
        XCTAssertNotNil(SpecialPlanInterpretation.date(from: "2026-09-05T18:30", calendar: calendar))
        XCTAssertNil(SpecialPlanInterpretation.date(from: "null", calendar: calendar))
        XCTAssertNil(SpecialPlanInterpretation.date(from: "", calendar: calendar))
    }

    func testEditAppliesTheNewReadingOntoTheExistingPlan() async throws {
        var existing = SpecialPlanInterpretation.empty.makePlan(
            requestText: "周六 4 个人", usesHomeInventory: true, contextDate: nil
        )
        existing.dishes = [SpecialPlanDish(recipeID: "r1", recipeName: "麻婆豆腐")]
        let responder = FakeMenuResponder(responses: [try response(sixDishes(), event: sampleEvent)])
        let composition = try await generator(responder).composeMenu(input(), inventory: [], existingRecipes: [])
        let updated = composition.interpretation.apply(
            to: existing, requestText: sampleRequest, usesHomeInventory: false
        )

        XCTAssertEqual(updated.id, existing.id)
        XCTAssertEqual(updated.dishes, existing.dishes, "editing the description does not touch the saved menu")
        XCTAssertEqual(updated.requestText, sampleRequest)
        XCTAssertFalse(updated.usesHomeInventory)
        XCTAssertEqual(updated.title, "周六朋友聚餐")
        XCTAssertEqual(updated.peopleCount, 7)
    }

    func testEditWithoutANewDateKeepsTheExactPreviousTime() async throws {
        let calendar = Calendar(identifier: .gregorian)
        let lunch = DateComponents(calendar: calendar, timeZone: .current, year: 2026, month: 9, day: 5, hour: 12, minute: 15).date!
        var existing = SpecialPlanInterpretation.empty.makePlan(requestText: "周六 4 个人", usesHomeInventory: true, contextDate: nil)
        existing.scheduledAt = lunch
        let noDateEvent: [String: Any] = ["title": "周六火锅", "peopleCount": 4, "constraintNotes": []]
        let responder = FakeMenuResponder(responses: [try response(sixDishes(), event: noDateEvent)])
        let composition = try await generator(responder).composeMenu(input("周六 4 个人吃火锅"), inventory: [], existingRecipes: [])
        let updated = composition.interpretation.apply(to: existing, requestText: "周六 4 个人吃火锅", usesHomeInventory: true)
        XCTAssertEqual(updated.scheduledAt, lunch, "a re-description that names no date must not move the meal to 18:00")
        XCTAssertEqual(updated.title, "周六火锅")
    }

    // MARK: - Hard constraints

    func testNonSpicyIsEnforcedFromTheRawRequestEvenIfTheReadingDroppedIt() async throws {
        var dishes = sixDishes()
        dishes[0] = aiDish("麻辣牛腩", ingredients: ["牛腩 500 克", "辣椒 3 个"])
        let noConstraintEvent: [String: Any] = ["title": "聚餐", "peopleCount": 7, "constraintNotes": []]
        let responder = FakeMenuResponder(responses: [try response(dishes, event: noConstraintEvent)])
        do {
            _ = try await generator(responder).composeMenu(input(), inventory: [], existingRecipes: [])
            XCTFail("a spicy dish must reject the whole composition")
        } catch {
            XCTAssertEqual(error as? SpecialPlanMenuGeneratorError, .hardConstraintViolation)
        }
    }

    // MARK: - Cardinality stays one authoritative check

    func testStatedSixDishesReturnedThreeIsRejected() async throws {
        let responder = FakeMenuResponder(responses: [try response(Array(sixDishes().prefix(3)), event: sampleEvent)])
        do {
            _ = try await generator(responder).composeMenu(input(), inventory: [], existingRecipes: [])
            XCTFail("three dishes are not the six that were asked for")
        } catch {
            XCTAssertEqual(error as? SpecialPlanMenuGeneratorError, .tooFewDishes)
        }
    }

    func testStatedSixDishesReturnedFiveIsAccepted() async throws {
        let responder = FakeMenuResponder(responses: [try response(Array(sixDishes().prefix(5)), event: sampleEvent)])
        let composition = try await generator(responder).composeMenu(input(), inventory: [], existingRecipes: [])
        XCTAssertEqual(composition.dishes.count, 5)
    }

    func testUnstatedCountLetsTheModelChooseAboveTheAbsoluteFloor() async throws {
        let responder = FakeMenuResponder(responses: [try response(Array(sixDishes().prefix(2)), event: sampleEvent)])
        let composition = try await generator(responder).composeMenu(
            input("随便做点好吃的"), inventory: [], existingRecipes: []
        )
        XCTAssertEqual(responder.requests.first?.dishesPerMeal, 0, "0 asks the model to choose the count")
        XCTAssertEqual(composition.dishes.count, 2)

        let single = FakeMenuResponder(responses: [try response(Array(sixDishes().prefix(1)), event: sampleEvent)])
        do {
            _ = try await generator(single).composeMenu(input("随便做点好吃的"), inventory: [], existingRecipes: [])
            XCTFail("one dish is never a menu")
        } catch {
            XCTAssertEqual(error as? SpecialPlanMenuGeneratorError, .tooFewDishes)
        }
    }

    // MARK: - Inventory switch: AI side

    private func stockedKitchenStore() throws -> KitchenStore {
        let store = try makeKitchenStore()
        store.addInventory(name: "牛腩", quantity: 300, unit: "克", expiryDate: Date().addingTimeInterval(86_400 * 5))
        store.addInventory(name: "鸡蛋", quantity: 6, unit: "个", expiryDate: Date().addingTimeInterval(86_400 * 10))
        return store
    }

    func testInventoryOffSendsNoHomeInventoryToTheModel() async throws {
        let kitchenStore = try stockedKitchenStore()
        XCTAssertFalse(kitchenStore.recipeCreationInventory.isEmpty, "fixture must have inventory to withhold")
        let responder = FakeMenuResponder(responses: [try response(sixDishes(), event: sampleEvent)])
        let draft = SpecialPlanMenuDraftStore(generator: generator(responder))
        await draft.compose(input(usesHomeInventory: false), kitchenStore: kitchenStore, recipeStore: makeRecipeStore())

        let request = try XCTUnwrap(responder.requests.first)
        XCTAssertTrue(request.inventory.isEmpty, "off means the model never sees the refrigerator")
        XCTAssertFalse(request.prioritizeExpiringIngredients)
        XCTAssertTrue(request.additionalRequest?.contains("不参考家中库存") == true)
        XCTAssertFalse(request.additionalRequest?.contains("牛腩") == true)
    }

    func testInventoryOnSendsTheRelevantInventoryToTheModel() async throws {
        let kitchenStore = try stockedKitchenStore()
        let responder = FakeMenuResponder(responses: [try response(sixDishes(), event: sampleEvent)])
        let draft = SpecialPlanMenuDraftStore(generator: generator(responder))
        await draft.compose(input(usesHomeInventory: true), kitchenStore: kitchenStore, recipeStore: makeRecipeStore())

        let request = try XCTUnwrap(responder.requests.first)
        XCTAssertEqual(Set(request.inventory.map(\.name)), Set(kitchenStore.recipeCreationInventory.map(\.name)))
        XCTAssertTrue(request.prioritizeExpiringIngredients)
        XCTAssertTrue(request.additionalRequest?.contains("在家做饭") == true)
    }

    // MARK: - Replacement retains the original intent

    private func savedPlan(usesHomeInventory: Bool) -> SpecialPlan {
        SpecialPlan(
            title: "周六朋友聚餐",
            scheduledAt: Date(timeIntervalSince1970: 1_788_100_000),
            peopleCount: 7,
            constraintNotes: ["1 人不吃辣"],
            requestText: sampleRequest,
            usesHomeInventory: usesHomeInventory
        )
    }

    func testReplacementReusesTheRawRequestConstraintsAndInventorySwitch() async throws {
        for usesHomeInventory in [false, true] {
            let kitchenStore = try stockedKitchenStore()
            let plan = savedPlan(usesHomeInventory: usesHomeInventory)
            kitchenStore.addSpecialPlan(plan)
            let responder = FakeMenuResponder(responses: [
                try response(sixDishes(), event: sampleEvent),
                try response([aiDish("清炒时蔬", ingredients: ["时蔬 300 克"])], event: sampleEvent)
            ])
            let draft = SpecialPlanMenuDraftStore(generator: generator(responder))
            await draft.generate(for: plan, kitchenStore: kitchenStore, recipeStore: makeRecipeStore())
            await draft.replaceDish(id: draft.dishes[0].id, for: plan, kitchenStore: kitchenStore, recipeStore: makeRecipeStore())

            XCTAssertEqual(responder.requests.count, 2)
            let replacement = responder.requests[1]
            XCTAssertEqual(replacement.dishesPerMeal, 1)
            XCTAssertEqual(replacement.eventRequest?.request, sampleRequest, "the original words travel with every replacement")
            XCTAssertTrue(replacement.additionalRequest?.contains("所有共享菜都必须完全不辣") == true)
            XCTAssertEqual(replacement.inventory.isEmpty, !usesHomeInventory, "replacement obeys the switch: \(usesHomeInventory)")
            XCTAssertEqual(draft.dishes[0].title, "清炒时蔬")
            XCTAssertEqual(draft.dishes.count, 6)
        }
    }

    func testSpicyReplacementIsRejectedFromTheRawRequestAlone() async throws {
        let kitchenStore = try makeKitchenStore()
        var plan = savedPlan(usesHomeInventory: false)
        plan.constraintNotes = []   // the reading dropped it; the words still say 不吃辣
        kitchenStore.addSpecialPlan(plan)
        let responder = FakeMenuResponder(responses: [
            try response(sixDishes(), event: sampleEvent),
            try response([aiDish("辣子鸡", ingredients: ["鸡 500 克", "干辣椒 50 克"])], event: sampleEvent)
        ])
        let draft = SpecialPlanMenuDraftStore(generator: generator(responder))
        await draft.generate(for: plan, kitchenStore: kitchenStore, recipeStore: makeRecipeStore())
        let original = draft.dishes[0]
        await draft.replaceDish(id: original.id, for: plan, kitchenStore: kitchenStore, recipeStore: makeRecipeStore())
        XCTAssertEqual(draft.dishes[0], original)
        XCTAssertEqual(draft.errorMessage, SpecialPlanMenuGeneratorError.hardConstraintViolation.errorDescription)
    }

    func testLegacyPlanWithoutARequestRegeneratesFromItsFields() async throws {
        let kitchenStore = try makeKitchenStore()
        let legacy = SpecialPlan(
            title: "朋友聚餐", scheduledAt: Date(), peopleCount: 7,
            constraintNotes: ["1 人不吃辣"], notes: "在家吃", usesHomeInventory: true
        )
        kitchenStore.addSpecialPlan(legacy)
        let responder = FakeMenuResponder(responses: [try response(sixDishes(), event: sampleEvent)])
        let draft = SpecialPlanMenuDraftStore(generator: generator(responder))
        await draft.generate(for: legacy, kitchenStore: kitchenStore, recipeStore: makeRecipeStore())

        let request = try XCTUnwrap(responder.requests.first)
        XCTAssertEqual(request.dishesPerMeal, SpecialPlanMenuBounds.suggestedDishCount(peopleCount: 7))
        XCTAssertTrue(request.eventRequest?.request.contains("朋友聚餐") == true)
        XCTAssertTrue(request.eventRequest?.request.contains("7 人") == true)
        XCTAssertTrue(request.eventRequest?.request.contains("1 人不吃辣") == true)
        XCTAssertEqual(draft.dishes.count, 6)
    }

    // MARK: - Inventory switch: shopping side

    private func beefRecipe() -> Recipe {
        Recipe(
            id: "special-ai-beef", title: "红烧牛腩", cookingTime: nil, difficulty: nil, tags: [],
            ingredients: ["牛腩 500 克"], steps: ["炖"], baseServings: SpecialPlanMenuBounds.aiRecipeBaseServings
        )
    }

    private func beefRequirement(
        usesHomeInventory: Bool,
        kitchenStore: KitchenStore
    ) throws -> IngredientRequirement {
        let store = ShoppingListGenerationStore()
        store.generate(
            source: .selectedRecipes([beefRecipe()], servings: 1),
            kitchenStore: kitchenStore,
            recipeStore: makeRecipeStore(),
            reconcilesAgainstInventory: usesHomeInventory
        )
        return try XCTUnwrap((store.missingItems + store.coveredItems).first { $0.displayName.contains("牛腩") })
    }

    func testInventoryOffShoppingListsTheRecipeQuantityUntouched() throws {
        let kitchenStore = try stockedKitchenStore()   // 300 g beef at home
        let beef = try beefRequirement(usesHomeInventory: false, kitchenStore: kitchenStore)
        XCTAssertEqual(beef.requiredQuantity, 500)
        XCTAssertEqual(beef.missingQuantity, 500, "food at home is not food at the venue")
        XCTAssertNil(beef.availableQuantity)
        XCTAssertFalse(beef.isCoveredByInventory)
    }

    func testInventoryOnShoppingSubtractsUsableHomeStock() throws {
        let kitchenStore = try stockedKitchenStore()
        let beef = try beefRequirement(usesHomeInventory: true, kitchenStore: kitchenStore)
        XCTAssertEqual(beef.requiredQuantity, 500)
        XCTAssertEqual(beef.availableQuantity, 300)
        XCTAssertEqual(beef.missingQuantity, 200)
    }

    func testInventoryOnStillIgnoresExpiredStock() throws {
        let kitchenStore = try makeKitchenStore()
        kitchenStore.addInventory(name: "牛腩", quantity: 300, unit: "克", expiryDate: Date().addingTimeInterval(-86_400 * 2))
        let beef = try beefRequirement(usesHomeInventory: true, kitchenStore: kitchenStore)
        XCTAssertEqual(beef.missingQuantity, 500, "expiry semantics are the generator's, unchanged")
    }

    func testSpecialPlanShoppingUsesWrittenQuantitiesRegardlessOfHeadcount() throws {
        // 7 people, 4-serving recipe: neither number reaches the scaler.
        let kitchenStore = try makeKitchenStore()
        let beef = try beefRequirement(usesHomeInventory: false, kitchenStore: kitchenStore)
        XCTAssertEqual(beef.requiredQuantity, 500)
        XCTAssertNotEqual(beef.requiredQuantity, 875)
        XCTAssertNotEqual(beef.requiredQuantity, 125)
    }

    func testNormalMealScalingIsUnchanged() throws {
        let recipeStore = makeRecipeStore()
        let recipe = beefRecipe()
        try recipeStore.saveUserRecipe(recipe)
        let draft = ShoppingListGenerator().generate(
            source: .todayPlans([MealPlanItem(recipeID: recipe.id, recipeName: recipe.title, plannedServings: 6)]),
            inventory: [], existingShoppingItems: [], recipeStore: recipeStore
        )
        let beef = try XCTUnwrap(draft.missingItems.first { $0.displayName.contains("牛腩") })
        XCTAssertEqual(beef.requiredQuantity, 750, "a Normal Meal with a stated target still scales 4 → 6")
    }

    // MARK: - The draft never carries a serving target

    func testDraftDishHasNoServingTargetEvenIfTheResponseVolunteersOne() async throws {
        var dishes = sixDishes()
        dishes[0]["suggestedPlannedServings"] = 7
        let responder = FakeMenuResponder(responses: [try response(dishes, event: sampleEvent)])
        let composition = try await generator(responder).composeMenu(input(), inventory: [], existingRecipes: [])
        let mirror = Mirror(reflecting: composition.dishes[0])
        XCTAssertFalse(
            mirror.children.contains { ($0.label ?? "").lowercased().contains("plannedservings") },
            "the draft dish model has no per-dish target field"
        )
        XCTAssertEqual(composition.dishes[0].baseServings, SpecialPlanMenuBounds.aiRecipeBaseServings)
    }
}

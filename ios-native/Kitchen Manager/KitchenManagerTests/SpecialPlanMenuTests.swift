import XCTest
import SwiftData
@testable import KitchenManager

/// AI menu slice: generation into a transient draft, targeted replacement,
/// acceptance into canonical state, and the deterministic shopping handoff.
///
/// These go through the SpecialPlanMenuRequesting seam, so no network call is
/// made and the weekly planner's own code stays untouched.
@MainActor
final class SpecialPlanMenuTests: XCTestCase {
    private var storeURL: URL!
    private var defaultsSuiteName: String!

    override func setUpWithError() throws {
        storeURL = FileManager.default.temporaryDirectory
            .appending(path: "specialplan-menu-\(UUID().uuidString).store")
        defaultsSuiteName = "specialplan-menu-\(UUID().uuidString)"
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

    /// Canned AI transport. Records every request so the tests can assert on the
    /// shape the generator builds without reaching the network.
    private final class FakeMenuResponder: SpecialPlanMenuRequesting, @unchecked Sendable {
        enum Outcome {
            case success(AIWeeklyMenuResponse)
            case failure(Error)
        }

        struct TransportFailure: Error {}

        private(set) var requests: [AIWeeklyMenuRequest] = []
        var outcomes: [Outcome]

        init(outcomes: [Outcome]) {
            self.outcomes = outcomes
        }

        func generatePlan(request: AIWeeklyMenuRequest) async throws -> AIWeeklyMenuResponse {
            requests.append(request)
            let outcome = outcomes.isEmpty
                ? Outcome.failure(TransportFailure())
                : outcomes.removeFirst()
            switch outcome {
            case .success(let response): return response
            case .failure(let error): throw error
            }
        }
    }

    /// Builds a weekly-shaped response through the real decoder, so these tests
    /// exercise the same tolerant parsing production uses.
    private func response(_ dishes: [[String: Any]]) throws -> AIWeeklyMenuResponse {
        let payload: [String: Any] = [
            "days": [
                [
                    "dayIndex": 0,
                    "meals": [["mealIndex": 0, "title": "晚餐", "recipes": dishes]]
                ]
            ],
            "shoppingItems": [],
            "warnings": []
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(AIWeeklyMenuResponse.self, from: data)
    }

    private func aiDish(
        _ name: String,
        ingredients: [String] = ["牛腩 500 克"],
        steps: [String] = ["炖煮"]
    ) -> [String: Any] {
        ["name": name, "ingredients": ingredients, "steps": steps, "source": "ai", "reason": "适合聚餐"]
    }

    private func draftDish(
        _ title: String = "清蒸鱼",
        ingredients: [String] = ["鱼 1 条"],
        seasonings: [String] = [],
        steps: [String] = ["蒸熟"]
    ) -> SpecialPlanMenuDraftDish {
        SpecialPlanMenuDraftDish(
            title: title,
            ingredients: ingredients,
            seasonings: seasonings,
            steps: steps,
            tags: [],
            cookingTime: nil,
            difficulty: nil,
            reason: nil,
            existingRecipeID: nil
        )
    }

    private func makeBundle() throws -> KitchenPersistenceBundle {
        try KitchenPersistenceFactory.bundle(
            container: KitchenPersistenceFactory.makeContainer(
                configuration: ModelConfiguration(url: storeURL)
            )
        )
    }

    private func makeKitchenStore() throws -> KitchenStore {
        KitchenStore(
            userDefaults: UserDefaults(suiteName: defaultsSuiteName)!,
            persistence: try makeBundle()
        )
    }

    private func makeRecipeStore() -> RecipeStore {
        RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    private func makeDraftStore(_ responder: FakeMenuResponder) -> SpecialPlanMenuDraftStore {
        SpecialPlanMenuDraftStore(
            generator: SpecialPlanMenuGenerator(service: responder)
        )
    }

    private func samplePlan(people: Int = 7) -> SpecialPlan {
        SpecialPlan(
            title: "朋友聚餐",
            scheduledAt: Date(timeIntervalSince1970: 1_750_000_000),
            peopleCount: people,
            constraintNotes: ["1 人不吃辣"],
            notes: "在家吃",
            dishes: []
        )
    }

    private func recipe(
        id: String,
        title: String,
        ingredients: [String] = ["食材 1 个"],
        steps: [String] = ["步骤"]
    ) -> Recipe {
        Recipe(
            id: id,
            title: title,
            cookingTime: nil,
            difficulty: nil,
            tags: [],
            ingredients: ingredients,
            steps: steps
        )
    }

    // MARK: - Generation

    func testSpecialPlanRequestCapsRecipeContextForOneMeal() {
        let recipes = (0..<25).map { index in
            recipe(id: "recipe-\(index)", title: "菜 \(index)")
        }

        let request = SpecialPlanMenuGenerator.makeRequest(
            for: samplePlan(),
            dishCount: 6,
            inventory: [],
            expiringItems: [],
            existingRecipes: recipes,
            excludedRecipeNames: []
        )

        XCTAssertEqual(request.existingRecipes.count, 20)
        XCTAssertEqual(request.existingRecipes.map(\.id), recipes.prefix(20).map(\.id))
    }

    func testStrictNoSpicyRequestExcludesOnlyKnownSpicyRecipeContext() {
        let recipes = [
            recipe(id: "spicy", title: "家常肉片", ingredients: ["猪肉", "干辣椒"]),
            recipe(id: "safe", title: "清蒸鲈鱼", ingredients: ["鲈鱼", "姜"])
        ]

        let request = SpecialPlanMenuGenerator.makeRequest(
            for: samplePlan(),
            dishCount: 6,
            inventory: [],
            expiringItems: [],
            existingRecipes: recipes,
            excludedRecipeNames: []
        )

        XCTAssertEqual(request.existingRecipes.map(\.id), ["safe"])

        var unconstrained = samplePlan()
        unconstrained.constraintNotes = []
        let unchanged = SpecialPlanMenuGenerator.makeRequest(
            for: unconstrained,
            dishCount: 6,
            inventory: [],
            expiringItems: [],
            existingRecipes: recipes,
            excludedRecipeNames: []
        )
        XCTAssertEqual(unchanged.existingRecipes.map(\.id), ["spicy", "safe"])
    }

    func testStrictNoSpicyConstraintRecognitionIsNarrow() {
        for note in [
            "1 人不吃辣", "有人不能吃辣", "不要辣", "完全不辣",
            "no spicy food", "not spicy", "can't eat spicy", "can’t eat spicy",
            "does not eat spicy", "no chili"
        ] {
            XCTAssertTrue(
                SpecialPlanConstraintPolicy(constraintNotes: [note]).requiresNonSpicyFood,
                "expected strict policy for: \(note)"
            )
        }

        for note in ["少辣", "微辣可以", "不要太辣", "prefers mild", "多放蔬菜"] {
            XCTAssertFalse(
                SpecialPlanConstraintPolicy(constraintNotes: [note]).requiresNonSpicyFood,
                "soft or unrelated preference must stay non-strict: \(note)"
            )
        }
    }

    func testNoSpicyValidatorRejectsHighConfidenceMarkers() {
        let policy = SpecialPlanConstraintPolicy(constraintNotes: ["1 人不吃辣"])
        let violatingDishes = [
            draftDish("宫保鸡丁（微辣）"),
            draftDish("麻辣香锅"),
            draftDish(ingredients: ["干辣椒 5 个"]),
            draftDish(seasonings: ["辣椒油 1 勺"]),
            draftDish(ingredients: ["chili oil 1 tbsp"]),
            draftDish(seasonings: ["hot sauce to taste"]),
            draftDish(steps: ["拌入 sriracha 后上桌"])
        ]

        for dish in violatingDishes {
            XCTAssertFalse(policy.allows(dish), "must reject: \(dish)")
        }
    }

    func testNoSpicyValidatorAllowsPepperFalsePositiveCasesAndOrdinaryDish() {
        let policy = SpecialPlanConstraintPolicy(constraintNotes: ["有人不吃辣"])
        for dish in [
            draftDish(ingredients: ["甜椒 1 个"]),
            draftDish(ingredients: ["彩椒 2 个"]),
            draftDish(ingredients: ["bell pepper 1"]),
            draftDish("清蒸鲈鱼", ingredients: ["鲈鱼 1 条", "姜 3 片"])
        ] {
            XCTAssertTrue(policy.allows(dish), "must allow: \(dish)")
        }
    }

    func testConstraintAbsentLeavesCurrentGenerationBehaviorUnchanged() async throws {
        let kitchenStore = try makeKitchenStore()
        let recipeStore = makeRecipeStore()
        var plan = samplePlan()
        plan.constraintNotes = []
        kitchenStore.addSpecialPlan(plan)
        let responder = FakeMenuResponder(outcomes: [
            .success(try response([aiDish("麻辣香锅"), aiDish("清蒸鱼")]))
        ])
        let draft = makeDraftStore(responder)

        await draft.generate(for: plan, kitchenStore: kitchenStore, recipeStore: recipeStore)

        XCTAssertEqual(draft.dishes.map(\.title), ["麻辣香锅", "清蒸鱼"])
        XCTAssertNil(draft.errorMessage)
    }

    func testOneViolatingDishRejectsWholeGenerationWithoutCanonicalWrites() async throws {
        let kitchenStore = try makeKitchenStore()
        let recipeStore = makeRecipeStore()
        let plan = samplePlan()
        kitchenStore.addSpecialPlan(plan)
        let responder = FakeMenuResponder(outcomes: [
            .success(try response([
                aiDish("清蒸鱼"),
                aiDish("凉拌黄瓜"),
                aiDish("干煸牛肉", ingredients: ["牛肉 300 克", "干辣椒 5 个"])
            ]))
        ])
        let draft = makeDraftStore(responder)

        await draft.generate(for: plan, kitchenStore: kitchenStore, recipeStore: recipeStore)

        XCTAssertTrue(draft.dishes.isEmpty, "a violating response must not become a usable draft")
        XCTAssertEqual(draft.errorMessage, SpecialPlanMenuGeneratorError.hardConstraintViolation.errorDescription)
        XCTAssertTrue(recipeStore.userRecipes.isEmpty, "rejection must create no recipe")
        XCTAssertEqual(kitchenStore.specialPlans.first?.dishes, [], "rejection must not mutate the plan")
    }

    func testSuccessfulGenerationOnlyProducesATransientDraft() async throws {
        let kitchenStore = try makeKitchenStore()
        let recipeStore = makeRecipeStore()
        let plan = samplePlan()
        kitchenStore.addSpecialPlan(plan)

        let responder = FakeMenuResponder(outcomes: [
            .success(try response([aiDish("红烧牛腩"), aiDish("蒜蓉虾"), aiDish("凉拌黄瓜")]))
        ])
        let draft = makeDraftStore(responder)

        await draft.generate(for: plan, kitchenStore: kitchenStore, recipeStore: recipeStore)

        XCTAssertTrue(draft.hasDraft)
        XCTAssertFalse(draft.isGenerating)
        XCTAssertEqual(draft.dishes.map(\.title), ["红烧牛腩", "蒜蓉虾", "凉拌黄瓜"])
        XCTAssertNil(draft.errorMessage)
        // Canonical state is untouched until the user saves.
        XCTAssertTrue(recipeStore.userRecipes.isEmpty, "generation must not write recipes")
        XCTAssertEqual(kitchenStore.specialPlans.first?.dishes, [], "generation must not write plan dishes")
    }

    func testMalformedResponseLeavesCanonicalStateUnchanged() async throws {
        let kitchenStore = try makeKitchenStore()
        let recipeStore = makeRecipeStore()
        let plan = samplePlan()
        kitchenStore.addSpecialPlan(plan)

        // Dishes with no ingredients/steps cannot become recipe drafts, so the
        // whole menu is rejected rather than half-built.
        let responder = FakeMenuResponder(outcomes: [
            .success(try response([
                ["name": "", "source": "ai"],
                ["name": "谜之菜", "source": "ai"]
            ]))
        ])
        let draft = makeDraftStore(responder)

        await draft.generate(for: plan, kitchenStore: kitchenStore, recipeStore: recipeStore)

        XCTAssertTrue(draft.dishes.isEmpty)
        XCTAssertFalse(draft.hasDraft)
        XCTAssertNotNil(draft.errorMessage)
        XCTAssertTrue(recipeStore.userRecipes.isEmpty)
        XCTAssertEqual(kitchenStore.specialPlans.first?.dishes, [])
    }

    func testTooFewDishesIsRejected() async throws {
        let kitchenStore = try makeKitchenStore()
        let recipeStore = makeRecipeStore()
        let plan = samplePlan()
        kitchenStore.addSpecialPlan(plan)

        let responder = FakeMenuResponder(outcomes: [
            .success(try response([aiDish("孤零零一道菜")]))
        ])
        let draft = makeDraftStore(responder)
        await draft.generate(for: plan, kitchenStore: kitchenStore, recipeStore: recipeStore)

        XCTAssertTrue(draft.dishes.isEmpty)
        XCTAssertEqual(
            draft.errorMessage,
            SpecialPlanMenuGeneratorError.tooFewDishes.errorDescription
        )
    }

    func testTransportFailureCreatesNoRecipesAndCanBeRetried() async throws {
        let kitchenStore = try makeKitchenStore()
        let recipeStore = makeRecipeStore()
        let plan = samplePlan()
        kitchenStore.addSpecialPlan(plan)

        let responder = FakeMenuResponder(outcomes: [
            .failure(FakeMenuResponder.TransportFailure()),
            .success(try response([aiDish("红烧牛腩"), aiDish("蒜蓉虾")]))
        ])
        let draft = makeDraftStore(responder)

        await draft.generate(for: plan, kitchenStore: kitchenStore, recipeStore: recipeStore)
        XCTAssertTrue(draft.dishes.isEmpty)
        XCTAssertNotNil(draft.errorMessage)
        XCTAssertTrue(recipeStore.userRecipes.isEmpty)

        // Retry on the same store succeeds.
        await draft.generate(for: plan, kitchenStore: kitchenStore, recipeStore: recipeStore)
        XCTAssertEqual(draft.dishes.map(\.title), ["红烧牛腩", "蒜蓉虾"])
        XCTAssertNil(draft.errorMessage)
    }

    func testExistingCanonicalDishesSurviveAFailedGeneration() async throws {
        let kitchenStore = try makeKitchenStore()
        let recipeStore = makeRecipeStore()
        var plan = samplePlan()
        plan.dishes = [SpecialPlanDish(recipeID: "sample-mapotofu", recipeName: "麻婆豆腐")]
        kitchenStore.addSpecialPlan(plan)

        let responder = FakeMenuResponder(outcomes: [.failure(FakeMenuResponder.TransportFailure())])
        let draft = makeDraftStore(responder)
        await draft.generate(for: plan, kitchenStore: kitchenStore, recipeStore: recipeStore)

        XCTAssertEqual(
            kitchenStore.specialPlans.first?.dishes.map(\.recipeName),
            ["麻婆豆腐"],
            "a failed generation must not disturb the saved menu"
        )
    }

    func testDuplicateNamesAreCollapsedAndTheMenuIsCapped() async throws {
        let kitchenStore = try makeKitchenStore()
        let recipeStore = makeRecipeStore()
        let plan = samplePlan()
        kitchenStore.addSpecialPlan(plan)

        var dishes = [aiDish("红烧牛腩"), aiDish("红烧牛腩 ")]
        for index in 0..<12 { dishes.append(aiDish("菜\(index)")) }
        let responder = FakeMenuResponder(outcomes: [.success(try response(dishes))])
        let draft = makeDraftStore(responder)

        await draft.generate(for: plan, kitchenStore: kitchenStore, recipeStore: recipeStore)

        XCTAssertEqual(draft.dishes.count, SpecialPlanMenuBounds.maximumDishes)
        XCTAssertEqual(
            Set(draft.dishes.map(\.title)).count,
            draft.dishes.count,
            "duplicate names must collapse"
        )
    }

    // MARK: - Request shaping

    func testPeopleCountShapesTheRequestWithoutQuantityScaling() async throws {
        let kitchenStore = try makeKitchenStore()
        let recipeStore = makeRecipeStore()
        let plan = samplePlan(people: 7)
        kitchenStore.addSpecialPlan(plan)

        let responder = FakeMenuResponder(outcomes: [
            .success(try response([aiDish("红烧牛腩"), aiDish("蒜蓉虾")]))
        ])
        let draft = makeDraftStore(responder)
        await draft.generate(for: plan, kitchenStore: kitchenStore, recipeStore: recipeStore)

        let request = try XCTUnwrap(responder.requests.first)
        XCTAssertEqual(request.numberOfDays, 1)
        XCTAssertEqual(request.mealsPerDay, 1)
        XCTAssertEqual(
            request.servings,
            1,
            "the shared weekly prompt scales quantities from servings; Special Plans have no base yield"
        )
        XCTAssertEqual(request.dishesPerMeal, SpecialPlanMenuBounds.suggestedDishCount(peopleCount: 7))

        let brief = try XCTUnwrap(request.additionalRequest)
        // Exact interpolated values: a broken interpolation would ship the
        // literal source text to the model.
        XCTAssertTrue(brief.contains("7 人"), "brief must carry the headcount, got: \(brief)")
        XCTAssertTrue(brief.contains("1 人不吃辣"), "brief must carry constraints, got: \(brief)")
        XCTAssertTrue(brief.contains("朋友聚餐"))
        XCTAssertTrue(brief.contains("所有共享菜都必须完全不辣"))
        XCTAssertTrue(brief.contains("不要生成需要用户自行去辣"))
        XCTAssertTrue(
            brief.contains("禁止按人数推算"),
            "the brief must not ask for scaled quantities"
        )
    }

    // MARK: - Targeted replacement

    func testReplacementChangesOnlyTheTargetedDish() async throws {
        let kitchenStore = try makeKitchenStore()
        let recipeStore = makeRecipeStore()
        let plan = samplePlan()
        kitchenStore.addSpecialPlan(plan)

        let responder = FakeMenuResponder(outcomes: [
            .success(try response([aiDish("红烧牛腩"), aiDish("蒜蓉虾"), aiDish("凉拌黄瓜")])),
            .success(try response([aiDish("清蒸鱼")]))
        ])
        let draft = makeDraftStore(responder)
        await draft.generate(for: plan, kitchenStore: kitchenStore, recipeStore: recipeStore)

        let before = draft.dishes
        let target = before[1]
        await draft.replaceDish(id: target.id, for: plan, kitchenStore: kitchenStore, recipeStore: recipeStore)

        XCTAssertEqual(draft.dishes.count, 3)
        XCTAssertEqual(draft.dishes[1].title, "清蒸鱼")
        XCTAssertEqual(draft.dishes[1].id, target.id, "the row identity must stay stable")
        XCTAssertEqual(draft.dishes[0], before[0], "sibling dishes must be untouched")
        XCTAssertEqual(draft.dishes[2], before[2], "sibling dishes must be untouched")
        XCTAssertNil(draft.replacingDishID)
    }

    func testReplacementRequestAsksForOneDishAndExcludesTheCurrentMenu() async throws {
        let kitchenStore = try makeKitchenStore()
        let recipeStore = makeRecipeStore()
        let plan = samplePlan()
        kitchenStore.addSpecialPlan(plan)

        let responder = FakeMenuResponder(outcomes: [
            .success(try response([aiDish("红烧牛腩"), aiDish("蒜蓉虾")])),
            .success(try response([aiDish("清蒸鱼")]))
        ])
        let draft = makeDraftStore(responder)
        await draft.generate(for: plan, kitchenStore: kitchenStore, recipeStore: recipeStore)
        await draft.replaceDish(
            id: draft.dishes[0].id,
            for: plan,
            kitchenStore: kitchenStore,
            recipeStore: recipeStore
        )

        XCTAssertEqual(responder.requests.count, 2)
        let replacement = responder.requests[1]
        XCTAssertEqual(replacement.dishesPerMeal, 1)
        XCTAssertTrue(replacement.excludedRecipeNames.contains("红烧牛腩"))
        XCTAssertTrue(replacement.excludedRecipeNames.contains("蒜蓉虾"))
        XCTAssertTrue(replacement.additionalRequest?.contains("不要生成整桌套餐") == true)
        XCTAssertTrue(replacement.additionalRequest?.contains("盆菜") == true)
        XCTAssertTrue(replacement.additionalRequest?.contains("所有共享菜都必须完全不辣") == true)
    }

    func testViolatingReplacementPreservesEveryExistingDish() async throws {
        let kitchenStore = try makeKitchenStore()
        let recipeStore = makeRecipeStore()
        let plan = samplePlan()
        kitchenStore.addSpecialPlan(plan)

        let responder = FakeMenuResponder(outcomes: [
            .success(try response([aiDish("红烧牛腩"), aiDish("蒜蓉虾"), aiDish("凉拌黄瓜")])),
            .success(try response([aiDish("香辣鸡丁")]))
        ])
        let draft = makeDraftStore(responder)
        await draft.generate(for: plan, kitchenStore: kitchenStore, recipeStore: recipeStore)
        let before = draft.dishes

        await draft.replaceDish(
            id: before[1].id,
            for: plan,
            kitchenStore: kitchenStore,
            recipeStore: recipeStore
        )

        XCTAssertEqual(draft.dishes, before, "a violating replacement must never enter the draft")
        XCTAssertEqual(draft.errorMessage, SpecialPlanMenuGeneratorError.hardConstraintViolation.errorDescription)
        XCTAssertTrue(recipeStore.userRecipes.isEmpty)
        XCTAssertEqual(kitchenStore.specialPlans.first?.dishes, [])
    }

    func testFailedReplacementPreservesTheOriginalDish() async throws {
        let kitchenStore = try makeKitchenStore()
        let recipeStore = makeRecipeStore()
        let plan = samplePlan()
        kitchenStore.addSpecialPlan(plan)

        let responder = FakeMenuResponder(outcomes: [
            .success(try response([aiDish("红烧牛腩"), aiDish("蒜蓉虾")])),
            .failure(FakeMenuResponder.TransportFailure())
        ])
        let draft = makeDraftStore(responder)
        await draft.generate(for: plan, kitchenStore: kitchenStore, recipeStore: recipeStore)
        let before = draft.dishes

        await draft.replaceDish(
            id: before[0].id,
            for: plan,
            kitchenStore: kitchenStore,
            recipeStore: recipeStore
        )

        XCTAssertEqual(draft.dishes, before, "a failed replacement must leave the draft intact")
        XCTAssertNotNil(draft.errorMessage)
        XCTAssertNil(draft.replacingDishID)
    }

    // MARK: - Acceptance

    func testSavingCreatesRecipesAndStablePlanReferences() async throws {
        let kitchenStore = try makeKitchenStore()
        let recipeStore = makeRecipeStore()
        let plan = samplePlan()
        kitchenStore.addSpecialPlan(plan)

        let responder = FakeMenuResponder(outcomes: [
            .success(try response([aiDish("红烧牛腩"), aiDish("蒜蓉虾")]))
        ])
        let draft = makeDraftStore(responder)
        await draft.generate(for: plan, kitchenStore: kitchenStore, recipeStore: recipeStore)

        XCTAssertTrue(recipeStore.userRecipes.isEmpty, "no recipe may exist before save")

        XCTAssertTrue(draft.save(to: plan.id, kitchenStore: kitchenStore, recipeStore: recipeStore))

        XCTAssertEqual(Set(recipeStore.userRecipes.map(\.title)), ["红烧牛腩", "蒜蓉虾"])
        let saved = try XCTUnwrap(kitchenStore.specialPlans.first)
        XCTAssertEqual(saved.dishes.map(\.recipeName), ["红烧牛腩", "蒜蓉虾"])
        for dish in saved.dishes {
            XCTAssertNotNil(recipeStore.recipe(id: dish.recipeID), "every reference must resolve")
        }
        // The draft is cleared, and the plan stores references only.
        XCTAssertTrue(draft.dishes.isEmpty)
        XCTAssertFalse(draft.hasDraft)
    }

    func testAcceptedReferencesStillResolveAfterAStoreReopen() async throws {
        let kitchenStore = try makeKitchenStore()
        let recipeStore = makeRecipeStore()
        let plan = samplePlan()
        kitchenStore.addSpecialPlan(plan)

        let responder = FakeMenuResponder(outcomes: [
            .success(try response([aiDish("红烧牛腩"), aiDish("蒜蓉虾")]))
        ])
        let draft = makeDraftStore(responder)
        await draft.generate(for: plan, kitchenStore: kitchenStore, recipeStore: recipeStore)
        XCTAssertTrue(draft.save(to: plan.id, kitchenStore: kitchenStore, recipeStore: recipeStore))
        let expected = try XCTUnwrap(kitchenStore.specialPlans.first).dishes

        // Reopen the same on-disk store: the plan's dish references survive.
        let reopened = try makeKitchenStore()
        XCTAssertEqual(reopened.specialPlans.first?.dishes, expected)
    }

    func testDeletingThePlanKeepsTheAcceptedRecipes() async throws {
        let kitchenStore = try makeKitchenStore()
        let recipeStore = makeRecipeStore()
        let plan = samplePlan()
        kitchenStore.addSpecialPlan(plan)

        let responder = FakeMenuResponder(outcomes: [
            .success(try response([aiDish("红烧牛腩"), aiDish("蒜蓉虾")]))
        ])
        let draft = makeDraftStore(responder)
        await draft.generate(for: plan, kitchenStore: kitchenStore, recipeStore: recipeStore)
        XCTAssertTrue(draft.save(to: plan.id, kitchenStore: kitchenStore, recipeStore: recipeStore))

        XCTAssertNotNil(kitchenStore.removeSpecialPlan(id: plan.id))
        XCTAssertEqual(recipeStore.userRecipes.count, 2, "deleting a plan must not delete recipes")
    }

    func testSaveRollsBackCreatedRecipesWhenThePlanIsGone() async throws {
        let kitchenStore = try makeKitchenStore()
        let recipeStore = makeRecipeStore()
        let plan = samplePlan()
        kitchenStore.addSpecialPlan(plan)

        let responder = FakeMenuResponder(outcomes: [
            .success(try response([aiDish("红烧牛腩"), aiDish("蒜蓉虾")]))
        ])
        let draft = makeDraftStore(responder)
        await draft.generate(for: plan, kitchenStore: kitchenStore, recipeStore: recipeStore)

        // The plan disappears (deleted on another screen) before the user saves.
        XCTAssertNotNil(kitchenStore.removeSpecialPlan(id: plan.id))

        XCTAssertFalse(draft.save(to: plan.id, kitchenStore: kitchenStore, recipeStore: recipeStore))
        XCTAssertTrue(
            recipeStore.userRecipes.isEmpty,
            "a failed save must not leave orphan recipes behind"
        )
        XCTAssertEqual(draft.dishes.count, 2, "the draft is kept so the user can retry")
        XCTAssertEqual(
            draft.errorMessage,
            SpecialPlanMenuAcceptanceError.planMissing.errorDescription
        )
    }

    func testAcceptanceReusesAnIdenticalExistingRecipe() async throws {
        let kitchenStore = try makeKitchenStore()
        let recipeStore = makeRecipeStore()
        let existing = recipe(
            id: "user-existing",
            title: "红烧牛腩",
            ingredients: ["牛腩 500 克"],
            steps: ["炖煮"]
        )
        try recipeStore.saveUserRecipe(existing)

        let plan = samplePlan()
        kitchenStore.addSpecialPlan(plan)

        let responder = FakeMenuResponder(outcomes: [
            .success(try response([aiDish("红烧牛腩"), aiDish("蒜蓉虾")]))
        ])
        let draft = makeDraftStore(responder)
        await draft.generate(for: plan, kitchenStore: kitchenStore, recipeStore: recipeStore)
        XCTAssertTrue(draft.save(to: plan.id, kitchenStore: kitchenStore, recipeStore: recipeStore))

        XCTAssertEqual(recipeStore.userRecipes.count, 2, "an identical recipe must not be duplicated")
        let saved = try XCTUnwrap(kitchenStore.specialPlans.first)
        XCTAssertEqual(saved.dishes.first?.recipeID, "user-existing")
    }

    // MARK: - Deterministic shopping handoff

    func testAcceptedDishesFeedTheExistingShoppingGeneratorWithoutHeadcountScaling() async throws {
        let kitchenStore = try makeKitchenStore()
        let recipeStore = makeRecipeStore()
        let plan = samplePlan(people: 7)
        kitchenStore.addSpecialPlan(plan)

        let responder = FakeMenuResponder(outcomes: [
            .success(try response([
                aiDish("红烧牛腩", ingredients: ["牛腩 200 克"]),
                aiDish("牛腩汤", ingredients: ["牛腩 200 克"])
            ]))
        ])
        let draft = makeDraftStore(responder)
        await draft.generate(for: plan, kitchenStore: kitchenStore, recipeStore: recipeStore)
        XCTAssertTrue(draft.save(to: plan.id, kitchenStore: kitchenStore, recipeStore: recipeStore))

        let saved = try XCTUnwrap(kitchenStore.specialPlans.first)
        let recipes = saved.dishes.compactMap { recipeStore.recipe(id: $0.recipeID) }
        XCTAssertEqual(recipes.count, 2)

        let generated = ShoppingListGenerator().generate(
            source: .selectedRecipes(recipes, servings: 1),
            inventory: [],
            existingShoppingItems: [],
            recipeStore: recipeStore
        )

        let beef = try XCTUnwrap(
            generated.missingItems.first { $0.displayName.contains("牛腩") }
        )
        // Recipe quantities are summed as written: 200 + 200. The 7-person
        // headcount must never multiply them, because no recipe here carries a
        // canonical base yield.
        XCTAssertEqual(beef.requiredQuantity, 400)
        XCTAssertNotEqual(beef.requiredQuantity, 400 * 7)
    }
}

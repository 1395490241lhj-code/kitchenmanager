import XCTest
@testable import KitchenManager

/// `MealPlanItem.plannedServings` — how many recipe servings this plan actually
/// prepares, and the numerator a future scaler will divide by
/// `Recipe.baseServings`.
///
/// These tests exist because the old `servings: Int = 1` carried three
/// different meanings at once: an unset placeholder from the one-tap add
/// buttons, a real target from the AI generator, and the weekly planner's
/// household headcount. Any of those reaching ingredient maths as a numerator
/// would be confidently wrong, so each provenance path is pinned here.
@MainActor
final class PlannedServingsTests: XCTestCase {
    private func makeStore() -> KitchenStore {
        KitchenStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            persistence: KitchenPersistenceFactory.isolatedInMemory()
        )
    }

    private func sampleRecipe(baseServings: Int? = nil) -> Recipe {
        Recipe(
            id: "r-\(UUID().uuidString)", title: "番茄炒蛋", cookingTime: nil, difficulty: nil,
            tags: [], ingredients: ["番茄 2 个"], steps: ["炒"], baseServings: baseServings
        )
    }

    // MARK: - Model

    func testUnstatedTargetIsNil() {
        let item = MealPlanItem(recipeID: "r", recipeName: "菜")
        XCTAssertNil(item.plannedServings, "no default 1: nobody stated a target")
    }

    func testOutOfRangeTargetIsRejectedNotClamped() {
        for invalid in [0, -1, 13, 99] {
            let item = MealPlanItem(recipeID: "r", recipeName: "菜", plannedServings: invalid)
            XCTAssertNil(item.plannedServings, "\(invalid) must not become a plausible-looking target")
        }
    }

    func testExplicitTargetIsKept() {
        XCTAssertEqual(
            MealPlanItem(recipeID: "r", recipeName: "菜", plannedServings: 2).plannedServings,
            2
        )
    }

    // MARK: - Legacy data is untrusted

    func testLegacyBackupServingsIsDroppedRatherThanMigrated() throws {
        // A stored 4 could be a real target or a household headcount, and
        // nothing in the old data distinguishes them. Losing a hint that may
        // have been right beats feeding a headcount into ingredient maths.
        let legacy = #"{"id":"11111111-1111-1111-1111-111111111111","recipeID":"r","recipeName":"回锅肉","date":0,"servings":4,"isCooked":false}"#
        let item = try JSONDecoder().decode(MealPlanItem.self, from: Data(legacy.utf8))
        XCTAssertNil(item.plannedServings, "ambiguous legacy servings must not become a target")
        XCTAssertEqual(item.recipeName, "回锅肉", "the rest of the record still restores")
    }

    func testLegacyServingsOfOneIsAlsoDropped() throws {
        // 1 is the old placeholder, so it is no more trustworthy than 4.
        let legacy = #"{"id":"22222222-2222-2222-2222-222222222222","recipeID":"r","recipeName":"菜","date":0,"servings":1,"isCooked":false}"#
        let item = try JSONDecoder().decode(MealPlanItem.self, from: Data(legacy.utf8))
        XCTAssertNil(item.plannedServings)
    }

    func testNewBackupRoundTripsAnExplicitTarget() throws {
        let item = MealPlanItem(recipeID: "r", recipeName: "菜", plannedServings: 2)
        let decoded = try JSONDecoder().decode(MealPlanItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded.plannedServings, 2)
    }

    func testNewBackupRoundTripsAnUnstatedTarget() throws {
        let item = MealPlanItem(recipeID: "r", recipeName: "菜")
        let decoded = try JSONDecoder().decode(MealPlanItem.self, from: JSONEncoder().encode(item))
        XCTAssertNil(decoded.plannedServings, "unknown must survive as unknown")
    }

    // MARK: - Provenance per path

    func testOneTapAddLeavesTheTargetUnstated() {
        // Recipe detail and Home recommendation both call this with no target.
        let store = makeStore()
        store.addPlan(recipe: sampleRecipe())
        XCTAssertEqual(store.plans.count, 1)
        XCTAssertNil(store.plans[0].plannedServings, "one-tap add is not a serving choice")
    }

    func testExplicitTargetSurvivesAddPlan() {
        let store = makeStore()
        store.addPlan(recipe: sampleRecipe(), plannedServings: 2)
        XCTAssertEqual(store.plans[0].plannedServings, 2)
    }

    func testBatchAddCarriesEachTargetIndependently() {
        let store = makeStore()
        let a = sampleRecipe()
        let b = sampleRecipe()
        store.addPlans([(recipe: a, plannedServings: Int?(3)), (recipe: b, plannedServings: Int?.none)])
        XCTAssertEqual(store.plans.first { $0.recipeID == a.id }?.plannedServings, 3)
        XCTAssertNil(store.plans.first { $0.recipeID == b.id }?.plannedServings)
    }

    func testOutOfRangeTargetDoesNotReachAStoredPlan() {
        let store = makeStore()
        store.addPlan(recipe: sampleRecipe(), plannedServings: 99)
        XCTAssertNil(store.plans[0].plannedServings)
    }

    // MARK: - Cooking session uses the recipe yield, not a raw multiplier

    func testKnownBaseAndTargetProduceARealFactor() {
        let session = RecipeCookingSession(servings: 2, baseServings: 4)
        XCTAssertEqual(session.displayMultiplier, 0.5)
        XCTAssertTrue(session.isScaled)
    }

    func testCookingAsWrittenLeavesQuantitiesUnchanged() {
        // The old bug: a 4-serving recipe at 4 人份 multiplied by 4.
        let session = RecipeCookingSession(servings: 4, baseServings: 4)
        XCTAssertEqual(session.displayMultiplier, 1)
    }

    func testUnknownBaseNeverScales() {
        let session = RecipeCookingSession(servings: 4, baseServings: nil)
        XCTAssertEqual(session.displayMultiplier, 1, "a recipe with no stated yield shows what it says")
        XCTAssertFalse(session.isScaled)
    }

    func testScaledTextUsesTheConvertedMultiplier() {
        let session = RecipeCookingSession(servings: 2, baseServings: 4)
        XCTAssertEqual(
            RecipeServingScaler.scaledText("番茄 4 个", multiplier: session.displayMultiplier),
            "番茄 2 个"
        )
    }

    // MARK: - Shopping still does not scale

    func testShoppingDoesNotScaleEvenWithBaseAndTargetKnown() {
        let store = makeStore()
        let recipeStore = RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let recipe = sampleRecipe(baseServings: 4)
        let generator = ShoppingListGenerator()

        let asWritten = generator.generate(
            source: .recipe(recipe, servings: 1), inventory: [],
            existingShoppingItems: [], recipeStore: recipeStore
        )
        let halved = generator.generate(
            source: .recipe(recipe, servings: 2), inventory: [],
            existingShoppingItems: [], recipeStore: recipeStore
        )
        XCTAssertEqual(
            asWritten.missingItems.first?.requiredQuantity,
            halved.missingItems.first?.requiredQuantity,
            "P2 clarifies semantics only — shopping scaling is a later phase"
        )
        _ = store
    }
}


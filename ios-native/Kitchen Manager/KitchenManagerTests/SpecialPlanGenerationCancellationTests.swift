import XCTest
import SwiftData
@testable import KitchenManager

/// P-4 of the behavior-contract prototype: a Special Plan generation the user
/// can always leave.
///
/// Before this slice the composer sheet disabled its own 取消 and its
/// interactive dismissal for the whole request, and the draft store held no
/// task handle — so a 50 s provider timeout was a 50 s trap with no exit at any
/// layer. These tests pin the four halves of the approved contract: the request
/// really stops, the draft you had survives, the surface becomes usable again,
/// and leaving is never blocked.
///
/// Everything goes through the `SpecialPlanMenuRequesting` seam, so no network
/// call is made and the weekly planner's own code stays untouched.
@MainActor
final class SpecialPlanGenerationCancellationTests: XCTestCase {

    // MARK: - Fixtures

    /// Blocks inside the request until the test cancels it. `Task.sleep` is the
    /// cancellation point, so a cancelled task throws `CancellationError` from
    /// exactly where a real in-flight `URLSession` call would throw
    /// `APIError.cancelled`.
    private final class BlockingMenuResponder: SpecialPlanMenuRequesting, @unchecked Sendable {
        let didStart = XCTestExpectation(description: "request started")
        private(set) var wasCancelled = false
        private(set) var requestCount = 0
        /// Returned when the request is allowed to finish instead of cancelled.
        var completion: (@Sendable () throws -> AIWeeklyMenuResponse)?

        func generatePlan(request: AIWeeklyMenuRequest) async throws -> AIWeeklyMenuResponse {
            requestCount += 1
            didStart.fulfill()
            do {
                // Long enough that the test always wins the race, short enough
                // that a broken cancellation fails rather than hangs.
                try await Task.sleep(for: .seconds(5))
            } catch {
                wasCancelled = true
                throw error
            }
            if let completion { return try completion() }
            throw CancellationError()
        }
    }

    /// Answers immediately, so a post-cancellation retry can be proven to work.
    private final class ImmediateMenuResponder: SpecialPlanMenuRequesting, @unchecked Sendable {
        private(set) var requestCount = 0
        let response: AIWeeklyMenuResponse

        init(response: AIWeeklyMenuResponse) {
            self.response = response
        }

        func generatePlan(request: AIWeeklyMenuRequest) async throws -> AIWeeklyMenuResponse {
            requestCount += 1
            return response
        }
    }

    private func menuResponse(_ names: [String]) throws -> AIWeeklyMenuResponse {
        let recipes: [[String: Any]] = names.map { name in
            [
                "name": name,
                "ingredients": ["牛腩 500 克"],
                "steps": ["炖煮"],
                "source": "ai",
                "reason": "适合聚餐",
                "baseServings": SpecialPlanMenuBounds.aiRecipeBaseServings
            ]
        }
        let payload: [String: Any] = [
            "days": [["dayIndex": 0, "meals": [["mealIndex": 0, "title": "晚餐", "recipes": recipes]]]],
            "shoppingItems": [],
            "warnings": []
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(AIWeeklyMenuResponse.self, from: data)
    }

    private func draftDish(_ title: String) -> SpecialPlanMenuDraftDish {
        SpecialPlanMenuDraftDish(
            title: title,
            ingredients: ["鱼 1 条"],
            seasonings: [],
            steps: ["蒸熟"],
            tags: [],
            cookingTime: nil,
            difficulty: nil,
            reason: nil,
            existingRecipeID: nil,
            baseServings: SpecialPlanMenuBounds.aiRecipeBaseServings
        )
    }

    private func makeStore(
        _ responder: any SpecialPlanMenuRequesting,
        dishes: [SpecialPlanMenuDraftDish] = []
    ) -> SpecialPlanMenuDraftStore {
        SpecialPlanMenuDraftStore(
            generator: SpecialPlanMenuGenerator(service: responder),
            dishes: dishes
        )
    }

    private func makeKitchenStore() throws -> KitchenStore {
        KitchenStore(
            userDefaults: UserDefaults(suiteName: "specialplan-cancel-\(UUID().uuidString)")!,
            persistence: try KitchenPersistenceFactory.bundle(
                container: KitchenPersistenceFactory.makeContainer(
                    configuration: ModelConfiguration(url: FileManager.default.temporaryDirectory
                        .appending(path: "specialplan-cancel-\(UUID().uuidString).store"))
                )
            )
        )
    }

    private func makeRecipeStore() -> RecipeStore {
        RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    private var sampleInput: SpecialPlanMenuGenerator.Input {
        SpecialPlanMenuGenerator.Input(
            requestText: "这周六 6 个人吃饭，做 4 道家常菜",
            usesHomeInventory: true
        )
    }

    private func samplePlan() -> SpecialPlan {
        SpecialPlan(
            title: "朋友聚餐",
            scheduledAt: Date(timeIntervalSince1970: 1_750_000_000),
            peopleCount: 6,
            constraintNotes: [],
            notes: "",
            requestText: "这周六 6 个人吃饭，做 4 道家常菜",
            usesHomeInventory: true,
            dishes: []
        )
    }

    // MARK: - The request actually stops

    func testCancelStopsTheUnderlyingRequestAndHandsTheSurfaceBack() async throws {
        let responder = BlockingMenuResponder()
        let store = makeStore(responder)
        let kitchen = try makeKitchenStore()
        let recipes = makeRecipeStore()

        let running = Task {
            await store.compose(sampleInput, kitchenStore: kitchen, recipeStore: recipes)
        }
        await fulfillment(of: [responder.didStart], timeout: 3)
        XCTAssertTrue(store.isGenerating, "The request is in flight.")

        store.cancelGeneration()

        XCTAssertFalse(
            store.isGenerating,
            "Cancel hands the surface back immediately, not when the provider finally answers."
        )
        let result = await running.value
        XCTAssertNil(result, "A cancelled composition produces no interpretation.")
        XCTAssertTrue(responder.wasCancelled, "The underlying request was cancelled, not abandoned.")
    }

    func testCancelIsNotReportedAsAFailure() async throws {
        let responder = BlockingMenuResponder()
        let store = makeStore(responder)
        let kitchen = try makeKitchenStore()
        let recipes = makeRecipeStore()

        let running = Task {
            await store.compose(sampleInput, kitchenStore: kitchen, recipeStore: recipes)
        }
        await fulfillment(of: [responder.didStart], timeout: 3)
        store.cancelGeneration()
        _ = await running.value

        XCTAssertNil(
            store.errorMessage,
            "Stopping on purpose is not an error, and must not surface as 暂时无法生成."
        )
    }

    // MARK: - The draft you had survives

    func testCancelRestoresThePreGenerationDraftIntact() async throws {
        let existing = [draftDish("清蒸鱼"), draftDish("蒜蓉青菜")]
        let responder = BlockingMenuResponder()
        let store = makeStore(responder, dishes: existing)
        let kitchen = try makeKitchenStore()
        let recipes = makeRecipeStore()

        let running = Task {
            await store.generate(for: samplePlan(), kitchenStore: kitchen, recipeStore: recipes)
        }
        await fulfillment(of: [responder.didStart], timeout: 3)
        store.cancelGeneration()
        await running.value

        XCTAssertEqual(
            store.dishes.map(\.title),
            ["清蒸鱼", "蒜蓉青菜"],
            "A cancelled regeneration leaves the menu the user already had, exactly as a failure does."
        )
        XCTAssertTrue(store.hasDraft)
    }

    func testCancellingAReplacementLeavesTheOriginalDishInPlace() async throws {
        let existing = [draftDish("清蒸鱼"), draftDish("蒜蓉青菜")]
        let responder = BlockingMenuResponder()
        let store = makeStore(responder, dishes: existing)
        let kitchen = try makeKitchenStore()
        let recipes = makeRecipeStore()
        let targetID = try XCTUnwrap(store.dishes.first?.id)

        let running = Task {
            await store.replaceDish(
                id: targetID, for: samplePlan(), kitchenStore: kitchen, recipeStore: recipes
            )
        }
        await fulfillment(of: [responder.didStart], timeout: 3)
        store.cancelGeneration()
        await running.value

        XCTAssertEqual(store.dishes.map(\.title), ["清蒸鱼", "蒜蓉青菜"])
        XCTAssertNil(store.replacingDishID, "The row stops showing progress.")
        XCTAssertNil(store.errorMessage)
    }

    // MARK: - The surface is usable again

    func testTheSameRequestCanBeResubmittedImmediatelyAfterCancelling() async throws {
        let blocking = BlockingMenuResponder()
        let store = makeStore(blocking)
        let kitchen = try makeKitchenStore()
        let recipes = makeRecipeStore()

        let running = Task {
            await store.compose(sampleInput, kitchenStore: kitchen, recipeStore: recipes)
        }
        await fulfillment(of: [blocking.didStart], timeout: 3)
        store.cancelGeneration()
        _ = await running.value

        XCTAssertFalse(store.isBusy, "The composer is editable again, so the same words can be resent.")

        // A second store standing in for the retry, because the blocking
        // responder only ever blocks. What matters is that the first one no
        // longer owns the surface.
        let retryStore = makeStore(ImmediateMenuResponder(response: try menuResponse(["红烧肉", "清蒸鱼", "炒时蔬", "冬瓜汤"])))
        let interpretation = await retryStore.compose(
            sampleInput, kitchenStore: kitchen, recipeStore: recipes
        )
        XCTAssertNotNil(interpretation, "A retry after a cancel behaves like any first attempt.")
        XCTAssertEqual(retryStore.dishes.count, 4)
    }

    // MARK: - Leaving is never blocked

    func testCancelIsSafeWhenNothingIsRunning() {
        let store = makeStore(BlockingMenuResponder(), dishes: [draftDish("清蒸鱼")])

        store.cancelGeneration()

        XCTAssertFalse(store.isGenerating)
        XCTAssertEqual(store.dishes.map(\.title), ["清蒸鱼"], "An idle cancel touches nothing.")
        XCTAssertNil(store.errorMessage)
    }

    func testDiscardingADraftAlsoStopsAnInFlightRequest() async throws {
        let responder = BlockingMenuResponder()
        let store = makeStore(responder, dishes: [draftDish("清蒸鱼")])
        let kitchen = try makeKitchenStore()
        let recipes = makeRecipeStore()

        let running = Task {
            await store.generate(for: samplePlan(), kitchenStore: kitchen, recipeStore: recipes)
        }
        await fulfillment(of: [responder.didStart], timeout: 3)

        store.discard()

        XCTAssertFalse(store.isGenerating, "Discarding cannot leave a request running behind an empty draft.")
        await running.value
        XCTAssertTrue(responder.wasCancelled)
        XCTAssertTrue(store.dishes.isEmpty)
    }
}

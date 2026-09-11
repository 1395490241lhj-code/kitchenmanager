import SwiftData
import XCTest
@testable import KitchenManager

/// The receipt that makes an interrupted weekly materialization recoverable:
/// what it stores, what it means next to the canonical plans, and the durable
/// write it depends on.
@MainActor
final class WeeklyMaterializationReceiptTests: XCTestCase {
    /// Counts writes and can be failed on demand, so a test can build real
    /// state and then fail exactly the write it is about.
    private final class ToggleableWeeklyPlanPersistence: WeeklyPlanPersistenceProtocol {
        struct ExpectedFailure: Error {}
        var plan: WeeklyMealPlan?
        var shouldFail = false
        var replaceCallCount = 0

        func loadPlan() throws -> WeeklyMealPlan? { plan }
        func replacePlan(with plan: WeeklyMealPlan?) throws {
            replaceCallCount += 1
            if shouldFail { throw ExpectedFailure() }
            self.plan = plan
        }
        func deleteAll() throws { plan = nil }
    }

    // MARK: - Fixtures

    private func dish(id: String = "weekly-ai-1", title: String = "番茄炒蛋") -> WeeklyMealPlanRecipe {
        WeeklyMealPlanRecipe(
            id: id, title: title, ingredients: ["番茄 2 个"], steps: ["炒熟"],
            tags: ["家常菜"], cookingTime: 15, difficulty: "简单",
            reason: "快手", source: .ai, existingRecipeID: nil
        )
    }

    private func plan(
        receipt: WeeklyMaterializationReceipt? = nil
    ) -> WeeklyMealPlan {
        WeeklyMealPlan(
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            days: [WeeklyMealPlanDay(dayIndex: 0, meals: [
                WeeklyMealPlanMeal(mealIndex: 0, title: "晚餐", recipes: [dish()])
            ])],
            shoppingItems: [],
            servings: 2,
            summary: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_001),
            materialization: receipt
        )
    }

    private func receipt(
        state: WeeklyMaterializationState,
        planIDs: [UUID],
        completedAt: Date? = nil
    ) -> WeeklyMaterializationReceipt {
        WeeklyMaterializationReceipt(
            state: state,
            planIDs: planIDs,
            // Both arrays are parallel to planIDs: one canonical recipe and one
            // intended day per meal.
            recipeIDs: planIDs.map { _ in "weekly-ai-1" },
            planDates: planIDs.enumerated().map { index, _ in
                Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(index) * 86_400)
            },
            startedAt: Date(timeIntervalSince1970: 1_700_000_002),
            completedAt: completedAt
        )
    }

    private func meal(id: UUID) -> MealPlanItem {
        MealPlanItem(id: id, recipeID: "weekly-ai-1", recipeName: "番茄炒蛋", date: Date())
    }

    private func persistence() throws -> SwiftDataWeeklyPlanPersistence {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: InventoryRecord.self, ShoppingItemRecord.self, TodayPlanRecord.self,
            ConsumptionRecordEntity.self, WeeklyPlanRecord.self,
            configurations: configuration
        )
        return SwiftDataWeeklyPlanPersistence(container: container)
    }

    private func makeStore(
        weeklyPlan: WeeklyPlanPersistenceProtocol
    ) -> KitchenStore {
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        return KitchenStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            inventoryPersistence: bundle.inventory,
            shoppingListPersistence: bundle.shoppingList,
            todayPlanPersistence: bundle.todayPlan,
            consumptionPersistence: bundle.consumption,
            weeklyPlanPersistence: weeklyPlan,
            preparedComponentPersistence: bundle.preparedComponents,
            specialPlanPersistence: bundle.specialPlans
        )
    }

    // MARK: - Codable compatibility

    func testAMenuStoredBeforeReceiptsExistedDecodesWithoutOne() throws {
        // The exact shape a WeeklyPlanRecord payload had before this feature:
        // every key of the old model, and no materialization key at all.
        let legacy = """
        {
          "startDate": 700000000,
          "days": [],
          "shoppingItems": [],
          "servings": 2,
          "createdAt": 700000001
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(WeeklyMealPlan.self, from: legacy)

        XCTAssertNil(decoded.materialization, "an old menu is simply one that was never materialized")
        XCTAssertEqual(decoded.servings, 2)

        // A receipt written before days were recorded decodes too, with no
        // mapping. Nothing is invented for it; see the materialization tests for
        // what happens when such a receipt is still pending.
        let receiptWithoutDates = """
        {
          "state": "pending",
          "planIDs": ["E621E1F8-C36C-495A-93FC-0C247A3E6E5F"],
          "recipeIDs": ["weekly-ai-1"],
          "startedAt": 700000002
        }
        """.data(using: .utf8)!
        let legacyReceipt = try JSONDecoder().decode(
            WeeklyMaterializationReceipt.self, from: receiptWithoutDates
        )
        XCTAssertNil(legacyReceipt.planDates)
        XCTAssertEqual(legacyReceipt.planIDs.count, 1)
    }

    func testAPendingReceiptSurvivesAStoreReopen() throws {
        let store = try persistence()
        let ids = [UUID(), UUID()]
        let saved = plan(receipt: receipt(state: .pending, planIDs: ids))

        try store.replacePlan(with: saved)
        let reloaded = try XCTUnwrap(try store.loadPlan())

        XCTAssertEqual(reloaded.materialization?.state, .pending)
        XCTAssertEqual(reloaded.materialization?.planIDs, ids, "the exact ids are the whole point")
        XCTAssertEqual(
            reloaded.materialization?.planDates, saved.materialization?.planDates,
            "and the day each one belongs on, or the mapping could not be proved later"
        )
        XCTAssertEqual(reloaded.materialization?.recipeIDs.count, ids.count)
        XCTAssertNil(reloaded.materialization?.completedAt)
        XCTAssertEqual(reloaded, saved)
    }

    func testAFinalizedReceiptSurvivesAStoreReopen() throws {
        let store = try persistence()
        let ids = [UUID()]
        let completed = Date(timeIntervalSince1970: 1_700_000_500)
        let saved = plan(receipt: receipt(state: .materialized, planIDs: ids, completedAt: completed))

        try store.replacePlan(with: saved)
        let reloaded = try XCTUnwrap(try store.loadPlan())

        XCTAssertEqual(reloaded.materialization?.state, .materialized)
        XCTAssertEqual(reloaded.materialization?.completedAt, completed)
        XCTAssertEqual(reloaded.materialization?.planDates, saved.materialization?.planDates)
        XCTAssertEqual(reloaded, saved)
    }

    // MARK: - Reconciliation

    func testNoReceiptMeansNothingWasEverAttempted() {
        XCTAssertEqual(
            WeeklyMaterializationStatus.resolve(receipt: nil, plans: []),
            .notStarted
        )
    }

    func testAPendingReceiptWithNoneOfItsRowsPresentStaysRetryable() {
        let ids = [UUID(), UUID()]

        let status = WeeklyMaterializationStatus.resolve(
            receipt: receipt(state: .pending, planIDs: ids),
            plans: [meal(id: UUID())]
        )

        XCTAssertEqual(status, .pending(missing: ids), "an unrelated meal is not one of ours")
    }

    func testAPendingReceiptWithEveryRowPresentIsAlreadyDone() {
        let ids = [UUID(), UUID()]

        let status = WeeklyMaterializationStatus.resolve(
            receipt: receipt(state: .pending, planIDs: ids),
            plans: ids.map { meal(id: $0) }
        )

        XCTAssertEqual(status, .materialized, "the batch landed; only the receipt needs repairing")
    }

    func testAPendingReceiptWithSomeRowsPresentIsExceptional() {
        let present = UUID()
        let missing = UUID()

        let status = WeeklyMaterializationStatus.resolve(
            receipt: receipt(state: .pending, planIDs: [present, missing]),
            plans: [meal(id: present)]
        )

        XCTAssertEqual(status, .partiallyPresent(present: [present], missing: [missing]))
    }

    func testAFinalizedMenuStaysFinalizedAfterItsMealIsDeletedInThePlanner() {
        let ids = [UUID(), UUID()]
        let finalized = receipt(state: .materialized, planIDs: ids, completedAt: Date())

        // The member removed one of the materialized meals. That is an ordinary
        // thing to do, and it must not make the menu look unsaved again.
        let status = WeeklyMaterializationStatus.resolve(
            receipt: finalized,
            plans: [meal(id: ids[0])]
        )

        XCTAssertEqual(status, .materialized)
        XCTAssertEqual(
            WeeklyMaterializationStatus.resolve(receipt: finalized, plans: []),
            .materialized,
            "not even deleting all of them reopens a finished materialization"
        )
    }

    // MARK: - Durable draft commit

    func testCommitPersistsBeforePublishingAndWritesOnce() {
        let persistence = ToggleableWeeklyPlanPersistence()
        let store = makeStore(weeklyPlan: persistence)
        let writesBefore = persistence.replaceCallCount
        let pending = plan(receipt: receipt(state: .pending, planIDs: [UUID()]))

        XCTAssertTrue(store.commitWeeklyPlan(pending))

        XCTAssertEqual(persistence.plan, pending, "the receipt is on disk")
        XCTAssertEqual(store.weeklyPlan, pending, "and published afterwards")
        XCTAssertEqual(
            persistence.replaceCallCount - writesBefore, 1,
            "publishing must not repeat the write"
        )
    }

    func testAFailedCommitPublishesNothingAndStaysRetryable() {
        let persistence = ToggleableWeeklyPlanPersistence()
        let store = makeStore(weeklyPlan: persistence)
        let first = plan(receipt: receipt(state: .pending, planIDs: [UUID()]))
        XCTAssertTrue(store.commitWeeklyPlan(first))

        persistence.shouldFail = true
        let attempted = plan(receipt: receipt(state: .materialized, planIDs: [UUID()], completedAt: Date()))

        XCTAssertFalse(store.commitWeeklyPlan(attempted))
        XCTAssertEqual(store.weeklyPlan, first, "a failed commit never publishes what it tried to write")
        XCTAssertEqual(persistence.plan, first, "and leaves the durable menu alone")
        XCTAssertNotNil(store.weeklyPlanNotice)

        // The same attempt succeeds once the write can happen again — the
        // caller does not have to rebuild anything.
        persistence.shouldFail = false
        XCTAssertTrue(store.commitWeeklyPlan(attempted))
        XCTAssertEqual(store.weeklyPlan, attempted)
        XCTAssertEqual(persistence.plan, attempted)
    }
}


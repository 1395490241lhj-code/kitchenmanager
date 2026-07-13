import SwiftData
import XCTest
@testable import KitchenManager

@MainActor
final class WeeklyPlanPersistenceTests: XCTestCase {
    private func plan(start: Date = Date(timeIntervalSince1970: 1_700_000_000), servings: Int = 2) -> WeeklyMealPlan {
        WeeklyMealPlan(
            startDate: start,
            days: [WeeklyMealPlanDay(dayIndex: 0, meals: [
                WeeklyMealPlanMeal(mealIndex: 0, title: "午餐", recipes: [
                    WeeklyMealPlanRecipe(
                        id: "ai-weekly-1", title: "番茄炒蛋", ingredients: ["番茄 2 个", "鸡蛋 3 个"],
                        steps: ["炒熟"], tags: ["家常菜"], cookingTime: 15, difficulty: "简单",
                        reason: "快手", source: .ai, existingRecipeID: nil
                    )
                ])
            ])],
            shoppingItems: [WeeklyMealPlanShoppingItem(name: "番茄", quantityText: "2", unit: "个", reason: "周菜单")],
            servings: servings,
            summary: "测试周菜单",
            createdAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
    }

    private func persistence() throws -> SwiftDataWeeklyPlanPersistence {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: InventoryRecord.self, ShoppingItemRecord.self, TodayPlanRecord.self, ConsumptionRecordEntity.self, WeeklyPlanRecord.self, configurations: configuration)
        return SwiftDataWeeklyPlanPersistence(container: container)
    }

    func testCRUDAndFullSnapshotRoundTrip() throws {
        let store = try persistence()
        XCTAssertNil(try store.loadPlan())
        let first = plan()
        try store.replacePlan(with: first)
        XCTAssertEqual(try store.loadPlan(), first)
        let updated = plan(servings: 4)
        try store.replacePlan(with: updated)
        XCTAssertEqual(try store.loadPlan(), updated)
        try store.replacePlan(with: nil)
        XCTAssertNil(try store.loadPlan())
    }

    func testLegacyMigrationIsIdempotentAndPreservesJSON() throws {
        let store = try persistence()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let legacy = plan()
        let data = try JSONEncoder().encode(legacy)
        defaults.set(data, forKey: WeeklyPlanMigration.legacyKey)
        XCTAssertEqual(try WeeklyPlanMigration.migrateIfNeeded(userDefaults: defaults, persistence: store), legacy)
        XCTAssertEqual(try WeeklyPlanMigration.migrateIfNeeded(userDefaults: defaults, persistence: store), legacy)
        XCTAssertTrue(defaults.bool(forKey: WeeklyPlanMigration.completionKey))
        XCTAssertEqual(defaults.data(forKey: WeeklyPlanMigration.legacyKey), data)
    }
}

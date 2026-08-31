import XCTest
import SwiftData
@testable import KitchenManager

/// Adding `SpecialPlanRecord` is a real SwiftData schema change (13 -> 14).
/// These tests build an on-disk store with the pre-change model list, write
/// kitchen data, close it, and reopen with the new schema: opens, no destructive
/// reset, existing modules intact, new collection empty, then CRUD works.
@MainActor
final class SpecialPlanSchemaUpgradeTests: XCTestCase {
    private var storeURL: URL!

    override func setUpWithError() throws {
        storeURL = FileManager.default.temporaryDirectory
            .appending(path: "specialplan-upgrade-\(UUID().uuidString).store")
    }

    override func tearDownWithError() throws {
        for suffix in ["", "-shm", "-wal"] {
            let url = URL(fileURLWithPath: storeURL.path + suffix)
            try? FileManager.default.removeItem(at: url)
        }
        storeURL = nil
    }

    private func makeLegacyContainer() throws -> ModelContainer {
        try ModelContainer(
            for: InventoryRecord.self,
            ShoppingItemRecord.self,
            TodayPlanRecord.self,
            ConsumptionRecordEntity.self,
            WeeklyPlanRecord.self,
            UserRecipeRecord.self,
            RecipePreferenceRecord.self,
            SyncMetadataRecord.self,
            PendingMutationRecord.self,
            SyncCursorRecord.self,
            GuestMergeSessionRecord.self,
            InventorySyncEnrollmentRecord.self,
            PreparedComponentRecord.self,
            configurations: ModelConfiguration(url: storeURL)
        )
    }

    func testUpgradeOpensAndKeepsExistingData() throws {
        let legacy = try makeLegacyContainer()
        let plan = MealPlanItem(recipeID: "recipe", recipeName: "番茄炒蛋", servings: 2)
        try SwiftDataTodayPlanPersistence(container: legacy).replacePlans(with: [plan])

        _ = try KitchenPersistenceFactory.makeContainer(
            configuration: ModelConfiguration(url: storeURL)
        )

        // New schema: existing plan survived, new collection reads empty.
        let bundle = try KitchenPersistenceFactory.bundle(
            container: KitchenPersistenceFactory.makeContainer(
                configuration: ModelConfiguration(url: storeURL)
            )
        )
        XCTAssertEqual(try bundle.todayPlan.loadPlans(), [plan])
        XCTAssertTrue(try bundle.specialPlans.loadPlans().isEmpty)

        // CRUD through the new storage works after upgrade.
        let special = SpecialPlan(
            title: "升级后新建",
            scheduledAt: Date(),
            peopleCount: 4
        )
        try bundle.specialPlans.upsert(special)
        XCTAssertEqual(try bundle.specialPlans.loadPlans(), [special])
    }
}

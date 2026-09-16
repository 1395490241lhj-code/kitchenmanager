import XCTest
import SwiftData
@testable import KitchenManager

/// Adding the four conversation records is a real SwiftData schema change
/// (14 -> 18). These tests build an on-disk store with the pre-change model
/// list, write kitchen data, close it, and reopen with the new schema: it opens,
/// nothing is destructively reset, existing modules are intact, the new
/// collection reads empty, and conversation CRUD then works.
///
/// This is the test that has to fail loudly. Conversation history is additive
/// and disposable; Inventory, plans and Special Plans are not, and a migration
/// that took them out to add a chat log would be the worst possible trade.
@MainActor
final class AIConversationSchemaUpgradeTests: XCTestCase {
    private var storeURL: URL!

    override func setUpWithError() throws {
        storeURL = FileManager.default.temporaryDirectory
            .appending(path: "conversation-upgrade-\(UUID().uuidString).store")
    }

    override func tearDownWithError() throws {
        for suffix in ["", "-shm", "-wal"] {
            let url = URL(fileURLWithPath: storeURL.path + suffix)
            try? FileManager.default.removeItem(at: url)
        }
        storeURL = nil
    }

    /// Seeds the on-disk store through the model list exactly as it stood before
    /// conversation persistence, then releases it.
    ///
    /// The legacy container is scoped to this call on purpose: holding it open
    /// while the new schema opens the same file risks a WAL lock and would also
    /// stop being the "close it, then reopen" scenario the test claims to be.
    private func seedLegacyStore(
        _ seed: (ModelContainer) throws -> Void = { _ in }
    ) throws {
        let legacy = try ModelContainer(
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
            SpecialPlanRecord.self,
            configurations: ModelConfiguration(url: storeURL)
        )
        try seed(legacy)
    }

    private func makeCurrentBundle() throws -> KitchenPersistenceBundle {
        KitchenPersistenceFactory.bundle(
            container: try KitchenPersistenceFactory.makeContainer(
                configuration: ModelConfiguration(url: storeURL)
            )
        )
    }

    func testUpgradeKeepsExistingKitchenDataAndStartsWithNoConversations() throws {
        let plan = MealPlanItem(recipeID: "recipe", recipeName: "番茄炒蛋", plannedServings: 2)
        let item = InventoryItem(name: "青椒", quantity: 2, unit: "个", expiryDate: nil)
        let special = SpecialPlan(title: "周末聚餐", scheduledAt: Date(), peopleCount: 6)
        try seedLegacyStore { legacy in
            try SwiftDataTodayPlanPersistence(container: legacy).replacePlans(with: [plan])
            try SwiftDataInventoryPersistence(container: legacy).replaceInventory(with: [item])
            try SwiftDataSpecialPlanPersistence(container: legacy).upsert(special)
        }

        let bundle = try makeCurrentBundle()

        XCTAssertEqual(try bundle.todayPlan.loadPlans(), [plan])
        XCTAssertEqual(try bundle.inventory.loadInventory().map(\.name), ["青椒"])
        XCTAssertEqual(try bundle.specialPlans.loadPlans(), [special])
        XCTAssertTrue(try bundle.conversations.loadConversations().isEmpty)
    }

    func testConversationCRUDWorksAfterUpgrade() throws {
        try seedLegacyStore()
        let bundle = try makeCurrentBundle()

        let conversation = AIConversation(
            lifecycleType: .dailyMeal,
            entryAffinity: .dailyMeal,
            activeUntil: Date().addingTimeInterval(48 * 60 * 60)
        )
        let message = AIConversationMessage(
            conversationID: conversation.id,
            role: .user,
            state: .completed,
            contentBlocks: [.text(.init(text: "升级后新建"))],
            turnID: UUID()
        )
        try bundle.conversations.createConversationWithFirstMessage(
            conversation, message: message
        )

        let reopened = try makeCurrentBundle()
        XCTAssertEqual(try reopened.conversations.loadConversations(), [conversation])
        XCTAssertEqual(try reopened.conversations.loadMessages(conversationID: conversation.id), [message])

        try reopened.conversations.deleteConversation(id: conversation.id)
        XCTAssertTrue(try makeCurrentBundle().conversations.loadConversations().isEmpty)
    }

    /// Conversation history is additive. A conversation write that fails must not
    /// take kitchen data with it — they share a container, not a fate.
    func testKitchenDataSurvivesAConversationWriteFailure() throws {
        let container = try KitchenPersistenceFactory.makeContainer(
            configuration: ModelConfiguration(url: storeURL)
        )
        let plan = MealPlanItem(recipeID: "recipe", recipeName: "番茄炒蛋")
        try SwiftDataTodayPlanPersistence(container: container).replacePlans(with: [plan])

        let conversations = SwiftDataConversationPersistence(container: container)
        conversations.failNextSaveForTesting = NSError(domain: "test", code: 7)
        let conversation = AIConversation(activeUntil: Date().addingTimeInterval(1))
        XCTAssertThrowsError(
            try conversations.createConversationWithFirstMessage(
                conversation,
                message: AIConversationMessage(
                    conversationID: conversation.id, role: .user, state: .completed,
                    contentBlocks: [], turnID: UUID()
                )
            )
        )

        let bundle = try makeCurrentBundle()
        XCTAssertEqual(try bundle.todayPlan.loadPlans(), [plan])
        XCTAssertTrue(try bundle.conversations.loadConversations().isEmpty)
    }

    /// V1 conversation history is explicitly excluded from backup, so the payload
    /// version must not move because conversations now exist.
    func testBackupPayloadIsUnchangedByConversationPersistence() throws {
        try seedLegacyStore()
        let bundle = try makeCurrentBundle()
        let conversation = AIConversation(activeUntil: Date().addingTimeInterval(1))
        try bundle.conversations.createConversationWithFirstMessage(
            conversation,
            message: AIConversationMessage(
                conversationID: conversation.id, role: .user, state: .completed,
                contentBlocks: [.text(.init(text: "不进备份"))], turnID: UUID()
            )
        )

        let payload = KitchenBackupPayload(
            inventory: [],
            plans: [],
            shoppingItems: [],
            weeklyPlan: nil,
            consumptionRecords: []
        )
        XCTAssertEqual(payload.version, 1, "conversation history must not move the backup version")

        let object = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(payload)
        ) as? [String: Any]
        let keys = Set((object?.keys ?? [:].keys).map { $0.lowercased() })
        XCTAssertFalse(keys.isEmpty)
        XCTAssertFalse(keys.contains(where: { $0.contains("conversation") }))
    }
}

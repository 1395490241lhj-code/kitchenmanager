import XCTest
import SwiftData
@testable import KitchenManager

@MainActor
final class ConversationStoreTests: XCTestCase {

    private func makeConversation(
        id: UUID,
        title: String,
        hasUserEditedTitle: Bool,
        isPinned: Bool,
        lastActivityAt: Date,
        activeUntil: Date,
        retentionPolicyVersion: Int,
        lifecycleType: AIConversationLifecycleType,
        entryAffinity: AIConversationAffinity,
        anchorDate: Date? = nil,
        anchorEntityID: UUID? = nil
    ) -> AIConversation {
        AIConversation(
            id: id,
            createdAt: lastActivityAt,
            title: title,
            lifecycleType: lifecycleType,
            entryAffinity: entryAffinity,
            lastActivityAt: lastActivityAt,
            activeUntil: activeUntil,
            isPinned: isPinned,
            anchorDate: anchorDate,
            anchorEntityID: anchorEntityID,
            retentionPolicyVersion: retentionPolicyVersion,
            hasUserEditedTitle: hasUserEditedTitle
        )
    }

    private struct Fixture {
        let container: ModelContainer
        let persistence: SwiftDataConversationPersistence
        let store: ConversationStore
        let fixedDate: Date
        let calendar: Calendar

        @MainActor init() throws {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(secondsFromGMT: 0)!
            calendar = cal
            fixedDate = Date(timeIntervalSince1970: 1700000000)

            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            container = try KitchenPersistenceFactory.makeContainer(configuration: config)
            persistence = SwiftDataConversationPersistence(container: container)
            store = ConversationStore(
                persistence: persistence,
                retentionPolicy: .v1,
                affinityResolver: ConversationAffinityResolver(),
                calendar: cal,
                now: { Date(timeIntervalSince1970: 1700000000) }
            )
        }
    }

    // 1. load performs interrupted-message recovery first
    func testLoadPerformsInterruptedMessageRecoveryFirst() throws {
        let f = try Fixture()
        let conv = makeConversation(
            id: UUID(),
            title: "未完成对话",
            hasUserEditedTitle: false,
            isPinned: false,
            lastActivityAt: f.fixedDate,
            activeUntil: f.fixedDate.addingTimeInterval(3600),
            retentionPolicyVersion: 1,
            lifecycleType: .dailyMeal,
            entryAffinity: .dailyMeal
        )
        let streamingMsg = AIConversationMessage(
            id: UUID(),
            conversationID: conv.id,
            role: .assistant,
            createdAt: f.fixedDate,
            state: .streaming,
            contentBlocks: [.text(.init(text: "正在输出部分文字..."))],
            turnID: UUID()
        )
        // Store directly via persistence
        try f.persistence.upsertConversation(conv)
        try f.persistence.upsertMessage(streamingMsg)

        // Loading history on the store triggers recovery
        try f.store.loadHistory()

        let messages = try f.store.messages(conversationID: conv.id)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].state, .failed) // Recovered to .failed!
        XCTAssertEqual(messages[0].plainTextSummary, "正在输出部分文字...") // Partial content preserved!
    }

    // 2. empty/new draft creates no persisted conversation
    func testEmptyNewDraftCreatesNoPersistedConversation() throws {
        let f = try Fixture()
        _ = f.store.createDraft(entryContext: .home)
        _ = f.store.createDraft(entryContext: .planner(weekStart: f.fixedDate, specialPlanID: nil))

        XCTAssertEqual(f.store.conversations.count, 0)
        let loaded = try f.persistence.loadConversations()
        XCTAssertEqual(loaded.count, 0)
    }

    // 3. first non-empty user message atomically creates conversation + user message
    func testFirstNonEmptyUserMessageAtomicallyCreatesConversationAndUserMessage() throws {
        let f = try Fixture()
        let draft = f.store.createDraft(entryContext: .home)
        let userMsg = AIConversationMessage(
            id: UUID(),
            conversationID: draft.id,
            role: .user,
            createdAt: f.fixedDate,
            state: .completed,
            contentBlocks: [.text(.init(text: "今晚吃什么？"))],
            turnID: UUID()
        )

        try f.store.saveFirstMessage(conversation: draft, message: userMsg)

        XCTAssertEqual(f.store.conversations.count, 1)
        XCTAssertEqual(f.store.conversations[0].id, draft.id)
        let msgs = try f.store.messages(conversationID: draft.id)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].plainTextSummary, "今晚吃什么？")
    }

    // 4. first-write failure produces no half-created History row
    func testFirstWriteFailureProducesNoHalfCreatedHistoryRow() throws {
        let f = try Fixture()
        let draft = f.store.createDraft(entryContext: .home)
        let userMsg = AIConversationMessage(
            id: UUID(),
            conversationID: draft.id,
            role: .user,
            createdAt: f.fixedDate,
            state: .completed,
            contentBlocks: [.text(.init(text: "测试写入失败"))],
            turnID: UUID()
        )

        #if DEBUG
        f.persistence.failNextSaveForTesting = NSError(domain: "Test", code: 500)
        #endif

        XCTAssertThrowsError(try f.store.saveFirstMessage(conversation: draft, message: userMsg))

        XCTAssertEqual(f.store.conversations.count, 0)
        let loaded = try f.persistence.loadConversations()
        XCTAssertEqual(loaded.count, 0)
    }

    // 5. Home selects active dailyMeal before general
    func testHomeSelectsActiveDailyMealBeforeGeneral() throws {
        let f = try Fixture()
        let generalConv = makeConversation(
            id: UUID(),
            title: "通用对话",
            hasUserEditedTitle: false,
            isPinned: false,
            lastActivityAt: f.fixedDate,
            activeUntil: f.fixedDate.addingTimeInterval(3600),
            retentionPolicyVersion: 1,
            lifecycleType: .general,
            entryAffinity: .general
        )
        let dailyConv = makeConversation(
            id: UUID(),
            title: "每日做菜",
            hasUserEditedTitle: false,
            isPinned: false,
            lastActivityAt: f.fixedDate.addingTimeInterval(-100),
            activeUntil: f.fixedDate.addingTimeInterval(3600),
            retentionPolicyVersion: 1,
            lifecycleType: .dailyMeal,
            entryAffinity: .dailyMeal
        )
        try f.store.saveConversation(generalConv)
        try f.store.saveConversation(dailyConv)

        let best = f.store.bestActiveConversation(for: .home)
        XCTAssertEqual(best?.id, dailyConv.id) // dailyMeal score (3) > general score (2)
    }

    // 6. Home ignores weekly/special conversations
    func testHomeIgnoresWeeklyAndSpecialConversations() throws {
        let f = try Fixture()
        let weeklyConv = makeConversation(
            id: UUID(),
            title: "周计划",
            hasUserEditedTitle: false,
            isPinned: false,
            lastActivityAt: f.fixedDate,
            activeUntil: f.fixedDate.addingTimeInterval(3600),
            retentionPolicyVersion: 1,
            lifecycleType: .weeklyPlanning,
            entryAffinity: .weeklyPlanning
        )
        try f.store.saveConversation(weeklyConv)

        let best = f.store.bestActiveConversation(for: .home)
        XCTAssertNil(best)
    }

    // 7. Planner selects matching week and ignores unrelated weeks
    func testPlannerSelectsMatchingWeekAndIgnoresUnrelatedWeeks() throws {
        let f = try Fixture()
        let thisWeekStart = f.calendar.date(from: DateComponents(year: 2026, month: 9, day: 14))!
        let otherWeekStart = f.calendar.date(from: DateComponents(year: 2026, month: 9, day: 21))!

        let matchingConv = makeConversation(
            id: UUID(),
            title: "本周计划",
            hasUserEditedTitle: false,
            isPinned: false,
            lastActivityAt: f.fixedDate,
            activeUntil: f.fixedDate.addingTimeInterval(3600),
            retentionPolicyVersion: 1,
            lifecycleType: .weeklyPlanning,
            entryAffinity: .weeklyPlanning,
            anchorDate: thisWeekStart
        )
        let unrelatedConv = makeConversation(
            id: UUID(),
            title: "下周计划",
            hasUserEditedTitle: false,
            isPinned: false,
            lastActivityAt: f.fixedDate,
            activeUntil: f.fixedDate.addingTimeInterval(3600),
            retentionPolicyVersion: 1,
            lifecycleType: .weeklyPlanning,
            entryAffinity: .weeklyPlanning,
            anchorDate: otherWeekStart
        )
        try f.store.saveConversation(matchingConv)
        try f.store.saveConversation(unrelatedConv)

        let best = f.store.bestActiveConversation(for: .planner(weekStart: thisWeekStart, specialPlanID: nil))
        XCTAssertEqual(best?.id, matchingConv.id)
    }

    // 8. exact active event-anchored Special Plan can outrank matching weekly when focused plan matches
    func testExactActiveEventAnchoredSpecialPlanCanOutrankMatchingWeekly() throws {
        let f = try Fixture()
        let weekStart = f.calendar.date(from: DateComponents(year: 2026, month: 9, day: 14))!
        let eventID = UUID()

        let weeklyConv = makeConversation(
            id: UUID(),
            title: "周计划",
            hasUserEditedTitle: false,
            isPinned: false,
            lastActivityAt: f.fixedDate,
            activeUntil: f.fixedDate.addingTimeInterval(3600),
            retentionPolicyVersion: 1,
            lifecycleType: .weeklyPlanning,
            entryAffinity: .weeklyPlanning,
            anchorDate: weekStart
        )
        let specialConv = makeConversation(
            id: UUID(),
            title: "聚餐计划",
            hasUserEditedTitle: false,
            isPinned: false,
            lastActivityAt: f.fixedDate,
            activeUntil: f.fixedDate.addingTimeInterval(3600),
            retentionPolicyVersion: 1,
            lifecycleType: .specialPlan,
            entryAffinity: .specialPlan,
            anchorDate: weekStart.addingTimeInterval(86400),
            anchorEntityID: eventID
        )
        try f.store.saveConversation(weeklyConv)
        try f.store.saveConversation(specialConv)

        let best = f.store.bestActiveConversation(for: .planner(weekStart: weekStart, specialPlanID: eventID))
        XCTAssertEqual(best?.id, specialConv.id) // Special plan score (5) > weekly (4)
    }

    // 9. expired relevant conversation is NOT auto-selected as current active
    func testExpiredRelevantConversationIsNotAutoSelected() throws {
        let f = try Fixture()
        let expiredConv = makeConversation(
            id: UUID(),
            title: "过期对话",
            hasUserEditedTitle: false,
            isPinned: false,
            lastActivityAt: f.fixedDate.addingTimeInterval(-100000),
            activeUntil: f.fixedDate.addingTimeInterval(-5000), // Expired!
            retentionPolicyVersion: 1,
            lifecycleType: .dailyMeal,
            entryAffinity: .dailyMeal
        )
        try f.store.saveConversation(expiredConv)

        let best = f.store.bestActiveConversation(for: .home)
        XCTAssertNil(best) // Expired not auto-selected!
    }

    // 10. open expired history does not alter activity/expiry
    func testOpenExpiredHistoryDoesNotAlterActivityOrExpiry() throws {
        let f = try Fixture()
        let oldActivity = f.fixedDate.addingTimeInterval(-100000)
        let oldExpiry = f.fixedDate.addingTimeInterval(-5000)
        let expiredConv = makeConversation(
            id: UUID(),
            title: "历史对话",
            hasUserEditedTitle: false,
            isPinned: false,
            lastActivityAt: oldActivity,
            activeUntil: oldExpiry,
            retentionPolicyVersion: 1,
            lifecycleType: .dailyMeal,
            entryAffinity: .dailyMeal
        )
        try f.store.saveConversation(expiredConv)

        let retrieved = f.store.conversation(id: expiredConv.id)
        XCTAssertEqual(retrieved?.lastActivityAt, oldActivity)
        XCTAssertEqual(retrieved?.activeUntil, oldExpiry)
    }

    // 11. explicit reactivation refreshes expiry via policy
    func testExplicitReactivationRefreshesExpiryViaPolicy() throws {
        let f = try Fixture()
        let oldActivity = f.fixedDate.addingTimeInterval(-100000)
        let oldExpiry = f.fixedDate.addingTimeInterval(-5000)
        let expiredConv = makeConversation(
            id: UUID(),
            title: "重新激活对话",
            hasUserEditedTitle: false,
            isPinned: false,
            lastActivityAt: oldActivity,
            activeUntil: oldExpiry,
            retentionPolicyVersion: 1,
            lifecycleType: .dailyMeal,
            entryAffinity: .dailyMeal
        )
        try f.store.saveConversation(expiredConv)

        let reactivated = try f.store.reactivate(id: expiredConv.id)
        XCTAssertEqual(reactivated.lastActivityAt, f.fixedDate)
        XCTAssertEqual(reactivated.activeUntil, f.fixedDate.addingTimeInterval(48 * 3600))
        XCTAssertFalse(reactivated.isExpired(now: f.fixedDate))
    }

    // 12. pinned conversation is non-expired
    func testPinnedConversationIsNonExpired() throws {
        let f = try Fixture()
        let conv = makeConversation(
            id: UUID(),
            title: "置顶对话",
            hasUserEditedTitle: false,
            isPinned: false,
            lastActivityAt: f.fixedDate.addingTimeInterval(-100000),
            activeUntil: f.fixedDate.addingTimeInterval(-5000),
            retentionPolicyVersion: 1,
            lifecycleType: .dailyMeal,
            entryAffinity: .dailyMeal
        )
        try f.store.saveConversation(conv)

        let pinned = try f.store.setPinned(id: conv.id, isPinned: true)
        XCTAssertTrue(pinned.isPinned)
        XCTAssertFalse(pinned.isExpired(now: f.fixedDate)) // Pinned is not expired
    }

    // 13. unpin does not manufacture new activity/expiry
    func testUnpinDoesNotManufactureNewActivityOrExpiry() throws {
        let f = try Fixture()
        let pastExpiry = f.fixedDate.addingTimeInterval(-5000)
        let conv = makeConversation(
            id: UUID(),
            title: "置顶后取消",
            hasUserEditedTitle: false,
            isPinned: true,
            lastActivityAt: f.fixedDate.addingTimeInterval(-100000),
            activeUntil: pastExpiry, // Truthful past expiry
            retentionPolicyVersion: 1,
            lifecycleType: .dailyMeal,
            entryAffinity: .dailyMeal
        )
        try f.store.saveConversation(conv)

        let unpinned = try f.store.setPinned(id: conv.id, isPinned: false)
        XCTAssertFalse(unpinned.isPinned)
        XCTAssertEqual(unpinned.activeUntil, pastExpiry)
        XCTAssertTrue(unpinned.isExpired(now: f.fixedDate)) // Immediately expired as truthful activeUntil passed!
    }

    // 14. user rename marks hasUserEditedTitle
    func testUserRenameMarksHasUserEditedTitle() throws {
        let f = try Fixture()
        let conv = makeConversation(
            id: UUID(),
            title: "默认对话",
            hasUserEditedTitle: false,
            isPinned: false,
            lastActivityAt: f.fixedDate,
            activeUntil: f.fixedDate.addingTimeInterval(3600),
            retentionPolicyVersion: 1,
            lifecycleType: .dailyMeal,
            entryAffinity: .dailyMeal
        )
        try f.store.saveConversation(conv)

        let renamed = try f.store.rename(id: conv.id, newTitle: "我的自定义菜谱对话")
        XCTAssertEqual(renamed.title, "我的自定义菜谱对话")
        XCTAssertTrue(renamed.hasUserEditedTitle)
    }

    // 15. generated-title candidate cannot overwrite user rename
    func testGeneratedTitleCandidateCannotOverwriteUserRename() throws {
        let f = try Fixture()
        let conv = makeConversation(
            id: UUID(),
            title: "用户自定义标题",
            hasUserEditedTitle: true,
            isPinned: false,
            lastActivityAt: f.fixedDate,
            activeUntil: f.fixedDate.addingTimeInterval(3600),
            retentionPolicyVersion: 1,
            lifecycleType: .dailyMeal,
            entryAffinity: .dailyMeal
        )
        try f.store.saveConversation(conv)

        var current = f.store.conversation(id: conv.id)!
        current.applyGeneratedTitle("模型生成的标题")
        XCTAssertEqual(current.title, "用户自定义标题") // Discarded!
    }

    // 16. deleting conversation removes its local conversation rows
    func testDeletingConversationRemovesItsLocalRows() throws {
        let f = try Fixture()
        let conv = makeConversation(
            id: UUID(),
            title: "要删除的对话",
            hasUserEditedTitle: false,
            isPinned: false,
            lastActivityAt: f.fixedDate,
            activeUntil: f.fixedDate.addingTimeInterval(3600),
            retentionPolicyVersion: 1,
            lifecycleType: .dailyMeal,
            entryAffinity: .dailyMeal
        )
        let msg = AIConversationMessage(
            id: UUID(),
            conversationID: conv.id,
            role: .user,
            createdAt: f.fixedDate,
            state: .completed,
            contentBlocks: [.text(.init(text: "消息"))],
            turnID: UUID()
        )
        try f.store.saveFirstMessage(conversation: conv, message: msg)

        try f.store.deleteConversation(id: conv.id)

        XCTAssertEqual(f.store.conversations.count, 0)
        let loadedMsgs = try f.store.messages(conversationID: conv.id)
        XCTAssertEqual(loadedMsgs.count, 0)
    }

    // 17. deleting conversation does NOT undo already-applied business state
    func testDeletingConversationDoesNotUndoAlreadyAppliedBusinessState() throws {
        let f = try Fixture()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let kitchenStore = KitchenStore(userDefaults: defaults)
        let recipeStore = RecipeStore(userDefaults: defaults)
        let recipe = Recipe(id: "r-persist", title: "红烧肉", cookingTime: 30, difficulty: nil, tags: [], ingredients: ["五花肉"], steps: ["做"])
        try recipeStore.saveUserRecipe(recipe)
        _ = kitchenStore.addPlan(recipe: recipe, on: f.fixedDate, calendar: f.calendar)

        XCTAssertEqual(kitchenStore.plans.count, 1)

        let conv = makeConversation(
            id: UUID(),
            title: "对话",
            hasUserEditedTitle: false,
            isPinned: false,
            lastActivityAt: f.fixedDate,
            activeUntil: f.fixedDate.addingTimeInterval(3600),
            retentionPolicyVersion: 1,
            lifecycleType: .dailyMeal,
            entryAffinity: .dailyMeal
        )
        try f.store.saveConversation(conv)
        try f.store.deleteConversation(id: conv.id)

        // Deleting conversation does not change KitchenStore plans
        XCTAssertEqual(kitchenStore.plans.count, 1)
        XCTAssertEqual(kitchenStore.plans.first?.recipeName, "红烧肉")
    }

    // 18. deleteAll removes all conversation history
    func testDeleteAllRemovesAllConversationHistory() throws {
        let f = try Fixture()
        let c1 = makeConversation(id: UUID(), title: "C1", hasUserEditedTitle: false, isPinned: false, lastActivityAt: f.fixedDate, activeUntil: f.fixedDate.addingTimeInterval(3600), retentionPolicyVersion: 1, lifecycleType: .dailyMeal, entryAffinity: .dailyMeal)
        let c2 = makeConversation(id: UUID(), title: "C2", hasUserEditedTitle: false, isPinned: false, lastActivityAt: f.fixedDate, activeUntil: f.fixedDate.addingTimeInterval(3600), retentionPolicyVersion: 1, lifecycleType: .dailyMeal, entryAffinity: .dailyMeal)
        try f.store.saveConversation(c1)
        try f.store.saveConversation(c2)

        try f.store.wipeAll()

        XCTAssertEqual(f.store.conversations.count, 0)
        let loaded = try f.persistence.loadConversations()
        XCTAssertEqual(loaded.count, 0)
    }

    // 19. explicit Special Plan draft is event-anchored
    func testExplicitSpecialPlanDraftIsEventAnchored() throws {
        let f = try Fixture()
        let planID = UUID()
        let scheduledAt = f.fixedDate.addingTimeInterval(86400 * 3)

        let draft = f.store.createSpecialPlanDraft(planID: planID, scheduledAt: scheduledAt)

        XCTAssertEqual(draft.lifecycleType, .specialPlan)
        XCTAssertEqual(draft.entryAffinity, .specialPlan)
        XCTAssertEqual(draft.anchorEntityID, planID)
        XCTAssertEqual(draft.anchorDate, scheduledAt)
        // Expiry uses the later of activity + 48h or event + 24h
        let expectedExpiry = max(f.fixedDate.addingTimeInterval(48 * 3600), scheduledAt.addingTimeInterval(24 * 3600))
        XCTAssertEqual(draft.activeUntil, expectedExpiry)
    }

    // 20. history ordering is deterministic for equal timestamps
    func testHistoryOrderingIsDeterministicForEqualTimestamps() throws {
        let f = try Fixture()
        let id1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let id2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let c1 = makeConversation(id: id1, title: "C1", hasUserEditedTitle: false, isPinned: false, lastActivityAt: f.fixedDate, activeUntil: f.fixedDate.addingTimeInterval(3600), retentionPolicyVersion: 1, lifecycleType: .dailyMeal, entryAffinity: .dailyMeal)
        let c2 = makeConversation(id: id2, title: "C2", hasUserEditedTitle: false, isPinned: false, lastActivityAt: f.fixedDate, activeUntil: f.fixedDate.addingTimeInterval(3600), retentionPolicyVersion: 1, lifecycleType: .dailyMeal, entryAffinity: .dailyMeal)

        try f.store.saveConversation(c1)
        try f.store.saveConversation(c2)

        let history = f.store.conversations
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0].id, id2) // Larger uuid string comes first
        XCTAssertEqual(history[1].id, id1)
    }

    // 21. reactivation rereads authoritative persisted metadata rather than using stale cache
    func testReactivationRereadsAuthoritativePersistedMetadata() throws {
        let f = try Fixture()
        let oldActivity = f.fixedDate.addingTimeInterval(-100000)
        let oldExpiry = f.fixedDate.addingTimeInterval(-5000)
        let conv = makeConversation(
            id: UUID(),
            title: "初始标题",
            hasUserEditedTitle: false,
            isPinned: false,
            lastActivityAt: oldActivity,
            activeUntil: oldExpiry,
            retentionPolicyVersion: 1,
            lifecycleType: .dailyMeal,
            entryAffinity: .dailyMeal
        )
        try f.store.saveConversation(conv)

        // Mutate authoritative persisted record outside this store's in-memory cache
        var mutated = conv
        mutated.title = "已在外部修改的标题"
        mutated.summary = "外部生成的摘要"
        try f.persistence.upsertConversation(mutated)

        // Reactivate through store
        let reactivated = try f.store.reactivate(id: conv.id)
        XCTAssertEqual(reactivated.title, "已在外部修改的标题")
        XCTAssertEqual(reactivated.summary, "外部生成的摘要")
    }
}

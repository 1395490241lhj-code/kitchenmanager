import XCTest
import SwiftData
@testable import KitchenManager

/// Local Kitchen AI conversation persistence.
///
/// Every test reads back through a *second* persistence instance over the same
/// container, because an object still sitting in one `ModelContext`'s cache
/// proves nothing about what was actually stored.
@MainActor
final class ConversationPersistenceTests: XCTestCase {
    private var container: ModelContainer!

    override func setUpWithError() throws {
        container = try KitchenPersistenceFactory.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    override func tearDownWithError() throws {
        container = nil
    }

    private func makePersistence() -> SwiftDataConversationPersistence {
        SwiftDataConversationPersistence(container: container)
    }

    private func makeConversation(
        id: UUID = UUID(),
        lifecycleType: AIConversationLifecycleType = .dailyMeal
    ) -> AIConversation {
        AIConversation(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lifecycleType: lifecycleType,
            entryAffinity: AIConversationAffinity(lifecycleType: lifecycleType),
            lastActivityAt: Date(timeIntervalSince1970: 1_700_000_000),
            activeUntil: Date(timeIntervalSince1970: 1_700_172_800)
        )
    }

    private func makeMessage(
        conversationID: UUID,
        role: AIConversationRole = .user,
        state: AIConversationMessageState = .completed,
        blocks: [AIContentBlock] = [.text(.init(text: "今晚吃什么"))]
    ) -> AIConversationMessage {
        AIConversationMessage(
            conversationID: conversationID,
            role: role,
            createdAt: Date(timeIntervalSince1970: 1_700_000_001),
            state: state,
            contentBlocks: blocks,
            turnID: UUID()
        )
    }

    // MARK: - Atomic first message

    /// An empty draft must never appear in History, so the conversation only
    /// becomes durable together with its first user message.
    func testFirstMessageCreatesConversationAndMessageTogether() throws {
        let conversation = makeConversation()
        let message = makeMessage(conversationID: conversation.id)
        try makePersistence().createConversationWithFirstMessage(conversation, message: message)

        let reader = makePersistence()
        XCTAssertEqual(try reader.loadConversations(), [conversation])
        XCTAssertEqual(try reader.loadMessages(conversationID: conversation.id), [message])
    }

    /// The whole point of one logical write: a failure leaves no orphan
    /// conversation row behind for History to show.
    func testFailedFirstMessageWritePersistsNothing() throws {
        let persistence = makePersistence()
        persistence.failNextSaveForTesting = NSError(domain: "test", code: 1)
        let conversation = makeConversation()

        XCTAssertThrowsError(
            try persistence.createConversationWithFirstMessage(
                conversation, message: makeMessage(conversationID: conversation.id)
            )
        )

        let reader = makePersistence()
        XCTAssertTrue(try reader.loadConversations().isEmpty)
        XCTAssertTrue(try reader.loadMessages(conversationID: conversation.id).isEmpty)
    }

    /// Rollback, observed where it actually matters: on the instance that
    /// failed. A fresh instance would re-fetch from the store and pass either
    /// way. Without `context.rollback()`, this context keeps the failed
    /// attempt's pending inserts, and the next write re-inserts under the same
    /// unique id.
    func testFailedWriteLeavesTheFailingInstanceUsable() throws {
        let persistence = makePersistence()
        persistence.failNextSaveForTesting = NSError(domain: "test", code: 1)
        let conversation = makeConversation()
        let message = makeMessage(conversationID: conversation.id)

        XCTAssertThrowsError(
            try persistence.createConversationWithFirstMessage(conversation, message: message)
        )
        XCTAssertTrue(try persistence.loadConversations().isEmpty)

        // The compensating retry must succeed through the same instance.
        try persistence.createConversationWithFirstMessage(conversation, message: message)
        XCTAssertEqual(try persistence.loadConversations(), [conversation])
        XCTAssertEqual(try makePersistence().loadMessages(conversationID: conversation.id), [message])
    }

    /// Atomicity is not the whole invariant. Storing conversation A together
    /// with a message belonging to conversation B succeeds durably and leaves
    /// History showing A with an empty transcript, so the ids are checked before
    /// anything is inserted — and not silently corrected, which would hide the
    /// caller's bug.
    func testFirstMessageBelongingToAnotherConversationIsRejected() throws {
        let persistence = makePersistence()
        let conversation = makeConversation()
        let foreign = makeMessage(conversationID: UUID())

        XCTAssertThrowsError(
            try persistence.createConversationWithFirstMessage(conversation, message: foreign)
        ) { error in
            XCTAssertEqual(
                error as? ConversationPersistenceError, .firstMessageConversationMismatch
            )
        }

        let reader = makePersistence()
        XCTAssertTrue(try reader.loadConversations().isEmpty)
        XCTAssertTrue(try reader.loadMessages(conversationID: conversation.id).isEmpty)
        XCTAssertTrue(try reader.loadMessages(conversationID: foreign.conversationID).isEmpty)
    }

    /// A conversation becomes durable on its first *user* message. An assistant
    /// message arriving first would mean a turn ran before anything was asked.
    func testFirstMessageMustComeFromTheUser() throws {
        let persistence = makePersistence()
        let conversation = makeConversation()

        XCTAssertThrowsError(
            try persistence.createConversationWithFirstMessage(
                conversation,
                message: makeMessage(conversationID: conversation.id, role: .assistant)
            )
        ) { error in
            XCTAssertEqual(error as? ConversationPersistenceError, .firstMessageMustBeFromUser)
        }
        XCTAssertTrue(try makePersistence().loadConversations().isEmpty)
    }

    /// `upsertConversation` is what carries rename, pin, `lastActivityAt` and
    /// `activeUntil` forward. If it inserted instead of updating, or dropped a
    /// scalar in `update(from:)`, History grouping and affinity would both be
    /// wrong while every other test stayed green.
    func testUpsertConversationUpdatesInPlaceAndCarriesEveryScalarForward() throws {
        var conversation = makeConversation()
        let persistence = makePersistence()
        try persistence.createConversationWithFirstMessage(
            conversation, message: makeMessage(conversationID: conversation.id)
        )

        conversation.applyUserTitle("周三聚餐")
        conversation.isPinned = true
        conversation.entryAffinity = .weeklyPlanning
        conversation.lastActivityAt = Date(timeIntervalSince1970: 1_700_500_000)
        conversation.activeUntil = Date(timeIntervalSince1970: 1_700_700_000)
        conversation.summary = "讨论了本周菜单"
        try persistence.upsertConversation(conversation)

        let stored = try makePersistence().loadConversations()
        XCTAssertEqual(stored, [conversation], "upsert must update, not insert a second row")

        // The scalar query columns are what History and affinity read, so they
        // have to move with the payload rather than keep their created values.
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<ConversationRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.isPinned, true)
        XCTAssertEqual(records.first?.affinityRawValue, AIConversationAffinity.weeklyPlanning.rawValue)
        XCTAssertEqual(records.first?.lastActivityAt, conversation.lastActivityAt)
        XCTAssertEqual(records.first?.activeUntil, conversation.activeUntil)
    }

    /// An upserted message must update its row too, not accumulate revisions.
    func testUpsertMessageUpdatesInPlace() throws {
        let conversation = makeConversation()
        let persistence = makePersistence()
        try persistence.createConversationWithFirstMessage(
            conversation, message: makeMessage(conversationID: conversation.id)
        )
        var assistant = makeMessage(
            conversationID: conversation.id, role: .assistant, state: .streaming,
            blocks: [.text(.init(text: "我先"))]
        )
        try persistence.upsertMessage(assistant)
        assistant.state = .completed
        assistant.contentBlocks = [.text(.init(text: "我先看看库存"))]
        try persistence.upsertMessage(assistant)

        let messages = try makePersistence().loadMessages(conversationID: conversation.id)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.last, assistant)
    }

    // MARK: - Round trips

    func testMessageBlockOrderSurvivesReload() throws {
        let conversation = makeConversation()
        let blocks: [AIContentBlock] = [
            .text(.init(text: "先看库存")),
            .contextResult(.init(title: "快过期", rows: [.init(label: "青椒", detail: "明天")])),
            .recipe(.init(
                recipe: Recipe(
                    id: "r-1", title: "清炒时蔬", cookingTime: 10, difficulty: "简单",
                    tags: [], ingredients: ["青椒 1 个"], steps: ["炒"]
                ),
                isTransient: true
            )),
            .text(.init(text: "要加入今晚吗？"))
        ]
        let message = makeMessage(
            conversationID: conversation.id, role: .assistant, blocks: blocks
        )
        let persistence = makePersistence()
        try persistence.createConversationWithFirstMessage(
            conversation, message: makeMessage(conversationID: conversation.id)
        )
        try persistence.upsertMessage(message)

        let reloaded = try makePersistence().loadMessages(conversationID: conversation.id)
        XCTAssertEqual(reloaded.count, 2)
        XCTAssertEqual(reloaded.last?.contentBlocks, blocks)
    }

    func testActionIdempotencyKeyLookupSurvivesReload() throws {
        let conversation = makeConversation()
        let persistence = makePersistence()
        try persistence.createConversationWithFirstMessage(
            conversation, message: makeMessage(conversationID: conversation.id)
        )

        let action = AIConversationActionRecord(
            conversationID: conversation.id,
            turnID: UUID(),
            actionType: .addRecipeToTonight,
            idempotencyKey: "stable-key-1",
            status: .succeeded,
            relatedEntityIDs: ["plan-1"],
            undoReference: .tonightPlan(
                plan: MealPlanItem(recipeID: "r-1", recipeName: "清炒时蔬"),
                createdRecipeIDs: ["r-1"]
            )
        )
        try persistence.upsertAction(action)

        let reader = makePersistence()
        XCTAssertEqual(try reader.action(idempotencyKey: "stable-key-1"), action)
        XCTAssertNil(try reader.action(idempotencyKey: "never-written"))
        XCTAssertEqual(try reader.loadActions(conversationID: conversation.id), [action])
    }

    func testActionUpsertUpdatesStatusInPlace() throws {
        let conversation = makeConversation()
        let persistence = makePersistence()
        try persistence.createConversationWithFirstMessage(
            conversation, message: makeMessage(conversationID: conversation.id)
        )
        var action = AIConversationActionRecord(
            conversationID: conversation.id,
            turnID: UUID(),
            actionType: .replacePlannedMeal,
            idempotencyKey: "key-2",
            status: .awaitingConfirmation
        )
        try persistence.upsertAction(action)
        action.status = .succeeded
        try persistence.upsertAction(action)

        let stored = try makePersistence().loadActions(conversationID: conversation.id)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.status, .succeeded)
    }

    /// What a colliding idempotency key actually does.
    ///
    /// The column is not unique on purpose: SwiftData resolves a unique conflict
    /// by upserting, which would silently overwrite the first action's undo
    /// receipt — the only way to reverse a mutation that already happened. So a
    /// duplicate is stored and both rows survive.
    func testCollidingIdempotencyKeyKeepsBothRows() throws {
        let conversation = makeConversation()
        let persistence = makePersistence()
        try persistence.createConversationWithFirstMessage(
            conversation, message: makeMessage(conversationID: conversation.id)
        )

        let first = AIConversationActionRecord(
            conversationID: conversation.id,
            turnID: UUID(),
            actionType: .addRecipeToTonight,
            idempotencyKey: "collision",
            status: .succeeded,
            createdAt: Date(timeIntervalSince1970: 1_700_000_500),
            undoReference: .tonightPlan(
                plan: MealPlanItem(recipeID: "r-1", recipeName: "清炒时蔬"),
                createdRecipeIDs: []
            )
        )
        let second = AIConversationActionRecord(
            conversationID: conversation.id,
            turnID: UUID(),
            actionType: .addRecipeToTonight,
            idempotencyKey: "collision",
            status: .failed,
            createdAt: Date(timeIntervalSince1970: 1_700_000_900)
        )
        try persistence.upsertAction(first)
        try persistence.upsertAction(second)

        let reader = makePersistence()
        XCTAssertEqual(try reader.loadActions(conversationID: conversation.id).count, 2)
        let resolved = try reader.action(idempotencyKey: "collision")
        XCTAssertEqual(resolved, first)
        XCTAssertNotNil(
            resolved?.undoReference,
            "the first action's undo receipt must not be overwritten by a colliding key"
        )
    }

    /// Retrying a failed action produces exactly this history, so the guard has
    /// to answer with the attempt that actually reached the kitchen.
    ///
    /// Answering with the earlier failed row would let a third retry repeat a
    /// mutation that already happened, which is the one thing idempotency exists
    /// to prevent.
    func testRetryGuardPrefersTheAttemptThatActuallySucceeded() throws {
        let conversation = makeConversation()
        let persistence = makePersistence()
        try persistence.createConversationWithFirstMessage(
            conversation, message: makeMessage(conversationID: conversation.id)
        )

        let failed = AIConversationActionRecord(
            conversationID: conversation.id, turnID: UUID(),
            actionType: .addRecipeToTonight, idempotencyKey: "retried",
            status: .failed, createdAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        let succeeded = AIConversationActionRecord(
            conversationID: conversation.id, turnID: UUID(),
            actionType: .addRecipeToTonight, idempotencyKey: "retried",
            status: .succeeded, createdAt: Date(timeIntervalSince1970: 1_700_000_900),
            undoReference: .tonightPlan(
                plan: MealPlanItem(recipeID: "r-1", recipeName: "清炒时蔬"),
                createdRecipeIDs: []
            )
        )
        try persistence.upsertAction(failed)
        try persistence.upsertAction(succeeded)

        XCTAssertEqual(try makePersistence().action(idempotencyKey: "retried"), succeeded)
    }

    /// An undone action is the key's current state. The coordinator has to see
    /// that rather than a stale failed attempt to decide what a later request means.
    func testRetryGuardTreatsAnUndoneActionAsHavingRun() throws {
        let conversation = makeConversation()
        let persistence = makePersistence()
        try persistence.createConversationWithFirstMessage(
            conversation, message: makeMessage(conversationID: conversation.id)
        )
        try persistence.upsertAction(
            AIConversationActionRecord(
                conversationID: conversation.id, turnID: UUID(),
                actionType: .addShoppingItems, idempotencyKey: "undone-key",
                status: .failed, createdAt: Date(timeIntervalSince1970: 1_700_000_100)
            )
        )
        let undone = AIConversationActionRecord(
            conversationID: conversation.id, turnID: UUID(),
            actionType: .addShoppingItems, idempotencyKey: "undone-key",
            status: .undone, createdAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        try persistence.upsertAction(undone)

        XCTAssertEqual(try makePersistence().action(idempotencyKey: "undone-key"), undone)
    }

    /// The lifecycle that makes recency, not insertion order, the right question:
    /// the user undid an action and then deliberately did the same thing again.
    ///
    /// Answering with the older undone row would read as "not currently applied"
    /// and let a later retry duplicate the second, real mutation.
    func testRetryGuardPrefersALaterReExecutionOverAnEarlierUndo() throws {
        let conversation = makeConversation()
        let persistence = makePersistence()
        try persistence.createConversationWithFirstMessage(
            conversation, message: makeMessage(conversationID: conversation.id)
        )

        let undone = AIConversationActionRecord(
            conversationID: conversation.id, turnID: UUID(),
            actionType: .addRecipeToTonight, idempotencyKey: "re-executed",
            status: .undone, createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let reExecuted = AIConversationActionRecord(
            conversationID: conversation.id, turnID: UUID(),
            actionType: .addRecipeToTonight, idempotencyKey: "re-executed",
            status: .succeeded, createdAt: Date(timeIntervalSince1970: 1_700_000_900),
            undoReference: .tonightPlan(
                plan: MealPlanItem(recipeID: "r-1", recipeName: "清炒时蔬"),
                createdRecipeIDs: []
            )
        )
        try persistence.upsertAction(undone)
        try persistence.upsertAction(reExecuted)

        let resolved = try makePersistence().action(idempotencyKey: "re-executed")
        XCTAssertEqual(resolved, reExecuted)
        XCTAssertEqual(resolved?.status, .succeeded)
        XCTAssertNotNil(
            resolved?.undoReference,
            "the live mutation's receipt is the one Undo would need"
        )
    }

    /// A succeeded action that the user then undid: the key's current state is
    /// undone, not succeeded.
    func testRetryGuardReportsAnUndoThatFollowedASuccess() throws {
        let conversation = makeConversation()
        let persistence = makePersistence()
        try persistence.createConversationWithFirstMessage(
            conversation, message: makeMessage(conversationID: conversation.id)
        )
        try persistence.upsertAction(
            AIConversationActionRecord(
                conversationID: conversation.id, turnID: UUID(),
                actionType: .addShoppingItems, idempotencyKey: "then-undone",
                status: .succeeded, createdAt: Date(timeIntervalSince1970: 1_700_000_100)
            )
        )
        let undone = AIConversationActionRecord(
            conversationID: conversation.id, turnID: UUID(),
            actionType: .addShoppingItems, idempotencyKey: "then-undone",
            status: .undone, createdAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        try persistence.upsertAction(undone)

        XCTAssertEqual(try makePersistence().action(idempotencyKey: "then-undone"), undone)
    }

    /// With nothing terminal yet, the guard is still deterministic: the most
    /// recent attempt, never an arbitrary row.
    func testRetryGuardIsDeterministicWhenNothingHasSucceededYet() throws {
        let conversation = makeConversation()
        let persistence = makePersistence()
        try persistence.createConversationWithFirstMessage(
            conversation, message: makeMessage(conversationID: conversation.id)
        )
        let latest = AIConversationActionRecord(
            conversationID: conversation.id, turnID: UUID(),
            actionType: .replacePlannedMeal, idempotencyKey: "pending-key",
            status: .failed, createdAt: Date(timeIntervalSince1970: 1_700_000_800)
        )
        try persistence.upsertAction(latest)
        try persistence.upsertAction(
            AIConversationActionRecord(
                conversationID: conversation.id, turnID: UUID(),
                actionType: .replacePlannedMeal, idempotencyKey: "pending-key",
                status: .failed, createdAt: Date(timeIntervalSince1970: 1_700_000_100)
            )
        )

        XCTAssertEqual(try makePersistence().action(idempotencyKey: "pending-key"), latest)
    }

    func testContextSnapshotsRoundTrip() throws {
        let conversation = makeConversation()
        let persistence = makePersistence()
        try persistence.createConversationWithFirstMessage(
            conversation, message: makeMessage(conversationID: conversation.id)
        )
        let snapshot = AIContextSnapshot(
            turnID: UUID(),
            readAt: Date(timeIntervalSince1970: 1_700_000_100),
            contextKinds: [.inventory, .tonightPlan],
            relatedEntityIDs: ["plan-1"],
            sourceFingerprints: ["inventory:7"]
        )
        try persistence.upsertContextSnapshot(snapshot, conversationID: conversation.id)

        // Snapshots are provenance, so they are read back through the record
        // rather than through a conversation-facing API that could be mistaken
        // for a source of kitchen truth.
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<ConversationContextSnapshotRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(try records.first?.snapshot(), snapshot)
    }

    // MARK: - Deletion

    func testDeletingAConversationRemovesOnlyItsOwnRows() throws {
        let kept = makeConversation()
        let deleted = makeConversation()
        let persistence = makePersistence()
        try persistence.createConversationWithFirstMessage(
            kept, message: makeMessage(conversationID: kept.id)
        )
        try persistence.createConversationWithFirstMessage(
            deleted, message: makeMessage(conversationID: deleted.id)
        )
        try persistence.upsertAction(
            AIConversationActionRecord(
                conversationID: deleted.id, turnID: UUID(),
                actionType: .addShoppingItems, idempotencyKey: "gone", status: .succeeded
            )
        )
        try persistence.upsertAction(
            AIConversationActionRecord(
                conversationID: kept.id, turnID: UUID(),
                actionType: .addShoppingItems, idempotencyKey: "stays", status: .succeeded
            )
        )
        let keptSnapshot = AIContextSnapshot(
            turnID: UUID(), readAt: Date(), contextKinds: [.plannerWeek]
        )
        try persistence.upsertContextSnapshot(keptSnapshot, conversationID: kept.id)
        try persistence.upsertContextSnapshot(
            AIContextSnapshot(turnID: UUID(), readAt: Date(), contextKinds: [.inventory]),
            conversationID: deleted.id
        )

        try persistence.deleteConversation(id: deleted.id)

        let reader = makePersistence()
        XCTAssertEqual(try reader.loadConversations().map(\.id), [kept.id])
        XCTAssertTrue(try reader.loadMessages(conversationID: deleted.id).isEmpty)
        XCTAssertEqual(try reader.loadMessages(conversationID: kept.id).count, 1)
        XCTAssertNil(try reader.action(idempotencyKey: "gone"))
        XCTAssertNotNil(try reader.action(idempotencyKey: "stays"))

        // Only the deleted conversation's provenance rows go; the other
        // conversation's must survive.
        let context = ModelContext(container)
        let snapshots = try context.fetch(FetchDescriptor<ConversationContextSnapshotRecord>())
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(try snapshots.first?.snapshot(), keptSnapshot)
        XCTAssertEqual(snapshots.first?.conversationID, kept.id)
    }

    // MARK: - Interrupted turns

    /// A reply the app died in the middle of is a failed reply, not a finished
    /// one. Recovery keeps the text that actually arrived.
    func testInterruptedStreamingMessagesBecomeFailedOnRecovery() throws {
        let conversation = makeConversation()
        let persistence = makePersistence()
        try persistence.createConversationWithFirstMessage(
            conversation, message: makeMessage(conversationID: conversation.id)
        )
        let streaming = makeMessage(
            conversationID: conversation.id,
            role: .assistant,
            state: .streaming,
            blocks: [.text(.init(text: "我先看看库存"))]
        )
        let pending = makeMessage(
            conversationID: conversation.id, role: .assistant, state: .pending, blocks: []
        )
        try persistence.upsertMessage(streaming)
        try persistence.upsertMessage(pending)

        let recovered = try makePersistence().recoverInterruptedMessages(now: Date())
        XCTAssertEqual(recovered, 2)

        let messages = try makePersistence().loadMessages(conversationID: conversation.id)
        let assistantStates = messages.filter { $0.role == .assistant }.map(\.state)
        XCTAssertEqual(assistantStates, [.failed, .failed])
        XCTAssertEqual(
            messages.first(where: { $0.id == streaming.id })?.contentBlocks,
            streaming.contentBlocks,
            "recovery must keep the text that had already arrived"
        )
        XCTAssertEqual(
            messages.first(where: { $0.role == .user })?.state,
            .completed,
            "recovery must not touch completed messages"
        )
    }

    func testRecoveryIsANoOpWhenNothingWasInterrupted() throws {
        let conversation = makeConversation()
        let persistence = makePersistence()
        try persistence.createConversationWithFirstMessage(
            conversation, message: makeMessage(conversationID: conversation.id)
        )
        XCTAssertEqual(try persistence.recoverInterruptedMessages(now: Date()), 0)
    }

    // MARK: - Bundle wiring

    func testSharedBundleExposesConversationPersistence() throws {
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        XCTAssertTrue(try bundle.conversations.loadConversations().isEmpty)

        let conversation = makeConversation()
        try bundle.conversations.createConversationWithFirstMessage(
            conversation, message: makeMessage(conversationID: conversation.id)
        )
        XCTAssertEqual(try bundle.conversations.loadConversations().count, 1)
    }

    /// The wipe the account-deletion and sign-out paths need. Conversation
    /// history quotes inventory, plans and the user's own prompts, so it has to
    /// be removable by the same request that deletes everything else.
    func testDeleteAllRemovesEveryConversationRow() throws {
        let persistence = makePersistence()
        for _ in 0..<2 {
            let conversation = makeConversation()
            try persistence.createConversationWithFirstMessage(
                conversation, message: makeMessage(conversationID: conversation.id)
            )
            try persistence.upsertAction(
                AIConversationActionRecord(
                    conversationID: conversation.id, turnID: UUID(),
                    actionType: .addShoppingItems,
                    idempotencyKey: "key-\(conversation.id.uuidString)", status: .succeeded
                )
            )
            try persistence.upsertContextSnapshot(
                AIContextSnapshot(turnID: UUID(), readAt: Date(), contextKinds: [.inventory]),
                conversationID: conversation.id
            )
        }

        try persistence.deleteAll()

        let reader = makePersistence()
        XCTAssertTrue(try reader.loadConversations().isEmpty)
        let context = ModelContext(container)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ConversationMessageRecord>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ConversationActionRecord>()).isEmpty)
        XCTAssertTrue(
            try context.fetch(FetchDescriptor<ConversationContextSnapshotRecord>()).isEmpty
        )
    }
}

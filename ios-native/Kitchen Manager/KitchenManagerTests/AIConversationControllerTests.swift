import XCTest
import SwiftData
@testable import KitchenManager

@MainActor
final class AIConversationControllerTests: XCTestCase {
    private final class Clock {
        var date: Date
        init(_ date: Date) { self.date = date }
    }
    private final class PersistenceSpy: ConversationPersistenceProtocol {
        let base: SwiftDataConversationPersistence
        var failCreate = false
        var failSaveConversation = false
        var failSaveAssistant = false
        var failLoadConversationsAfterFirstWrite = false
        var upsertMessageCount = 0
        var deleteAllCount = 0
        var snapshots: [UUID: AIContextSnapshot] = [:]

        init(_ base: SwiftDataConversationPersistence) { self.base = base }
        func loadConversations() throws -> [AIConversation] {
            if failLoadConversationsAfterFirstWrite {
                throw NSError(domain: "test", code: 4)
            }
            return try base.loadConversations()
        }
        func loadMessages(conversationID: UUID) throws -> [AIConversationMessage] { try base.loadMessages(conversationID: conversationID) }
        func loadActions(conversationID: UUID) throws -> [AIConversationActionRecord] { try base.loadActions(conversationID: conversationID) }
        func action(idempotencyKey: String) throws -> AIConversationActionRecord? { try base.action(idempotencyKey: idempotencyKey) }
        func action(id: UUID) throws -> AIConversationActionRecord? { try base.action(id: id) }
        func createConversationWithFirstMessage(_ conversation: AIConversation, message: AIConversationMessage) throws {
            if failCreate { throw NSError(domain: "test", code: 1) }
            try base.createConversationWithFirstMessage(conversation, message: message)
            if failLoadConversationsAfterFirstWrite {
                // Next call to loadConversations will fail
            }
        }
        func updateConversationWithUserMessage(_ conversation: AIConversation, message: AIConversationMessage) throws {
            if failSaveConversation { throw NSError(domain: "test", code: 2) }
            try base.updateConversationWithUserMessage(conversation, message: message)
        }
        func upsertConversation(_ conversation: AIConversation) throws {
            if failSaveConversation { throw NSError(domain: "test", code: 2) }
            try base.upsertConversation(conversation)
        }
        func upsertMessage(_ message: AIConversationMessage) throws {
            if failSaveAssistant && message.role == .assistant {
                throw NSError(domain: "test", code: 3)
            }
            upsertMessageCount += 1
            try base.upsertMessage(message)
        }
        func upsertAction(_ action: AIConversationActionRecord) throws { try base.upsertAction(action) }
        func upsertContextSnapshot(_ snapshot: AIContextSnapshot, conversationID: UUID) throws {
            snapshots[snapshot.id] = snapshot
            try base.upsertContextSnapshot(snapshot, conversationID: conversationID)
        }
        func deleteConversation(id: UUID) throws { try base.deleteConversation(id: id) }
        func deleteAll() throws {
            deleteAllCount += 1
            try base.deleteAll()
        }
        func recoverInterruptedMessages(now: Date) throws -> Int { try base.recoverInterruptedMessages(now: now) }
    }

    private final class ScriptedOrchestrator: ConversationOrchestrating {
        enum Script {
            case events([AIConversationTurnEvent])
            case failure(Error)
            case manual
        }

        var scripts: [Script] = []
        var inputs: [AIConversationTurnInput] = []
        var cancelCount = 0
        var onRun: ((AIConversationTurnInput) -> Void)?
        private var continuations: [AsyncThrowingStream<AIConversationTurnEvent, Error>.Continuation] = []

        func runTurn(_ input: AIConversationTurnInput) -> AsyncThrowingStream<AIConversationTurnEvent, Error> {
            inputs.append(input)
            onRun?(input)
            let script = scripts.isEmpty ? .events([.state(.completed), .finished]) : scripts.removeFirst()
            return AsyncThrowingStream { continuation in
                switch script {
                case let .events(events):
                    events.forEach { continuation.yield($0) }
                    continuation.finish()
                case let .failure(error):
                    continuation.finish(throwing: error)
                case .manual:
                    continuations.append(continuation)
                }
            }
        }

        func cancelCurrentTurn() { cancelCount += 1 }
        func emit(_ event: AIConversationTurnEvent, at index: Int = 0) {
            guard continuations.indices.contains(index) else { return }
            continuations[index].yield(event)
        }
        func finish(at index: Int = 0) {
            guard continuations.indices.contains(index) else { return }
            continuations[index].finish()
        }
    }

    private struct Fixture {
        let container: ModelContainer
        let persistence: PersistenceSpy
        let store: ConversationStore
        let orchestrator: ScriptedOrchestrator
        let kitchenStore: KitchenStore
        let recipeStore: RecipeStore
        let coordinator: ConversationActionCoordinator
        let fixedDate: Date
        let defaults: UserDefaults

        @MainActor init(
            metadataRequest: @escaping (String, String) async throws -> String = { _, _ in "" }
        ) throws {
            fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
            defaults = UserDefaults(suiteName: UUID().uuidString)!
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
            container = try KitchenPersistenceFactory.makeContainer(configuration: configuration)
            let base = SwiftDataConversationPersistence(container: container)
            persistence = PersistenceSpy(base)
            store = ConversationStore(persistence: persistence, calendar: Self.calendar, now: { Date(timeIntervalSince1970: 1_800_000_000) })
            orchestrator = ScriptedOrchestrator()
            kitchenStore = KitchenStore(userDefaults: defaults)
            recipeStore = RecipeStore(userDefaults: defaults)
            let domain = KitchenConversationDomainTools(kitchenStore: kitchenStore, recipeStore: recipeStore, calendar: Self.calendar)
            coordinator = ConversationActionCoordinator(
                domainTools: domain,
                persistence: persistence,
                now: { Date(timeIntervalSince1970: 1_800_000_000) },
                undoExpiresAt: { $0.addingTimeInterval(600) }
            )
            controller = AIConversationController(
                store: store,
                orchestrator: orchestrator,
                actionCoordinator: coordinator,
                metadataService: ConversationMetadataService(request: metadataRequest),
                now: { Date(timeIntervalSince1970: 1_800_000_000) }
            )
        }

        let controller: AIConversationController
        static var calendar: Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            return calendar
        }
    }

    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    private func send(_ text: String, in fixture: Fixture) async {
        fixture.controller.draftText = text
        fixture.controller.send()
        await settle()
    }

    private func completedScript(text: String = "好的") -> [AIConversationTurnEvent] {
        [.state(.requesting), .appendText(text), .state(.completed), .finished]
    }

    private func makePersistedConversation(_ fixture: Fixture, activeUntil: Date? = nil) throws -> AIConversation {
        var conversation = fixture.store.createDraft(entryContext: .home)
        conversation.activeUntil = activeUntil ?? fixture.fixedDate.addingTimeInterval(3600)
        let first = AIConversationMessage(
            conversationID: conversation.id,
            role: .user,
            createdAt: fixture.fixedDate,
            state: .completed,
            contentBlocks: [.text(.init(text: "第一条"))],
            turnID: UUID()
        )
        try fixture.store.saveFirstMessage(conversation: conversation, message: first)
        return conversation
    }

    private func preparedShopping(_ fixture: Fixture, conversationID: UUID, turnID: UUID) throws -> PreparedAIAction {
        try fixture.coordinator.prepare(
            .addShoppingItems(items: [.init(name: "牛奶", quantity: 1, unit: "盒")]),
            conversationID: conversationID,
            turnID: turnID
        )
    }

    func testOpenHomeWithoutRelevantConversationIsEphemeral() throws {
        let f = try Fixture()
        f.controller.open(entryContext: .home)
        XCTAssertNotNil(f.controller.currentConversation)
        XCTAssertTrue(f.controller.messages.isEmpty)
        XCTAssertTrue(try f.persistence.loadConversations().isEmpty)
    }

    func testWhitespaceSendDoesNothing() async throws {
        let f = try Fixture()
        f.controller.open(entryContext: .home)
        await send("  \n ", in: f)
        XCTAssertTrue(try f.persistence.loadConversations().isEmpty)
        XCTAssertTrue(f.orchestrator.inputs.isEmpty)
    }

    func testFirstSendPersistsUserBeforeOrchestratorStarts() async throws {
        let f = try Fixture()
        f.controller.open(entryContext: .home)
        f.orchestrator.onRun = { input in
            XCTAssertEqual(try? f.persistence.loadMessages(conversationID: input.conversationID).first?.role, .user)
        }
        await send("今晚吃什么", in: f)
        XCTAssertEqual(f.orchestrator.inputs.count, 1)
    }

    func testUserMessageAppearsBeforeFirstAssistantEvent() async throws {
        let f = try Fixture()
        f.controller.open(entryContext: .home)
        f.orchestrator.scripts = [.manual]
        await send("今晚吃什么", in: f)
        XCTAssertEqual(f.controller.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(f.controller.messages.last?.state, .streaming)
    }

    func testNewSendGetsNewTurnID() async throws {
        let f = try Fixture()
        f.controller.open(entryContext: .home)
        f.orchestrator.scripts = [.events(completedScript()), .events(completedScript())]
        await send("第一问", in: f)
        await send("第二问", in: f)
        XCTAssertEqual(f.orchestrator.inputs.count, 2)
        XCTAssertNotEqual(f.orchestrator.inputs[0].turnID, f.orchestrator.inputs[1].turnID)
    }

    func testGenerationRetryReusesTurnID() async throws {
        let f = try Fixture()
        f.controller.open(entryContext: .home)
        f.orchestrator.scripts = [.failure(NSError(domain: "test", code: 1)), .events(completedScript())]
        await send("重试这条", in: f)
        f.controller.retryGeneration()
        await settle()
        XCTAssertEqual(f.orchestrator.inputs.count, 2)
        XCTAssertEqual(f.orchestrator.inputs[0].turnID, f.orchestrator.inputs[1].turnID)
    }

    func testInterruptedPartialReplyKeepsTextMarksFailedAndRetriesWithoutDuplicatingUser() async throws {
        let f = try Fixture()
        f.controller.open(entryContext: .home)
        let interrupted = AIErrorBlock(message: ConversationFailurePresentation.partialReplyInterruptedMessage, retry: .generation)
        f.orchestrator.scripts = [
            .events([.state(.streaming), .appendText("先把番茄切块"), .appendBlock(.error(interrupted)), .state(.failed)]),
            .events(completedScript())
        ]
        await send("番茄怎么做", in: f)
        let conversationID = try XCTUnwrap(f.controller.currentConversation?.id)

        let persisted = try f.persistence.loadMessages(conversationID: conversationID)
        let failedReply = try XCTUnwrap(persisted.first { $0.role == .assistant })
        XCTAssertEqual(failedReply.state, .failed, "a partial reply is not a clean success")
        XCTAssertEqual(failedReply.contentBlocks.count, 2)
        guard case let .text(text) = failedReply.contentBlocks.first else { return XCTFail("text must survive the failure") }
        XCTAssertEqual(text.text, "先把番茄切块")
        XCTAssertEqual(failedReply.contentBlocks.last, .error(interrupted))
        XCTAssertTrue(f.controller.canRetryGeneration)

        f.controller.retryGeneration()
        await settle()
        let after = try f.persistence.loadMessages(conversationID: conversationID)
        XCTAssertEqual(after.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(after.first { $0.id == failedReply.id }?.contentBlocks.first, failedReply.contentBlocks.first)
    }

    func testRetryDoesNotPersistUserAgain() async throws {
        let f = try Fixture()
        f.controller.open(entryContext: .home)
        f.orchestrator.scripts = [.failure(NSError(domain: "test", code: 1)), .events(completedScript())]
        await send("只存一次", in: f)
        let conversationID = try XCTUnwrap(f.controller.currentConversation?.id)
        f.controller.retryGeneration()
        await settle()
        let users = try f.persistence.loadMessages(conversationID: conversationID).filter { $0.role == .user }
        XCTAssertEqual(users.count, 1)
    }

    func testRetryPreservesOriginalExclusions() async throws {
        let f = try Fixture()
        f.controller.open(entryContext: .home)
        f.controller.nextTurnExcludedContexts = [.inventory]
        f.orchestrator.scripts = [.failure(NSError(domain: "test", code: 1)), .events(completedScript())]
        await send("库存", in: f)
        f.controller.retryGeneration()
        await settle()
        XCTAssertEqual(f.orchestrator.inputs.map(\.excludedContextKinds), [[.inventory], [.inventory]])
    }

    func testExclusionsResetAfterAcceptedSend() async throws {
        let f = try Fixture()
        f.controller.open(entryContext: .home)
        f.controller.nextTurnExcludedContexts = [.inventory]
        await send("库存", in: f)
        XCTAssertTrue(f.controller.nextTurnExcludedContexts.isEmpty)
    }

    func testFailedFirstPersistenceKeepsDraftAndExclusionsAndSkipsProvider() async throws {
        let f = try Fixture()
        f.controller.open(entryContext: .home)
        f.controller.draftText = "保留我"
        f.controller.nextTurnExcludedContexts = [.inventory]
        f.persistence.failCreate = true
        f.controller.send()
        await settle()
        XCTAssertEqual(f.controller.draftText, "保留我")
        XCTAssertEqual(f.controller.nextTurnExcludedContexts, [.inventory])
        XCTAssertTrue(f.orchestrator.inputs.isEmpty)
        XCTAssertTrue(try f.persistence.loadConversations().isEmpty)
    }

    func testAssistantStreamingRowIsDurableBeforeProviderEvents() async throws {
        let f = try Fixture()
        f.controller.open(entryContext: .home)
        f.orchestrator.scripts = [.manual]
        await send("开始", in: f)
        let conversationID = try XCTUnwrap(f.controller.currentConversation?.id)
        XCTAssertEqual(try f.persistence.loadMessages(conversationID: conversationID).last?.state, .streaming)
    }

    func testTextDeltasDoNotPersistPerToken() async throws {
        let f = try Fixture()
        f.controller.open(entryContext: .home)
        f.orchestrator.scripts = [.events([.appendText("甲"), .appendText("乙"), .appendText("丙"), .state(.completed), .finished])]
        await send("写字", in: f)
        XCTAssertEqual(f.controller.messages.last?.plainTextSummary, "甲乙丙")
        XCTAssertEqual(f.persistence.upsertMessageCount, 2) // streaming row + terminal boundary
    }

    func testStructuredBlockPersistsAssistant() async throws {
        let f = try Fixture()
        f.controller.open(entryContext: .home)
        let block = AIContentBlock.contextResult(.init(title: "库存", rows: []))
        f.orchestrator.scripts = [.events([.appendBlock(block), .state(.completed), .finished])]
        await send("库存", in: f)
        XCTAssertGreaterThanOrEqual(f.persistence.upsertMessageCount, 3)
    }

    func testReplaceBlockUsesStableIDAndPersists() async throws {
        let f = try Fixture()
        f.controller.open(entryContext: .home)
        let id = UUID()
        let first = AIContentBlock.text(.init(id: id, text: "旧"))
        let replacement = AIContentBlock.text(.init(id: id, text: "新"))
        f.orchestrator.scripts = [.events([.appendBlock(first), .replaceBlock(replacement), .state(.completed), .finished])]
        await send("替换", in: f)
        XCTAssertEqual(f.controller.messages.last?.plainTextSummary, "新")
    }

    func testStopPreservesPartialTextAndPersistsCancelled() async throws {
        let f = try Fixture()
        f.controller.open(entryContext: .home)
        f.orchestrator.scripts = [.manual]
        await send("开始", in: f)
        f.orchestrator.emit(.appendText("部分"))
        await settle()
        f.controller.stop()
        let assistant = try XCTUnwrap(f.controller.messages.last)
        XCTAssertEqual(assistant.plainTextSummary, "部分")
        XCTAssertEqual(assistant.state, .cancelled)
        XCTAssertEqual(f.orchestrator.cancelCount, 1)
    }

    func testFailurePreservesPartialTextAndPersistsFailed() async throws {
        let f = try Fixture()
        f.controller.open(entryContext: .home)
        f.orchestrator.scripts = [.events([.appendText("部分"), .state(.failed)])]
        await send("开始", in: f)
        XCTAssertEqual(f.controller.messages.last?.plainTextSummary, "部分")
        XCTAssertEqual(f.controller.messages.last?.state, .failed)
    }

    func testOldStreamCannotAppendAfterConversationSwitch() async throws {
        let f = try Fixture()
        let other = try makePersistedConversation(f)
        f.controller.newConversation(entryContext: .home)
        f.orchestrator.scripts = [.manual]
        await send("旧流", in: f)
        f.controller.openConversation(id: other.id)
        f.orchestrator.emit(.appendText("迟到"))
        await settle()
        XCTAssertFalse(f.controller.messages.contains { $0.plainTextSummary.contains("迟到") })
    }

    /// An assistant row can be reloaded still persisted as `.streaming` while
    /// the runtime turn is `.idle` — here because the stop that reopening
    /// performs could not save the row as cancelled. No Kitchen AI activity may
    /// be synthesized for it: the row shows no status and no orb, because
    /// nothing is actually running for this row.
    func testReopenedStreamingMessageWithIdleTurnShowsNoActivity() async throws {
        let f = try Fixture()
        let conversation = try makePersistedConversation(f)
        f.controller.openConversation(id: conversation.id)
        f.orchestrator.scripts = [.manual]
        await send("还在回复", in: f)
        f.orchestrator.emit(.state(.streaming))
        await settle()

        let live = try XCTUnwrap(f.controller.messages.last { $0.role == .assistant })
        XCTAssertEqual(live.state, .streaming)
        XCTAssertEqual(
            MessageRowView.activityPhase(for: live, turnState: f.controller.turnState),
            .composing,
            "control: a truly streaming turn does show activity"
        )

        f.persistence.failSaveAssistant = true
        f.controller.openConversation(id: conversation.id)
        f.persistence.failSaveAssistant = false

        let reopened = try XCTUnwrap(f.controller.messages.first { $0.id == live.id })
        XCTAssertEqual(reopened.state, .streaming, "the persisted row still says streaming")
        XCTAssertEqual(f.controller.turnState, .idle)
        XCTAssertNil(f.controller.turnState.aiActivityPhase)
        XCTAssertNil(MessageRowView.activityPhase(for: reopened, turnState: f.controller.turnState))
    }

    private func pendingMeal(_ f: Fixture) async throws -> (AIConversation, PreparedAIAction) {
        let conversation = try makePersistedConversation(f)
        f.controller.openConversation(id: conversation.id)
        let recipe = Recipe(id: "pending-tofu", title: "清蒸豆腐", cookingTime: 10,
                            difficulty: "简单", tags: [], ingredients: ["豆腐"], steps: ["蒸熟"] )
        try f.recipeStore.saveUserRecipe(recipe)
        let meal = MealPlanItem(recipeID: "old", recipeName: "香辣鸡丁", date: f.fixedDate)
        f.kitchenStore.plans = [meal]
        let prepared = try f.coordinator.prepare(.replacePlannedMeal(planID: meal.id,
            replacement: AIRecipeBlock(id: UUID(), recipe: recipe, isTransient: false)),
            conversationID: conversation.id, turnID: UUID())
        f.orchestrator.scripts = [.events([.pendingAction(prepared), .state(.awaitingConfirmation)])]
        await send("换清淡一点", in: f)
        XCTAssertEqual(f.controller.preparedAction, prepared)
        XCTAssertEqual(try f.persistence.action(id: prepared.id)?.status, .awaitingConfirmation)
        return (conversation, prepared)
    }

    func testReopenSameActiveConversationPreservesExactPendingAction() async throws {
        let f = try Fixture()
        let (conversation, prepared) = try await pendingMeal(f)
        f.controller.openConversation(id: conversation.id)
        XCTAssertEqual(f.controller.preparedAction, prepared)
        XCTAssertEqual(f.controller.turnState, .awaitingConfirmation)
    }

    func testReopenConfirmationExecutesOriginalActionOnceWithoutProvider() async throws {
        let f = try Fixture()
        let (conversation, prepared) = try await pendingMeal(f)
        let count = f.orchestrator.inputs.count
        let mealID = f.kitchenStore.plans.first?.id
        f.controller.openConversation(id: conversation.id)
        f.controller.confirmPreparedAction()
        f.controller.confirmPreparedAction()
        XCTAssertEqual(f.orchestrator.inputs.count, count)
        XCTAssertEqual(f.kitchenStore.plans.count, 1)
        XCTAssertEqual(f.kitchenStore.plans.first?.id, mealID)
        XCTAssertEqual(f.kitchenStore.plans.first?.recipeName, "清蒸豆腐")
        XCTAssertEqual(try f.persistence.action(id: prepared.id)?.status, .succeeded)
        XCTAssertNil(f.controller.preparedAction)
    }

    func testReopenDifferentConversationClearsPendingAction() async throws {
        let f = try Fixture()
        _ = try await pendingMeal(f)
        let other = try makePersistedConversation(f)
        f.controller.openConversation(id: other.id)
        XCTAssertNil(f.controller.preparedAction)
        XCTAssertEqual(f.controller.turnState, .idle)
    }

    func testReopenTerminalActionDoesNotPreserveCapability() async throws {
        let f = try Fixture()
        let (conversation, prepared) = try await pendingMeal(f)
        _ = try f.coordinator.execute(prepared)
        f.controller.openConversation(id: conversation.id)
        XCTAssertNil(f.controller.preparedAction)
        XCTAssertEqual(f.controller.turnState, .idle)
    }

    /// The preview heading is derived from the persisted action record, never
    /// from `preparedAction`: pending asks for confirmation, while succeeded and
    /// undone — including after reopening — read as a neutral record. The
    /// stored block keeps its original title throughout.
    func testPlannerPreviewTitleFollowsPersistedActionStatusAcrossReopen() async throws {
        let f = try Fixture()
        let (conversation, prepared) = try await pendingMeal(f)
        guard case let .plannerPreview(preview)? = prepared.preview else {
            return XCTFail("expected a planner preview")
        }
        try f.store.saveMessage(AIConversationMessage(conversationID: conversation.id, role: .assistant,
            state: .completed, contentBlocks: [.plannerPreview(preview)], turnID: UUID()))
        func storedBlock() -> AIPlannerPreviewBlock? {
            f.controller.messages.flatMap(\.contentBlocks).lazy.compactMap { block -> AIPlannerPreviewBlock? in
                if case let .plannerPreview(value) = block, value.id == preview.id { return value }
                return nil
            }.first
        }
        func title() -> String? {
            storedBlock().map { AIPlannerPreviewPresentation.title(for: $0, record: f.controller.actionRecord(id: prepared.id)) }
        }

        f.controller.openConversation(id: conversation.id)
        XCTAssertEqual(title(), "确认计划变更")

        f.controller.confirmPreparedAction()
        XCTAssertEqual(try f.persistence.action(id: prepared.id)?.status, .succeeded)
        XCTAssertEqual(title(), "计划变更")

        let other = try makePersistedConversation(f)
        f.controller.openConversation(id: other.id)
        f.controller.openConversation(id: conversation.id)
        XCTAssertNil(f.controller.preparedAction)
        XCTAssertEqual(title(), "计划变更")

        f.controller.undo(actionID: prepared.id)
        XCTAssertEqual(try f.persistence.action(id: prepared.id)?.status, .undone)
        XCTAssertEqual(title(), "计划变更")
        XCTAssertEqual(storedBlock()?.title, "确认计划变更")
    }

    /// History's fallback excerpt projects the Planner preview heading from the
    /// persisted action record, and Apply/Undo drop a cached pending excerpt.
    /// `plainTextSummary` — the recent-message window's text — keeps the stored
    /// title, so model context is unchanged.
    func testHistoryExcerptProjectsPlannerPreviewTitleWithoutChangingPlainTextSummary() async throws {
        let f = try Fixture()
        let (conversation, prepared) = try await pendingMeal(f)
        guard case let .plannerPreview(preview)? = prepared.preview else {
            return XCTFail("expected a planner preview")
        }
        let transcript = AIConversationMessage(conversationID: conversation.id, role: .assistant,
            createdAt: f.fixedDate.addingTimeInterval(60), state: .completed,
            contentBlocks: [.text(.init(text: "为您准备了以下计划修改：")), .plannerPreview(preview)], turnID: UUID())
        try f.store.saveMessage(transcript)
        f.controller.openConversation(id: conversation.id)

        // Pending, and read once so the excerpt is cached before Apply.
        let pending = try XCTUnwrap(f.controller.lastMessageExcerpt(for: conversation.id))
        XCTAssertTrue(pending.contains("确认计划变更"))

        f.controller.confirmPreparedAction()
        XCTAssertEqual(try f.persistence.action(id: prepared.id)?.status, .succeeded)
        let applied = try XCTUnwrap(f.controller.lastMessageExcerpt(for: conversation.id))
        XCTAssertTrue(applied.contains("计划变更"))
        XCTAssertFalse(applied.contains("确认计划变更"))

        let other = try makePersistedConversation(f)
        f.controller.openConversation(id: other.id)
        f.controller.openConversation(id: conversation.id)
        let reopened = try XCTUnwrap(f.controller.lastMessageExcerpt(for: conversation.id))
        XCTAssertTrue(reopened.contains("计划变更"))
        XCTAssertFalse(reopened.contains("确认计划变更"))

        f.controller.undo(actionID: prepared.id)
        XCTAssertEqual(try f.persistence.action(id: prepared.id)?.status, .undone)
        let undone = try XCTUnwrap(f.controller.lastMessageExcerpt(for: conversation.id))
        XCTAssertTrue(undone.contains("计划变更"))
        XCTAssertFalse(undone.contains("确认计划变更"))

        let stored = try XCTUnwrap(f.store.messages(conversationID: conversation.id).first { $0.id == transcript.id })
        XCTAssertTrue(stored.plainTextSummary.hasPrefix("为您准备了以下计划修改： 确认计划变更"))
    }

    func testReopenExpiredConversationClearsPendingAction() async throws {
        let f = try Fixture()
        var (conversation, _) = try await pendingMeal(f)
        conversation.activeUntil = f.fixedDate.addingTimeInterval(-1)
        try f.persistence.upsertConversation(conversation)
        try f.store.loadHistory()
        f.controller.openConversation(id: conversation.id)
        XCTAssertNil(f.controller.preparedAction)
        XCTAssertEqual(f.controller.turnState, .idle)
    }

    func testPendingActionOnlySetsPreparedAction() async throws {
        let f = try Fixture()
        let conversation = try makePersistedConversation(f)
        f.controller.openConversation(id: conversation.id)
        let prepared = try preparedShopping(f, conversationID: conversation.id, turnID: UUID())
        f.orchestrator.scripts = [.events([.pendingAction(prepared), .state(.awaitingConfirmation)])]
        await send("加入牛奶", in: f)
        XCTAssertEqual(f.controller.preparedAction?.id, prepared.id)
        XCTAssertTrue(f.kitchenStore.shoppingItems.isEmpty)
    }

    func testConfirmExecutesPreparedActionWithoutProviderRequest() async throws {
        let f = try Fixture()
        let conversation = try makePersistedConversation(f)
        f.controller.openConversation(id: conversation.id)
        let prepared = try preparedShopping(f, conversationID: conversation.id, turnID: UUID())
        f.orchestrator.scripts = [.events([.pendingAction(prepared), .state(.awaitingConfirmation)])]
        await send("加入牛奶", in: f)
        let providerCount = f.orchestrator.inputs.count
        f.controller.confirmPreparedAction()
        XCTAssertEqual(f.orchestrator.inputs.count, providerCount)
        XCTAssertEqual(f.kitchenStore.shoppingItems.count, 1)
    }

    func testSuccessfulConfirmPersistsTruthfulStatus() async throws {
        let f = try Fixture()
        let conversation = try makePersistedConversation(f)
        f.controller.openConversation(id: conversation.id)
        let prepared = try preparedShopping(f, conversationID: conversation.id, turnID: UUID())
        f.orchestrator.scripts = [.events([.pendingAction(prepared), .state(.awaitingConfirmation)])]
        await send("加入牛奶", in: f)
        f.controller.confirmPreparedAction()
        XCTAssertTrue(f.controller.messages.flatMap(\.contentBlocks).contains {
            if case let .actionStatus(status) = $0 { return !status.isFailure && status.actionID == prepared.id }
            return false
        })
    }

    func testConfirmedActionReconstructsVisibleStatusWhenMessageSaveFailed() async throws {
        let f = try Fixture()
        let conversation = try makePersistedConversation(f)
        f.controller.openConversation(id: conversation.id)
        let turnID = UUID()
        let prepared = try preparedShopping(f, conversationID: conversation.id, turnID: turnID)
        f.orchestrator.scripts = [.events([.pendingAction(prepared), .state(.awaitingConfirmation)])]
        await send("加入牛奶", in: f)

        // Inject failure on saving the assistant message during confirmation
        f.persistence.failSaveAssistant = true
        let providerCountBeforeConfirm = f.orchestrator.inputs.count
        f.controller.confirmPreparedAction()

        // Kitchen domain mutation succeeded
        XCTAssertEqual(f.kitchenStore.shoppingItems.count, 1)
        // Authoritative record succeeded
        let actionRecord = try XCTUnwrap(f.persistence.action(id: prepared.id))
        XCTAssertEqual(actionRecord.status, .succeeded)

        // Reopen conversation
        f.persistence.failSaveAssistant = false
        f.controller.openConversation(id: conversation.id)

        // No model/provider request occurs
        XCTAssertEqual(f.orchestrator.inputs.count, providerCountBeforeConfirm)

        // Matching actionStatus is reconstructed
        let reconstructedStatus = f.controller.messages.flatMap(\.contentBlocks).compactMap { block -> AIActionStatusBlock? in
            guard case let .actionStatus(status) = block, status.actionID == prepared.id else { return nil }
            return status
        }.first
        XCTAssertNotNil(reconstructedStatus, "successful confirmed action must remain visibly reconstructible after status-message save failure")
        XCTAssertEqual(reconstructedStatus?.actionID, prepared.id)
        XCTAssertEqual(reconstructedStatus?.canUndo, actionRecord.canUndo(now: f.fixedDate))
    }

    func testReopeningConversationRepeatedlyDoesNotDuplicateSynthesizedBlock() async throws {
        let f = try Fixture()
        let conversation = try makePersistedConversation(f)
        f.controller.openConversation(id: conversation.id)
        let prepared = try preparedShopping(f, conversationID: conversation.id, turnID: UUID())
        f.orchestrator.scripts = [.events([.pendingAction(prepared), .state(.awaitingConfirmation)])]
        await send("加入牛奶", in: f)

        f.persistence.failSaveAssistant = true
        f.controller.confirmPreparedAction()
        f.persistence.failSaveAssistant = false

        // Open once
        f.controller.openConversation(id: conversation.id)
        // Open twice
        f.controller.openConversation(id: conversation.id)

        let statusBlocks = f.controller.messages.flatMap(\.contentBlocks).compactMap { block -> AIActionStatusBlock? in
            guard case let .actionStatus(status) = block, status.actionID == prepared.id else { return nil }
            return status
        }
        XCTAssertEqual(statusBlocks.count, 1)
    }

    func testReconcilingUndoneActionShowsUndoneAndCanUndoFalse() async throws {
        let f = try Fixture()
        let conversation = try makePersistedConversation(f)
        f.controller.openConversation(id: conversation.id)
        let prepared = try preparedShopping(f, conversationID: conversation.id, turnID: UUID())
        _ = try f.coordinator.execute(prepared)
        _ = try f.coordinator.undo(actionID: prepared.id)

        // Authoritative record is .undone, but assistant message has no status block
        f.controller.openConversation(id: conversation.id)

        let status = f.controller.messages.flatMap(\.contentBlocks).compactMap { block -> AIActionStatusBlock? in
            guard case let .actionStatus(status) = block, status.actionID == prepared.id else { return nil }
            return status
        }.first
        XCTAssertNotNil(status)
        XCTAssertEqual(status?.message, AIActionOutcomePresentation.undoneTitle(for: prepared.proposal.actionType))
        XCTAssertFalse(status?.canUndo ?? true)
    }

    func testReconciliationAssociatesStatusBlockWithMatchingTurnAssistant() async throws {
        let f = try Fixture()
        let conversation = try makePersistedConversation(f)
        f.controller.openConversation(id: conversation.id)

        // Turn 1
        f.orchestrator.scripts = [.events(completedScript(text: "回复1"))]
        await send("问题1", in: f)
        let turn1ID = f.orchestrator.inputs.last!.turnID

        // Turn 2
        f.orchestrator.scripts = [.events(completedScript(text: "回复2"))]
        await send("问题2", in: f)
        let turn2ID = f.orchestrator.inputs.last!.turnID

        // Suppose an action succeeded for Turn 1, but its status block was never attached to Turn 1's assistant
        let record = AIConversationActionRecord(
            actionID: UUID(),
            conversationID: conversation.id,
            turnID: turn1ID,
            actionType: .addShoppingItems,
            idempotencyKey: "turn1-action",
            status: .succeeded,
            createdAt: f.fixedDate,
            undoReference: .shoppingAdditions(before: [], after: []),
            undoExpiresAt: f.fixedDate.addingTimeInterval(600)
        )
        try f.persistence.upsertAction(record)

        // Reopen conversation to trigger reconciliation
        f.controller.openConversation(id: conversation.id)

        let assistantTurn1 = try XCTUnwrap(f.controller.messages.first(where: { $0.role == .assistant && $0.turnID == turn1ID }))
        let assistantTurn2 = try XCTUnwrap(f.controller.messages.first(where: { $0.role == .assistant && $0.turnID == turn2ID }))

        XCTAssertTrue(assistantTurn1.contentBlocks.contains {
            if case let .actionStatus(status) = $0 { return status.actionID == record.actionID }
            return false
        })
        XCTAssertFalse(assistantTurn2.contentBlocks.contains {
            if case let .actionStatus(status) = $0 { return status.actionID == record.actionID }
            return false
        })
    }

    func testExpiredActionReconcilesWithCanUndoFalse() async throws {
        let f = try Fixture()
        let conversation = try makePersistedConversation(f)
        f.controller.openConversation(id: conversation.id)
        let turnID = UUID()
        let record = AIConversationActionRecord(
            actionID: UUID(),
            conversationID: conversation.id,
            turnID: turnID,
            actionType: .addShoppingItems,
            idempotencyKey: "expired-action",
            status: .succeeded,
            createdAt: f.fixedDate.addingTimeInterval(-1000),
            undoReference: .shoppingAdditions(before: [], after: []),
            undoExpiresAt: f.fixedDate.addingTimeInterval(-1) // Expired!
        )
        try f.persistence.upsertAction(record)

        f.controller.openConversation(id: conversation.id)

        let status = f.controller.messages.flatMap(\.contentBlocks).compactMap { block -> AIActionStatusBlock? in
            guard case let .actionStatus(status) = block, status.actionID == record.actionID else { return nil }
            return status
        }.first
        XCTAssertNotNil(status)
        XCTAssertFalse(status?.canUndo ?? true)
    }

    func testLowRiskDurableActionReconcilesMissingVisibleStatusBlock() throws {
        let f = try Fixture()
        let conversation = try makePersistedConversation(f)
        let turnID = UUID()
        let record = AIConversationActionRecord(
            actionID: UUID(),
            conversationID: conversation.id,
            turnID: turnID,
            actionType: .addRecipeToTonight,
            idempotencyKey: "low-risk-action",
            status: .succeeded,
            createdAt: f.fixedDate,
            undoReference: .tonightPlan(plan: MealPlanItem(recipeID: "r1", recipeName: "豆腐", date: f.fixedDate), createdRecipeIDs: []),
            undoExpiresAt: f.fixedDate.addingTimeInterval(600)
        )
        try f.persistence.upsertAction(record)

        f.controller.openConversation(id: conversation.id)

        let status = f.controller.messages.flatMap(\.contentBlocks).compactMap { block -> AIActionStatusBlock? in
            guard case let .actionStatus(status) = block, status.actionID == record.actionID else { return nil }
            return status
        }.first
        XCTAssertNotNil(status)
        XCTAssertEqual(status?.message, "已加入今晚计划")
        XCTAssertTrue(status?.canUndo ?? false)
    }

    func testUndoUsesCoordinatorAndUpdatesStatusWithoutProvider() async throws {
        let f = try Fixture()
        let conversation = try makePersistedConversation(f)
        f.controller.openConversation(id: conversation.id)
        let prepared = try preparedShopping(f, conversationID: conversation.id, turnID: UUID())
        _ = try f.coordinator.execute(prepared)
        let status = AIContentBlock.actionStatus(.init(message: "已加入购物清单", actionID: prepared.id, canUndo: true))
        let assistant = AIConversationMessage(conversationID: conversation.id, role: .assistant, state: .completed, contentBlocks: [status], turnID: UUID())
        try f.store.saveMessage(assistant)
        f.controller.openConversation(id: conversation.id)
        let providerCount = f.orchestrator.inputs.count
        f.controller.undo(actionID: prepared.id)
        XCTAssertEqual(f.orchestrator.inputs.count, providerCount)
        XCTAssertTrue(f.kitchenStore.shoppingItems.isEmpty)
        let updatedStatus = f.controller.messages.flatMap(\.contentBlocks).compactMap { block -> AIActionStatusBlock? in
            guard case let .actionStatus(value) = block, value.actionID == prepared.id else { return nil }
            return value
        }.first
        XCTAssertEqual(updatedStatus?.message, AIActionOutcomePresentation.undoneTitle(for: prepared.proposal.actionType))
    }

    func testExpiredUndoRefusesAndDoesNotMarkUndone() throws {
        let f = try Fixture()
        let conversation = try makePersistedConversation(f)
        f.controller.openConversation(id: conversation.id)
        let record = AIConversationActionRecord(
            actionID: UUID(), conversationID: conversation.id, turnID: UUID(),
            actionType: .addShoppingItems, idempotencyKey: "expired", status: .succeeded,
            createdAt: f.fixedDate.addingTimeInterval(-1000),
            undoReference: .shoppingAdditions(before: [], after: []),
            undoExpiresAt: f.fixedDate
        )
        try f.persistence.upsertAction(record)
        f.controller.undo(actionID: record.id)
        XCTAssertNotNil(f.controller.localErrorMessage)
        XCTAssertEqual(try f.persistence.action(id: record.id)?.status, .succeeded)
    }

    func testExpiredConversationRefusesSendUntilReactivated() async throws {
        let f = try Fixture()
        let expired = try makePersistedConversation(f, activeUntil: f.fixedDate.addingTimeInterval(-1))
        f.controller.openConversation(id: expired.id)
        await send("不能发", in: f)
        XCTAssertTrue(f.orchestrator.inputs.isEmpty)
        f.controller.reactivate(id: expired.id)
        await send("现在可以", in: f)
        XCTAssertEqual(f.orchestrator.inputs.count, 1)
    }

    /// A pin keeps a conversation active past its stored deadline; unpinning
    /// must not quietly invent a new one. The stored date stays, so the
    /// conversation archives at once and only 继续 refreshes continuity.
    func testUnpinAfterStoredDeadlineArchivesImmediatelyWithoutFreshDeadline() throws {
        let f = try Fixture()
        let pastDeadline = f.fixedDate.addingTimeInterval(-1)
        let conversation = try makePersistedConversation(f, activeUntil: pastDeadline)
        f.controller.setPinned(id: conversation.id, isPinned: true)
        f.controller.openConversation(id: conversation.id)
        XCTAssertFalse(f.controller.currentConversationRequiresReactivation, "pinned conversations do not archive")

        f.controller.setPinned(id: conversation.id, isPinned: false)
        XCTAssertTrue(f.controller.currentConversationRequiresReactivation)
        XCTAssertEqual(f.controller.currentConversation?.activeUntil, pastDeadline, "unpin must not extend the deadline")

        f.controller.reactivate(id: conversation.id)
        XCTAssertFalse(f.controller.currentConversationRequiresReactivation)
        XCTAssertEqual(f.controller.currentConversation?.id, conversation.id)
        XCTAssertGreaterThan(f.controller.currentConversation!.activeUntil, f.fixedDate)
    }

    func testOpeningWeeklyHistoryRestoresItsPlannerEntryContext() async throws {
        let f = try Fixture()
        let weekStart = Fixture.calendar.date(from: DateComponents(year: 2027, month: 1, day: 4))!
        var conversation = f.store.createDraft(entryContext: .planner(weekStart: weekStart, specialPlanID: nil))
        conversation.activeUntil = f.fixedDate.addingTimeInterval(3600)
        let first = AIConversationMessage(
            conversationID: conversation.id,
            role: .user,
            createdAt: f.fixedDate,
            state: .completed,
            contentBlocks: [.text(.init(text: "本周"))],
            turnID: UUID()
        )
        try f.store.saveFirstMessage(conversation: conversation, message: first)
        f.controller.openConversation(id: conversation.id)
        await send("继续安排", in: f)
        guard case let .planner(actualWeek, focusedPlanID) = f.orchestrator.inputs.last?.entryContext else {
            return XCTFail("History send did not restore Planner context")
        }
        XCTAssertEqual(actualWeek, weekStart)
        XCTAssertNil(focusedPlanID)
    }

    func testMakeSpecialPlanDraftUpdatesControllerEntryContext() async throws {
        let f = try Fixture()
        let planID = UUID()
        let eventDate = Fixture.calendar.date(from: DateComponents(year: 2026, month: 10, day: 15))!
        let expectedWeek = PlannerProjection.startOfWeek(containing: eventDate, calendar: Fixture.calendar)

        f.controller.makeSpecialPlanDraft(planID: planID, scheduledAt: eventDate)
        await send("继续聚餐菜单", in: f)

        guard case let .planner(weekStart, focusedID) = f.orchestrator.inputs.last?.entryContext else {
            return XCTFail("Special Plan draft send used non-Planner entry context")
        }
        XCTAssertEqual(weekStart, expectedWeek)
        XCTAssertEqual(focusedID, planID)

        let otherWeek = Fixture.calendar.date(from: DateComponents(year: 2026, month: 3, day: 2))!
        f.controller.open(entryContext: .planner(weekStart: otherWeek, specialPlanID: nil))
        f.controller.makeSpecialPlanDraft(planID: planID, scheduledAt: eventDate)
        await send("再次聚餐", in: f)

        guard case let .planner(weekStart2, focusedID2) = f.orchestrator.inputs.last?.entryContext else {
            return XCTFail("Special Plan draft after planner send used non-Planner entry context")
        }
        XCTAssertEqual(weekStart2, expectedWeek)
        XCTAssertEqual(focusedID2, planID)
    }

    func testSameTurnAssistantMessageHasStrictlyLaterTimestampThanUserMessage() async throws {
        let f = try Fixture()
        f.controller.open(entryContext: .home)
        f.orchestrator.scripts = [.events([.appendText("回复"), .state(.completed), .finished])]
        await send("提问", in: f)

        let messages = f.controller.messages
        XCTAssertEqual(messages.count, 2)
        let user = messages[0]
        let assistant = messages[1]
        XCTAssertEqual(user.role, .user)
        XCTAssertEqual(assistant.role, .assistant)
        XCTAssertGreaterThan(assistant.createdAt, user.createdAt)

        // Persisted reload retains user before assistant
        let loaded = try f.persistence.loadMessages(conversationID: user.conversationID)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].role, .user)
        XCTAssertEqual(loaded[1].role, .assistant)

        // User/assistant causal ordering survives ContextAssembler sorting
        // even if user UUID is lexically greater than assistant UUID
        var highIDUser = user
        highIDUser.id = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        var lowIDAssistant = assistant
        lowIDAssistant.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let thirdUser = AIConversationMessage(
            id: UUID(),
            conversationID: user.conversationID,
            role: .user,
            createdAt: assistant.createdAt.addingTimeInterval(10),
            state: .completed,
            contentBlocks: [.text(.init(text: "后续提问"))],
            turnID: UUID()
        )
        let assembler = ConversationContextAssembler(
            domainTools: KitchenConversationDomainTools(
                kitchenStore: f.kitchenStore,
                recipeStore: f.recipeStore,
                calendar: Fixture.calendar
            )
        )
        let prepared = try assembler.prepare(
            entry: .home,
            summary: "",
            messages: [lowIDAssistant, highIDUser],
            currentUserMessage: thirdUser,
            excludedKinds: [],
            readAt: f.fixedDate.addingTimeInterval(20)
        )
        XCTAssertEqual(prepared.recentMessages.count, 2)
        XCTAssertEqual(prepared.recentMessages[0].role, .user)
        XCTAssertEqual(prepared.recentMessages[1].role, .assistant)

        // Retry assistant still follows user message
        f.orchestrator.scripts = [.failure(NSError(domain: "test", code: 1)), .events(completedScript())]
        await send("触发重试", in: f)
        f.controller.retryGeneration()
        await settle()
        let retriedMessages = f.controller.messages
        let lastUser = retriedMessages.filter { $0.role == .user }.last!
        let lastAssistant = retriedMessages.filter { $0.role == .assistant }.last!
        XCTAssertGreaterThan(lastAssistant.createdAt, lastUser.createdAt)
    }

    func testExistingConversationUserSaveFailureLeavesNoOrphanUserMessage() async throws {
        let f = try Fixture()
        let conv = try makePersistedConversation(f)
        f.controller.openConversation(id: conv.id)

        // We want to simulate failure during the conversation activity save
        // after the user message was about to be added to an existing conversation.
        f.persistence.failSaveConversation = true
        f.controller.draftText = "第二条消息"
        f.controller.nextTurnExcludedContexts = [.inventory]
        f.controller.send()
        await settle()

        XCTAssertEqual(f.controller.draftText, "第二条消息")
        XCTAssertEqual(f.controller.nextTurnExcludedContexts, [.inventory])
        XCTAssertTrue(f.orchestrator.inputs.isEmpty)

        // Authoritative messages should only have the original 1 user message, NOT 2
        let messages = try f.persistence.loadMessages(conversationID: conv.id)
        XCTAssertEqual(messages.count, 1)
    }

    func testAssistantStartPersistenceFailurePreservesUserTurnAndAllowsRetry() async throws {
        let f = try Fixture()
        f.controller.open(entryContext: .home)
        f.controller.nextTurnExcludedContexts = [.inventory]

        // Force failure on the assistant message save
        f.persistence.failSaveAssistant = true
        f.controller.draftText = "首次提问"
        f.controller.send()
        await settle()

        XCTAssertEqual(f.controller.turnState, .failed)
        XCTAssertTrue(f.orchestrator.inputs.isEmpty)

        let conversationID = try XCTUnwrap(f.controller.currentConversation?.id)
        let durableMessages = try f.persistence.loadMessages(conversationID: conversationID)
        XCTAssertEqual(durableMessages.count, 1)
        XCTAssertEqual(durableMessages[0].role, .user)

        // Now allow assistant save and retry
        f.persistence.failSaveAssistant = false
        f.orchestrator.scripts = [.events(completedScript())]
        f.controller.retryGeneration()
        await settle()

        XCTAssertEqual(f.orchestrator.inputs.count, 1)
        let input = f.orchestrator.inputs[0]
        XCTAssertEqual(input.turnID, durableMessages[0].turnID)
        XCTAssertEqual(input.excludedContextKinds, [.inventory])
        let finalUsers = try f.persistence.loadMessages(conversationID: conversationID).filter { $0.role == .user }
        XCTAssertEqual(finalUsers.count, 1)
    }

    func testSuccessfulFirstWriteWithFailingHistoryReloadStillAcceptsSend() async throws {
        let f = try Fixture()
        f.controller.open(entryContext: .home)
        f.controller.draftText = "首次提问"
        f.controller.nextTurnExcludedContexts = [.inventory]
        f.orchestrator.scripts = [.events(completedScript())]

        f.persistence.failLoadConversationsAfterFirstWrite = true
        await send("首次提问", in: f)

        let conversationID = try XCTUnwrap(f.controller.currentConversation?.id)
        let durableConversations = try f.container.mainContext.fetch(FetchDescriptor<ConversationRecord>())
        XCTAssertEqual(durableConversations.count, 1)
        let durableMessages = try f.container.mainContext.fetch(FetchDescriptor<ConversationMessageRecord>()).map { try $0.message() }
        XCTAssertEqual(durableMessages.filter { $0.role == .user }.count, 1)

        XCTAssertEqual(f.controller.draftText, "")
        XCTAssertTrue(f.controller.nextTurnExcludedContexts.isEmpty)
        XCTAssertEqual(f.orchestrator.inputs.count, 1)
        XCTAssertEqual(f.orchestrator.inputs[0].turnID, durableMessages.first?.turnID)
    }

    func testMetadataTaskHandleNotRemovedByEarlierCancelledTask() async throws {
        let gateA = AsyncStream<Void>.makeStream()
        let gateB = AsyncStream<Void>.makeStream()
        var taskBWasCancelled = false

        var callCount = 0
        let f = try Fixture(metadataRequest: { _, _ in
            callCount += 1
            if callCount == 1 {
                for await _ in gateA.stream { break }
                return "标题A"
            } else {
                for await _ in gateB.stream { break }
                taskBWasCancelled = Task.isCancelled
                return "标题B"
            }
        })
        var conv = try makePersistedConversation(f)
        conv.summary = "已有摘要"
        conv.summaryUpdatedAt = f.fixedDate.addingTimeInterval(-100)
        try f.store.saveConversation(conv)
        f.controller.openConversation(id: conv.id)

        // Turn 1 completes -> starts metadata Task A
        f.orchestrator.scripts = [.events(completedScript())]
        await send("消息1", in: f)

        // Turn 2 completes -> cancels Task A, starts metadata Task B
        f.orchestrator.scripts = [.events(completedScript())]
        await send("消息2", in: f)

        // Task A resumes and finishes
        gateA.continuation.yield(())
        gateA.continuation.finish()
        await settle()

        // Now wipe local history: should cancel Task B if Task B is still properly owned
        f.controller.wipeLocalHistory()

        // Release Task B
        gateB.continuation.yield(())
        gateB.continuation.finish()
        await settle()

        XCTAssertTrue(taskBWasCancelled, "Task B should have been cancelled by wipeLocalHistory")
    }

    func testDeletingNonCurrentConversationPublishesControllerChange() throws {
        let f = try Fixture()
        let convA = try makePersistedConversation(f)
        let convB = try makePersistedConversation(f)
        f.controller.openConversation(id: convA.id)

        var changeCount = 0
        let cancellable = f.controller.objectWillChange.sink { changeCount += 1 }
        _ = cancellable

        f.controller.delete(id: convB.id)

        XCTAssertFalse(f.controller.history.contains { $0.id == convB.id })
        XCTAssertGreaterThan(changeCount, 0)
    }

    func testStoreHistoryMutationPublishesControllerChange() throws {
        let f = try Fixture()
        let convA = try makePersistedConversation(f)
        let convB = try makePersistedConversation(f)
        f.controller.openConversation(id: convA.id)

        var changeCount = 0
        let cancellable = f.controller.objectWillChange.sink { changeCount += 1 }
        _ = cancellable

        _ = try f.store.rename(id: convB.id, newTitle: "新标题B")

        XCTAssertEqual(f.controller.history.first(where: { $0.id == convB.id })?.title, "新标题B")
        XCTAssertGreaterThan(changeCount, 0)
    }

    func testContextSnapshotEventPersists() async throws {
        let f = try Fixture()
        f.controller.open(entryContext: .home)
        let snapshot = AIContextSnapshot(turnID: UUID(), readAt: f.fixedDate, contextKinds: [.inventory])
        f.orchestrator.scripts = [.events([.contextSnapshot(snapshot), .state(.completed), .finished])]
        await send("库存", in: f)
        XCTAssertEqual(f.persistence.snapshots[snapshot.id], snapshot)
    }

    func testSnapshotUpdatesUpsertSameIdentity() async throws {
        let f = try Fixture()
        f.controller.open(entryContext: .home)
        let id = UUID()
        let turnID = UUID()
        let first = AIContextSnapshot(id: id, turnID: turnID, readAt: f.fixedDate, contextKinds: [.inventory])
        let second = AIContextSnapshot(id: id, turnID: turnID, readAt: f.fixedDate, contextKinds: [.inventory, .recipe])
        f.orchestrator.scripts = [.events([.contextSnapshot(first), .contextSnapshot(second), .state(.completed), .finished])]
        await send("库存", in: f)
        XCTAssertEqual(f.persistence.snapshots.count, 1)
        XCTAssertEqual(f.persistence.snapshots[id]?.contextKinds, [.inventory, .recipe])
    }

    func testInitialSnapshotDrivesActuallyUsedKinds() async throws {
        let f = try Fixture()
        f.controller.open(entryContext: .home)
        let snapshot = AIContextSnapshot(turnID: UUID(), readAt: f.fixedDate, contextKinds: [.tonightPlan])
        f.orchestrator.scripts = [.events([.contextSnapshot(snapshot), .state(.completed), .finished])]
        await send("今晚", in: f)
        XCTAssertEqual(f.controller.actuallyUsedContextKinds, [.tonightPlan])
    }

    func testLaterReadSnapshotUpdatesActuallyUsedKinds() async throws {
        let f = try Fixture()
        f.controller.open(entryContext: .home)
        let id = UUID()
        let first = AIContextSnapshot(id: id, turnID: UUID(), readAt: f.fixedDate, contextKinds: [.tonightPlan])
        let second = AIContextSnapshot(id: id, turnID: first.turnID, readAt: f.fixedDate, contextKinds: [.inventory, .tonightPlan])
        f.orchestrator.scripts = [.events([.contextSnapshot(first), .contextSnapshot(second), .state(.completed), .finished])]
        await send("库存", in: f)
        XCTAssertEqual(f.controller.actuallyUsedContextKinds, [.inventory, .tonightPlan])
    }

    func testTitleGenerationIsNonBlocking() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let f = try Fixture(metadataRequest: { _, _ in
            for await _ in gate.stream { break }
            return "稍后标题"
        })
        f.controller.open(entryContext: .home)
        f.orchestrator.scripts = [.events(completedScript())]
        await send("先完成", in: f)
        XCTAssertEqual(f.controller.turnState, .completed)
        XCTAssertEqual(f.controller.currentConversation?.title, AIConversation.defaultTitle)
        gate.continuation.yield(())
        gate.continuation.finish()
    }

    func testUserRenameWinsDelayedTitleRace() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let f = try Fixture(metadataRequest: { _, task in
            if task == "conversation_title" { for await _ in gate.stream { break } }
            return "模型标题"
        })
        f.controller.open(entryContext: .home)
        f.orchestrator.scripts = [.events(completedScript())]
        await send("先完成", in: f)
        f.controller.rename("用户标题")
        gate.continuation.yield(())
        gate.continuation.finish()
        await settle()
        XCTAssertEqual(f.controller.currentConversation?.title, "用户标题")
    }

    func testMetadataFailureDoesNotFailCompletedTurn() async throws {
        let f = try Fixture(metadataRequest: { _, _ in throw NSError(domain: "metadata", code: 1) })
        f.controller.open(entryContext: .home)
        f.orchestrator.scripts = [.events(completedScript())]
        await send("完成", in: f)
        XCTAssertEqual(f.controller.turnState, .completed)
        XCTAssertEqual(f.controller.messages.last?.state, .completed)
    }

    func testSummaryUsesSemanticStaleness() async throws {
        var taskTypes: [String] = []
        let f = try Fixture(metadataRequest: { _, task in taskTypes.append(task); return "摘要" })
        var conversation = try makePersistedConversation(f)
        conversation.summary = "旧摘要"
        conversation.summaryUpdatedAt = f.fixedDate.addingTimeInterval(-100)
        try f.store.saveConversation(conversation)
        f.controller.openConversation(id: conversation.id)
        f.orchestrator.scripts = [.events(completedScript())]
        await send("新消息", in: f)
        await settle()
        XCTAssertTrue(taskTypes.contains("conversation_summary"))
    }

    func testMetadataAfterDeleteCannotRecreateConversation() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let f = try Fixture(metadataRequest: { _, _ in
            for await _ in gate.stream { break }
            return "迟到标题"
        })
        f.controller.open(entryContext: .home)
        f.orchestrator.scripts = [.events(completedScript())]
        await send("完成", in: f)
        let id = try XCTUnwrap(f.controller.currentConversation?.id)
        f.controller.delete(id: id)
        gate.continuation.yield(())
        gate.continuation.finish()
        await settle()
        XCTAssertNil(f.store.conversation(id: id))
        XCTAssertTrue(try f.persistence.loadConversations().isEmpty)
    }

    func testDeleteCurrentResetsStateAndPreservesKitchenTruth() async throws {
        let f = try Fixture()
        let recipe = Recipe(id: "keep", title: "保留菜", cookingTime: 10, difficulty: nil, tags: [], ingredients: ["菜"], steps: ["做"])
        _ = f.kitchenStore.addPlan(recipe: recipe, on: f.fixedDate, calendar: Fixture.calendar)
        let conversation = try makePersistedConversation(f)
        f.controller.openConversation(id: conversation.id)
        f.controller.delete(id: conversation.id)
        XCTAssertNil(f.controller.currentConversation)
        XCTAssertTrue(f.controller.messages.isEmpty)
        XCTAssertEqual(f.kitchenStore.plans.count, 1)
    }

    func testWipeCancelsAndClearsControllerState() async throws {
        let f = try Fixture()
        f.controller.open(entryContext: .home)
        f.orchestrator.scripts = [.manual]
        await send("进行中", in: f)
        f.controller.wipeLocalHistory()
        XCTAssertEqual(f.orchestrator.cancelCount, 1)
        XCTAssertNil(f.controller.currentConversation)
        XCTAssertTrue(f.controller.messages.isEmpty)
        XCTAssertNil(f.controller.preparedAction)
        XCTAssertEqual(f.persistence.deleteAllCount, 1)
    }

    func testProductionUndoWindowAllows599SecondsAndExpiresAt600Seconds() throws {
        func coordinatorFixture() throws -> (ConversationActionCoordinator, Clock, UUID) {
            let container = try KitchenPersistenceFactory.makeContainer(
                configuration: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            let persistence = SwiftDataConversationPersistence(container: container)
            let defaults = UserDefaults(suiteName: UUID().uuidString)!
            let domain = KitchenConversationDomainTools(
                kitchenStore: KitchenStore(userDefaults: defaults),
                recipeStore: RecipeStore(userDefaults: defaults),
                calendar: Fixture.calendar
            )
            let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
            let coordinator = ConversationActionCoordinator(
                domainTools: domain,
                persistence: persistence,
                now: { clock.date },
                undoExpiresAt: { $0.addingTimeInterval(600) }
            )
            let conversationID = UUID()
            let prepared = try coordinator.prepare(
                .addShoppingItems(items: [.init(name: "牛奶", quantity: 1, unit: "盒")]),
                conversationID: conversationID,
                turnID: UUID()
            )
            _ = try coordinator.execute(prepared)
            return (coordinator, clock, prepared.id)
        }

        let (permitted, permittedClock, permittedID) = try coordinatorFixture()
        permittedClock.date.addTimeInterval(599)
        XCTAssertEqual(try permitted.undo(actionID: permittedID).record.status, .undone)

        let (expired, expiredClock, expiredID) = try coordinatorFixture()
        expiredClock.date.addTimeInterval(600)
        XCTAssertThrowsError(try expired.undo(actionID: expiredID)) {
            XCTAssertEqual($0 as? AIActionExecutionError, .expired)
        }
    }

    func testPendingActionDisablesCanAcceptNewMessageAndSendRefusesUntilConfirmed() async throws {
        let f = try Fixture()
        let conversation = try makePersistedConversation(f)
        f.controller.openConversation(id: conversation.id)
        let prepared = try preparedShopping(f, conversationID: conversation.id, turnID: UUID())
        f.orchestrator.scripts = [.events([.pendingAction(prepared), .state(.awaitingConfirmation)])]
        await send("买牛奶", in: f)

        XCTAssertEqual(f.controller.preparedAction?.id, prepared.id)
        XCTAssertFalse(f.controller.canAcceptNewMessage)

        let inputCountBefore = f.orchestrator.inputs.count
        let messageCountBefore = f.controller.messages.count
        f.controller.draftText = "再买一盒鸡蛋"
        f.controller.send()
        await settle()

        XCTAssertEqual(f.orchestrator.inputs.count, inputCountBefore)
        XCTAssertEqual(f.controller.messages.count, messageCountBefore)

        f.controller.confirmPreparedAction()
        XCTAssertNil(f.controller.preparedAction)
        XCTAssertTrue(f.controller.canAcceptNewMessage)
    }

    func testSwitchingConversationClearsDraftTextAndExcludedContexts() async throws {
        let f = try Fixture()
        let conversationA = try makePersistedConversation(f)
        let conversationB = try makePersistedConversation(f)

        f.controller.openConversation(id: conversationA.id)
        f.controller.draftText = "只属于第一条对话"
        f.controller.nextTurnExcludedContexts = [.inventory]

        f.controller.openConversation(id: conversationB.id)
        XCTAssertEqual(f.controller.draftText, "")
        XCTAssertTrue(f.controller.nextTurnExcludedContexts.isEmpty)
    }

    func testReopeningSameConversationPreservesDraft() async throws {
        let f = try Fixture()
        let conversation = try makePersistedConversation(f)

        f.controller.openConversation(id: conversation.id)
        f.controller.draftText = "保留在当前对话中的草稿"
        f.controller.nextTurnExcludedContexts = [.inventory]

        // Re-opening same conversation does not clear draft
        f.controller.openConversation(id: conversation.id)
        XCTAssertEqual(f.controller.draftText, "保留在当前对话中的草稿")
        XCTAssertEqual(f.controller.nextTurnExcludedContexts, [.inventory])
    }
}

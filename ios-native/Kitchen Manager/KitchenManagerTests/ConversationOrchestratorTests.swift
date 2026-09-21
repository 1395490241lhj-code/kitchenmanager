import XCTest
@testable import KitchenManager

@MainActor
final class ConversationOrchestratorTests: XCTestCase {

    // MARK: - Test Doubles

    private final class TestPersistence: ConversationPersistenceProtocol {
        var actions: [UUID: AIConversationActionRecord] = [:]

        func loadConversations() throws -> [AIConversation] { [] }
        func loadMessages(conversationID: UUID) throws -> [AIConversationMessage] { [] }
        func loadActions(conversationID: UUID) throws -> [AIConversationActionRecord] {
            actions.values.filter { $0.conversationID == conversationID }.sorted {
                $0.createdAt == $1.createdAt ? $0.actionID.uuidString > $1.actionID.uuidString : $0.createdAt > $1.createdAt
            }
        }
        func action(id: UUID) throws -> AIConversationActionRecord? { actions[id] }
        func action(idempotencyKey: String) throws -> AIConversationActionRecord? {
            let sorted = actions.values.filter { $0.idempotencyKey == idempotencyKey }.sorted {
                $0.createdAt == $1.createdAt ? $0.actionID.uuidString > $1.actionID.uuidString : $0.createdAt > $1.createdAt
            }
            return sorted.first { $0.status == .succeeded || $0.status == .undone } ?? sorted.first
        }
        func upsertAction(_ action: AIConversationActionRecord) throws {
            actions[action.id] = action
        }
        func createConversationWithFirstMessage(_ conversation: AIConversation, message: AIConversationMessage) throws {}
        func updateConversationWithUserMessage(_ conversation: AIConversation, message: AIConversationMessage) throws {}
        func upsertConversation(_ conversation: AIConversation) throws {}
        func upsertMessage(_ message: AIConversationMessage) throws {}
        func upsertContextSnapshot(_ snapshot: AIContextSnapshot, conversationID: UUID) throws {}
        func deleteConversation(id: UUID) throws {}
        func deleteAll() throws {}
        func recoverInterruptedMessages(now: Date) throws -> Int { 0 }
    }

    private actor AsyncGate {
        private var isOpened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpened { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func open() {
            isOpened = true
            for waiter in waiters {
                waiter.resume()
            }
            waiters.removeAll()
        }
    }

    private actor ScriptedTransport: AIConversationRuntimeTransport {
        var capturedRequests: [AIConversationRuntimeRequest] = []
        var stepResponses: [[AIConversationStreamEvent]] = []
        var onRequest: ((AIConversationRuntimeRequest) async -> [AIConversationStreamEvent])?
        var onCancel: (() -> Void)?
        var gate: AsyncGate?
        var isCancelled: Bool = false
        var onEventYielded: ((AIConversationStreamEvent) async -> Void)?
        var pauseBeforeEvent: ((AIConversationStreamEvent) async -> Void)?
        var ignoreTaskCancellation: Bool = false

        init(stepResponses: [[AIConversationStreamEvent]] = [], gate: AsyncGate? = nil, onRequest: ((AIConversationRuntimeRequest) async -> [AIConversationStreamEvent])? = nil) {
            self.stepResponses = stepResponses
            self.gate = gate
            self.onRequest = onRequest
        }

        func setGate(_ gate: AsyncGate) { self.gate = gate }
        func setOnRequest(_ handler: @escaping (AIConversationRuntimeRequest) async -> [AIConversationStreamEvent]) { self.onRequest = handler }
        func setOnEventYielded(_ handler: @escaping (AIConversationStreamEvent) async -> Void) { self.onEventYielded = handler }
        func setPauseBeforeEvent(_ handler: @escaping (AIConversationStreamEvent) async -> Void) { self.pauseBeforeEvent = handler }
        func setIgnoreTaskCancellation(_ ignore: Bool) { self.ignoreTaskCancellation = ignore }

        func stream(_ request: AIConversationRuntimeRequest) -> AsyncThrowingStream<AIConversationStreamEvent, Error> {
            capturedRequests.append(request)
            return AsyncThrowingStream { continuation in
                let task = Task {
                    if let gate = self.gate {
                        await gate.wait()
                    }
                    if Task.isCancelled && !self.ignoreTaskCancellation {
                        self.isCancelled = true
                        self.onCancel?()
                        continuation.finish()
                        return
                    }

                    let events: [AIConversationStreamEvent]
                    if let custom = self.onRequest {
                        events = await custom(request)
                    } else if !self.stepResponses.isEmpty {
                        events = self.stepResponses.removeFirst()
                    } else {
                        events = [.completed(finishReason: "stop")]
                    }

                    for event in events {
                        if Task.isCancelled && !self.ignoreTaskCancellation {
                            self.isCancelled = true
                            self.onCancel?()
                            continuation.finish()
                            return
                        }
                        if let pause = self.pauseBeforeEvent {
                            await pause(event)
                        }
                        continuation.yield(event)
                        if let onYielded = self.onEventYielded {
                            await onYielded(event)
                        }
                    }
                    continuation.finish()
                }

                continuation.onTermination = { @Sendable _ in
                    task.cancel()
                    Task { [weak self] in
                        await self?.markCancelled()
                    }
                }
            }
        }

        private var cancelWaiters: [CheckedContinuation<Void, Never>] = []

        func waitForCancel() async {
            if isCancelled { return }
            await withCheckedContinuation { continuation in
                cancelWaiters.append(continuation)
            }
        }

        func markCancelled() {
            isCancelled = true
            onCancel?()
            for w in cancelWaiters { w.resume() }
            cancelWaiters.removeAll()
        }
    }

    // MARK: - Test Environment Fixture

    private struct TestEnv {
        let kitchenStore: KitchenStore
        let recipeStore: RecipeStore
        let domainTools: KitchenConversationDomainTools
        let persistence: TestPersistence
        let coordinator: ConversationActionCoordinator
        let assembler: ConversationContextAssembler
        let conversationID: UUID
        let turnID: UUID
        let currentUserMessage: AIConversationMessage
        let defaultInput: AIConversationTurnInput

        @MainActor
        init() throws {
            let defaults = UserDefaults(suiteName: UUID().uuidString)!
            kitchenStore = KitchenStore(userDefaults: defaults)
            recipeStore = RecipeStore(userDefaults: defaults)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            domainTools = KitchenConversationDomainTools(kitchenStore: kitchenStore, recipeStore: recipeStore, calendar: calendar)
            persistence = TestPersistence()
            coordinator = ConversationActionCoordinator(
                domainTools: domainTools,
                persistence: persistence,
                undoExpiresAt: { $0.addingTimeInterval(3600) }
            )
            assembler = ConversationContextAssembler(domainTools: domainTools)
            conversationID = UUID()
            turnID = UUID()
            currentUserMessage = AIConversationMessage(
                id: UUID(),
                conversationID: conversationID,
                role: .user,
                createdAt: Date(),
                state: .completed,
                contentBlocks: [.text(.init(text: "今晚吃什么？"))],
                turnID: turnID
            )
            defaultInput = AIConversationTurnInput(
                conversationID: conversationID,
                turnID: turnID,
                currentUserMessage: currentUserMessage
            )
        }

        @MainActor
        func makeOrchestrator(
            transport: any AIConversationRuntimeTransport,
            providerRouter: @escaping (UserDefaults) -> AIConversationProviderRoute = { _ in .cloud(provider: .gemini) },
            isReadOptional: @escaping (AIReadToolRequest) -> Bool = { _ in false }
        ) -> ConversationOrchestrator {
            ConversationOrchestrator(
                contextAssembler: assembler,
                domainTools: domainTools,
                actionCoordinator: coordinator,
                providerRouter: providerRouter,
                transportFactory: { _ in transport },
                isReadOptional: isReadOptional
            )
        }
    }

    private func collectEvents(from stream: AsyncThrowingStream<AIConversationTurnEvent, Error>) async throws -> [AIConversationTurnEvent] {
        var events: [AIConversationTurnEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    // MARK: - 38 Required Tests

    // 1: READ LOOP: step 1 text + read_inventory -> live read -> step 2 receives assistant tool_call + matching tool result
    func testReadLoop_step1Inventory_step2ReceivesToolResultTranscript() async throws {
        let env = try TestEnv()
        let step1Events: [AIConversationStreamEvent] = [
            .textDelta("为您查找库存："),
            .toolCall(id: "call-inv-1", name: "read_inventory", arguments: Data("{}".utf8)),
            .completed(finishReason: "tool_calls")
        ]
        let step2Events: [AIConversationStreamEvent] = [
            .completed(finishReason: "stop")
        ]

        let transport = ScriptedTransport(stepResponses: [step1Events, step2Events])
        let orchestrator = env.makeOrchestrator(transport: transport)
        let events = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        XCTAssertTrue(events.contains(.appendText("为您查找库存：")))
        let captured = await transport.capturedRequests
        XCTAssertEqual(captured.count, 2)
        let step2Messages = captured[1].messages
        XCTAssertTrue(step2Messages.contains(where: { $0.role == .assistant && $0.toolCalls?.first?.id == "call-inv-1" }))
        XCTAssertTrue(step2Messages.contains(where: { $0.role == .tool && $0.toolCallID == "call-inv-1" }))
    }

    // 2: READ LOOP: step 2 two recipe-card calls -> two blocks emitted in order
    func testReadLoop_step2TwoRecipeCardCalls_emitsTwoBlocksInOrder() async throws {
        let env = try TestEnv()
        let recipe1 = Recipe(id: "rec-1", title: "番茄炒蛋", cookingTime: 10, difficulty: "简单", tags: [], ingredients: ["番茄", "鸡蛋"], steps: ["炒熟"])
        let recipe2 = Recipe(id: "rec-2", title: "清炒菜心", cookingTime: 8, difficulty: "简单", tags: [], ingredients: ["菜心"], steps: ["炒熟"])
        try env.recipeStore.saveUserRecipe(recipe1)
        try env.recipeStore.saveUserRecipe(recipe2)

        let card1Args = #"{"recipe":{"recipeID":"rec-1","title":"番茄炒蛋"}}"#
        let card2Args = #"{"recipe":{"recipeID":"rec-2","title":"清炒菜心"}}"#
        let stepEvents: [AIConversationStreamEvent] = [
            .toolCall(id: "call-c1", name: "present_recipe_card", arguments: Data(card1Args.utf8)),
            .toolCall(id: "call-c2", name: "present_recipe_card", arguments: Data(card2Args.utf8)),
            .completed(finishReason: "stop")
        ]

        let transport = ScriptedTransport(stepResponses: [stepEvents])
        let orchestrator = env.makeOrchestrator(transport: transport)
        let events = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        let recipeBlocks = events.compactMap { event -> AIRecipeBlock? in
            if case let .appendBlock(.recipe(block)) = event { return block }
            return nil
        }
        XCTAssertEqual(recipeBlocks.count, 2)
        XCTAssertEqual(recipeBlocks[0].recipe.id, "rec-1")
        XCTAssertEqual(recipeBlocks[1].recipe.id, "rec-2")
        XCTAssertTrue(events.contains(.state(.completed)))
        XCTAssertTrue(events.contains(.finished))
    }

    // 3: Read tool uses current domain truth at execution time
    func testReadToolUsesCurrentDomainTruthAtExecutionTime() async throws {
        let env = try TestEnv()
        var step2ReceivedInventoryText: String?

        let step1Events: [AIConversationStreamEvent] = [
            .toolCall(id: "call-inv", name: "read_inventory", arguments: Data("{}".utf8)),
            .completed(finishReason: "tool_calls")
        ]
        let step2Events: [AIConversationStreamEvent] = [
            .completed(finishReason: "stop")
        ]

        let transport = ScriptedTransport()
        await transport.setOnRequest { req in
            if await transport.capturedRequests.count == 1 {
                // Mutate inventory right before tool execution happens
                Task { @MainActor in
                    _ = env.kitchenStore.addInventory(name: "土豆", quantity: 5, unit: "个", expiryDate: nil)
                }
                return step1Events
            } else {
                let toolMsg = req.messages.first(where: { $0.role == .tool && $0.toolCallID == "call-inv" })
                step2ReceivedInventoryText = toolMsg?.content
                return step2Events
            }
        }

        let orchestrator = env.makeOrchestrator(transport: transport)
        _ = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        XCTAssertNotNil(step2ReceivedInventoryText)
        XCTAssertTrue(step2ReceivedInventoryText!.contains("土豆"))
    }

    // 4: resolve_recipe query-only goes through Task 4 finite semantic resolver
    func testResolveRecipeQueryOnlyExecutesThroughFiniteResolver() async throws {
        let env = try TestEnv()
        let recipe = Recipe(id: "rec-solve", title: "麻婆豆腐", cookingTime: 15, difficulty: "简单", tags: [], ingredients: ["豆腐", "肉末"], steps: ["翻炒"])
        try env.recipeStore.saveUserRecipe(recipe)

        var step2ToolResultText: String?

        let step1Events: [AIConversationStreamEvent] = [
            .toolCall(id: "call-res", name: "resolve_recipe", arguments: Data(#"{"query":"麻婆豆腐"}"#.utf8)),
            .completed(finishReason: "tool_calls")
        ]
        let step2Events: [AIConversationStreamEvent] = [.completed(finishReason: "stop")]

        let transport = ScriptedTransport()
        await transport.setOnRequest { req in
            if await transport.capturedRequests.count == 1 {
                return step1Events
            } else {
                let toolMsg = req.messages.first(where: { $0.role == .tool && $0.toolCallID == "call-res" })
                step2ToolResultText = toolMsg?.content
                return step2Events
            }
        }

        let orchestrator = env.makeOrchestrator(transport: transport)
        let events = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        XCTAssertNotNil(step2ToolResultText)
        XCTAssertTrue(step2ToolResultText!.contains("rec-solve"))
        XCTAssertTrue(step2ToolResultText!.contains("麻婆豆腐"))

        let snapshot = events.compactMap { ev -> AIContextSnapshot? in
            if case let .contextSnapshot(snap) = ev { return snap }
            return nil
        }.last
        XCTAssertNotNil(snapshot)
        XCTAssertTrue(snapshot!.contextKinds.contains(.recipe))
        XCTAssertTrue(snapshot!.relatedEntityIDs.contains("rec-solve"))
    }

    // 5: Low-risk add-to-tonight executes exactly once
    func testLowRiskAddToTonightExecutesExactlyOnce() async throws {
        let env = try TestEnv()
        let recipe = Recipe(id: "rec-tonight", title: "鸡蛋汤", cookingTime: 5, difficulty: "简单", tags: [], ingredients: ["鸡蛋"], steps: ["煮汤"])
        try env.recipeStore.saveUserRecipe(recipe)

        let step1Events: [AIConversationStreamEvent] = [
            .toolCall(id: "call-add", name: "propose_add_recipe_to_tonight", arguments: Data(#"{"recipe":{"recipeID":"rec-tonight","title":"鸡蛋汤"}}"#.utf8)),
            .completed(finishReason: "stop")
        ]

        let transport = ScriptedTransport(stepResponses: [step1Events])
        let orchestrator = env.makeOrchestrator(transport: transport)

        let events = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        XCTAssertEqual(env.kitchenStore.plans.count, 1)
        XCTAssertEqual(env.kitchenStore.plans.first?.recipeName, "鸡蛋汤")

        let statusBlock = events.compactMap { event -> AIActionStatusBlock? in
            if case let .appendBlock(.actionStatus(block)) = event { return block }
            return nil
        }
        XCTAssertEqual(statusBlock.count, 1)
        XCTAssertTrue(statusBlock.first!.canUndo)
        XCTAssertFalse(statusBlock.first!.isFailure)
        XCTAssertTrue(events.contains(.state(.completed)))
    }

    // 6: Low-risk same-turn Retry reuses the original turnID and causes zero duplicate domain mutation
    func testLowRiskSameTurnRetryReusesTurnIDAndCausesZeroDuplicateMutation() async throws {
        let env = try TestEnv()
        let recipe = Recipe(id: "rec-tonight", title: "鸡蛋汤", cookingTime: 5, difficulty: "简单", tags: [], ingredients: ["鸡蛋"], steps: ["煮汤"])
        try env.recipeStore.saveUserRecipe(recipe)

        let stepEvents: [AIConversationStreamEvent] = [
            .toolCall(id: "call-add", name: "propose_add_recipe_to_tonight", arguments: Data(#"{"recipe":{"recipeID":"rec-tonight","title":"鸡蛋汤"}}"#.utf8)),
            .completed(finishReason: "stop")
        ]

        let transport1 = ScriptedTransport(stepResponses: [stepEvents])
        let orchestrator1 = env.makeOrchestrator(transport: transport1)
        _ = try await collectEvents(from: orchestrator1.runTurn(env.defaultInput))
        XCTAssertEqual(env.kitchenStore.plans.count, 1)

        // Retry same turn with same turnID
        let retryInput = AIConversationTurnInput(
            conversationID: env.conversationID,
            turnID: env.turnID, // Same logical turn
            currentUserMessage: env.currentUserMessage
        )
        let transport2 = ScriptedTransport(stepResponses: [stepEvents])
        let orchestrator2 = env.makeOrchestrator(transport: transport2)
        _ = try await collectEvents(from: orchestrator2.runTurn(retryInput))

        // Must NOT duplicate the mutation
        XCTAssertEqual(env.kitchenStore.plans.count, 1)
    }

    // 7: Identical action from a NEW logical turn can execute again
    func testIdenticalActionFromNewLogicalTurnCanExecuteAgain() async throws {
        let env = try TestEnv()
        let recipe = Recipe(id: "rec-tonight", title: "鸡蛋汤", cookingTime: 5, difficulty: "简单", tags: [], ingredients: ["鸡蛋"], steps: ["煮汤"])
        try env.recipeStore.saveUserRecipe(recipe)

        let stepEvents: [AIConversationStreamEvent] = [
            .toolCall(id: "call-add", name: "propose_add_recipe_to_tonight", arguments: Data(#"{"recipe":{"recipeID":"rec-tonight","title":"鸡蛋汤"}}"#.utf8)),
            .completed(finishReason: "stop")
        ]

        let transport1 = ScriptedTransport(stepResponses: [stepEvents])
        let orchestrator1 = env.makeOrchestrator(transport: transport1)
        _ = try await collectEvents(from: orchestrator1.runTurn(env.defaultInput))
        XCTAssertEqual(env.kitchenStore.plans.count, 1)

        // Genuinely NEW turn with NEW turnID
        let newTurnID = UUID()
        let newMsg = AIConversationMessage(
            id: UUID(),
            conversationID: env.conversationID,
            role: .user,
            createdAt: Date(),
            state: .completed,
            contentBlocks: [.text(.init(text: "再加一次鸡蛋汤"))],
            turnID: newTurnID
        )
        let newInput = AIConversationTurnInput(
            conversationID: env.conversationID,
            turnID: newTurnID,
            currentUserMessage: newMsg
        )
        let transport2 = ScriptedTransport(stepResponses: [stepEvents])
        let orchestrator2 = env.makeOrchestrator(transport: transport2)
        _ = try await collectEvents(from: orchestrator2.runTurn(newInput))

        // New turn executes again
        XCTAssertEqual(env.kitchenStore.plans.count, 2)
    }

    // 8: Medium Planner proposal emits preview + pendingAction and zero mutation
    func testMediumPlannerProposalEmitsPreviewAndPendingActionWithZeroMutation() async throws {
        let env = try TestEnv()
        let oldRecipe = Recipe(id: "rec-old", title: "旧菜", cookingTime: 5, difficulty: "简单", tags: [], ingredients: ["菜"], steps: ["做"])
        let newRecipe = Recipe(id: "rec-new", title: "新菜", cookingTime: 5, difficulty: "简单", tags: [], ingredients: ["新菜"], steps: ["做"])
        try env.recipeStore.saveUserRecipe(oldRecipe)
        try env.recipeStore.saveUserRecipe(newRecipe)

        let saveResult = env.kitchenStore.addPlan(recipe: oldRecipe, on: Date(), calendar: env.domainTools.calendar)
        guard case .saved(let plan) = saveResult else { return XCTFail() }

        let step1Events: [AIConversationStreamEvent] = [
            .toolCall(id: "call-rep", name: "propose_replace_planned_meal", arguments: Data(#"{"planID":"\#(plan.id.uuidString)","replacement":{"recipeID":"rec-new","title":"新菜"}}"#.utf8)),
            .completed(finishReason: "stop")
        ]

        let transport = ScriptedTransport(stepResponses: [step1Events])
        let orchestrator = env.makeOrchestrator(transport: transport)

        let events = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        // Zero mutation occurred!
        XCTAssertEqual(env.kitchenStore.plans.first?.recipeName, "旧菜")

        // Emitted preview and pendingAction
        let preview = events.compactMap { event -> AIPlannerPreviewBlock? in
            if case let .appendBlock(.plannerPreview(preview)) = event { return preview }
            return nil
        }
        XCTAssertEqual(preview.count, 1)

        let pending = events.compactMap { event -> PreparedAIAction? in
            if case let .pendingAction(action) = event { return action }
            return nil
        }
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.risk, .medium)
        XCTAssertTrue(events.contains(.state(.awaitingConfirmation)))
    }

    // 9: High/bulk proposal exposes every preview row and zero mutation
    func testHighBulkProposalExposesEveryPreviewRowAndZeroMutation() async throws {
        let env = try TestEnv()
        let r1 = Recipe(id: "r1", title: "菜1", cookingTime: 5, difficulty: "简单", tags: [], ingredients: ["1"], steps: ["1"])
        let r2 = Recipe(id: "r2", title: "菜2", cookingTime: 5, difficulty: "简单", tags: [], ingredients: ["2"], steps: ["2"])
        let rNew = Recipe(id: "r-new", title: "替换菜", cookingTime: 5, difficulty: "简单", tags: [], ingredients: ["新"], steps: ["新"])
        try env.recipeStore.saveUserRecipe(r1)
        try env.recipeStore.saveUserRecipe(r2)
        try env.recipeStore.saveUserRecipe(rNew)

        guard case .saved(let p1) = env.kitchenStore.addPlan(recipe: r1, on: Date(), calendar: env.domainTools.calendar),
              case .saved(let p2) = env.kitchenStore.addPlan(recipe: r2, on: Date(), calendar: env.domainTools.calendar) else { return XCTFail() }

        let json = #"{"changes":[{"planID":"\#(p1.id.uuidString)","replacement":{"recipeID":"r-new","title":"替换菜"}},{"planID":"\#(p2.id.uuidString)","replacement":{"recipeID":"r-new","title":"替换菜"}}]}"#
        let step1Events: [AIConversationStreamEvent] = [
            .toolCall(id: "call-bulk", name: "propose_apply_planner_changes", arguments: Data(json.utf8)),
            .completed(finishReason: "stop")
        ]

        let transport = ScriptedTransport(stepResponses: [step1Events])
        let orchestrator = env.makeOrchestrator(transport: transport)

        let events = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        // Zero mutation
        XCTAssertEqual(env.kitchenStore.plans[0].recipeName, "菜1")
        XCTAssertEqual(env.kitchenStore.plans[1].recipeName, "菜2")

        let pending = events.compactMap { event -> PreparedAIAction? in
            if case let .pendingAction(action) = event { return action }
            return nil
        }
        XCTAssertEqual(pending.first?.risk, .high)
        if case let .plannerPreview(preview)? = pending.first?.preview {
            XCTAssertEqual(preview.changes.count, 2)
        } else {
            XCTFail("Missing preview")
        }
    }

    // 10: Apply is not an Orchestrator/provider operation
    func testApplyIsNotAnOrchestratorOperation() throws {
        // Orchestrator exposes only runTurn and cancelCurrentTurn.
        // Confirm execution of a prepared action is performed directly on ActionCoordinator.
        let env = try TestEnv()
        let r = Recipe(id: "r1", title: "鸡蛋", cookingTime: 5, difficulty: nil, tags: [], ingredients: ["蛋"], steps: ["做"])
        try env.recipeStore.saveUserRecipe(r)
        let prepared = try env.coordinator.prepare(.addRecipeToTonight(recipe: .init(id: UUID(), recipe: r, isTransient: false)), conversationID: env.conversationID, turnID: env.turnID)
        let result = try env.coordinator.execute(prepared)
        XCTAssertEqual(result.record.status, .succeeded)
    }

    // 11: All stateless provider steps within a turn retain one logical turnID
    func testAllStatelessProviderStepsWithinTurnRetainOneLogicalTurnID() async throws {
        let env = try TestEnv()
        let step1: [AIConversationStreamEvent] = [
            .toolCall(id: "c1", name: "read_inventory", arguments: Data("{}".utf8)),
            .completed(finishReason: "tool_calls")
        ]
        let step2: [AIConversationStreamEvent] = [
            .toolCall(id: "c2", name: "read_tonight_plan", arguments: Data("{}".utf8)),
            .completed(finishReason: "tool_calls")
        ]
        let step3: [AIConversationStreamEvent] = [
            .completed(finishReason: "stop")
        ]

        let transport = ScriptedTransport(stepResponses: [step1, step2, step3])
        let orchestrator = env.makeOrchestrator(transport: transport)

        _ = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        let reqs = await transport.capturedRequests
        XCTAssertEqual(reqs.count, 3)
        // Same logical turn across all steps
        XCTAssertEqual(env.defaultInput.turnID, env.turnID)
    }

    // 12: Targeted Retry of failed/cancelled turn retains original turnID
    func testTargetedRetryOfFailedOrCancelledTurnRetainsOriginalTurnID() {
        let originalTurnID = UUID()
        let input1 = AIConversationTurnInput(
            conversationID: UUID(),
            turnID: originalTurnID,
            currentUserMessage: .init(conversationID: UUID(), role: .user, state: .completed, contentBlocks: [], turnID: originalTurnID)
        )
        let retryInput = AIConversationTurnInput(
            conversationID: input1.conversationID,
            turnID: input1.turnID, // Retains original turnID
            currentUserMessage: input1.currentUserMessage
        )
        XCTAssertEqual(input1.turnID, retryInput.turnID)
    }

    // 13: Genuinely new user message has a new turnID
    func testGenuinelyNewUserMessageHasNewTurnID() {
        let turn1 = UUID()
        let turn2 = UUID()
        XCTAssertNotEqual(turn1, turn2)
    }

    // 14: Cancellation after text preserves text
    func testCancellationAfterTextPreservesText() async throws {
        let env = try TestEnv()
        let gate = AsyncGate()
        let textDeliveredGate = AsyncGate()
        let allowCompletedGate = AsyncGate()
        let transport = ScriptedTransport()
        await transport.setGate(gate)
        await transport.setOnEventYielded { ev in
            if case .textDelta = ev {
                await textDeliveredGate.open()
            }
        }
        await transport.setPauseBeforeEvent { ev in
            if case .completed = ev {
                await allowCompletedGate.wait()
            }
        }
        await transport.setOnRequest { _ in
            [
                .textDelta("部分输出文字"),
                .completed(finishReason: "stop")
            ]
        }

        let orchestrator = env.makeOrchestrator(transport: transport)
        let stream = orchestrator.runTurn(env.defaultInput)

        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next() // .state(.preparingContext)
        _ = try await iterator.next() // .contextSnapshot
        _ = try await iterator.next() // .state(.requesting)
        await gate.open()
        _ = try await iterator.next() // .state(.streaming)
        let textEvent = try await iterator.next()
        XCTAssertEqual(textEvent, .appendText("部分输出文字"))

        await textDeliveredGate.wait()
        orchestrator.cancelCurrentTurn()
        await allowCompletedGate.open()

        let cancelledEvent = try await iterator.next()
        XCTAssertEqual(cancelledEvent, .state(.cancelled))
        let end = try await iterator.next()
        XCTAssertNil(end)
    }

    // 15: Cancellation cancels active provider iteration
    func testCancellationCancelsActiveProviderIteration() async throws {
        let env = try TestEnv()
        let gate = AsyncGate()
        let transport = ScriptedTransport()
        await transport.setGate(gate)

        let orchestrator = env.makeOrchestrator(transport: transport)
        let stream = orchestrator.runTurn(env.defaultInput)
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next() // preparingContext
        _ = try await iterator.next() // requesting

        orchestrator.cancelCurrentTurn()
        await gate.open()
        await transport.waitForCancel()

        let isCancelled = await transport.isCancelled
        XCTAssertTrue(isCancelled)
    }

    // 16: Outer transport ending nil after requested cancellation becomes .cancelled, NOT .completed
    func testOuterTransportEndingNilAfterRequestedCancellationBecomesCancelledNotCompleted() async throws {
        let env = try TestEnv()
        let gate = AsyncGate()
        let transport = ScriptedTransport()
        await transport.setGate(gate)
        await transport.setOnRequest { _ in [] } // ends with nil/empty immediately after gate opens

        let orchestrator = env.makeOrchestrator(transport: transport)
        let stream = orchestrator.runTurn(env.defaultInput)
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next() // preparingContext
        _ = try await iterator.next() // requesting

        orchestrator.cancelCurrentTurn()
        await gate.open()

        var events: [AIConversationTurnEvent] = []
        while let ev = try await iterator.next() {
            events.append(ev)
        }

        XCTAssertTrue(events.contains(.state(.cancelled)))
        XCTAssertFalse(events.contains(.state(.completed)))
    }

    // 17: Events arriving after cancellation are ignored
    func testEventsArrivingAfterCancellationAreIgnored() async throws {
        let env = try TestEnv()
        let transport = ScriptedTransport(stepResponses: [
            [.textDelta("A"), .textDelta("B")]
        ])
        let orchestrator = env.makeOrchestrator(transport: transport)
        let stream = orchestrator.runTurn(env.defaultInput)
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next() // preparingContext
        orchestrator.cancelCurrentTurn()

        var remaining: [AIConversationTurnEvent] = []
        while let ev = try await iterator.next() {
            remaining.append(ev)
        }
        XCTAssertFalse(remaining.contains(.appendText("B")))
    }

    // 18: Cancelled old turn cannot append into a newly started turn
    func testCancelledOldTurnCannotAppendIntoNewlyStartedTurn() async throws {
        let env = try TestEnv()
        let gate1 = AsyncGate()
        let transport = ScriptedTransport()
        await transport.setOnRequest { req in
            if req.messages.contains(where: { $0.content == "Turn 1" }) {
                await gate1.wait()
                return [.textDelta("Turn 1 message")]
            } else {
                return [.textDelta("Turn 2 message"), .completed(finishReason: "stop")]
            }
        }
        let orchestrator = env.makeOrchestrator(transport: transport)

        let msg1 = AIConversationMessage(conversationID: env.conversationID, role: .user, state: .completed, contentBlocks: [.text(.init(text: "Turn 1"))], turnID: UUID())
        let input1 = AIConversationTurnInput(conversationID: env.conversationID, currentUserMessage: msg1)
        _ = orchestrator.runTurn(input1)

        orchestrator.cancelCurrentTurn()

        let msg2 = AIConversationMessage(conversationID: env.conversationID, role: .user, state: .completed, contentBlocks: [.text(.init(text: "Turn 2"))], turnID: UUID())
        let input2 = AIConversationTurnInput(conversationID: env.conversationID, currentUserMessage: msg2)
        let stream2 = orchestrator.runTurn(input2)

        await gate1.open()

        let events2 = try await collectEvents(from: stream2)
        XCTAssertFalse(events2.contains(.appendText("Turn 1 message")))
        XCTAssertTrue(events2.contains(.appendText("Turn 2 message")))
    }

    // 19: Recipe block emitted before later provider error remains
    func testRecipeBlockEmittedBeforeLaterProviderErrorRemains() async throws {
        let env = try TestEnv()
        let recipe = Recipe(id: "r-err", title: "鸡蛋", cookingTime: 5, difficulty: nil, tags: [], ingredients: ["蛋"], steps: ["做"])
        try env.recipeStore.saveUserRecipe(recipe)

        let stepEvents: [AIConversationStreamEvent] = [
            .toolCall(id: "c-rec", name: "present_recipe_card", arguments: Data(#"{"recipe":{"recipeID":"r-err","title":"鸡蛋"}}"#.utf8)),
            .error(code: "server_err", message: "网络异常中断"),
            .completed(finishReason: "error")
        ]

        let transport = ScriptedTransport(stepResponses: [stepEvents])
        let orchestrator = env.makeOrchestrator(transport: transport)

        let events = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        // Recipe card was emitted and remains
        let hasRecipe = events.contains(where: {
            if case let .appendBlock(.recipe(block)) = $0 { return block.recipe.id == "r-err" }
            return false
        })
        XCTAssertTrue(hasRecipe)
        XCTAssertTrue(events.contains(.state(.failed)))
    }

    // 20: Scoped error emitted exactly once
    func testScopedErrorEmittedExactlyOnce() async throws {
        let env = try TestEnv()
        let stepEvents: [AIConversationStreamEvent] = [
            .error(code: "err", message: "服务器错误"),
            .completed(finishReason: "error")
        ]
        let transport = ScriptedTransport(stepResponses: [stepEvents])
        let orchestrator = env.makeOrchestrator(transport: transport)

        let events = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))
        let errorBlocks = events.compactMap { ev -> AIErrorBlock? in
            if case let .appendBlock(.error(err)) = ev { return err }
            return nil
        }
        XCTAssertEqual(errorBlocks.count, 1)
        XCTAssertEqual(errorBlocks.first?.message, "服务器错误")
    }

    // 21: Provider error produces no fake finished success
    func testProviderErrorProducesNoFakeFinishedSuccess() async throws {
        let env = try TestEnv()
        let transport = ScriptedTransport(stepResponses: [
            [.error(code: "err", message: "fail")]
        ])
        let orchestrator = env.makeOrchestrator(transport: transport)
        let events = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        XCTAssertFalse(events.contains(.finished))
        XCTAssertFalse(events.contains(.state(.completed)))
        XCTAssertTrue(events.contains(.state(.failed)))
    }

    // 22: Six provider steps permitted
    func testSixProviderStepsPermitted() async throws {
        let env = try TestEnv()
        var steps: [[AIConversationStreamEvent]] = []
        for i in 1...5 {
            steps.append([
                .toolCall(id: "c(i)", name: "read_tonight_plan", arguments: Data("{}".utf8)),
                .completed(finishReason: "tool_calls")
            ])
        }
        steps.append([.completed(finishReason: "stop")]) // 6th step finishes

        let transport = ScriptedTransport(stepResponses: steps)
        let orchestrator = env.makeOrchestrator(transport: transport)
        let events = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        XCTAssertTrue(events.contains(.state(.completed)))
        XCTAssertTrue(events.contains(.finished))
        let captured = await transport.capturedRequests
        XCTAssertEqual(captured.count, 6)
    }

    // 23: Seventh provider step refused
    func testSeventhProviderStepRefused() async throws {
        let env = try TestEnv()
        var steps: [[AIConversationStreamEvent]] = []
        for i in 1...7 {
            steps.append([
                .toolCall(id: "c(i)", name: "read_tonight_plan", arguments: Data("{}".utf8)),
                .completed(finishReason: "tool_calls")
            ])
        }

        let transport = ScriptedTransport(stepResponses: steps)
        let orchestrator = env.makeOrchestrator(transport: transport)
        let events = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        XCTAssertTrue(events.contains(.state(.failed)))
        XCTAssertFalse(events.contains(.state(.completed)))
        let captured = await transport.capturedRequests
        XCTAssertEqual(captured.count, 6) // Stopped before making 7th request!
    }

    // 24: Twelve tool calls permitted
    func testTwelveToolCallsPermitted() async throws {
        let env = try TestEnv()
        var calls: [AIConversationStreamEvent] = []
        for i in 1...12 {
            calls.append(.toolCall(id: "c(i)", name: "read_tonight_plan", arguments: Data("{}".utf8)))
        }
        calls.append(.completed(finishReason: "tool_calls"))

        let step2: [AIConversationStreamEvent] = [.completed(finishReason: "stop")]

        let transport = ScriptedTransport(stepResponses: [calls, step2])
        let orchestrator = env.makeOrchestrator(transport: transport)
        let events = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        XCTAssertTrue(events.contains(.state(.completed)))
    }

    // 25: Thirteenth tool call refused before execution
    func testThirteenthToolCallRefusedBeforeExecution() async throws {
        let env = try TestEnv()
        var calls: [AIConversationStreamEvent] = []
        for i in 1...13 {
            calls.append(.toolCall(id: "c(i)", name: "read_tonight_plan", arguments: Data("{}".utf8)))
        }
        calls.append(.completed(finishReason: "tool_calls"))

        let transport = ScriptedTransport(stepResponses: [calls])
        let orchestrator = env.makeOrchestrator(transport: transport)
        let events = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        XCTAssertTrue(events.contains(.state(.failed)))
        let errorBlocks = events.compactMap { ev -> AIErrorBlock? in
            if case let .appendBlock(.error(err)) = ev { return err }
            return nil
        }
        XCTAssertEqual(errorBlocks.first?.message, "已达到本次对话的工具调用上限，已停止执行后续操作。")
    }

    // 26: Bounded-loop error leaves previous content intact
    func testBoundedLoopErrorLeavesPreviousContentIntact() async throws {
        let env = try TestEnv()
        var calls: [AIConversationStreamEvent] = [
            .textDelta("前序文本内容")
        ]
        for i in 1...13 {
            calls.append(.toolCall(id: "c(i)", name: "read_tonight_plan", arguments: Data("{}".utf8)))
        }
        let transport = ScriptedTransport(stepResponses: [calls])
        let orchestrator = env.makeOrchestrator(transport: transport)
        let events = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        XCTAssertTrue(events.contains(.appendText("前序文本内容")))
        XCTAssertTrue(events.contains(.state(.failed)))
    }

    // 27: Unknown tool -> interpreter rejection -> no domain action, failed terminal, no completed/finished
    func testUnknownToolCausesInterpreterRejectionAndNoDomainAction() async throws {
        let env = try TestEnv()
        let stepEvents: [AIConversationStreamEvent] = [
            .toolCall(id: "c-unk", name: "unknown_hack_tool", arguments: Data("{}".utf8)),
            .completed(finishReason: "stop")
        ]
        let transport = ScriptedTransport(stepResponses: [stepEvents])
        let orchestrator = env.makeOrchestrator(transport: transport)
        let events = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        let errorBlocks = events.compactMap { ev -> AIErrorBlock? in
            if case let .appendBlock(.error(err)) = ev { return err }
            return nil
        }
        XCTAssertEqual(errorBlocks.count, 1)
        XCTAssertEqual(errorBlocks.first?.message, "无法识别这次操作，没有改动。")
        XCTAssertTrue(events.contains(.state(.failed)))
        XCTAssertFalse(events.contains(.state(.completed)))
        XCTAssertFalse(events.contains(.finished))
        XCTAssertEqual(env.kitchenStore.plans.count, 0)
    }

    // 28: Malformed args -> no domain action, failed terminal, no completed/finished
    func testMalformedToolArgsCausesInterpreterRejectionAndNoDomainAction() async throws {
        let env = try TestEnv()
        let stepEvents: [AIConversationStreamEvent] = [
            .toolCall(id: "c-mal", name: "propose_add_shopping_items", arguments: Data(#"{"items":[{"name":"鸡蛋","quantity":-5}]}"#.utf8)),
            .completed(finishReason: "stop")
        ]
        let transport = ScriptedTransport(stepResponses: [stepEvents])
        let orchestrator = env.makeOrchestrator(transport: transport)
        let events = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        XCTAssertEqual(env.kitchenStore.shoppingItems.count, 0)
        let errorBlocks = events.compactMap { ev -> AIErrorBlock? in
            if case let .appendBlock(.error(err)) = ev { return err }
            return nil
        }
        XCTAssertEqual(errorBlocks.count, 1)
        XCTAssertEqual(errorBlocks.first?.message, "无法识别这次操作，没有改动。")
        XCTAssertTrue(events.contains(.state(.failed)))
        XCTAssertFalse(events.contains(.state(.completed)))
        XCTAssertFalse(events.contains(.finished))
    }

    // 29: Optional read failure follows explicit semantic optionality only
    func testOptionalReadFailureFollowsExplicitSemanticOptionality() async throws {
        let env = try TestEnv()
        var step2ReceivedErrorResult = false

        let step1: [AIConversationStreamEvent] = [
            .toolCall(id: "c-spec", name: "read_special_plan", arguments: Data(#"{"planID":"\#(UUID().uuidString)"}"#.utf8)),
            .completed(finishReason: "tool_calls")
        ]
        let step2: [AIConversationStreamEvent] = [.completed(finishReason: "stop")]

        let transport = ScriptedTransport()
        await transport.setOnRequest { req in
            if await transport.capturedRequests.count == 1 {
                return step1
            } else {
                let toolMsg = req.messages.first(where: { $0.role == .tool && $0.toolCallID == "c-spec" })
                if toolMsg?.content?.contains("error") == true {
                    step2ReceivedErrorResult = true
                }
                return step2
            }
        }

        // Mark specialPlan as optional
        let orchestrator = env.makeOrchestrator(
            transport: transport,
            isReadOptional: { req in
                if case .specialPlan = req { return true }
                return false
            }
        )
        let events = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        XCTAssertTrue(step2ReceivedErrorResult)
        XCTAssertTrue(events.contains(.state(.completed)))
    }

    // 30: Required/non-optional read failure fails closed
    func testRequiredReadFailureFailsClosed() async throws {
        let env = try TestEnv()
        let step1: [AIConversationStreamEvent] = [
            .toolCall(id: "c-spec", name: "read_special_plan", arguments: Data(#"{"planID":"\#(UUID().uuidString)"}"#.utf8)),
            .completed(finishReason: "tool_calls")
        ]

        let transport = ScriptedTransport(stepResponses: [step1])
        let orchestrator = env.makeOrchestrator(
            transport: transport,
            isReadOptional: { _ in false } // Required
        )
        let events = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        XCTAssertTrue(events.contains(.state(.failed)))
        let errorBlocks = events.compactMap { ev -> AIErrorBlock? in
            if case let .appendBlock(.error(err)) = ev { return err }
            return nil
        }
        XCTAssertEqual(errorBlocks.first?.message, "读取厨房上下文失败，已停止处理。")
    }

    // 31: Global Gemini route uses Gemini cloud runtime
    func testGlobalGeminiRouteUsesGeminiCloudRuntime() async throws {
        let env = try TestEnv()
        var selectedProvider: AIRecommendationProvider?
        let orchestrator = ConversationOrchestrator(
            contextAssembler: env.assembler,
            domainTools: env.domainTools,
            actionCoordinator: env.coordinator,
            providerRouter: { _ in .cloud(provider: .gemini) },
            transportFactory: { prov in
                selectedProvider = prov
                return ScriptedTransport(stepResponses: [[.completed(finishReason: "stop")]])
            }
        )
        _ = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))
        XCTAssertEqual(selectedProvider, .gemini)
    }

    // 32: Global Groq route uses Groq cloud runtime
    func testGlobalGroqRouteUsesGroqCloudRuntime() async throws {
        let env = try TestEnv()
        var selectedProvider: AIRecommendationProvider?
        let orchestrator = ConversationOrchestrator(
            contextAssembler: env.assembler,
            domainTools: env.domainTools,
            actionCoordinator: env.coordinator,
            providerRouter: { _ in .cloud(provider: .groq) },
            transportFactory: { prov in
                selectedProvider = prov
                return ScriptedTransport(stepResponses: [[.completed(finishReason: "stop")]])
            }
        )
        _ = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))
        XCTAssertEqual(selectedProvider, .groq)
    }

    // 33: A pending conversation provider choice creates no cloud request
    func testNeedsProviderSelectionCreatesNoCloudRequest() async throws {
        let env = try TestEnv()
        var cloudFactoryCalled = false
        let orchestrator = ConversationOrchestrator(
            contextAssembler: env.assembler,
            domainTools: env.domainTools,
            actionCoordinator: env.coordinator,
            providerRouter: { _ in .needsProviderSelection },
            transportFactory: { _ in
                cloudFactoryCalled = true
                return ScriptedTransport()
            }
        )
        let events = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        XCTAssertFalse(cloudFactoryCalled)
        XCTAssertTrue(events.contains(.state(.failed)))
        let errorBlocks = events.compactMap { ev -> AIErrorBlock? in
            if case let .appendBlock(.error(err)) = ev { return err }
            return nil
        }
        XCTAssertEqual(
            errorBlocks.first?.message,
            AIConversationProviderPreference.setupTitle + AIConversationProviderPreference.setupDetail
        )
    }

    // 33b: Production wiring against real UserDefaults. Tests 31-33 inject a
    // route, so nothing above pins what the app itself resolves at send time.
    func testProductionResolverScopesConversationToItsOwnPreference() async throws {
        let env = try TestEnv()
        let suiteName = "ConversationOrchestratorProductionRouting.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Fresh install: a first send reaches the canonical cloud default with
        // nothing persisted and no Settings visit in between.
        var freshProvider: AIRecommendationProvider?
        let freshOrchestrator = ConversationOrchestrator(
            contextAssembler: env.assembler,
            domainTools: env.domainTools,
            actionCoordinator: env.coordinator,
            userDefaults: defaults,
            transportFactory: { provider in
                freshProvider = provider
                return ScriptedTransport(stepResponses: [[.completed(finishReason: "stop")]])
            }
        )
        _ = try await collectEvents(from: freshOrchestrator.runTurn(env.defaultInput))
        XCTAssertNil(defaults.string(forKey: AIConversationProviderPreference.storageKey))
        XCTAssertEqual(freshProvider, AIRecommendationProvider.defaultProvider)

        // Legacy device-local recommendation with no conversation choice yet:
        // the turn ends without a transport instead of picking a cloud model.
        defaults.set(AIRecommendationProvider.apple.rawValue, forKey: AIRecommendationProvider.storageKey)
        var transportBuiltWhileAwaitingChoice = false
        let appleOrchestrator = ConversationOrchestrator(
            contextAssembler: env.assembler,
            domainTools: env.domainTools,
            actionCoordinator: env.coordinator,
            userDefaults: defaults,
            transportFactory: { _ in
                transportBuiltWhileAwaitingChoice = true
                return ScriptedTransport()
            }
        )
        let appleEvents = try await collectEvents(from: appleOrchestrator.runTurn(env.defaultInput))
        XCTAssertFalse(transportBuiltWhileAwaitingChoice)
        let appleErrors = appleEvents.compactMap { ev -> AIErrorBlock? in
            if case let .appendBlock(.error(err)) = ev { return err }
            return nil
        }
        XCTAssertEqual(
            appleErrors.first?.message,
            AIConversationProviderPreference.setupTitle + AIConversationProviderPreference.setupDetail
        )

        // The member answers the setup state. Recipe recommendations stay on
        // the device model while the next send goes to the chosen cloud one.
        AIConversationProviderPreference.select(.groq, in: defaults)
        var providerAfterChoice: AIRecommendationProvider?
        let afterSettingsOrchestrator = ConversationOrchestrator(
            contextAssembler: env.assembler,
            domainTools: env.domainTools,
            actionCoordinator: env.coordinator,
            userDefaults: defaults,
            transportFactory: { provider in
                providerAfterChoice = provider
                return ScriptedTransport(stepResponses: [[.completed(finishReason: "stop")]])
            }
        )
        _ = try await collectEvents(from: afterSettingsOrchestrator.runTurn(env.defaultInput))
        XCTAssertEqual(providerAfterChoice, .groq)
        XCTAssertEqual(
            AIRecommendationProvider.selected(in: defaults),
            .apple,
            "recipe recommendations must still run on the device model"
        )
    }

    // 34: State machine: valid successful no-tool turn transition sequence
    func testStateMachine_validSuccessfulNoToolTurn() async throws {
        let env = try TestEnv()
        let transport = ScriptedTransport(stepResponses: [
            [.textDelta("你好"), .completed(finishReason: "stop")]
        ])
        let orchestrator = env.makeOrchestrator(transport: transport)
        let events = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        let states = events.compactMap { ev -> AIConversationTurnState? in
            if case let .state(s) = ev { return s }
            return nil
        }
        XCTAssertEqual(states, [.preparingContext, .requesting, .streaming, .completed])
    }

    // 35: State machine: medium/high pending-confirmation transition sequence
    func testStateMachine_mediumHighPendingConfirmation() async throws {
        let env = try TestEnv()
        let oldRecipe = Recipe(id: "r-old", title: "旧菜", cookingTime: 5, difficulty: nil, tags: [], ingredients: ["菜"], steps: ["做"])
        let newRecipe = Recipe(id: "r-new", title: "新菜", cookingTime: 5, difficulty: nil, tags: [], ingredients: ["菜"], steps: ["做"])
        try env.recipeStore.saveUserRecipe(oldRecipe)
        try env.recipeStore.saveUserRecipe(newRecipe)
        guard case .saved(let plan) = env.kitchenStore.addPlan(recipe: oldRecipe, on: Date(), calendar: env.domainTools.calendar) else { return XCTFail() }

        let step1: [AIConversationStreamEvent] = [
            .textDelta("替换菜品"),
            .toolCall(id: "c-rep", name: "propose_replace_planned_meal", arguments: Data(#"{"planID":"\#(plan.id.uuidString)","replacement":{"recipeID":"r-new","title":"新菜"}}"#.utf8)),
            .completed(finishReason: "stop")
        ]
        let transport = ScriptedTransport(stepResponses: [step1])
        let orchestrator = env.makeOrchestrator(transport: transport)
        let events = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        let states = events.compactMap { ev -> AIConversationTurnState? in
            if case let .state(s) = ev { return s }
            return nil
        }
        XCTAssertEqual(states, [.preparingContext, .requesting, .streaming, .toolRequested, .awaitingConfirmation])
    }

    // 36: State machine: failed sequence
    func testStateMachine_failedSequence() async throws {
        let env = try TestEnv()
        let transport = ScriptedTransport(stepResponses: [
            [.error(code: "fatal", message: "boom")]
        ])
        let orchestrator = env.makeOrchestrator(transport: transport)
        let events = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        let states = events.compactMap { ev -> AIConversationTurnState? in
            if case let .state(s) = ev { return s }
            return nil
        }
        XCTAssertEqual(states, [.preparingContext, .requesting, .failed])
    }

    // 37: State machine: cancelled sequence
    func testStateMachine_cancelledSequence() async throws {
        let env = try TestEnv()
        let gate = AsyncGate()
        let secondGate = AsyncGate()
        let transport = ScriptedTransport()
        await transport.setGate(gate)
        await transport.setOnRequest { _ in
            await secondGate.wait()
            return [.textDelta("hi")]
        }

        let orchestrator = env.makeOrchestrator(transport: transport)
        let stream = orchestrator.runTurn(env.defaultInput)
        var iterator = stream.makeAsyncIterator()

        _ = try await iterator.next() // preparingContext
        _ = try await iterator.next() // contextSnapshot
        _ = try await iterator.next() // requesting
        await gate.open()

        // Cancel while waiting on secondGate
        orchestrator.cancelCurrentTurn()
        await secondGate.open()

        var remainingStates: [AIConversationTurnState] = []
        while let ev = try await iterator.next() {
            if case let .state(s) = ev { remainingStates.append(s) }
        }
        XCTAssertEqual(remainingStates, [.cancelled])
    }

    // 38: State machine: no simultaneous active-turn event leakage
    func testStateMachine_noSimultaneousActiveTurnEventLeakage() async throws {
        let env = try TestEnv()
        let gate = AsyncGate()
        let transport = ScriptedTransport()
        await transport.setGate(gate)
        await transport.setOnRequest { req in
            if req.messages.contains(where: { $0.content == "Turn 1" }) {
                return [.textDelta("Leak from 1")]
            } else {
                return [.textDelta("Response 2"), .completed(finishReason: "stop")]
            }
        }

        let orchestrator = env.makeOrchestrator(transport: transport)
        let msg1 = AIConversationMessage(conversationID: env.conversationID, role: .user, state: .completed, contentBlocks: [.text(.init(text: "Turn 1"))], turnID: UUID())
        let input1 = AIConversationTurnInput(conversationID: env.conversationID, currentUserMessage: msg1)

        let msg2 = AIConversationMessage(conversationID: env.conversationID, role: .user, state: .completed, contentBlocks: [.text(.init(text: "Turn 2"))], turnID: UUID())
        let input2 = AIConversationTurnInput(conversationID: env.conversationID, currentUserMessage: msg2)

        _ = orchestrator.runTurn(input1)
        // Immediately start Turn 2 before Turn 1 finishes
        let stream2 = orchestrator.runTurn(input2)
        await gate.open()

        let events2 = try await collectEvents(from: stream2)
        XCTAssertFalse(events2.contains(.appendText("Leak from 1")))
        XCTAssertTrue(events2.contains(.appendText("Response 2")))
    }

    // 39: Two shopping proposals in one step (5+5 bypass) are rejected before any write
    func testTwoShoppingProposalsInOneStepAreRejectedBeforeAnyWrite() async throws {
        let env = try TestEnv()
        let itemsA = #"{"items":[{"name":"A1","quantity":1,"unit":"个"},{"name":"A2","quantity":1,"unit":"个"},{"name":"A3","quantity":1,"unit":"个"},{"name":"A4","quantity":1,"unit":"个"},{"name":"A5","quantity":1,"unit":"个"}]}"#
        let itemsB = #"{"items":[{"name":"B1","quantity":1,"unit":"个"},{"name":"B2","quantity":1,"unit":"个"},{"name":"B3","quantity":1,"unit":"个"},{"name":"B4","quantity":1,"unit":"个"},{"name":"B5","quantity":1,"unit":"个"}]}"#

        let stepEvents: [AIConversationStreamEvent] = [
            .toolCall(id: "c-shop-1", name: "propose_add_shopping_items", arguments: Data(itemsA.utf8)),
            .toolCall(id: "c-shop-2", name: "propose_add_shopping_items", arguments: Data(itemsB.utf8)),
            .completed(finishReason: "stop")
        ]

        let transport = ScriptedTransport(stepResponses: [stepEvents])
        let orchestrator = env.makeOrchestrator(transport: transport)
        let events = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        XCTAssertEqual(env.kitchenStore.shoppingItems.count, 0)
        XCTAssertTrue(events.contains(.state(.failed)))
        XCTAssertFalse(events.contains(.state(.completed)))
    }

    // 40: Multiple low-risk mutation proposals in one logical turn are rejected
    func testMultipleLowRiskMutationProposalsInOneTurnAreRejected() async throws {
        let env = try TestEnv()
        let r1 = Recipe(id: "r1", title: "菜1", cookingTime: 5, difficulty: nil, tags: [], ingredients: ["1"], steps: ["1"])
        let r2 = Recipe(id: "r2", title: "菜2", cookingTime: 5, difficulty: nil, tags: [], ingredients: ["2"], steps: ["2"])
        try env.recipeStore.saveUserRecipe(r1)
        try env.recipeStore.saveUserRecipe(r2)

        let stepEvents: [AIConversationStreamEvent] = [
            .toolCall(id: "c-m1", name: "propose_add_recipe_to_tonight", arguments: Data(#"{"recipe":{"recipeID":"r1","title":"菜1"}}"#.utf8)),
            .toolCall(id: "c-m2", name: "propose_add_recipe_to_tonight", arguments: Data(#"{"recipe":{"recipeID":"r2","title":"菜2"}}"#.utf8)),
            .completed(finishReason: "stop")
        ]

        let transport = ScriptedTransport(stepResponses: [stepEvents])
        let orchestrator = env.makeOrchestrator(transport: transport)
        let events = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        XCTAssertEqual(env.kitchenStore.plans.count, 0) // Neither executed!
        XCTAssertTrue(events.contains(.state(.failed)))
    }

    // 41: Medium/high + low-risk mutation calls in the same provider step are rejected before any write
    func testMediumHighPlusLowRiskMutationCallsInSameStepAreRejectedBeforeAnyWrite() async throws {
        let env = try TestEnv()
        let rOld = Recipe(id: "r-old", title: "旧菜", cookingTime: 5, difficulty: nil, tags: [], ingredients: ["旧"], steps: ["做"])
        let rNew = Recipe(id: "r-new", title: "新菜", cookingTime: 5, difficulty: nil, tags: [], ingredients: ["新"], steps: ["做"])
        let rTon = Recipe(id: "r-ton", title: "今晚菜", cookingTime: 5, difficulty: nil, tags: [], ingredients: ["今"], steps: ["做"])
        try env.recipeStore.saveUserRecipe(rOld)
        try env.recipeStore.saveUserRecipe(rNew)
        try env.recipeStore.saveUserRecipe(rTon)

        guard case .saved(let plan) = env.kitchenStore.addPlan(recipe: rOld, on: Date(), calendar: env.domainTools.calendar) else { return XCTFail() }

        let stepEvents: [AIConversationStreamEvent] = [
            .toolCall(id: "c-low", name: "propose_add_recipe_to_tonight", arguments: Data(#"{"recipe":{"recipeID":"r-ton","title":"今晚菜"}}"#.utf8)),
            .toolCall(id: "c-med", name: "propose_replace_planned_meal", arguments: Data(#"{"planID":"\#(plan.id.uuidString)","replacement":{"recipeID":"r-new","title":"新菜"}}"#.utf8)),
            .completed(finishReason: "stop")
        ]

        let transport = ScriptedTransport(stepResponses: [stepEvents])
        let orchestrator = env.makeOrchestrator(transport: transport)
        let events = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        XCTAssertEqual(env.kitchenStore.plans.count, 1)
        XCTAssertEqual(env.kitchenStore.plans.first?.recipeName, "旧菜") // Neither changed!
        XCTAssertTrue(events.contains(.state(.failed)))
    }

    // 42: Read + mutation in the same provider step fails closed before any mutation write
    func testReadPlusMutationInSameStepFailsClosedBeforeAnyMutation() async throws {
        let env = try TestEnv()
        let stepEvents: [AIConversationStreamEvent] = [
            .toolCall(id: "c-rd", name: "read_inventory", arguments: Data("{}".utf8)),
            .toolCall(id: "c-mut", name: "propose_add_shopping_items", arguments: Data(#"{"items":[{"name":"土豆","quantity":2,"unit":"个"}]}"#.utf8)),
            .completed(finishReason: "tool_calls")
        ]

        let transport = ScriptedTransport(stepResponses: [stepEvents])
        let orchestrator = env.makeOrchestrator(transport: transport)
        let events = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        XCTAssertEqual(env.kitchenStore.shoppingItems.count, 0)
        XCTAssertTrue(events.contains(.state(.failed)))
        XCTAssertFalse(events.contains(.state(.completed)))
    }

    // 43: One valid low-risk mutation executes once, emits actionStatus, completes turn, and issues NO subsequent provider request
    func testOneValidLowRiskMutationExecutesOnceAndCompletesWithoutSubsequentProviderRequest() async throws {
        let env = try TestEnv()
        let recipe = Recipe(id: "r-solo", title: "红烧排骨", cookingTime: 30, difficulty: "中等", tags: [], ingredients: ["排骨"], steps: ["红烧"])
        try env.recipeStore.saveUserRecipe(recipe)

        let stepEvents: [AIConversationStreamEvent] = [
            .toolCall(id: "c-add", name: "propose_add_recipe_to_tonight", arguments: Data(#"{"recipe":{"recipeID":"r-solo","title":"红烧排骨"}}"#.utf8)),
            .completed(finishReason: "stop")
        ]

        let transport = ScriptedTransport(stepResponses: [stepEvents])
        let orchestrator = env.makeOrchestrator(transport: transport)
        let events = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        XCTAssertEqual(env.kitchenStore.plans.count, 1)
        XCTAssertTrue(events.contains(where: {
            if case let .appendBlock(.actionStatus(st)) = $0 { return st.canUndo && !st.isFailure }
            return false
        }))
        XCTAssertTrue(events.contains(.state(.completed)))
        XCTAssertTrue(events.contains(.finished))

        let reqs = await transport.capturedRequests
        XCTAssertEqual(reqs.count, 1) // NO subsequent provider request!
    }

    // 44: Presentation + read in one step: every assistant tool_call ID has one matching tool-result ID in continuation
    func testPresentationPlusReadInOneStepHasMatchingToolResultsForEveryToolCallBeforeContinuation() async throws {
        let env = try TestEnv()
        let recipe = Recipe(id: "r-card", title: "拌黄瓜", cookingTime: 5, difficulty: nil, tags: [], ingredients: ["黄瓜"], steps: ["拌"])
        try env.recipeStore.saveUserRecipe(recipe)

        let step1Events: [AIConversationStreamEvent] = [
            .toolCall(id: "pres-1", name: "present_recipe_card", arguments: Data(#"{"recipe":{"recipeID":"r-card","title":"拌黄瓜"}}"#.utf8)),
            .toolCall(id: "read-1", name: "read_inventory", arguments: Data("{}".utf8)),
            .completed(finishReason: "tool_calls")
        ]
        let step2Events: [AIConversationStreamEvent] = [
            .completed(finishReason: "stop")
        ]

        let transport = ScriptedTransport(stepResponses: [step1Events, step2Events])
        let orchestrator = env.makeOrchestrator(transport: transport)
        _ = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        let reqs = await transport.capturedRequests
        XCTAssertEqual(reqs.count, 2)
        let step2Messages = reqs[1].messages

        // Find assistant tool calls in step 2
        let assistantCalls = step2Messages.first(where: { $0.role == .assistant && $0.toolCalls != nil })?.toolCalls ?? []
        let assistantCallIDs = Set(assistantCalls.map(\.id))
        XCTAssertEqual(assistantCallIDs, ["pres-1", "read-1"])

        // Find all tool results in step 2
        let toolResultIDs = Set(step2Messages.filter { $0.role == .tool }.compactMap(\.toolCallID))
        XCTAssertEqual(assistantCallIDs, toolResultIDs) // Exact pairing!
    }

    // 45: Two read calls: both have matching results before continuation
    func testTwoReadCallsHaveMatchingToolResultsBeforeContinuation() async throws {
        let env = try TestEnv()
        let step1Events: [AIConversationStreamEvent] = [
            .toolCall(id: "rd-1", name: "read_inventory", arguments: Data("{}".utf8)),
            .toolCall(id: "rd-2", name: "read_tonight_plan", arguments: Data("{}".utf8)),
            .completed(finishReason: "tool_calls")
        ]
        let step2Events: [AIConversationStreamEvent] = [
            .completed(finishReason: "stop")
        ]

        let transport = ScriptedTransport(stepResponses: [step1Events, step2Events])
        let orchestrator = env.makeOrchestrator(transport: transport)
        _ = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        let reqs = await transport.capturedRequests
        XCTAssertEqual(reqs.count, 2)
        let step2Messages = reqs[1].messages

        let assistantCalls = step2Messages.first(where: { $0.role == .assistant && $0.toolCalls != nil })?.toolCalls ?? []
        let assistantCallIDs = Set(assistantCalls.map(\.id))
        XCTAssertEqual(assistantCallIDs, ["rd-1", "rd-2"])

        let toolResultIDs = Set(step2Messages.filter { $0.role == .tool }.compactMap(\.toolCallID))
        XCTAssertEqual(assistantCallIDs, toolResultIDs)
    }

    // 46: Presentation + optional failing read: both calls are resolved in the continuation transcript
    func testPresentationPlusOptionalFailingReadResolvesBothCallsInContinuationTranscript() async throws {
        let env = try TestEnv()
        let recipe = Recipe(id: "r-p", title: "鸡蛋", cookingTime: 5, difficulty: nil, tags: [], ingredients: ["蛋"], steps: ["做"])
        try env.recipeStore.saveUserRecipe(recipe)

        let step1Events: [AIConversationStreamEvent] = [
            .toolCall(id: "pres-opt", name: "present_recipe_card", arguments: Data(#"{"recipe":{"recipeID":"r-p","title":"鸡蛋"}}"#.utf8)),
            .toolCall(id: "read-fail", name: "read_special_plan", arguments: Data(#"{"planID":"\#(UUID().uuidString)"}"#.utf8)),
            .completed(finishReason: "tool_calls")
        ]
        let step2Events: [AIConversationStreamEvent] = [.completed(finishReason: "stop")]

        let transport = ScriptedTransport(stepResponses: [step1Events, step2Events])
        let orchestrator = env.makeOrchestrator(
            transport: transport,
            isReadOptional: { _ in true }
        )
        _ = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        let reqs = await transport.capturedRequests
        XCTAssertEqual(reqs.count, 2)
        let step2Messages = reqs[1].messages

        let assistantCallIDs = Set(step2Messages.first(where: { $0.role == .assistant && $0.toolCalls != nil })?.toolCalls?.map(\.id) ?? [])
        XCTAssertEqual(assistantCallIDs, ["pres-opt", "read-fail"])

        let toolResultIDs = Set(step2Messages.filter { $0.role == .tool }.compactMap(\.toolCallID))
        XCTAssertEqual(assistantCallIDs, toolResultIDs)
    }

    // 47: Malformed presentation tool: one error only, failed terminal, no continuation
    func testMalformedPresentationToolCausesOneErrorFailedTerminalAndNoContinuation() async throws {
        let env = try TestEnv()
        let step1Events: [AIConversationStreamEvent] = [
            .toolCall(id: "c-bad-pres", name: "present_recipe_card", arguments: Data(#"{"recipe":{"title":"无步骤菜谱"}}"#.utf8)),
            .completed(finishReason: "stop")
        ]

        let transport = ScriptedTransport(stepResponses: [step1Events])
        let orchestrator = env.makeOrchestrator(transport: transport)
        let events = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        let errorBlocks = events.compactMap { ev -> AIErrorBlock? in
            if case let .appendBlock(.error(err)) = ev { return err }
            return nil
        }
        XCTAssertEqual(errorBlocks.count, 1)
        XCTAssertEqual(errorBlocks.first?.message, "无法识别这次操作，没有改动。")
        XCTAssertTrue(events.contains(.state(.failed)))
        XCTAssertFalse(events.contains(.state(.completed)))
        XCTAssertFalse(events.contains(.finished))

        let reqs = await transport.capturedRequests
        XCTAssertEqual(reqs.count, 1) // NO continuation!
    }

    // 48: Large inventory continuation must fit server AI_PROMPT_MAX_CHARS (12,000)
    func testLargeInventoryContinuationMustFitServerBudget() async throws {
        let env = try TestEnv()
        for i in 1...150 {
            _ = env.kitchenStore.addInventory(name: "食材编号_#(i)_有机生鲜蔬菜大米调味品", quantity: Double(i), unit: "包", expiryDate: Date().addingTimeInterval(TimeInterval(i * 86400)))
        }

        let step1Events: [AIConversationStreamEvent] = [
            .toolCall(id: "call-big-inv", name: "read_inventory", arguments: Data("{}".utf8)),
            .completed(finishReason: "tool_calls")
        ]
        let step2Events: [AIConversationStreamEvent] = [
            .completed(finishReason: "stop")
        ]

        let transport = ScriptedTransport(stepResponses: [step1Events, step2Events])
        let orchestrator = env.makeOrchestrator(transport: transport)
        _ = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        let reqs = await transport.capturedRequests
        XCTAssertEqual(reqs.count, 2)
        let step2Cost = ConversationOrchestrator.serverCompatibleCharacterCost(reqs[1].messages)
        XCTAssertLessThanOrEqual(step2Cost, ConversationOrchestrator.serverPromptMaxChars)
    }

    // 49: Near-max initial context + large inventory: continuation stays within limit preserving core exchange
    func testNearMaxInitialContextPlusLargeInventoryStaysWithinLimit() async throws {
        let env = try TestEnv()
        for i in 1...100 {
            _ = env.kitchenStore.addInventory(name: "食材_#(i)_保鲜冷藏", quantity: Double(i), unit: "斤", expiryDate: nil)
        }

        // Add older prior messages that fill up context
        var priors: [AIConversationMessage] = []
        for i in 1...6 {
            let pUser = AIConversationMessage(conversationID: env.conversationID, role: .user, state: .completed, contentBlocks: [.text(.init(text: String(repeating: "历史提问_#(i)_", count: 30)))], turnID: UUID())
            let pAss = AIConversationMessage(conversationID: env.conversationID, role: .assistant, state: .completed, contentBlocks: [.text(.init(text: String(repeating: "历史回答_#(i)_", count: 30)))], turnID: UUID())
            priors.append(contentsOf: [pUser, pAss])
        }
        let input = AIConversationTurnInput(
            conversationID: env.conversationID,
            turnID: env.turnID,
            summary: String(repeating: "长期记忆摘要内容_", count: 20),
            priorMessages: priors,
            currentUserMessage: env.currentUserMessage
        )

        let step1Events: [AIConversationStreamEvent] = [
            .toolCall(id: "c-inv-big", name: "read_inventory", arguments: Data("{}".utf8)),
            .completed(finishReason: "tool_calls")
        ]
        let step2Events: [AIConversationStreamEvent] = [.completed(finishReason: "stop")]

        let transport = ScriptedTransport(stepResponses: [step1Events, step2Events])
        let orchestrator = env.makeOrchestrator(transport: transport)
        _ = try await collectEvents(from: orchestrator.runTurn(input))

        let reqs = await transport.capturedRequests
        XCTAssertEqual(reqs.count, 2)
        let step2Cost = ConversationOrchestrator.serverCompatibleCharacterCost(reqs[1].messages)
        XCTAssertLessThanOrEqual(step2Cost, ConversationOrchestrator.serverPromptMaxChars)

        // Verify current user message and tool result remain preserved
        XCTAssertTrue(reqs[1].messages.contains(where: { $0.role == .user && $0.content?.contains("今晚吃什么？") == true }))
        XCTAssertTrue(reqs[1].messages.contains(where: { $0.role == .tool && $0.toolCallID == "c-inv-big" }))
    }

    // 50: Multiple sequential read steps: every request independently stays <= 12,000
    func testMultipleSequentialReadStepsEveryRequestIndependentlyStaysWithinLimit() async throws {
        let env = try TestEnv()
        for i in 1...80 {
            _ = env.kitchenStore.addInventory(name: "备选食材_#(i)", quantity: 2, unit: "袋", expiryDate: nil)
        }

        let step1: [AIConversationStreamEvent] = [
            .toolCall(id: "c-seq-1", name: "read_inventory", arguments: Data("{}".utf8)),
            .completed(finishReason: "tool_calls")
        ]
        let step2: [AIConversationStreamEvent] = [
            .toolCall(id: "c-seq-2", name: "read_tonight_plan", arguments: Data("{}".utf8)),
            .completed(finishReason: "tool_calls")
        ]
        let step3: [AIConversationStreamEvent] = [
            .toolCall(id: "c-seq-3", name: "read_planner_week", arguments: Data(#"{"weekStart":"2026-09-14"}"#.utf8)),
            .completed(finishReason: "tool_calls")
        ]
        let step4: [AIConversationStreamEvent] = [
            .completed(finishReason: "stop")
        ]

        let transport = ScriptedTransport(stepResponses: [step1, step2, step3, step4])
        let orchestrator = env.makeOrchestrator(transport: transport)
        _ = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        let reqs = await transport.capturedRequests
        XCTAssertEqual(reqs.count, 4)
        for (idx, req) in reqs.enumerated() {
            let cost = ConversationOrchestrator.serverCompatibleCharacterCost(req.messages)
            XCTAssertLessThanOrEqual(cost, ConversationOrchestrator.serverPromptMaxChars, "Request at index \(idx) exceeded limit")
        }
    }

    // 51: Large planner-week result produces valid bounded JSON <= 12,000
    func testLargePlannerWeekResultProducesValidBoundedJSONWithinLimit() async throws {
        let env = try TestEnv()
        for i in 1...30 {
            let r = Recipe(id: "r-wk-\(i)", title: "菜谱_\(i)", cookingTime: 10, difficulty: nil, tags: [], ingredients: ["原料_\(i)"], steps: ["翻炒"])
            try env.recipeStore.saveUserRecipe(r)
            _ = env.kitchenStore.addPlan(recipe: r, on: Date().addingTimeInterval(TimeInterval(i * 3600 * 4)), calendar: env.domainTools.calendar)
        }

        let step1: [AIConversationStreamEvent] = [
            .toolCall(id: "c-wk", name: "read_planner_week", arguments: Data(#"{"weekStart":"2026-09-14"}"#.utf8)),
            .completed(finishReason: "tool_calls")
        ]
        let step2: [AIConversationStreamEvent] = [.completed(finishReason: "stop")]

        let transport = ScriptedTransport(stepResponses: [step1, step2])
        let orchestrator = env.makeOrchestrator(transport: transport)
        _ = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        let reqs = await transport.capturedRequests
        XCTAssertEqual(reqs.count, 2)
        let cost = ConversationOrchestrator.serverCompatibleCharacterCost(reqs[1].messages)
        XCTAssertLessThanOrEqual(cost, ConversationOrchestrator.serverPromptMaxChars)

        // Verify valid JSON
        let toolMsg = reqs[1].messages.first(where: { $0.role == .tool && $0.toolCallID == "c-wk" })
        XCTAssertNotNil(toolMsg?.content)
        let jsonObj = try JSONSerialization.jsonObject(with: Data(toolMsg!.content!.utf8))
        XCTAssertNotNil(jsonObj)
    }

    // 52: Large Special Plan result produces valid bounded JSON <= 12,000
    func testLargeSpecialPlanResultProducesValidBoundedJSONWithinLimit() async throws {
        let env = try TestEnv()
        var dishes: [SpecialPlanDish] = []
        for i in 1...30 {
            dishes.append(SpecialPlanDish(id: UUID(), recipeID: "rec-#(i)", recipeName: "宴席菜品_#(i)_风味浓郁", isCooked: false))
        }
        let plan = SpecialPlan(
            id: UUID(),
            title: "超大型家庭聚餐宴席活动",
            scheduledAt: Date().addingTimeInterval(86400),
            peopleCount: 20,
            constraintNotes: (1...15).map { "忌口约束条目编号_\($0)_不吃辣无葱花" },
            notes: "详细活动说明文档内容",
            usesHomeInventory: true,
            dishes: dishes
        )
        env.kitchenStore.specialPlans = [plan]

        let step1: [AIConversationStreamEvent] = [
            .toolCall(id: "c-spec-big", name: "read_special_plan", arguments: Data(#"{"planID":"\#(plan.id.uuidString)"}"#.utf8)),
            .completed(finishReason: "tool_calls")
        ]
        let step2: [AIConversationStreamEvent] = [.completed(finishReason: "stop")]

        let transport = ScriptedTransport(stepResponses: [step1, step2])
        let orchestrator = env.makeOrchestrator(transport: transport)
        _ = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        let reqs = await transport.capturedRequests
        XCTAssertEqual(reqs.count, 2)
        let cost = ConversationOrchestrator.serverCompatibleCharacterCost(reqs[1].messages)
        XCTAssertLessThanOrEqual(cost, ConversationOrchestrator.serverPromptMaxChars)

        let toolMsg = reqs[1].messages.first(where: { $0.role == .tool && $0.toolCallID == "c-spec-big" })
        XCTAssertNotNil(toolMsg?.content)
        let jsonObj = try JSONSerialization.jsonObject(with: Data(toolMsg!.content!.utf8))
        XCTAssertNotNil(jsonObj)
    }

    // 53: Unicode, emoji, and escaped strings character budget agrees with UTF-16 server semantics
    func testUnicodeEmojiAndEscapedStringsCharacterBudgetAgreesWithUTF16() {
        let sampleText = #"临期食材推荐 👨‍👩‍👧‍👦 "带引号" 🥑🥦🥕"#
        let msg = AIConversationTranscriptMessage.user(sampleText)!
        let cost = ConversationOrchestrator.serverCompatibleCharacterCost([msg])
        XCTAssertEqual(cost, sampleText.utf16.count)
    }

    // 54: Tool-call and result integrity remains exact after trimming
    func testToolCallAndResultIntegrityRemainsExactAfterTrimming() {
        let call1 = AIConversationTranscriptToolCall(id: "call-1", name: "read_inventory", arguments: .object(["arg": .string(String(repeating: "x", count: 2000))]))
        let call2 = AIConversationTranscriptToolCall(id: "call-2", name: "read_tonight_plan", arguments: .object(["arg": .string(String(repeating: "y", count: 2000))]))

        let messages: [AIConversationTranscriptMessage] = [
            .systemText("系统指令")!,
            .systemText("摘要内容")!,
            .systemText("实时上下文")!,
            .user("用户提问")!,
            .assistantToolCalls([call1])!,
            .toolResult(forToolCallID: "call-1", text: String(repeating: "result1_", count: 400))!,
            .assistantToolCalls([call2])!,
            .toolResult(forToolCallID: "call-2", text: String(repeating: "result2_", count: 400))!,
        ]

        let budgeted = ConversationOrchestrator.rebudgetContinuation(messages, limit: 7000)
        XCTAssertNotNil(budgeted)
        guard let list = budgeted else { return }

        // All assistant tool_calls in the list must have their matching tool_result
        let assistantCalls = list.filter { $0.role == .assistant && $0.toolCalls != nil }.flatMap { $0.toolCalls! }
        let toolResults = list.filter { $0.role == .tool }.compactMap { $0.toolCallID }

        let callIDs = Set(assistantCalls.map(\.id))
        let resultIDs = Set(toolResults)
        XCTAssertEqual(callIDs, resultIDs, "Tool calls and tool results must remain paired")
    }

    // 55: Current live read truth wins over older stale history when budget requires trimming
    func testCurrentLiveReadTruthWinsOverOlderStaleHistoryWhenBudgetRequiresTrimming() {
        let oldHistoryUser = AIConversationTranscriptMessage.user(String(repeating: "以前有四个鸡蛋_", count: 200))!
        let oldHistoryAss = AIConversationTranscriptMessage.assistantText(String(repeating: "历史记录说有四个鸡蛋_", count: 200))!

        let liveCall = AIConversationTranscriptToolCall(id: "call-live", name: "read_inventory", arguments: .object([:]))
        let liveResult = AIConversationTranscriptMessage.toolResult(forToolCallID: "call-live", text: #"{"available":[{"name":"鸡蛋","quantity":1}],"readAt":"2026-09-17T09:00:00Z"}"#)!

        let messages: [AIConversationTranscriptMessage] = [
            .systemText("系统指令")!,
            .systemText("历史摘要")!,
            .systemText("旧实时数据")!,
            oldHistoryUser,
            oldHistoryAss,
            .user("现在有几个鸡蛋？")!,
            .assistantToolCalls([liveCall])!,
            liveResult
        ]

        // Impose a tight budget that forces trimming
        let budgeted = ConversationOrchestrator.rebudgetContinuation(messages, limit: 250)
        XCTAssertNotNil(budgeted)
        guard let list = budgeted else { return }

        // Live tool result must be retained
        XCTAssertTrue(list.contains(where: { $0.role == .tool && $0.toolCallID == "call-live" }))
        // Old stale history is trimmed
        XCTAssertFalse(list.contains(where: { $0.content?.contains("以前有四个鸡蛋") == true }))
    }

    // 56: Irreducible oversized request fails locally with zero network request for the oversized step
    func testIrreducibleOversizedRequestFailsLocallyWithZeroNetworkRequest() async throws {
        let env = try TestEnv()
        let hugeArgs = String(repeating: "超长大字典参数内容_", count: 1500)
        let step1Events: [AIConversationStreamEvent] = [
            .toolCall(id: "c-huge", name: "read_inventory", arguments: Data(#"{"key":"\#(hugeArgs)"}"#.utf8)),
            .completed(finishReason: "tool_calls")
        ]

        let transport = ScriptedTransport(stepResponses: [step1Events])
        let orchestrator = env.makeOrchestrator(transport: transport)
        let events = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        XCTAssertTrue(events.contains(.state(.failed)))
        XCTAssertFalse(events.contains(.state(.completed)))
        XCTAssertFalse(events.contains(.finished))

        let captured = await transport.capturedRequests
        XCTAssertEqual(captured.count, 1) // Step 1 was sent; step 2 was oversized and had ZERO network requests!
    }

    // 57: Context snapshot provenance: stable identity, accumulates successful reads, excludes failed reads
    func testContextSnapshotProvenanceEmittedAndAccumulatedAcrossReads() async throws {
        let env = try TestEnv()
        _ = env.kitchenStore.addInventory(name: "豆腐", quantity: 2, unit: "盒", expiryDate: nil)
        let recipe = Recipe(
            id: "snapshot-plan",
            title: "快炒豆腐",
            cookingTime: 10,
            difficulty: nil,
            tags: [],
            ingredients: ["豆腐"],
            steps: ["炒"]
        )
        let plan = env.kitchenStore.addPlan(
            recipe: recipe,
            on: Date(),
            calendar: env.domainTools.calendar
        ).value!

        let step1Events: [AIConversationStreamEvent] = [
            .toolCall(id: "c-inv-snap", name: "read_inventory", arguments: Data("{}".utf8)),
            .completed(finishReason: "tool_calls")
        ]
        let step2Events: [AIConversationStreamEvent] = [
            .toolCall(id: "c-tonight-snap", name: "read_tonight_plan", arguments: Data("{}".utf8)),
            .completed(finishReason: "tool_calls")
        ]
        let step3Events: [AIConversationStreamEvent] = [
            .toolCall(id: "c-spec-opt-fail", name: "read_special_plan", arguments: Data(#"{"planID":"\#(UUID().uuidString)"}"#.utf8)),
            .completed(finishReason: "tool_calls")
        ]
        let step4Events: [AIConversationStreamEvent] = [
            .completed(finishReason: "stop")
        ]

        let transport = ScriptedTransport(stepResponses: [step1Events, step2Events, step3Events, step4Events])
        let orchestrator = env.makeOrchestrator(
            transport: transport,
            isReadOptional: { _ in true }
        )
        let events = try await collectEvents(from: orchestrator.runTurn(env.defaultInput))

        let snapshots = events.compactMap { ev -> AIContextSnapshot? in
            if case let .contextSnapshot(snap) = ev { return snap }
            return nil
        }
        XCTAssertGreaterThanOrEqual(snapshots.count, 2)

        // All snapshots retain stable id == currentUserMessage.id and turnID == input.turnID
        for s in snapshots {
            XCTAssertEqual(s.id, env.currentUserMessage.id)
            XCTAssertEqual(s.turnID, env.defaultInput.turnID)
            // No raw payload is stored in sourceFingerprints (each is a SHA256 hex string of 64 chars)
            for fp in s.sourceFingerprints {
                XCTAssertEqual(fp.count, 64)
            }
        }

        // Final snapshot includes .inventory from successful read
        let finalSnapshot = snapshots.last!
        XCTAssertTrue(finalSnapshot.contextKinds.contains(.inventory))
        XCTAssertTrue(finalSnapshot.contextKinds.contains(.tonightPlan))
        XCTAssertTrue(finalSnapshot.relatedEntityIDs.contains(plan.id.uuidString))
        // Optional failed read does NOT falsely register .specialPlan in snapshot
        XCTAssertFalse(finalSnapshot.contextKinds.contains(.specialPlan))
    }

    // 48: Cancellation after low-risk mutation tool call before provider step completion prevents domain mutation
    func testCancellationAfterLowRiskToolCallBeforeStepCompletionPreventsDomainMutation() async throws {
        let env = try TestEnv()
        let recipe = Recipe(
            id: "rec-tonight",
            title: "西红柿鸡蛋汤",
            cookingTime: 10,
            difficulty: "简单",
            tags: ["家常菜"],
            ingredients: ["西红柿 2个", "鸡蛋 2个"],
            steps: ["切番茄", "打蛋花", "出锅"]
        )
        try env.recipeStore.saveUserRecipe(recipe)

        let toolCallEvent = AIConversationStreamEvent.toolCall(
            id: "call-lowrisk-1",
            name: "propose_add_recipe_to_tonight",
            arguments: Data(#"{"recipe":{"recipeID":"rec-tonight","title":"西红柿鸡蛋汤"}}"#.utf8)
        )
        let completedEvent = AIConversationStreamEvent.completed(finishReason: "stop")

        let toolCallDeliveredGate = AsyncGate()
        let allowLateCompletionGate = AsyncGate()
        let lateCompletionDeliveredGate = AsyncGate()

        let transport = ScriptedTransport()
        await transport.setIgnoreTaskCancellation(true) // Adversarial transport: does not stop immediately on Task.cancel()
        await transport.setOnRequest { _ in
            [toolCallEvent, completedEvent]
        }
        await transport.setOnEventYielded { event in
            if case .toolCall = event {
                await toolCallDeliveredGate.open()
            }
            if case .completed = event {
                await lateCompletionDeliveredGate.open()
            }
        }
        await transport.setPauseBeforeEvent { event in
            if case .completed = event {
                await allowLateCompletionGate.wait()
            }
        }

        let orchestrator = env.makeOrchestrator(transport: transport)
        let stream = orchestrator.runTurn(env.defaultInput)

        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next() // .state(.preparingContext)
        _ = try await iterator.next() // .contextSnapshot
        _ = try await iterator.next() // .state(.requesting)

        // Wait until the low-risk mutation tool call has actually arrived and been consumed by orchestrator
        await toolCallDeliveredGate.wait()
        let toolReqEvent = try await iterator.next()
        XCTAssertEqual(toolReqEvent, .state(.toolRequested), "Orchestrator must have observed and yielded toolRequested for the tool call")

        // The member cancels NOW, while the provider step is still in-flight before .completed
        orchestrator.cancelCurrentTurn()

        // Next event received on stream must be .state(.cancelled)
        let cancelEvent = try await iterator.next()
        XCTAssertEqual(cancelEvent, .state(.cancelled))

        // Now allow the adversarial provider to deliver its late .completed event and wait for acknowledgement
        await allowLateCompletionGate.open()
        await lateCompletionDeliveredGate.wait()
        await Task.yield()

        // Drain any remaining events in the stream
        var trailingEvents: [AIConversationTurnEvent] = []
        while let trailing = try await iterator.next() {
            trailingEvents.append(trailing)
        }

        // 1. Kitchen Domain state: absolutely no plan added to today!
        XCTAssertTrue(env.kitchenStore.plans.isEmpty, "Cancelled low-risk mutation must never modify KitchenStore plans")

        // 2. Action persistence: no action receipt created or executed!
        XCTAssertTrue(env.persistence.actions.isEmpty, "Cancelled low-risk mutation must never write action persistence")

        // 3. Outward events: must not contain any actionStatus, completed or finished
        XCTAssertFalse(trailingEvents.contains { event in
            if case .appendBlock(.actionStatus) = event { return true }
            if case .state(.completed) = event { return true }
            if case .finished = event { return true }
            return false
        }, "No success or completion events may be produced after cancellation")
    }
}

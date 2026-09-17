import Foundation

nonisolated enum AIConversationTurnEvent: Equatable, Sendable {
    case state(AIConversationTurnState)
    case appendText(String)
    case appendBlock(AIContentBlock)
    case replaceBlock(AIContentBlock)
    case pendingAction(PreparedAIAction)
    case finished
}

nonisolated struct AIConversationTurnInput: Sendable {
    let conversationID: UUID
    let turnID: UUID
    let entryContext: AIConversationEntryContext
    let summary: String
    let priorMessages: [AIConversationMessage]
    let currentUserMessage: AIConversationMessage
    let excludedContextKinds: Set<AIContextKind>
    let readAt: Date

    init(
        conversationID: UUID,
        turnID: UUID? = nil,
        entryContext: AIConversationEntryContext = .home,
        summary: String = "",
        priorMessages: [AIConversationMessage] = [],
        currentUserMessage: AIConversationMessage,
        excludedContextKinds: Set<AIContextKind> = [],
        readAt: Date = Date()
    ) {
        self.conversationID = conversationID
        self.turnID = turnID ?? currentUserMessage.turnID
        self.entryContext = entryContext
        self.summary = summary
        self.priorMessages = priorMessages
        self.currentUserMessage = currentUserMessage
        self.excludedContextKinds = excludedContextKinds
        self.readAt = readAt
    }
}

@MainActor
final class ConversationOrchestrator {
    static let maxProviderStepsPerTurn = 6
    static let maxToolCallsPerTurn = 12

    static let enabledTools: [String] = [
        "read_inventory",
        "read_tonight_plan",
        "read_planner_week",
        "read_special_plan",
        "resolve_recipe",
        "present_recipe_card",
        "present_context_result",
        "propose_add_recipe_to_tonight",
        "propose_replace_planned_meal",
        "propose_apply_planner_changes",
        "propose_special_plan_changes",
        "propose_add_shopping_items"
    ]

    private let contextAssembler: ConversationContextAssembler
    private let domainTools: any AIConversationDomainTooling
    private let actionCoordinator: ConversationActionCoordinator
    private let interpreter: ConversationResponseInterpreter
    private let providerRouter: (UserDefaults) -> AIConversationProviderRoute
    private let userDefaults: UserDefaults
    private let transportFactory: (AIRecommendationProvider) -> any AIConversationRuntimeTransport
    private let now: () -> Date
    private let uuidGenerator: () -> UUID
    private let isReadOptional: (AIReadToolRequest) -> Bool

    private var activeRunID: UUID?
    private var activeTask: Task<Void, Never>?
    private var isCancellationRequested: Bool = false
    private var activeContinuation: AsyncThrowingStream<AIConversationTurnEvent, Error>.Continuation?

    init(
        contextAssembler: ConversationContextAssembler,
        domainTools: any AIConversationDomainTooling,
        actionCoordinator: ConversationActionCoordinator,
        interpreter: ConversationResponseInterpreter = ConversationResponseInterpreter(),
        providerRouter: @escaping (UserDefaults) -> AIConversationProviderRoute = { AIConversationProviderRouter.route(userDefaults: $0) },
        userDefaults: UserDefaults = .standard,
        transportFactory: @escaping (AIRecommendationProvider) -> any AIConversationRuntimeTransport,
        now: @escaping () -> Date = Date.init,
        uuidGenerator: @escaping () -> UUID = UUID.init,
        isReadOptional: @escaping (AIReadToolRequest) -> Bool = { _ in false }
    ) {
        self.contextAssembler = contextAssembler
        self.domainTools = domainTools
        self.actionCoordinator = actionCoordinator
        self.interpreter = interpreter
        self.providerRouter = providerRouter
        self.userDefaults = userDefaults
        self.transportFactory = transportFactory
        self.now = now
        self.uuidGenerator = uuidGenerator
        self.isReadOptional = isReadOptional
    }

    func cancelCurrentTurn() {
        isCancellationRequested = true
        activeTask?.cancel()
        activeContinuation?.yield(.state(.cancelled))
        activeContinuation?.finish()
        activeContinuation = nil
        activeTask = nil
    }

    func runTurn(_ input: AIConversationTurnInput) -> AsyncThrowingStream<AIConversationTurnEvent, Error> {
        if activeTask != nil {
            cancelCurrentTurn()
        }

        let runID = uuidGenerator()
        activeRunID = runID
        isCancellationRequested = false

        return AsyncThrowingStream { continuation in
            self.activeContinuation = continuation

            continuation.onTermination = { [weak self] termination in
                if case .cancelled = termination {
                    Task { @MainActor [weak self] in
                        guard let self, self.activeRunID == runID else { return }
                        self.cancelCurrentTurn()
                    }
                }
            }

            let task = Task { [weak self] in
                guard let self else { return }
                await self.executeTurn(input: input, runID: runID, continuation: continuation)
            }
            self.activeTask = task
        }
    }

    private func executeTurn(
        input: AIConversationTurnInput,
        runID: UUID,
        continuation: AsyncThrowingStream<AIConversationTurnEvent, Error>.Continuation
    ) async {
        func emit(_ event: AIConversationTurnEvent) -> Bool {
            guard self.activeRunID == runID else { return false }
            if self.isCancellationRequested || Task.isCancelled {
                continuation.yield(.state(.cancelled))
                continuation.finish()
                return false
            }
            continuation.yield(event)
            return true
        }

        guard emit(.state(.preparingContext)) else { return }

        let preparedRequest: PreparedAIConversationRequest
        do {
            preparedRequest = try contextAssembler.prepare(
                entry: input.entryContext,
                summary: input.summary,
                messages: input.priorMessages,
                currentUserMessage: input.currentUserMessage,
                excludedKinds: input.excludedContextKinds,
                readAt: input.readAt
            )
        } catch {
            _ = emit(.appendBlock(.error(.init(id: uuidGenerator(), message: "准备对话上下文失败。", retry: .contextRead))))
            _ = emit(.state(.failed))
            continuation.finish()
            return
        }

        let route = providerRouter(userDefaults)
        let transport: any AIConversationRuntimeTransport
        switch route {
        case .cloud(let provider):
            transport = transportFactory(provider)
        case .unavailable(let message):
            _ = emit(.appendBlock(.error(.init(id: uuidGenerator(), message: message, retry: nil))))
            _ = emit(.state(.failed))
            continuation.finish()
            return
        }

        var ephemeralTranscript: [AIConversationTranscriptMessage] = preparedRequest.messages
        var providerStepCount = 0
        var toolCallCount = 0

        while true {
            guard self.activeRunID == runID && !self.isCancellationRequested && !Task.isCancelled else {
                _ = emit(.state(.cancelled))
                continuation.finish()
                return
            }

            providerStepCount += 1
            if providerStepCount > Self.maxProviderStepsPerTurn {
                _ = emit(.appendBlock(.error(.init(id: uuidGenerator(), message: "已达到本次对话的最大步骤上限，已停止处理。", retry: .generation))))
                _ = emit(.state(.failed))
                continuation.finish()
                return
            }

            guard emit(.state(.requesting)) else { return }

            let runtimeRequest = AIConversationRuntimeRequest(
                messages: ephemeralTranscript,
                enabledTools: Self.enabledTools,
                requestID: uuidGenerator()
            )

            var stepText = ""
            var stepToolCalls: [AIConversationToolCall] = []
            var stepError: (code: String, message: String)?

            do {
                let stream = await transport.stream(runtimeRequest)
                for try await event in stream {
                    guard self.activeRunID == runID && !self.isCancellationRequested && !Task.isCancelled else {
                        _ = emit(.state(.cancelled))
                        continuation.finish()
                        return
                    }

                    switch event {
                    case .textDelta(let delta):
                        guard emit(.state(.streaming)) else { return }
                        guard emit(.appendText(delta)) else { return }
                        stepText += delta

                    case .toolCall(let id, let name, let arguments):
                        toolCallCount += 1
                        if toolCallCount > Self.maxToolCallsPerTurn {
                            _ = emit(.appendBlock(.error(.init(id: uuidGenerator(), message: "已达到本次对话的工具调用上限，已停止执行后续操作。", retry: .generation))))
                            _ = emit(.state(.failed))
                            continuation.finish()
                            return
                        }
                        guard emit(.state(.toolRequested)) else { return }
                        let call = AIConversationToolCall(id: id, name: name, arguments: arguments)
                        if name == "present_recipe_card" || name == "present_context_result" {
                            let context = buildInterpretationContext(for: call)
                            let intent = interpreter.interpret(toolCall: call, context: context)
                            if case .appendBlock(let block) = intent {
                                guard emit(.appendBlock(block)) else { return }
                            }
                        }
                        stepToolCalls.append(call)

                    case .completed:
                        break

                    case .error(let code, let message):
                        stepError = (code, message)
                    }
                }
            } catch {
                if self.isCancellationRequested || Task.isCancelled {
                    _ = emit(.state(.cancelled))
                    continuation.finish()
                    return
                }
                _ = emit(.appendBlock(.error(.init(id: uuidGenerator(), message: "服务暂时不可用，请稍后重试。", retry: .generation))))
                _ = emit(.state(.failed))
                continuation.finish()
                return
            }

            if self.isCancellationRequested || Task.isCancelled {
                _ = emit(.state(.cancelled))
                continuation.finish()
                return
            }

            if let error = stepError {
                _ = emit(.appendBlock(.error(.init(id: uuidGenerator(), message: error.message, retry: .generation))))
                _ = emit(.state(.failed))
                continuation.finish()
                return
            }

            if stepToolCalls.isEmpty {
                guard emit(.state(.completed)) else { return }
                guard emit(.finished) else { return }
                continuation.finish()
                return
            }

            if !stepText.isEmpty {
                if let msg = AIConversationTranscriptMessage.assistantText(stepText) {
                    ephemeralTranscript.append(msg)
                }
            }

            var transcriptCalls: [AIConversationTranscriptToolCall] = []
            for call in stepToolCalls {
                let jsonVal = (try? JSONDecoder().decode(JSONAnyValue.self, from: call.arguments)) ?? .object([:])
                transcriptCalls.append(AIConversationTranscriptToolCall(id: call.id, name: call.name, arguments: jsonVal))
            }
            if let callsMsg = AIConversationTranscriptMessage.assistantToolCalls(transcriptCalls) {
                ephemeralTranscript.append(callsMsg)
            }

            var hasReadContinuation = false
            var shouldPauseTurn = false

            for call in stepToolCalls {
                if call.name == "present_recipe_card" || call.name == "present_context_result" {
                    continue
                }
                let context = buildInterpretationContext(for: call)
                let intent = interpreter.interpret(toolCall: call, context: context)

                switch intent {
                case .appendBlock(let block):
                    guard emit(.appendBlock(block)) else { return }

                case .proposeAction(let proposal):
                    do {
                        let prepared = try actionCoordinator.prepare(proposal, conversationID: input.conversationID, turnID: input.turnID)
                        if prepared.risk.requiresExplicitConfirmation {
                            if let preview = prepared.preview {
                                guard emit(.appendBlock(preview)) else { return }
                            }
                            guard emit(.pendingAction(prepared)) else { return }
                            guard emit(.state(.awaitingConfirmation)) else { return }
                            shouldPauseTurn = true
                        } else {
                            guard emit(.state(.executing)) else { return }
                            let execResult = try actionCoordinator.execute(prepared)
                            let statusMsg: String
                            switch proposal {
                            case .addRecipeToTonight: statusMsg = "已加入今晚计划"
                            case .addShoppingItems: statusMsg = "已加入购物清单"
                            default: statusMsg = "操作已完成"
                            }
                            let statusBlock = AIActionStatusBlock(
                                id: uuidGenerator(),
                                message: statusMsg,
                                actionID: execResult.record.actionID,
                                canUndo: true,
                                isFailure: false
                            )
                            guard emit(.appendBlock(.actionStatus(statusBlock))) else { return }
                        }
                    } catch {
                        let errBlock = AIErrorBlock(id: uuidGenerator(), message: error.localizedDescription, retry: .action)
                        guard emit(.appendBlock(.error(errBlock))) else { return }
                        guard emit(.state(.failed)) else { return }
                        continuation.finish()
                        return
                    }

                case .read(let readRequest):
                    guard emit(.state(.executing)) else { return }
                    do {
                        let resultText = try executeReadTool(readRequest)
                        if let toolMsg = AIConversationTranscriptMessage.toolResult(forToolCallID: call.id, text: resultText) {
                            ephemeralTranscript.append(toolMsg)
                            hasReadContinuation = true
                        }
                    } catch {
                        if isReadOptional(readRequest) {
                            if let toolMsg = AIConversationTranscriptMessage.toolResult(forToolCallID: call.id, text: #"{"error":"read_failed"}"#) {
                                ephemeralTranscript.append(toolMsg)
                                hasReadContinuation = true
                            }
                        } else {
                            let errBlock = AIErrorBlock(id: uuidGenerator(), message: "读取厨房上下文失败，已停止处理。", retry: .contextRead)
                            guard emit(.appendBlock(.error(errBlock))) else { return }
                            guard emit(.state(.failed)) else { return }
                            continuation.finish()
                            return
                        }
                    }
                }
            }

            if shouldPauseTurn {
                continuation.finish()
                return
            }

            if !hasReadContinuation {
                guard emit(.state(.completed)) else { return }
                guard emit(.finished) else { return }
                continuation.finish()
                return
            }
        }
    }

    private func executeReadTool(_ request: AIReadToolRequest) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        switch request {
        case .inventory(let expiringOnly):
            let inventory = domainTools.inventoryContext(now: now())
            if expiringOnly == true {
                let data = try encoder.encode(inventory.expiring)
                return String(decoding: data, as: UTF8.self)
            } else {
                let data = try encoder.encode(inventory)
                return String(decoding: data, as: UTF8.self)
            }
        case .tonightPlan:
            let tonight = domainTools.tonightPlanContext(now: now(), calendar: domainTools.calendar)
            let data = try encoder.encode(tonight)
            return String(decoding: data, as: UTF8.self)
        case .plannerWeek(let weekStart):
            let week = domainTools.plannerWeekContext(weekStart: weekStart, calendar: domainTools.calendar)
            let data = try encoder.encode(week)
            return String(decoding: data, as: UTF8.self)
        case .specialPlan(let id):
            guard let special = domainTools.specialPlanContext(id: id) else {
                throw AIDomainToolError.specialPlanNotFound(id)
            }
            let data = try encoder.encode(special)
            return String(decoding: data, as: UTF8.self)
        case .resolveRecipe(let query, let recipeID):
            if let recipe = domainTools.resolveRecipe(query: query, recipeID: recipeID) {
                let data = try encoder.encode(recipe)
                return String(decoding: data, as: UTF8.self)
            } else {
                return #"{"found":false}"#
            }
        }
    }

    private func buildInterpretationContext(for toolCall: AIConversationToolCall) -> AIConversationInterpretationContext {
        let blockID = uuidGenerator()
        let rowIDs = (0..<20).map { _ in uuidGenerator() }
        var recipesByPath: [String: AIRecipeBlock] = [:]
        var transientIdentitiesByPath: [String: AITransientRecipeIdentity] = [:]

        if let json = try? JSONDecoder().decode(JSONAnyValue.self, from: toolCall.arguments),
           case .object(let dict) = json {
            inspectRecipeField(dict["recipe"], path: "recipe", intoRecipes: &recipesByPath, intoTransients: &transientIdentitiesByPath)
            inspectRecipeField(dict["replacement"], path: "replacement", intoRecipes: &recipesByPath, intoTransients: &transientIdentitiesByPath)
            if case .array(let changes)? = dict["changes"] {
                for (index, change) in changes.enumerated() {
                    if case .object(let changeDict) = change {
                        inspectRecipeField(changeDict["replacement"], path: "changes.\(index).replacement", intoRecipes: &recipesByPath, intoTransients: &transientIdentitiesByPath)
                    }
                }
            }
        }

        return AIConversationInterpretationContext(
            blockID: blockID,
            rowIDs: rowIDs,
            recipesByPath: recipesByPath,
            transientIdentitiesByPath: transientIdentitiesByPath,
            calendar: domainTools.calendar
        )
    }

    private func inspectRecipeField(
        _ value: JSONAnyValue?,
        path: String,
        intoRecipes: inout [String: AIRecipeBlock],
        intoTransients: inout [String: AITransientRecipeIdentity]
    ) {
        guard case .object(let fields)? = value else { return }
        if case .string(let id)? = fields["recipeID"], !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let found = domainTools.resolveRecipe(query: "", recipeID: id) {
                intoRecipes[path] = AIRecipeBlock(id: uuidGenerator(), recipe: found, isTransient: false)
            }
        } else {
            intoTransients[path] = AITransientRecipeIdentity(blockID: uuidGenerator(), recipeID: "transient-" + uuidGenerator().uuidString)
        }
    }
}

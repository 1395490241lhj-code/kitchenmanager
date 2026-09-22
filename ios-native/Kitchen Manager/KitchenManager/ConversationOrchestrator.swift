import Foundation
import CryptoKit

nonisolated enum AIConversationTurnEvent: Equatable, Sendable {
    case state(AIConversationTurnState)
    case appendText(String)
    case appendBlock(AIContentBlock)
    case replaceBlock(AIContentBlock)
    case pendingAction(PreparedAIAction)
    case contextSnapshot(AIContextSnapshot)
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
protocol ConversationOrchestrating: AnyObject {
    func runTurn(_ input: AIConversationTurnInput) -> AsyncThrowingStream<AIConversationTurnEvent, Error>
    func cancelCurrentTurn()
}

@MainActor
final class ConversationOrchestrator: ConversationOrchestrating {
    static let maxProviderStepsPerTurn = 6
    static let maxToolCallsPerTurn = 12

    /// Cross-layer contract constant pinned to src/server/config.js: AI_PROMPT_MAX_CHARS = 12000.
    nonisolated static let serverPromptMaxChars = 12000

    nonisolated static func serverCompatibleCharacterCost(_ messages: [AIConversationTranscriptMessage]) -> Int {
        var total = 0
        for message in messages {
            if let content = message.content {
                total += content.utf16.count
            }
            if let toolCalls = message.toolCalls {
                for call in toolCalls {
                    if case .object(let dict) = call.arguments,
                       let str = try? AIConversationTranscriptToolCall.canonicalArgumentsString(dict) {
                        total += str.utf16.count
                    }
                }
            }
        }
        return total
    }

    nonisolated static func rebudgetContinuation(
        _ messages: [AIConversationTranscriptMessage],
        limit: Int = serverPromptMaxChars
    ) -> [AIConversationTranscriptMessage]? {
        var current = messages
        if serverCompatibleCharacterCost(current) <= limit {
            return current
        }

        // Priority 1: Trim older prior conversation messages (between initial headers and currentUser)
        while serverCompatibleCharacterCost(current) > limit {
            guard let currentUserIndex = current.lastIndex(where: { $0.role == .user }) else { break }
            var foundPriorIndex: Int?
            for idx in current.indices {
                if idx > 2 && idx < currentUserIndex {
                    let role = current[idx].role
                    if role == .user || role == .assistant {
                        foundPriorIndex = idx
                        break
                    }
                }
            }
            guard let priorIndex = foundPriorIndex else { break }
            current.remove(at: priorIndex)
        }
        if serverCompatibleCharacterCost(current) <= limit { return current }

        // Priority 2: Trim superseded preloaded live context (index 2)
        if current.indices.contains(2) && current[2].role == .system {
            current[2] = .systemText(#"{"live":[]}"#)!
        }
        if serverCompatibleCharacterCost(current) <= limit { return current }

        // Priority 2b: Trim old summary (index 1)
        if current.indices.contains(1) && current[1].role == .system {
            current.remove(at: 1)
        }
        if serverCompatibleCharacterCost(current) <= limit { return current }

        // Priority 3: Trim older ephemeral tool exchanges from earlier steps in this turn
        while serverCompatibleCharacterCost(current) > limit {
            var assistantIndices: [Int] = []
            for (idx, msg) in current.enumerated() {
                if msg.role == .assistant && msg.toolCalls != nil {
                    assistantIndices.append(idx)
                }
            }
            guard assistantIndices.count > 1 else { break }
            let oldestIndex = assistantIndices[0]
            var callIDs = Set<String>()
            if let calls = current[oldestIndex].toolCalls {
                for c in calls { callIDs.insert(c.id) }
            }
            var filtered: [AIConversationTranscriptMessage] = []
            for (idx, msg) in current.enumerated() {
                if idx == oldestIndex { continue }
                if msg.role == .tool, let id = msg.toolCallID, callIDs.contains(id) { continue }
                filtered.append(msg)
            }
            current = filtered
        }
        if serverCompatibleCharacterCost(current) <= limit { return current }

        return nil
    }

    private struct ExecutedReadToolResult {
        let text: String
        let relatedEntityIDs: [String]
    }

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

    nonisolated private static func semanticEntityIDs(in json: String) -> [String] {
        guard let value = try? JSONDecoder().decode(JSONAnyValue.self, from: Data(json.utf8)) else {
            return []
        }
        func collect(_ value: JSONAnyValue) -> [String] {
            switch value {
            case let .object(fields):
                return fields.flatMap { key, child in
                    if key.hasSuffix("ID"), case let .string(id) = child { return [id] }
                    return collect(child)
                }
            case let .array(values):
                return values.flatMap(collect)
            default:
                return []
            }
        }
        return Array(Set(collect(value))).sorted()
    }

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
        providerRouter: @escaping (UserDefaults) -> AIConversationProviderRoute = { AIConversationProviderPreference.resolve(in: $0) },
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

    private func cleanupActiveRun(_ runID: UUID) {
        if self.activeRunID == runID {
            self.activeTask = nil
            self.activeContinuation = nil
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

        guard emit(.state(.preparingContext)) else {
            cleanupActiveRun(runID)
            return
        }

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
            cleanupActiveRun(runID)
            return
        }

        let initialSnapshot = AIContextSnapshot(
            id: input.currentUserMessage.id,
            turnID: input.turnID,
            readAt: input.readAt,
            contextKinds: Array(Set(preparedRequest.contexts.map(\.kind))).sorted { $0.rawValue < $1.rawValue },
            relatedEntityIDs: Array(Set(preparedRequest.contexts.flatMap(\.relatedEntityIDs))).sorted(),
            sourceFingerprints: Array(Set(preparedRequest.contexts.map {
                SHA256.hash(data: Data($0.value.utf8)).map { String(format: "%02x", $0) }.joined()
            })).sorted()
        )
        var currentTurnSnapshot = initialSnapshot
        _ = emit(.contextSnapshot(currentTurnSnapshot))

        let route = providerRouter(userDefaults)
        let transport: any AIConversationRuntimeTransport
        switch route {
        case .cloud(let provider):
            transport = transportFactory(provider)
        case .needsProviderSelection:
            // Defensive terminal state, not the product path. The surface
            // blocks sending while a choice is pending, so a turn should never
            // arrive here — and if one does it must end without a transport
            // rather than pick a cloud provider on the member's behalf.
            _ = emit(.appendBlock(.error(.init(
                id: uuidGenerator(),
                message: AIConversationProviderPreference.setupTitle + AIConversationProviderPreference.setupDetail,
                retry: nil
            ))))
            _ = emit(.state(.failed))
            continuation.finish()
            cleanupActiveRun(runID)
            return
        }

        var ephemeralTranscript: [AIConversationTranscriptMessage] = preparedRequest.messages
        var providerStepCount = 0
        var toolCallCount = 0
        var turnMutationCount = 0
        // Once any non-blank assistant text reached the member, a later failure
        // must not read as if nothing was generated.
        var hasVisibleAssistantText = false

        while true {
            guard self.activeRunID == runID && !self.isCancellationRequested && !Task.isCancelled else {
                _ = emit(.state(.cancelled))
                continuation.finish()
                cleanupActiveRun(runID)
                return
            }

            providerStepCount += 1
            if providerStepCount > Self.maxProviderStepsPerTurn {
                _ = emit(.appendBlock(.error(.init(id: uuidGenerator(), message: "已达到本次对话的最大步骤上限，已停止处理。", retry: .generation))))
                _ = emit(.state(.failed))
                continuation.finish()
                cleanupActiveRun(runID)
                return
            }

            guard emit(.state(.requesting)) else {
                cleanupActiveRun(runID)
                return
            }

            guard let budgetedMessages = Self.rebudgetContinuation(ephemeralTranscript, limit: Self.serverPromptMaxChars) else {
                _ = emit(.appendBlock(.error(.init(id: uuidGenerator(), message: "对话上下文超出限制，已停止处理。", retry: .generation))))
                _ = emit(.state(.failed))
                continuation.finish()
                cleanupActiveRun(runID)
                return
            }
            ephemeralTranscript = budgetedMessages

            let runtimeRequest = AIConversationRuntimeRequest(
                messages: ephemeralTranscript,
                enabledTools: Self.enabledTools,
                requestID: uuidGenerator(),
                turnID: runID
            )

            var stepText = ""
            var stepToolCalls: [AIConversationToolCall] = []
            var stepError: (code: String, message: String)?
            var emittedPresentationToolIDs: Set<String> = []

            do {
                let stream = await transport.stream(runtimeRequest)
                for try await event in stream {
                    guard self.activeRunID == runID && !self.isCancellationRequested && !Task.isCancelled else {
                        _ = emit(.state(.cancelled))
                        continuation.finish()
                        cleanupActiveRun(runID)
                        return
                    }

                    switch event {
                    case .textDelta(let delta):
                        guard emit(.state(.streaming)) else {
                            cleanupActiveRun(runID)
                            return
                        }
                        guard emit(.appendText(delta)) else {
                            cleanupActiveRun(runID)
                            return
                        }
                        stepText += delta
                        if !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            hasVisibleAssistantText = true
                        }

                    case .toolCall(let id, let name, let arguments):
                        toolCallCount += 1
                        if toolCallCount > Self.maxToolCallsPerTurn {
                            _ = emit(.appendBlock(.error(.init(id: uuidGenerator(), message: "已达到本次对话的工具调用上限，已停止执行后续操作。", retry: .generation))))
                            _ = emit(.state(.failed))
                            continuation.finish()
                            cleanupActiveRun(runID)
                            return
                        }
                        guard emit(.state(.toolRequested)) else {
                            cleanupActiveRun(runID)
                            return
                        }
                        let call = AIConversationToolCall(id: id, name: name, arguments: arguments)
                        if name == "present_recipe_card" || name == "present_context_result" {
                            let context = buildInterpretationContext(for: call)
                            let intent = interpreter.interpret(toolCall: call, context: context)
                            if case .appendBlock(let block) = intent {
                                if case .error = block {
                                    _ = emit(.appendBlock(block))
                                    _ = emit(.state(.failed))
                                    continuation.finish()
                                    cleanupActiveRun(runID)
                                    return
                                }
                                guard emit(.appendBlock(block)) else {
                                    cleanupActiveRun(runID)
                                    return
                                }
                                emittedPresentationToolIDs.insert(id)
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
                let category = ConversationFailurePresentation.category(for: error)
                if self.isCancellationRequested || Task.isCancelled || category == .cancelled {
                    _ = emit(.state(.cancelled))
                    continuation.finish()
                    cleanupActiveRun(runID)
                    return
                }
                let message = hasVisibleAssistantText
                    ? ConversationFailurePresentation.partialReplyInterruptedMessage
                    : (ConversationFailurePresentation.message(for: category) ?? ConversationFailurePresentation.unavailableMessage)
                _ = emit(.appendBlock(.error(.init(id: uuidGenerator(), message: message, retry: .generation))))
                _ = emit(.state(.failed))
                continuation.finish()
                cleanupActiveRun(runID)
                return
            }

            if self.isCancellationRequested || Task.isCancelled {
                _ = emit(.state(.cancelled))
                continuation.finish()
                cleanupActiveRun(runID)
                return
            }

            if let error = stepError {
                // Server stream error copy is already safe; after visible text it
                // is replaced by copy that says the partial reply was kept.
                let message = hasVisibleAssistantText
                    ? ConversationFailurePresentation.partialReplyInterruptedMessage
                    : error.message
                _ = emit(.appendBlock(.error(.init(id: uuidGenerator(), message: message, retry: .generation))))
                _ = emit(.state(.failed))
                continuation.finish()
                cleanupActiveRun(runID)
                return
            }

            if stepToolCalls.isEmpty {
                guard emit(.state(.completed)) else {
                    cleanupActiveRun(runID)
                    return
                }
                guard emit(.finished) else {
                    cleanupActiveRun(runID)
                    return
                }
                continuation.finish()
                cleanupActiveRun(runID)
                return
            }

            // Interpret all tool calls for this step
            var interpretedCalls: [(AIConversationToolCall, AIConversationToolIntent)] = []
            for call in stepToolCalls {
                let context = buildInterpretationContext(for: call)
                let intent = interpreter.interpret(toolCall: call, context: context)
                interpretedCalls.append((call, intent))
            }

            // Check for interpreter rejection errors (unknown tool, malformed args)
            for (call, intent) in interpretedCalls {
                if case let .appendBlock(.error(errBlock)) = intent {
                    if !emittedPresentationToolIDs.contains(call.id) {
                        _ = emit(.appendBlock(.error(errBlock)))
                    }
                    _ = emit(.state(.failed))
                    continuation.finish()
                    cleanupActiveRun(runID)
                    return
                }
            }

            // Safety policy checks
            let stepMutationCalls = interpretedCalls.filter { if case .proposeAction = $0.1 { return true } else { return false } }
            let stepReadCalls = interpretedCalls.filter { if case .read = $0.1 { return true } else { return false } }

            // Important 1: At most one mutation proposal per logical turn, no splitting
            if (turnMutationCount > 0 && !stepMutationCalls.isEmpty) || stepMutationCalls.count > 1 {
                _ = emit(.appendBlock(.error(.init(id: uuidGenerator(), message: "单次对话最多只能执行一项修改操作，请分步进行。", retry: .action))))
                _ = emit(.state(.failed))
                continuation.finish()
                cleanupActiveRun(runID)
                return
            }

            // Important 1: No mixed read + mutation in the same step
            if !stepMutationCalls.isEmpty && !stepReadCalls.isEmpty {
                _ = emit(.appendBlock(.error(.init(id: uuidGenerator(), message: "不能在同一步骤中同时读取数据并提交修改操作，请先读取后再操作。", retry: .action))))
                _ = emit(.state(.failed))
                continuation.finish()
                cleanupActiveRun(runID)
                return
            }

            // If this step contains the one allowed mutation proposal
            if stepMutationCalls.count == 1 {
                turnMutationCount += 1

                // Emit any presentation blocks first
                for (call, intent) in interpretedCalls {
                    if case let .appendBlock(block) = intent, !emittedPresentationToolIDs.contains(call.id) {
                        guard emit(.appendBlock(block)) else {
                            cleanupActiveRun(runID)
                            return
                        }
                        emittedPresentationToolIDs.insert(call.id)
                    }
                }

                guard case let .proposeAction(proposal) = stepMutationCalls[0].1 else { return }
                do {
                    let prepared = try actionCoordinator.prepare(proposal, conversationID: input.conversationID, turnID: input.turnID)
                    if prepared.risk.requiresExplicitConfirmation {
                        if let preview = prepared.preview {
                            guard emit(.appendBlock(preview)) else {
                                cleanupActiveRun(runID)
                                return
                            }
                        }
                        guard emit(.pendingAction(prepared)) else {
                            cleanupActiveRun(runID)
                            return
                        }
                        guard emit(.state(.awaitingConfirmation)) else {
                            cleanupActiveRun(runID)
                            return
                        }
                        continuation.finish()
                        cleanupActiveRun(runID)
                        return
                    } else {
                        guard emit(.state(.executing)) else {
                            cleanupActiveRun(runID)
                            return
                        }
                        let execResult = try actionCoordinator.execute(prepared)
                        // One source of outcome copy, shared with the
                        // controller's confirm and reconcile paths, so a
                        // block never reads differently before and after a
                        // reopen.
                        let statusMsg = AIActionOutcomePresentation.outcomeTitle(for: proposal.actionType)
                        let statusBlock = AIActionStatusBlock(
                            id: uuidGenerator(),
                            message: statusMsg,
                            actionID: execResult.record.actionID,
                            canUndo: true,
                            isFailure: false
                        )
                        guard emit(.appendBlock(.actionStatus(statusBlock))) else {
                            cleanupActiveRun(runID)
                            return
                        }
                        // Low-risk mutation terminates provider generation
                        guard emit(.state(.completed)) else {
                            cleanupActiveRun(runID)
                            return
                        }
                        guard emit(.finished) else {
                            cleanupActiveRun(runID)
                            return
                        }
                        continuation.finish()
                        cleanupActiveRun(runID)
                        return
                    }
                } catch {
                    let errBlock = AIErrorBlock(id: uuidGenerator(), message: error.localizedDescription, retry: .action)
                    _ = emit(.appendBlock(.error(errBlock)))
                    _ = emit(.state(.failed))
                    continuation.finish()
                    cleanupActiveRun(runID)
                    return
                }
            }

            // If stepMutationCalls.isEmpty: Only presentation tools and/or read tools
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

            // Important 2: Every assistant tool_call must have a matching tool_result row before continuation
            for (call, intent) in interpretedCalls {
                switch intent {
                case .appendBlock(let block):
                    if !emittedPresentationToolIDs.contains(call.id) {
                        guard emit(.appendBlock(block)) else {
                            cleanupActiveRun(runID)
                            return
                        }
                        emittedPresentationToolIDs.insert(call.id)
                    }
                    if let ack = AIConversationTranscriptMessage.toolResult(forToolCallID: call.id, text: #"{"presented":true}"#) {
                        ephemeralTranscript.append(ack)
                    }
                case .read(let readRequest):
                    guard emit(.state(.executing)) else {
                        cleanupActiveRun(runID)
                        return
                    }
                    do {
                        let executedResult = try executeReadTool(readRequest)
                        let resultText = executedResult.text
                        let kind: AIContextKind
                        switch readRequest {
                        case .inventory: kind = .inventory
                        case .tonightPlan: kind = .tonightPlan
                        case .plannerWeek: kind = .plannerWeek
                        case .specialPlan: kind = .specialPlan
                        case .resolveRecipe: kind = .recipe
                        }
                        let fingerprint = SHA256.hash(data: Data(resultText.utf8)).map { String(format: "%02x", $0) }.joined()
                        var updatedKinds = Set(currentTurnSnapshot.contextKinds)
                        updatedKinds.insert(kind)
                        var updatedFingerprints = Set(currentTurnSnapshot.sourceFingerprints)
                        updatedFingerprints.insert(fingerprint)
                        var updatedEntityIDs = Set(currentTurnSnapshot.relatedEntityIDs)
                        executedResult.relatedEntityIDs.forEach { updatedEntityIDs.insert($0) }
                        currentTurnSnapshot = AIContextSnapshot(
                            id: currentTurnSnapshot.id,
                            turnID: input.turnID,
                            readAt: now(),
                            contextKinds: Array(updatedKinds).sorted { $0.rawValue < $1.rawValue },
                            relatedEntityIDs: Array(updatedEntityIDs).sorted(),
                            sourceFingerprints: Array(updatedFingerprints).sorted()
                        )
                        _ = emit(.contextSnapshot(currentTurnSnapshot))

                        if let toolMsg = AIConversationTranscriptMessage.toolResult(forToolCallID: call.id, text: resultText) {
                            ephemeralTranscript.append(toolMsg)
                        }
                    } catch {
                        if isReadOptional(readRequest) {
                            if let toolMsg = AIConversationTranscriptMessage.toolResult(forToolCallID: call.id, text: #"{"error":"read_failed"}"#) {
                                ephemeralTranscript.append(toolMsg)
                            }
                        } else {
                            let errBlock = AIErrorBlock(id: uuidGenerator(), message: "读取厨房上下文失败，已停止处理。", retry: .contextRead)
                            _ = emit(.appendBlock(.error(errBlock)))
                            _ = emit(.state(.failed))
                            continuation.finish()
                            cleanupActiveRun(runID)
                            return
                        }
                    }
                case .proposeAction:
                    break
                }
            }

            if stepReadCalls.isEmpty {
                // No read continuation needed
                guard emit(.state(.completed)) else {
                    cleanupActiveRun(runID)
                    return
                }
                guard emit(.finished) else {
                    cleanupActiveRun(runID)
                    return
                }
                continuation.finish()
                cleanupActiveRun(runID)
                return
            }

            // Has read calls -> continues to next provider step with complete transcript
        }
    }

    private func executeReadTool(_ request: AIReadToolRequest) throws -> ExecutedReadToolResult {
        switch request {
        case .inventory(let expiringOnly):
            let inventory = domainTools.inventoryContext(now: now())
            let text: String
            if expiringOnly == true {
                text = ConversationContextAssembler.boundedToolResultJSON(inventory.expiring, limit: 3000)
            } else {
                text = ConversationContextAssembler.boundedToolResultJSON(inventory, limit: 3000)
            }
            return ExecutedReadToolResult(
                text: text,
                relatedEntityIDs: Self.semanticEntityIDs(in: text)
            )
        case .tonightPlan:
            let tonight = domainTools.tonightPlanContext(now: now(), calendar: domainTools.calendar)
            let text = ConversationContextAssembler.boundedToolResultJSON(tonight, limit: 3000)
            return ExecutedReadToolResult(
                text: text,
                relatedEntityIDs: Self.semanticEntityIDs(in: text)
            )
        case .plannerWeek(let weekStart):
            let week = domainTools.plannerWeekContext(weekStart: weekStart, calendar: domainTools.calendar)
            let text = ConversationContextAssembler.boundedToolResultJSON(week, limit: 3000)
            return ExecutedReadToolResult(
                text: text,
                relatedEntityIDs: Self.semanticEntityIDs(in: text)
            )
        case .specialPlan(let id):
            guard let special = domainTools.specialPlanContext(id: id) else {
                throw AIDomainToolError.specialPlanNotFound(id)
            }
            let text = ConversationContextAssembler.boundedToolResultJSON(special, limit: 3000)
            return ExecutedReadToolResult(
                text: text,
                relatedEntityIDs: Self.semanticEntityIDs(in: text)
            )
        case .resolveRecipe(let query, let recipeID):
            if let recipe = domainTools.resolveRecipe(query: query, recipeID: recipeID) {
                let text = ConversationContextAssembler.boundedToolResultJSON(recipe, limit: 3000)
                return ExecutedReadToolResult(
                    text: text,
                    relatedEntityIDs: [recipe.id]
                )
            } else {
                return ExecutedReadToolResult(
                    text: #"{"found":false}"#,
                    relatedEntityIDs: []
                )
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

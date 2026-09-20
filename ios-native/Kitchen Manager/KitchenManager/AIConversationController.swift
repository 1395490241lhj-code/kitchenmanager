import Foundation
import Combine

@MainActor
final class AIConversationController: ObservableObject {
    @Published private(set) var currentConversation: AIConversation?
    @Published private(set) var messages: [AIConversationMessage] = []
    @Published private(set) var turnState: AIConversationTurnState = .idle
    @Published var draftText = ""
    @Published var nextTurnExcludedContexts: Set<AIContextKind> = []
    @Published private(set) var preparedAction: PreparedAIAction?
    @Published private(set) var actuallyUsedContextKinds: Set<AIContextKind> = []
    @Published private(set) var localErrorMessage: String?

    var history: [AIConversation] { store.conversations }
    var currentConversationRequiresReactivation: Bool {
        currentConversation?.isExpired(now: now()) ?? false
    }
    var isPersisted: Bool {
        guard let conv = currentConversation else { return false }
        return store.conversation(id: conv.id) != nil
    }
    var canAcceptNewMessage: Bool {
        turnState.acceptsUserInput
            && preparedAction == nil
            && !currentConversationRequiresReactivation
            && !needsConversationProviderSelection
    }
    /// Resolved live on every read rather than cached. A cached availability
    /// flag is precisely the shape of defect this surface is recovering from.
    var conversationProviderRoute: AIConversationProviderRoute {
        AIConversationProviderPreference.resolve(in: userDefaults)
    }
    var needsConversationProviderSelection: Bool {
        conversationProviderRoute == .needsProviderSelection
    }
    var canRetryGeneration: Bool {
        retryInput != nil && currentConversation?.id == retryInput?.conversationID && (turnState == .failed || turnState == .cancelled)
    }
    var isGenerating: Bool {
        turnState == .preparingContext || turnState == .requesting || turnState == .streaming || turnState == .toolRequested || turnState == .executing
    }
    @Published private(set) var contentRevision: Int = 0
    var activeEntryContext: AIConversationEntryContext {
        entryContext
    }
    var likelyContextKinds: [AIContextKind] {
        switch entryContext {
        case .home:
            return [.inventory, .tonightPlan]
        case let .planner(_, specialPlanID):
            var kinds: [AIContextKind] = [.inventory, .plannerWeek]
            if specialPlanID != nil {
                kinds.append(.specialPlan)
            }
            return kinds
        }
    }

    private let store: ConversationStore
    private let orchestrator: any ConversationOrchestrating
    private let actionCoordinator: ConversationActionCoordinator
    private let metadataService: ConversationMetadataService
    private let userDefaults: UserDefaults
    private let now: () -> Date
    private let uuid: () -> UUID

    private var entryContext: AIConversationEntryContext = .home
    private var activeRunID: UUID?
    private var activeAssistantID: UUID?
    private var activeTask: Task<Void, Never>?
    private var retryInput: AIConversationTurnInput?
    private struct MetadataTaskHandle {
        let token: UUID
        let task: Task<Void, Never>
    }
    private var metadataTasks: [UUID: MetadataTaskHandle] = [:]
    private var cachedExcerpts: [UUID: String] = [:]
    private var storeCancellable: AnyCancellable?

    init(
        store: ConversationStore,
        orchestrator: any ConversationOrchestrating,
        actionCoordinator: ConversationActionCoordinator,
        metadataService: ConversationMetadataService,
        userDefaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        uuid: @escaping () -> UUID = UUID.init
    ) {
        self.store = store
        self.orchestrator = orchestrator
        self.actionCoordinator = actionCoordinator
        self.metadataService = metadataService
        self.userDefaults = userDefaults
        self.now = now
        self.uuid = uuid
        self.storeCancellable = store.objectWillChange.sink { [weak self] _ in
            self?.cachedExcerpts.removeAll()
            self?.objectWillChange.send()
        }
        do {
            try store.loadHistory()
        } catch {
            localErrorMessage = "无法读取对话记录。"
        }
    }

    deinit {
        storeCancellable?.cancel()
        activeTask?.cancel()
        metadataTasks.values.forEach { $0.task.cancel() }
    }

    func open(entryContext: AIConversationEntryContext) {
        stop()
        self.entryContext = entryContext
        if let conversation = store.bestActiveConversation(for: entryContext) {
            load(conversation)
        } else {
            currentConversation = store.createDraft(entryContext: entryContext)
            messages = []
            resetTransientState()
        }
    }

    func newConversation(entryContext: AIConversationEntryContext) {
        stop()
        self.entryContext = entryContext
        currentConversation = store.createDraft(entryContext: entryContext)
        messages = []
        resetTransientState()
    }

    func makeSpecialPlanDraft(planID: UUID, scheduledAt: Date) {
        stop()
        let draft = store.createSpecialPlanDraft(planID: planID, scheduledAt: scheduledAt)
        entryContext = entryContext(for: draft)
        currentConversation = draft
        messages = []
        resetTransientState()
    }

    func openConversation(id: UUID) {
        stop()
        guard let conversation = store.conversation(id: id) else {
            localErrorMessage = "找不到该对话。"
            return
        }
        load(conversation)
    }

    func reactivate(id: UUID) {
        stop()
        do {
            let conversation = try store.reactivate(id: id)
            load(conversation)
        } catch {
            localErrorMessage = safeMessage(error, fallback: "无法继续该对话。")
        }
    }

    /// The member's explicit answer to the setup state. Writing the canonical
    /// preference is the whole action — nothing else is cached to go stale.
    func selectConversationProvider(_ provider: AIRecommendationProvider) {
        AIConversationProviderPreference.select(provider, in: userDefaults)
        objectWillChange.send()
    }

    func send() {
        localErrorMessage = nil
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard turnState.acceptsUserInput, preparedAction == nil else { return }
        // A pending provider choice is a setup state, not a failed turn: no
        // message is consumed and no conversation record is written.
        guard !needsConversationProviderSelection else { return }

        if currentConversation == nil {
            currentConversation = store.createDraft(entryContext: entryContext)
        }
        guard var conversation = currentConversation else { return }
        guard !conversation.isExpired(now: now()) else {
            localErrorMessage = "该对话已归档，请先选择“继续此对话”。"
            turnState = .failed
            return
        }

        let acceptedAt = now()
        conversation = store.retentionPolicy.refreshed(conversation, now: acceptedAt, calendar: store.calendar)
        let turnID = uuid()
        let userMessage = AIConversationMessage(
            id: uuid(),
            conversationID: conversation.id,
            role: .user,
            createdAt: acceptedAt,
            state: .completed,
            contentBlocks: [.text(.init(id: uuid(), text: text))],
            turnID: turnID
        )

        do {
            if store.conversation(id: conversation.id) == nil {
                try store.saveFirstMessage(conversation: conversation, message: userMessage)
            } else {
                try store.saveUserMessage(userMessage, to: conversation)
            }
        } catch {
            localErrorMessage = "无法保存消息，请稍后重试。"
            turnState = .failed
            return
        }

        currentConversation = store.conversation(id: conversation.id) ?? conversation
        messages.append(userMessage)
        let exclusions = nextTurnExcludedContexts
        nextTurnExcludedContexts = []
        draftText = ""
        actuallyUsedContextKinds = []

        let input = AIConversationTurnInput(
            conversationID: conversation.id,
            turnID: turnID,
            entryContext: entryContext,
            summary: conversation.summary,
            priorMessages: messages.filter { $0.id != userMessage.id },
            currentUserMessage: userMessage,
            excludedContextKinds: exclusions,
            readAt: acceptedAt
        )
        retryInput = input

        let initialAssistantCreatedAt = Date(timeIntervalSinceReferenceDate: userMessage.createdAt.timeIntervalSinceReferenceDate.nextUp)
        let assistant = AIConversationMessage(
            id: uuid(),
            conversationID: conversation.id,
            role: .assistant,
            createdAt: initialAssistantCreatedAt,
            state: .streaming,
            contentBlocks: [],
            turnID: turnID
        )
        do {
            try store.saveMessage(assistant)
        } catch {
            localErrorMessage = "无法开始回复，请稍后重试。"
            turnState = .failed
            return
        }
        messages.append(assistant)

        start(input, assistantID: assistant.id)
    }

    func retryGeneration() {
        localErrorMessage = nil
        guard let input = retryInput,
              currentConversation?.id == input.conversationID,
              turnState == .failed || turnState == .cancelled else { return }
        let assistantCreatedAt = assistantCreatedAt(after: input.currentUserMessage)
        let assistant = AIConversationMessage(
            id: uuid(),
            conversationID: input.conversationID,
            role: .assistant,
            createdAt: assistantCreatedAt,
            state: .streaming,
            contentBlocks: [],
            turnID: input.turnID
        )
        do {
            try store.saveMessage(assistant)
        } catch {
            localErrorMessage = "无法开始重试，请稍后再试。"
            return
        }
        messages.append(assistant)
        start(input, assistantID: assistant.id)
        contentRevision += 1
    }

    private func assistantCreatedAt(after userMessage: AIConversationMessage) -> Date {
        let current = now()
        if current > userMessage.createdAt {
            return current
        }
        return Date(timeIntervalSinceReferenceDate: userMessage.createdAt.timeIntervalSinceReferenceDate.nextUp)
    }

    func stop() {
        guard let assistantID = activeAssistantID else { return }
        orchestrator.cancelCurrentTurn()
        activeRunID = nil
        activeTask?.cancel()
        activeTask = nil
        activeAssistantID = nil
        turnState = .cancelled
        finishAssistant(id: assistantID, state: .cancelled)
        contentRevision += 1
    }

    func confirmPreparedAction() {
        guard let action = preparedAction else { return }
        do {
            let result = try actionCoordinator.execute(action)
            let messageText = actionStatusMessage(for: result.record.actionType, isUndone: false)
            let block = AIContentBlock.actionStatus(.init(
                id: uuid(),
                message: messageText,
                actionID: result.record.actionID,
                canUndo: result.record.canUndo(now: now())
            ))
            preparedAction = nil
            turnState = .completed
            appendToTurnAssistant(block, turnID: result.record.turnID)
            contentRevision += 1
        } catch {
            localErrorMessage = safeMessage(error, fallback: "操作未完成。")
            contentRevision += 1
        }
    }

    func undo(actionID: UUID) {
        do {
            let result = try actionCoordinator.undo(actionID: actionID)
            for messageIndex in messages.indices {
                var changed = false
                for blockIndex in messages[messageIndex].contentBlocks.indices {
                    guard case var .actionStatus(status) = messages[messageIndex].contentBlocks[blockIndex],
                          status.actionID == actionID else { continue }
                    status.message = actionStatusMessage(for: result.record.actionType, isUndone: true)
                    status.canUndo = false
                    messages[messageIndex].contentBlocks[blockIndex] = .actionStatus(status)
                    changed = true
                }
                if changed { try? store.saveMessage(messages[messageIndex]) }
            }
            contentRevision += 1
        } catch {
            localErrorMessage = safeMessage(error, fallback: "无法撤销该操作。")
            contentRevision += 1
        }
    }

    func rename(_ title: String) {
        guard let id = currentConversation?.id else { return }
        rename(id: id, newTitle: title)
    }

    func rename(id: UUID, newTitle: String) {
        do {
            let updated = try store.rename(id: id, newTitle: newTitle)
            if currentConversation?.id == id {
                currentConversation = updated
            }
        } catch {
            localErrorMessage = "无法重命名该对话。"
        }
    }

    func setPinned(_ isPinned: Bool) {
        guard let id = currentConversation?.id else { return }
        setPinned(id: id, isPinned: isPinned)
    }

    /// Called once when the current conversation's continuity boundary passes
    /// while the workspace is open. Nothing is stored: every reader of
    /// `isExpired(now:)` simply evaluates again against the clock.
    func lifetimeBoundaryCrossed() {
        objectWillChange.send()
    }

    func setPinned(id: UUID, isPinned: Bool) {
        do {
            let updated = try store.setPinned(id: id, isPinned: isPinned)
            if currentConversation?.id == id {
                currentConversation = updated
            }
        } catch {
            localErrorMessage = "无法更新置顶状态。"
        }
    }

    func delete(id: UUID) {
        if currentConversation?.id == id { stop() }
        metadataTasks.removeValue(forKey: id)?.task.cancel()
        cachedExcerpts.removeValue(forKey: id)
        do {
            try store.deleteConversation(id: id)
            if currentConversation?.id == id {
                currentConversation = nil
                messages = []
                resetTransientState()
            }
        } catch {
            localErrorMessage = "无法删除该对话。"
        }
    }

    func wipeLocalHistory() {
        stop()
        metadataTasks.values.forEach { $0.task.cancel() }
        metadataTasks.removeAll()
        cachedExcerpts.removeAll()
        do {
            try store.wipeAll()
            currentConversation = nil
            messages = []
            draftText = ""
            nextTurnExcludedContexts = []
            retryInput = nil
            resetTransientState()
        } catch {
            localErrorMessage = "无法清除对话记录。"
        }
    }

    func dismissLocalError() {
        localErrorMessage = nil
    }

    func lastMessageExcerpt(for conversationID: UUID) -> String? {
        if let cached = cachedExcerpts[conversationID] {
            return cached
        }
        if let messages = try? store.messages(conversationID: conversationID),
           let last = messages.last(where: { !$0.plainTextSummary.isEmpty }) {
            cachedExcerpts[conversationID] = last.plainTextSummary
            return last.plainTextSummary
        }
        return nil
    }

    private func load(_ conversation: AIConversation) {
        let pendingAction = currentConversation?.id == conversation.id
            && !conversation.isExpired(now: now()) ? preparedAction : nil
        preparedAction = nil
        turnState = .idle
        if currentConversation?.id != conversation.id {
            resetNextTurnComposerState()
        }
        entryContext = entryContext(for: conversation)
        currentConversation = conversation
        do {
            messages = try store.messages(conversationID: conversation.id)
            if let pendingAction,
               try store.actions(conversationID: conversation.id).contains(where: {
                   $0.id == pendingAction.id && $0.conversationID == conversation.id
                       && $0.status == .awaitingConfirmation
               }) {
                preparedAction = pendingAction
                turnState = .awaitingConfirmation
            }
            reconcileActionStatusBlocks(conversationID: conversation.id)
            actuallyUsedContextKinds = []
            localErrorMessage = nil
        } catch {
            messages = []
            localErrorMessage = "无法读取对话消息。"
        }
    }

    private func resetTransientState() {
        turnState = .idle
        preparedAction = nil
        actuallyUsedContextKinds = []
        retryInput = nil
        localErrorMessage = nil
        resetNextTurnComposerState()
    }

    private func resetNextTurnComposerState() {
        draftText = ""
        nextTurnExcludedContexts = []
    }

    private func entryContext(for conversation: AIConversation) -> AIConversationEntryContext {
        switch conversation.lifecycleType {
        case .general, .dailyMeal:
            return .home
        case .weeklyPlanning:
            return .planner(
                weekStart: conversation.anchorDate ?? now(),
                specialPlanID: conversation.anchorEntityID
            )
        case .specialPlan:
            let eventDate = conversation.anchorDate ?? now()
            return .planner(
                weekStart: PlannerProjection.startOfWeek(containing: eventDate, calendar: store.calendar),
                specialPlanID: conversation.anchorEntityID
            )
        }
    }

    private func start(_ input: AIConversationTurnInput, assistantID: UUID) {
        let runID = uuid()
        activeRunID = runID
        activeAssistantID = assistantID
        turnState = .preparingContext
        contentRevision += 1
        let stream = orchestrator.runTurn(input)
        activeTask = Task { [weak self] in
            guard let self else { return }
            await self.consume(stream, input: input, assistantID: assistantID, runID: runID)
        }
    }

    private func consume(
        _ stream: AsyncThrowingStream<AIConversationTurnEvent, Error>,
        input: AIConversationTurnInput,
        assistantID: UUID,
        runID: UUID
    ) async {
        do {
            for try await event in stream {
                guard activeRunID == runID,
                      activeAssistantID == assistantID,
                      currentConversation?.id == input.conversationID else { continue }
                handle(event, assistantID: assistantID)
            }
            if activeRunID == runID && !turnState.isTerminal && turnState != .awaitingConfirmation {
                turnState = .failed
                finishAssistant(id: assistantID, state: .failed)
            }
        } catch {
            guard activeRunID == runID else { return }
            turnState = Task.isCancelled ? .cancelled : .failed
            finishAssistant(id: assistantID, state: Task.isCancelled ? .cancelled : .failed)
        }
        guard activeRunID == runID else { return }
        activeRunID = nil
        activeAssistantID = nil
        activeTask = nil
    }

    private func handle(_ event: AIConversationTurnEvent, assistantID: UUID) {
        switch event {
        case let .state(state):
            turnState = state
            switch state {
            case .completed:
                finishAssistant(id: assistantID, state: .completed)
                retryInput = nil
            case .cancelled:
                finishAssistant(id: assistantID, state: .cancelled)
            case .failed:
                finishAssistant(id: assistantID, state: .failed)
            case .awaitingConfirmation:
                finishAssistant(id: assistantID, state: .completed)
                retryInput = nil
            default:
                break
            }
        case let .appendText(text):
            mutateAssistant(id: assistantID) { message in
                if let last = message.contentBlocks.indices.last,
                   case var .text(block) = message.contentBlocks[last] {
                    block.text += text
                    message.contentBlocks[last] = .text(block)
                } else {
                    message.contentBlocks.append(.text(.init(id: uuid(), text: text)))
                }
            }
            contentRevision += 1
        case let .appendBlock(block):
            mutateAssistant(id: assistantID) { $0.contentBlocks.append(block) }
            persistAssistant(id: assistantID)
            contentRevision += 1
        case let .replaceBlock(block):
            mutateAssistant(id: assistantID) { message in
                guard let index = message.contentBlocks.firstIndex(where: { $0.id == block.id }) else { return }
                message.contentBlocks[index] = block
            }
            persistAssistant(id: assistantID)
            contentRevision += 1
        case let .pendingAction(action):
            preparedAction = action
            persistAssistant(id: assistantID)
            contentRevision += 1
        case let .contextSnapshot(snapshot):
            do {
                guard let conversationID = currentConversation?.id else { return }
                try store.upsertContextSnapshot(snapshot, conversationID: conversationID)
                actuallyUsedContextKinds = Set(snapshot.contextKinds)
                contentRevision += 1
            } catch {
                localErrorMessage = "无法保存本轮上下文来源。"
            }
        case .finished:
            if turnState != .completed {
                turnState = .completed
                finishAssistant(id: assistantID, state: .completed)
                retryInput = nil
                contentRevision += 1
            }
        }
    }

    private func mutateAssistant(id: UUID, _ mutation: (inout AIConversationMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        mutation(&messages[index])
        if let convID = currentConversation?.id, !messages[index].plainTextSummary.isEmpty {
            cachedExcerpts[convID] = messages[index].plainTextSummary
        }
    }

    private func persistAssistant(id: UUID) {
        guard let message = messages.first(where: { $0.id == id }) else { return }
        do {
            try store.saveMessage(message)
        } catch {
            localErrorMessage = "无法保存回复进度。"
        }
    }

    private func finishAssistant(id: UUID, state: AIConversationMessageState) {
        guard let index = messages.firstIndex(where: { $0.id == id }),
              messages[index].state == .streaming else { return }
        messages[index].state = state
        persistAssistant(id: id)
        refreshConversationActivity()
        if state == .completed {
            scheduleMetadata(completedAssistantID: id)
        }
    }

    private func refreshConversationActivity() {
        guard let conversation = currentConversation else { return }
        let refreshed = store.retentionPolicy.refreshed(conversation, now: now(), calendar: store.calendar)
        do {
            try store.saveConversation(refreshed)
            currentConversation = refreshed
        } catch {
            localErrorMessage = "无法更新对话活动时间。"
        }
    }

    private func appendToTurnAssistant(_ block: AIContentBlock, turnID: UUID) {
        guard let index = messages.lastIndex(where: { $0.role == .assistant && $0.turnID == turnID })
                ?? messages.lastIndex(where: { $0.role == .assistant }) else { return }
        messages[index].contentBlocks.append(block)
        messages[index].state = .completed
        do {
            try store.saveMessage(messages[index])
        } catch {
            localErrorMessage = "操作已成功应用，但界面记录保存失败。"
        }
    }

    private func actionStatusMessage(for actionType: AIActionType, isUndone: Bool) -> String {
        isUndone
            ? AIActionOutcomePresentation.undoneTitle(for: actionType)
            : AIActionOutcomePresentation.outcomeTitle(for: actionType)
    }

    /// Read-only view of the persisted action truth a status block projects,
    /// so presentation can derive destination and undo expiry from the record
    /// instead of from a second stored copy. Nil when the record is gone.
    func actionRecord(id: UUID) -> AIConversationActionRecord? {
        guard let conversationID = currentConversation?.id,
              let records = try? store.actions(conversationID: conversationID) else { return nil }
        return records.first { $0.id == id }
    }

    private func reconcileActionStatusBlocks(conversationID: UUID) {
        guard let records = try? store.actions(conversationID: conversationID) else { return }
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })

        var existingActionIDs = Set<UUID>()

        // 1. Update existing visible status blocks
        for messageIndex in messages.indices {
            for blockIndex in messages[messageIndex].contentBlocks.indices {
                guard case var .actionStatus(status) = messages[messageIndex].contentBlocks[blockIndex],
                      let record = byID[status.actionID] else { continue }
                existingActionIDs.insert(status.actionID)
                let expectedCanUndo = (record.status == .succeeded) && record.canUndo(now: now())
                let expectedMessage = actionStatusMessage(for: record.actionType, isUndone: record.status == .undone)
                status.canUndo = expectedCanUndo
                status.message = expectedMessage
                messages[messageIndex].contentBlocks[blockIndex] = .actionStatus(status)
            }
        }

        // 2. Synthesize missing visible status blocks for terminal actions (.succeeded or .undone)
        let terminalRecords = records
            .filter { ($0.status == .succeeded || $0.status == .undone) && !existingActionIDs.contains($0.actionID) }
            .sorted { $0.createdAt < $1.createdAt }

        for record in terminalRecords {
            let messageText = actionStatusMessage(for: record.actionType, isUndone: record.status == .undone)
            let canUndo = (record.status == .succeeded) && record.canUndo(now: now())
            let statusBlock = AIActionStatusBlock(
                id: uuid(),
                message: messageText,
                actionID: record.actionID,
                canUndo: canUndo,
                isFailure: false
            )
            existingActionIDs.insert(record.actionID)

            if let matchIndex = messages.lastIndex(where: { $0.role == .assistant && $0.turnID == record.turnID }) {
                messages[matchIndex].contentBlocks.append(.actionStatus(statusBlock))
                try? store.saveMessage(messages[matchIndex])
            } else {
                let assistant = AIConversationMessage(
                    id: uuid(),
                    conversationID: conversationID,
                    role: .assistant,
                    createdAt: record.completedAt ?? record.createdAt,
                    state: .completed,
                    contentBlocks: [.actionStatus(statusBlock)],
                    turnID: record.turnID
                )
                messages.append(assistant)
                try? store.saveMessage(assistant)
                messages.sort {
                    if $0.createdAt != $1.createdAt {
                        return $0.createdAt < $1.createdAt
                    }
                    return $0.id.uuidString < $1.id.uuidString
                }
            }
        }
    }

    private func scheduleMetadata(completedAssistantID: UUID) {
        guard let conversation = currentConversation else { return }
        let scopedMessages = messages
        let stale = isSummaryStale(conversation: conversation, messages: scopedMessages)
        let token = uuid()
        metadataTasks[conversation.id]?.task.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            if let title = await metadataService.titleCandidate(
                conversation: conversation,
                messages: scopedMessages,
                completedAssistantID: completedAssistantID
            ) {
                apply(title)
            }
            if let summary = await metadataService.summaryCandidate(
                conversation: conversation,
                messages: scopedMessages,
                completedAssistantID: completedAssistantID,
                isSummaryStale: stale
            ) {
                apply(summary)
            }
            if metadataTasks[conversation.id]?.token == token {
                metadataTasks.removeValue(forKey: conversation.id)
            }
        }
        metadataTasks[conversation.id] = MetadataTaskHandle(token: token, task: task)
    }

    private func apply(_ candidate: ConversationMetadataCandidate) {
        do {
            guard var current = try store.authoritativeConversation(id: candidate.conversationID),
                  candidate.canApply(to: current, completedAssistantID: candidate.completedAssistantID) else { return }
            switch candidate.kind {
            case .title:
                current.applyGeneratedTitle(candidate.value)
            case .summary:
                current.summary = candidate.value
                current.summaryUpdatedAt = current.lastActivityAt
            }
            try store.saveConversation(current)
            if currentConversation?.id == current.id { currentConversation = current }
        } catch {
            // Metadata is optimistic and never changes turn success.
        }
    }

    private func isSummaryStale(conversation: AIConversation, messages: [AIConversationMessage]) -> Bool {
        guard !conversation.summary.isEmpty, let updatedAt = conversation.summaryUpdatedAt else { return false }
        return messages.contains {
            $0.state == .completed && ($0.role == .user || $0.role == .assistant) && $0.createdAt > updatedAt
        }
    }

    private func safeMessage(_ error: Error, fallback: String) -> String {
        (error as? LocalizedError)?.errorDescription ?? fallback
    }
}

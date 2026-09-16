import Foundation

// MARK: - Lifecycle, affinity, roles
//
// The Kitchen AI conversation value layer. Everything here is a plain value:
// no store access, no networking, no SwiftUI. That matters because these are
// exactly the values that cross two untrusted-ish boundaries — provider output
// coming in, and local SwiftData history going out — and both boundaries need a
// closed, decodable shape rather than a dictionary the model can widen at will.
//
// Kitchen truth is not represented here. A recipe snapshot is a snapshot; a plan
// id is a reference. Current Inventory/Planner/Special Plan facts are always
// reread from their own domain layer when a turn depends on them.

/// Why the conversation exists, which is what its expiry is computed from.
nonisolated enum AIConversationLifecycleType: String, Codable, Sendable, CaseIterable {
    case general
    case dailyMeal
    case weeklyPlanning
    case specialPlan
}

/// Which entry surface a conversation belongs to. Kept separate from
/// `lifecycleType` so a later product change can reassign entry preference
/// without rewriting stored retention behavior.
nonisolated enum AIConversationAffinity: String, Codable, Sendable, CaseIterable {
    case general
    case dailyMeal
    case weeklyPlanning
    case specialPlan

    init(lifecycleType: AIConversationLifecycleType) {
        switch lifecycleType {
        case .general: self = .general
        case .dailyMeal: self = .dailyMeal
        case .weeklyPlanning: self = .weeklyPlanning
        case .specialPlan: self = .specialPlan
        }
    }
}

nonisolated enum AIConversationRole: String, Codable, Sendable {
    case user
    case assistant
    case systemStatus
}

nonisolated enum AIConversationMessageState: String, Codable, Sendable {
    case pending
    case streaming
    case completed
    case cancelled
    case failed
}

/// One explicit turn state instead of interdependent loading booleans. A turn
/// may cycle through the tool-related states more than once before completing.
nonisolated enum AIConversationTurnState: Equatable, Sendable {
    case idle
    case preparingContext
    case requesting
    case streaming
    case toolRequested
    case executing
    case awaitingConfirmation
    case completed
    case cancelled
    case failed

    /// Whether a new user message may start while this state is current.
    var acceptsUserInput: Bool {
        switch self {
        case .idle, .completed, .cancelled, .failed, .awaitingConfirmation: return true
        case .preparingContext, .requesting, .streaming, .toolRequested, .executing: return false
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed: return true
        default: return false
        }
    }
}

/// What the entry surface contributes, and the only thing it contributes. Home
/// and Planner own no conversation state of their own.
nonisolated enum AIConversationEntryContext: Equatable, Sendable {
    case home
    case planner(weekStart: Date, specialPlanID: UUID?)

    /// A Planner entry creates a week-anchored conversation even when a Special
    /// Plan is in focus.
    ///
    /// `.specialPlan` expiry is derived from the event time, and the entry
    /// surface only knows the displayed week — anchoring a `.specialPlan`
    /// conversation on a Monday would compute a window nobody asked for. The
    /// focused plan is still recorded in `anchorEntityID`, so the Special Plan
    /// context is reread and affinity can still match a genuinely
    /// event-anchored conversation created with that event's own date.
    var newConversationLifecycle: AIConversationLifecycleType {
        switch self {
        case .home: return .dailyMeal
        case .planner: return .weeklyPlanning
        }
    }

    var newConversationAffinity: AIConversationAffinity {
        AIConversationAffinity(lifecycleType: newConversationLifecycle)
    }

    /// The task anchor a new conversation stores so expiry stays deterministic.
    var anchorDate: Date? {
        switch self {
        case .home: return nil
        case let .planner(weekStart, _): return weekStart
        }
    }

    var anchorEntityID: UUID? {
        switch self {
        case .home: return nil
        case let .planner(_, specialPlanID): return specialPlanID
        }
    }
}

// MARK: - Context provenance

/// Which live domain source a turn may consult. Also the unit the user can
/// exclude for a single message.
nonisolated enum AIContextKind: String, Codable, Sendable, CaseIterable {
    case inventory
    case tonightPlan
    case plannerWeek
    case specialPlan
    case recipe

    /// Context-chip copy. The chip names a source, never its payload.
    var displayName: String {
        switch self {
        case .inventory: return "库存"
        case .tonightPlan: return "今晚计划"
        case .plannerWeek: return "本周计划"
        case .specialPlan: return "聚餐计划"
        case .recipe: return "菜谱"
        }
    }
}

/// Freshness/provenance metadata for one turn. Explicitly **not** a second
/// source of kitchen truth: nothing reads a snapshot to answer a later question.
nonisolated struct AIContextSnapshot: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var turnID: UUID
    var readAt: Date
    var contextKinds: [AIContextKind]
    var relatedEntityIDs: [String]
    /// Cheap change detectors (counts/updatedAt digests) used to explain what was
    /// read, not to reconstruct it.
    var sourceFingerprints: [String]

    init(
        id: UUID = UUID(),
        turnID: UUID,
        readAt: Date,
        contextKinds: [AIContextKind],
        relatedEntityIDs: [String] = [],
        sourceFingerprints: [String] = []
    ) {
        self.id = id
        self.turnID = turnID
        self.readAt = readAt
        self.contextKinds = contextKinds
        self.relatedEntityIDs = relatedEntityIDs
        self.sourceFingerprints = sourceFingerprints
    }
}

// MARK: - Content blocks

nonisolated struct AITextBlock: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var text: String

    init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

/// A recipe the assistant surfaced.
///
/// `isTransient` is the whole point of the type: a generated suggestion is not a
/// `RecipeStore` recipe until an explicit domain action needs it to be. The
/// snapshot is stored so old history still renders, while any mutation
/// re-resolves or materializes the recipe at execution time.
nonisolated struct AIRecipeBlock: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var recipe: Recipe
    var isTransient: Bool
    var reason: String?

    init(id: UUID = UUID(), recipe: Recipe, isTransient: Bool, reason: String? = nil) {
        self.id = id
        self.recipe = recipe
        self.isTransient = isTransient
        self.reason = reason
    }
}

nonisolated struct AIPlannerChangeRow: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    /// The canonical domain row being changed — a `MealPlanItem.id` or a
    /// `SpecialPlanDish.id`, never a model-authored label.
    var targetID: UUID
    var before: String
    var after: String

    init(id: UUID = UUID(), targetID: UUID, before: String, after: String) {
        self.id = id
        self.targetID = targetID
        self.before = before
        self.after = after
    }
}

/// A real before -> after diff. Every affected row is listed; there is no
/// summarized or hidden change, because this block is what the user actually
/// approves.
nonisolated struct AIPlannerPreviewBlock: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var changes: [AIPlannerChangeRow]
    /// The prepared, already validated action this preview confirms.
    var pendingActionID: UUID?

    init(
        id: UUID = UUID(),
        title: String,
        changes: [AIPlannerChangeRow],
        pendingActionID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.changes = changes
        self.pendingActionID = pendingActionID
    }
}

nonisolated struct AIContextRow: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var label: String
    var detail: String

    init(id: UUID = UUID(), label: String, detail: String) {
        self.id = id
        self.label = label
        self.detail = detail
    }
}

nonisolated struct AIContextResultBlock: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var rows: [AIContextRow]
    var kind: AIContextKind?

    init(id: UUID = UUID(), title: String, rows: [AIContextRow], kind: AIContextKind? = nil) {
        self.id = id
        self.title = title
        self.rows = rows
        self.kind = kind
    }
}

nonisolated struct AIActionStatusBlock: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var message: String
    var actionID: UUID
    var canUndo: Bool
    /// True when the mutation did not happen, so the row can offer a targeted
    /// retry instead of a celebratory success line.
    var isFailure: Bool

    init(
        id: UUID = UUID(),
        message: String,
        actionID: UUID,
        canUndo: Bool,
        isFailure: Bool = false
    ) {
        self.id = id
        self.message = message
        self.actionID = actionID
        self.canUndo = canUndo
        self.isFailure = isFailure
    }
}

/// Which stage a retry should restart. Retrying the whole turn could repeat a
/// side effect, so the scope is explicit rather than inferred.
nonisolated enum AIRetryScope: String, Codable, Sendable {
    case generation
    case contextRead
    case action
    case interpretation
}

nonisolated struct AIErrorBlock: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var message: String
    var retry: AIRetryScope?

    init(id: UUID = UUID(), message: String, retry: AIRetryScope? = nil) {
        self.id = id
        self.message = message
        self.retry = retry
    }
}

/// Exactly six kinds, deliberately closed.
///
/// A universal "arbitrary widget" case would let provider output name UI and
/// bypass validation, which is the failure this enum exists to prevent. A new
/// block kind is a product decision, not a runtime payload.
nonisolated enum AIContentBlock: Codable, Equatable, Sendable, Identifiable {
    case text(AITextBlock)
    case recipe(AIRecipeBlock)
    case plannerPreview(AIPlannerPreviewBlock)
    case contextResult(AIContextResultBlock)
    case actionStatus(AIActionStatusBlock)
    case error(AIErrorBlock)

    var id: UUID {
        switch self {
        case let .text(block): return block.id
        case let .recipe(block): return block.id
        case let .plannerPreview(block): return block.id
        case let .contextResult(block): return block.id
        case let .actionStatus(block): return block.id
        case let .error(block): return block.id
        }
    }

    var asText: AITextBlock? {
        if case let .text(block) = self { return block }
        return nil
    }
}

// MARK: - Messages

/// A message owns ordered content blocks, not one Markdown string. Streaming
/// text grows the trailing `text` block; a structured block is appended whole.
nonisolated struct AIConversationMessage: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var conversationID: UUID
    var role: AIConversationRole
    var createdAt: Date
    var state: AIConversationMessageState
    var contentBlocks: [AIContentBlock]
    var turnID: UUID

    init(
        id: UUID = UUID(),
        conversationID: UUID,
        role: AIConversationRole,
        createdAt: Date = Date(),
        state: AIConversationMessageState,
        contentBlocks: [AIContentBlock],
        turnID: UUID
    ) {
        self.id = id
        self.conversationID = conversationID
        self.role = role
        self.createdAt = createdAt
        self.state = state
        self.contentBlocks = contentBlocks
        self.turnID = turnID
    }

    /// Plain text of the message, used for the recent-message window and the
    /// History excerpt. Structured blocks contribute their own short summary
    /// rather than a serialized payload.
    var plainTextSummary: String {
        contentBlocks.compactMap { block in
            switch block {
            case let .text(text): return text.text
            case let .recipe(recipe): return recipe.recipe.title
            case let .plannerPreview(preview): return preview.title
            case let .contextResult(context): return context.title
            case let .actionStatus(status): return status.message
            case let .error(error): return error.message
            }
        }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Conversation

nonisolated struct AIConversation: Identifiable, Codable, Equatable, Sendable {
    /// The placeholder title. Generated titles only ever replace this value.
    static let defaultTitle = "新对话"

    var id: UUID
    var createdAt: Date
    var title: String
    var lifecycleType: AIConversationLifecycleType
    var entryAffinity: AIConversationAffinity
    var lastActivityAt: Date
    /// When this conversation stops being the automatic default. Never a
    /// deletion deadline: expired history stays readable forever.
    ///
    /// Always assigned from `ConversationRetentionPolicy`; it has no default,
    /// because a conversation with a guessed window is one affinity can never
    /// resume.
    var activeUntil: Date
    var isPinned: Bool
    var anchorDate: Date?
    var anchorEntityID: UUID?
    var summary: String
    var summaryUpdatedAt: Date?
    var retentionPolicyVersion: Int
    /// A rename is a user decision, so automatic title generation has to be able
    /// to tell it from the untouched placeholder instead of comparing strings.
    var hasUserEditedTitle: Bool

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        title: String = AIConversation.defaultTitle,
        lifecycleType: AIConversationLifecycleType = .general,
        entryAffinity: AIConversationAffinity = .general,
        lastActivityAt: Date = Date(),
        activeUntil: Date,
        isPinned: Bool = false,
        anchorDate: Date? = nil,
        anchorEntityID: UUID? = nil,
        summary: String = "",
        summaryUpdatedAt: Date? = nil,
        retentionPolicyVersion: Int = ConversationRetentionPolicy.v1.version,
        hasUserEditedTitle: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.lifecycleType = lifecycleType
        self.entryAffinity = entryAffinity
        self.lastActivityAt = lastActivityAt
        self.activeUntil = activeUntil
        self.isPinned = isPinned
        self.anchorDate = anchorDate
        self.anchorEntityID = anchorEntityID
        self.summary = summary
        self.summaryUpdatedAt = summaryUpdatedAt
        self.retentionPolicyVersion = retentionPolicyVersion
        self.hasUserEditedTitle = hasUserEditedTitle
    }

    /// Expiry ends automatic continuity only. A pinned conversation never
    /// expires while it stays pinned.
    func isExpired(now: Date) -> Bool {
        guard !isPinned else { return false }
        return activeUntil <= now
    }

    /// Whether a generated title may still be applied.
    var acceptsGeneratedTitle: Bool {
        !hasUserEditedTitle && title == Self.defaultTitle
    }

    mutating func applyUserTitle(_ newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        title = trimmed
        hasUserEditedTitle = true
    }

    /// Applies a generated title, or does nothing if the user already named it.
    mutating func applyGeneratedTitle(_ newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard acceptsGeneratedTitle, !trimmed.isEmpty else { return }
        title = trimmed
    }
}

// MARK: - Actions

nonisolated enum AIActionRisk: String, Codable, Sendable {
    case low
    case medium
    case high

    /// Medium and high risk never execute from prose. They render a real diff
    /// and wait for an explicit Apply.
    var requiresExplicitConfirmation: Bool { self != .low }
}

nonisolated enum AIActionType: String, Codable, Sendable, CaseIterable {
    case addRecipeToTonight
    case replacePlannedMeal
    case applyPlannerChanges
    case replaceSpecialPlanDishes
    case addShoppingItems
}

nonisolated enum AIActionStatus: String, Codable, Sendable {
    case proposed
    case awaitingConfirmation
    case executing
    case succeeded
    case failed
    case undone
}

nonisolated struct AIPlannerMealChange: Codable, Equatable, Sendable {
    /// The canonical `MealPlanItem.id` being replaced. The "before" text is never
    /// taken from the model — the preview reads it from current Planner state.
    var planID: UUID
    var replacement: AIRecipeBlock
    var plannedServings: Int?

    init(planID: UUID, replacement: AIRecipeBlock, plannedServings: Int? = nil) {
        self.planID = planID
        self.replacement = replacement
        self.plannedServings = plannedServings
    }
}

nonisolated struct AISpecialPlanDishChange: Codable, Equatable, Sendable {
    var dishID: UUID
    var replacement: AIRecipeBlock

    init(dishID: UUID, replacement: AIRecipeBlock) {
        self.dishID = dishID
        self.replacement = replacement
    }
}

nonisolated struct AIShoppingItemProposal: Codable, Equatable, Sendable {
    var name: String
    var quantity: Double
    var unit: String
    var remark: String?

    init(name: String, quantity: Double, unit: String, remark: String? = nil) {
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.remark = remark
    }
}

/// Mutation intent as a closed set of five typed proposals.
///
/// Model prose never mutates anything. Intent becomes one of these values, and
/// `ConversationActionCoordinator` is the only path from here to a domain write.
/// A capability the model merely asks for does not exist.
nonisolated enum AIActionProposal: Codable, Equatable, Sendable {
    case addRecipeToTonight(recipe: AIRecipeBlock)
    case replacePlannedMeal(planID: UUID, replacement: AIRecipeBlock)
    case applyPlannerChanges(changes: [AIPlannerMealChange])
    case replaceSpecialPlanDishes(planID: UUID, changes: [AISpecialPlanDishChange])
    case addShoppingItems(items: [AIShoppingItemProposal])

    var actionType: AIActionType {
        switch self {
        case .addRecipeToTonight: return .addRecipeToTonight
        case .replacePlannedMeal: return .replacePlannedMeal
        case .applyPlannerChanges: return .applyPlannerChanges
        case .replaceSpecialPlanDishes: return .replaceSpecialPlanDishes
        case .addShoppingItems: return .addShoppingItems
        }
    }

    /// References to the domain entities this proposal touches, free of model
    /// prose. This is what `AIConversationActionRecord.relatedEntityIDs` stores,
    /// and what provenance and Undo-safety checks look up.
    ///
    /// It is deliberately **not** the idempotency identity. It omits material
    /// proposal data — `plannedServings`, Shopping remarks, the rest of the
    /// replacement payload — so two genuinely different proposals against the
    /// same targets share this list. The idempotency key is canonicalized from
    /// the whole proposal by `ConversationActionCoordinator`; deriving it from
    /// these values alone would make a real second edit look like a retry and
    /// silently drop it.
    var relatedEntityIDs: [String] {
        switch self {
        case let .addRecipeToTonight(recipe):
            return [recipe.recipe.id]
        case let .replacePlannedMeal(planID, replacement):
            return [planID.uuidString, replacement.recipe.id]
        case let .applyPlannerChanges(changes):
            return changes.flatMap { [$0.planID.uuidString, $0.replacement.recipe.id] }
        case let .replaceSpecialPlanDishes(planID, changes):
            return [planID.uuidString] + changes.flatMap {
                [$0.dishID.uuidString, $0.replacement.recipe.id]
            }
        case let .addShoppingItems(items):
            return items.map { "\($0.name)|\($0.quantity)|\($0.unit)" }
        }
    }
}

/// The exact pre-mutation state Undo restores, plus the post-mutation state it
/// compares against first.
///
/// Both halves are required. Restoring `before` without checking `after` would
/// silently overwrite whatever the user changed in the meantime, which is worse
/// than refusing to undo. Undo is app-owned and deterministic; the model is
/// never asked to reconstruct it later.
nonisolated enum AIDomainMutationReceipt: Codable, Equatable, Sendable {
    /// One plan added to today. `createdRecipeIDs` are only the recipes this
    /// action itself created, so compensation never deletes a pre-existing one.
    case tonightPlan(plan: MealPlanItem, createdRecipeIDs: [String])
    case plannerReplacement(before: [MealPlanItem], after: [MealPlanItem], createdRecipeIDs: [String])
    case specialPlanMenu(before: SpecialPlan, after: SpecialPlan, createdRecipeIDs: [String])
    case shoppingAdditions(before: [KitchenShoppingItem], after: [KitchenShoppingItem])

    /// Recipes this action created and may therefore compensate.
    var createdRecipeIDs: [String] {
        switch self {
        case let .tonightPlan(_, createdRecipeIDs): return createdRecipeIDs
        case let .plannerReplacement(_, _, createdRecipeIDs): return createdRecipeIDs
        case let .specialPlanMenu(_, _, createdRecipeIDs): return createdRecipeIDs
        case .shoppingAdditions: return []
        }
    }
}

nonisolated struct AIConversationActionRecord: Identifiable, Codable, Equatable, Sendable {
    var actionID: UUID
    var conversationID: UUID
    var turnID: UUID
    var actionType: AIActionType
    /// Stable digest of the canonical proposal. A retry with the same intent
    /// finds the succeeded record instead of mutating twice.
    var idempotencyKey: String
    var status: AIActionStatus
    var createdAt: Date
    var completedAt: Date?
    var relatedEntityIDs: [String]
    var undoReference: AIDomainMutationReceipt?
    var undoExpiresAt: Date?
    /// Truthful, user-safe failure copy. Never provider diagnostics.
    var failureMessage: String?

    var id: UUID { actionID }

    init(
        actionID: UUID = UUID(),
        conversationID: UUID,
        turnID: UUID,
        actionType: AIActionType,
        idempotencyKey: String,
        status: AIActionStatus,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        relatedEntityIDs: [String] = [],
        undoReference: AIDomainMutationReceipt? = nil,
        undoExpiresAt: Date? = nil,
        failureMessage: String? = nil
    ) {
        self.actionID = actionID
        self.conversationID = conversationID
        self.turnID = turnID
        self.actionType = actionType
        self.idempotencyKey = idempotencyKey
        self.status = status
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.relatedEntityIDs = relatedEntityIDs
        self.undoReference = undoReference
        self.undoExpiresAt = undoExpiresAt
        self.failureMessage = failureMessage
    }

    /// Undo is offered only while the app still holds a deterministic reversal.
    func canUndo(now: Date) -> Bool {
        guard status == .succeeded, undoReference != nil else { return false }
        if let undoExpiresAt { return now < undoExpiresAt }
        return true
    }
}

import Foundation
import CryptoKit

/// Immutable capability produced only by prepare. Apply cannot substitute a proposal.
struct PreparedAIAction: Identifiable, Equatable {
    let id: UUID
    let proposal: AIActionProposal
    let risk: AIActionRisk
    let preview: AIContentBlock?
    let idempotencyKey: String
    fileprivate let conversationID: UUID
    fileprivate let plans: [MealPlanItem]
    fileprivate let specialPlan: SpecialPlan?
    fileprivate let recipes: [Recipe]
    fileprivate let terminalID: UUID?
    fileprivate let terminalStatus: AIActionStatus?
    fileprivate let day: Date
}

struct AIActionExecutionResult: Equatable {
    let record: AIConversationActionRecord
}

enum AIActionExecutionError: LocalizedError, Equatable {
    case notPrepared, stale, uncertain, expired, unsupported, invalidRecipe, invalidExpiry, storage

    var errorDescription: String? {
        switch self {
        case .notPrepared: return "找不到已准备的操作，请重新准备。"
        case .stale: return "内容或操作状态已变化，请重新查看后确认，没有改动。"
        case .uncertain: return "本地操作记录与实际结果尚未确认，已停止重复执行，请先检查计划或购物清单。"
        case .expired: return "这次操作已超过可撤销期限，没有改动。"
        case .unsupported: return "这次批量购物操作暂不支持，请每次添加最多 5 项。"
        case .invalidRecipe: return "菜谱内容不完整，无法加入计划。"
        case .invalidExpiry: return "撤销期限尚未正确配置，没有改动。"
        case .storage: return "操作记录保存失败；没有保留这次改动，请稍后重试。"
        }
    }
}

/// The sole conversation mutation gateway. Synchronous main-actor calls keep
/// validation, durable intent, and the domain write in one non-suspending section.
@MainActor
final class ConversationActionCoordinator {
    private let domain: any AIConversationDomainTooling
    private let persistence: any ConversationPersistenceProtocol
    private let now: () -> Date
    private let undoExpiresAt: (Date) -> Date
    private let actionID: () -> UUID

    init(domainTools: any AIConversationDomainTooling, persistence: any ConversationPersistenceProtocol,
         now: @escaping () -> Date = Date.init, undoExpiresAt: @escaping (Date) -> Date,
         actionID: @escaping () -> UUID = UUID.init) {
        domain = domainTools
        self.persistence = persistence
        self.now = now
        self.undoExpiresAt = undoExpiresAt
        self.actionID = actionID
    }

    func prepare(_ proposal: AIActionProposal, conversationID: UUID, turnID: UUID) throws -> PreparedAIAction {
        let time = now()
        let blocks = recipeBlocks(proposal)
        let recipes = domain.mutationRecipes(blocks)
        guard recipes.count == blocks.count else { throw AIActionExecutionError.invalidRecipe }
        guard recipes.allSatisfy({ !$0.id.isEmpty && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !$0.ingredients.isEmpty && !$0.steps.isEmpty }) else { throw AIActionExecutionError.invalidRecipe }
        let id = actionID()
        var plans: [MealPlanItem] = []
        var special: SpecialPlan?
        var rows: [AIPlannerChangeRow] = []
        let risk: AIActionRisk
        switch proposal {
        case .addRecipeToTonight:
            risk = .low
        case .replacePlannedMeal, .applyPlannerChanges:
            let changes = plannerChanges(proposal)
            try validateTargets(changes.map(\.planID))
            for (change, recipe) in zip(changes, recipes) {
                guard let before = domain.plannedMeal(id: change.planID) else {
                    throw AIDomainToolError.planNotFound([change.planID])
                }
                if let servings = change.plannedServings, !Recipe.validBaseServings.contains(servings) {
                    throw AIActionExecutionError.invalidRecipe
                }
                plans.append(before)
                rows.append(.init(targetID: before.id,
                    before: mealText(before.recipeName, servings: before.plannedServings, cooked: before.isCooked),
                    after: mealText(recipe.title, servings: change.plannedServings ?? before.plannedServings, cooked: false)))
            }
            risk = changes.count == 1 ? .medium : .high
        case let .replaceSpecialPlanDishes(planID, changes):
            try validateTargets(changes.map(\.dishID))
            guard let before = domain.specialPlan(id: planID) else { throw AIDomainToolError.specialPlanNotFound(planID) }
            special = before
            for (change, recipe) in zip(changes, recipes) {
                guard let dish = before.dishes.first(where: { $0.id == change.dishID }) else {
                    throw AIDomainToolError.dishNotFound([change.dishID])
                }
                rows.append(.init(targetID: dish.id,
                    before: mealText(dish.recipeName, servings: nil, cooked: dish.isCooked),
                    after: mealText(recipe.title, servings: nil, cooked: false)))
            }
            risk = changes.count == 1 ? .medium : .high
        case let .addShoppingItems(items):
            guard !items.isEmpty else { throw AIDomainToolError.emptyRequest }
            guard items.count <= 5 else { throw AIActionExecutionError.unsupported }
            guard items.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw AIDomainToolError.unnamedShoppingItem
            }
            guard items.allSatisfy({ $0.quantity.isFinite && $0.quantity > 0 }) else {
                throw AIDomainToolError.invalidShoppingQuantity
            }
            risk = .low
        }
        let key = try idempotencyKey(proposal, recipes: recipes, conversationID: conversationID, turnID: turnID, day: domain.calendar.startOfDay(for: time))
        let history = try persistence.loadActions(conversationID: conversationID)
        try refuseUncertain(history, key: key)
        let terminal = try persistence.action(idempotencyKey: key)
        guard try persistence.action(id: id) == nil else { throw AIActionExecutionError.notPrepared }
        // Preserve createdAt thereafter. A fixed/coarse clock must not place a
        // new execution behind an older undone attempt's UUID tiebreak.
        let latest = history.map(\.createdAt).max()
        let createdAt = latest.map { $0 >= time ? Date(timeIntervalSinceReferenceDate: $0.timeIntervalSinceReferenceDate.nextUp) : time } ?? time
        var record = AIConversationActionRecord(actionID: id, conversationID: conversationID, turnID: turnID,
            actionType: proposal.actionType, idempotencyKey: key, status: .proposed, createdAt: createdAt,
            relatedEntityIDs: proposal.relatedEntityIDs)
        try persistence.upsertAction(record)
        if risk.requiresExplicitConfirmation {
            record.status = .awaitingConfirmation
            try persistence.upsertAction(record)
        }
        return PreparedAIAction(id: id, proposal: proposal, risk: risk,
            preview: rows.isEmpty ? nil : .plannerPreview(.init(title: "确认计划变更", changes: rows, pendingActionID: id)),
            idempotencyKey: key, conversationID: conversationID, plans: plans, specialPlan: special, recipes: recipes,
            terminalID: terminal?.status == .undone || terminal?.status == .succeeded ? terminal?.id : nil,
            terminalStatus: terminal?.status == .undone || terminal?.status == .succeeded ? terminal?.status : nil,
            day: domain.calendar.startOfDay(for: time))
    }

    func execute(_ action: PreparedAIAction) throws -> AIActionExecutionResult {
        guard var record = try persistence.action(id: action.id), record.conversationID == action.conversationID,
              record.idempotencyKey == action.idempotencyKey else { throw AIActionExecutionError.notPrepared }
        // Terminal lookup intentionally prefers terminal rows. Scan the complete
        // history too: an older undone row must not hide an interrupted redo.
        try refuseUncertain(persistence.loadActions(conversationID: record.conversationID), key: record.idempotencyKey)
        let time = now()
        if case .addRecipeToTonight = action.proposal,
           domain.calendar.startOfDay(for: time) != action.day { throw AIActionExecutionError.stale }
        if let terminal = try persistence.action(idempotencyKey: record.idempotencyKey) {
            if terminal.status == .succeeded { return .init(record: terminal) }
            if terminal.status == .undone {
                guard action.terminalID == terminal.id, action.terminalStatus == .undone,
                      record.id != terminal.id else { throw AIActionExecutionError.stale }
            }
        }
        guard [.proposed, .awaitingConfirmation, .failed].contains(record.status) else { throw AIActionExecutionError.stale }
        guard !action.risk.requiresExplicitConfirmation || record.status == .awaitingConfirmation || record.status == .failed else {
            throw AIActionExecutionError.notPrepared
        }
        guard action.plans.allSatisfy({ domain.plannedMeal(id: $0.id) == $0 }),
              action.specialPlan.map({ domain.specialPlan(id: $0.id) == $0 }) ?? true,
              domain.mutationRecipes(recipeBlocks(action.proposal)) == action.recipes else { throw AIActionExecutionError.stale }
        let expiry = undoExpiresAt(time)
        guard expiry.timeIntervalSinceReferenceDate.isFinite, expiry > time else { throw AIActionExecutionError.invalidExpiry }
        record.status = .executing
        record.failureMessage = nil
        record.completedAt = nil
        try persistence.upsertAction(record)

        let receipt: AIDomainMutationReceipt
        do {
            switch action.proposal {
            case let .addRecipeToTonight(recipe): receipt = try domain.addRecipeToTonight(recipe, now: time)
            case .replacePlannedMeal, .applyPlannerChanges: receipt = try domain.replacePlannedMeals(plannerChanges(action.proposal))
            case let .replaceSpecialPlanDishes(planID, changes): receipt = try domain.replaceSpecialPlanDishes(planID: planID, changes: changes)
            case let .addShoppingItems(items): receipt = try domain.addShoppingItems(items)
            }
        } catch let error as AIDomainToolError {
            record.status = .failed
            record.completedAt = now()
            record.failureMessage = error.errorDescription
            do { try persistence.upsertAction(record) } catch { throw AIActionExecutionError.uncertain }
            throw error
        } catch {
            // An undocumented throw cannot prove that nothing was written.
            throw AIActionExecutionError.uncertain
        }
        record.status = .succeeded
        record.completedAt = now()
        record.undoReference = receipt
        record.undoExpiresAt = expiry
        do {
            try persistence.upsertAction(record)
        } catch {
            // The durable executing row remains the replay barrier until both
            // exact compensation and a durable non-applied record succeed.
            record.status = .executing
            record.completedAt = nil
            record.failureMessage = AIActionExecutionError.uncertain.errorDescription
            do {
                // Save the recovery receipt before attempting a reversal that
                // can succeed only partly across the independent stores.
                try persistence.upsertAction(record)
                guard domain.currentStateMatchesPostState(of: receipt) else { throw AIActionExecutionError.uncertain }
                try domain.undo(receipt)
                guard domain.isCompletelyReversed(receipt) else { throw AIActionExecutionError.uncertain }
            } catch { throw AIActionExecutionError.uncertain }
            record.status = .failed
            record.undoReference = nil
            record.undoExpiresAt = nil
            record.failureMessage = AIActionExecutionError.storage.errorDescription
            record.completedAt = now()
            do { try persistence.upsertAction(record) } catch { throw AIActionExecutionError.uncertain }
            throw AIActionExecutionError.storage
        }
        return .init(record: record)
    }

    func undo(actionID: UUID) throws -> AIActionExecutionResult {
        guard var record = try persistence.action(id: actionID) else { throw AIActionExecutionError.notPrepared }
        try refuseUncertain(persistence.loadActions(conversationID: record.conversationID), key: record.idempotencyKey)
        if record.status == .undone { return .init(record: record) }
        guard record.status == .succeeded, let receipt = record.undoReference else { throw AIActionExecutionError.notPrepared }
        guard let expiry = record.undoExpiresAt, now() < expiry else { throw AIActionExecutionError.expired }
        guard domain.currentStateMatchesPostState(of: receipt) else { throw AIActionExecutionError.stale }
        let success = record
        // Undo has the same cross-store failure window. An executing row with a
        // receipt denotes an uncertain reversal if the process stops here.
        record.status = .executing
        try persistence.upsertAction(record)
        do { try domain.undo(receipt) } catch {
            do { try persistence.upsertAction(success) } catch { throw AIActionExecutionError.uncertain }
            throw error
        }
        record.status = .undone
        record.completedAt = now()
        do { try persistence.upsertAction(record) } catch { throw AIActionExecutionError.uncertain }
        return .init(record: record)
    }

    private func refuseUncertain(_ history: [AIConversationActionRecord], key: String) throws {
        guard !history.contains(where: { $0.idempotencyKey == key && $0.status == .executing }) else {
            throw AIActionExecutionError.uncertain
        }
    }

    private func validateTargets(_ ids: [UUID]) throws {
        guard !ids.isEmpty else { throw AIDomainToolError.emptyRequest }
        var seen = Set<UUID>()
        let duplicates = ids.filter { !seen.insert($0).inserted }
        guard duplicates.isEmpty else { throw AIDomainToolError.duplicateTargets(duplicates) }
    }

    private func mealText(_ name: String, servings: Int?, cooked: Bool) -> String {
        [name, servings.map { "\($0) 份" }, cooked ? "已做" : "未做"].compactMap { $0 }.joined(separator: " · ")
    }

    private func plannerChanges(_ proposal: AIActionProposal) -> [AIPlannerMealChange] {
        switch proposal {
        case let .replacePlannedMeal(id, replacement): return [.init(planID: id, replacement: replacement)]
        case let .applyPlannerChanges(changes): return changes
        default: return []
        }
    }

    private func recipeBlocks(_ proposal: AIActionProposal) -> [AIRecipeBlock] {
        switch proposal {
        case let .addRecipeToTonight(recipe): return [recipe]
        case let .replacePlannedMeal(_, replacement): return [replacement]
        case let .applyPlannerChanges(changes): return changes.map(\.replacement)
        case let .replaceSpecialPlanDishes(_, changes): return changes.map(\.replacement)
        case .addShoppingItems: return []
        }
    }

    /// Codable's explicit enum tags and full recipe payload (including source)
    /// are preserved. Only presentation fields and transient local identity are
    /// removed. Ordered arrays remain ordered; JSON uses sorted object keys and
    /// rejects nonfinite numbers. The canonical digest is lowercase SHA256 hex.
    private func idempotencyKey(_ proposal: AIActionProposal, recipes: [Recipe], conversationID: UUID, turnID: UUID, day: Date) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var index = 0
        func resolved(_ block: AIRecipeBlock) -> AIRecipeBlock {
            defer { index += 1 }
            return AIRecipeBlock(id: block.id, recipe: recipes[index], isTransient: block.isTransient)
        }
        let effective: AIActionProposal
        switch proposal {
        case let .addRecipeToTonight(recipe): effective = .addRecipeToTonight(recipe: resolved(recipe))
        case let .replacePlannedMeal(id, recipe): effective = .replacePlannedMeal(planID: id, replacement: resolved(recipe))
        case let .applyPlannerChanges(changes): effective = .applyPlannerChanges(changes: changes.map {
            .init(planID: $0.planID, replacement: resolved($0.replacement), plannedServings: $0.plannedServings)
        })
        case let .replaceSpecialPlanDishes(id, changes): effective = .replaceSpecialPlanDishes(planID: id, changes: changes.map {
            .init(dishID: $0.dishID, replacement: resolved($0.replacement))
        })
        case .addShoppingItems: effective = proposal
        }
        func canonical(_ value: Any) -> Any {
            if let array = value as? [Any] { return array.map(canonical) }
            guard var object = value as? [String: Any] else { return value }
            if let transient = object["isTransient"] as? Bool, var recipe = object["recipe"] as? [String: Any] {
                object.removeValue(forKey: "id")
                object.removeValue(forKey: "reason")
                if transient { recipe.removeValue(forKey: "id") }
                object["recipe"] = recipe
            }
            return object.mapValues(canonical)
        }
        var object: [String: Any] = ["conversationID": conversationID.uuidString.lowercased(),
                                    "turnID": turnID.uuidString.lowercased(),
                                    "proposal": canonical(try JSONSerialization.jsonObject(with: encoder.encode(effective)))]
        if case .addRecipeToTonight = proposal {
            // Use the domain calendar's resolved day, independent of clock time
            // and locale formatting. Another day represents another mutation.
            object["targetDay"] = day.timeIntervalSince1970
        }
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

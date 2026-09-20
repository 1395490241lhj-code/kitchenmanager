import Foundation

/// Presentation-only answer to "what did this AI action change, where can I
/// see it, and for how long can I take it back". Everything is derived from
/// the persisted `AIConversationActionRecord`, which the controller already
/// reconciles status blocks against on reopen, so no second copy of outcome
/// truth is stored anywhere. Provider prose never reaches this type.
nonisolated struct AIActionOutcomePresentation: Equatable {
    /// Where the affected kitchen data now lives, expressed as an existing
    /// `AppNavigationStore` command rather than a new route.
    enum Destination: Equatable {
        case today
        case plannedMeal(UUID)
        case plannerWeek
        case specialPlan(UUID)
        case shopping

        var label: String {
            switch self {
            case .today: return "查看今晚计划"
            case .plannedMeal, .plannerWeek: return "查看计划"
            case .specialPlan: return "查看聚餐"
            case .shopping: return "查看买菜清单"
            }
        }

        var accessibilityIdentifier: String {
            switch self {
            case .today: return "kitchenAI.action.destination.today"
            case .plannedMeal, .plannerWeek: return "kitchenAI.action.destination.planner"
            case .specialPlan: return "kitchenAI.action.destination.specialPlan"
            case .shopping: return "kitchenAI.action.destination.shopping"
            }
        }
    }

    /// Action-specific copy for a successful mutation, in the app's own words.
    static func outcomeTitle(for actionType: AIActionType) -> String {
        switch actionType {
        case .addRecipeToTonight: return "已加入今晚计划"
        case .replacePlannedMeal: return "已更新计划中的这餐"
        case .applyPlannerChanges: return "已更新本周计划"
        case .replaceSpecialPlanDishes: return "已更新聚餐菜单"
        case .addShoppingItems: return "已加入买菜清单"
        }
    }

    /// Undo restores the exact pre-mutation snapshot the receipt holds, so
    /// "恢复" is the one verb that is always true regardless of what the
    /// mutation had merged, replaced or added.
    static func undoneTitle(for actionType: AIActionType) -> String {
        switch actionType {
        case .addRecipeToTonight: return "已撤销，今晚计划已恢复"
        case .replacePlannedMeal: return "已撤销，这餐已恢复"
        case .applyPlannerChanges: return "已撤销，本周计划已恢复"
        case .replaceSpecialPlanDishes: return "已撤销，聚餐菜单已恢复"
        case .addShoppingItems: return "已撤销，买菜清单已恢复"
        }
    }

    /// The destination is derived from the record's action type and the domain
    /// ids it already stores. A record whose ids cannot name a single target
    /// falls back to the surface's root, never to a guessed entity.
    static func destination(for record: AIConversationActionRecord) -> Destination? {
        guard record.status == .succeeded else { return nil }
        switch record.actionType {
        case .addRecipeToTonight:
            return .today
        case .replacePlannedMeal:
            if let first = record.relatedEntityIDs.first, let planID = UUID(uuidString: first) {
                return .plannedMeal(planID)
            }
            return .plannerWeek
        case .applyPlannerChanges:
            return .plannerWeek
        case .replaceSpecialPlanDishes:
            if let first = record.relatedEntityIDs.first, let planID = UUID(uuidString: first) {
                return .specialPlan(planID)
            }
            return .plannerWeek
        case .addShoppingItems:
            return .shopping
        }
    }

    /// "可撤销至 HH:mm", only while the persisted expiry still lies ahead. Static
    /// on purpose: the block is re-read from the record on reopen, and the undo
    /// command itself refuses an expired attempt, so a live countdown would add
    /// a second clock without adding truth.
    static func undoAvailability(for record: AIConversationActionRecord, now: Date) -> String? {
        guard record.canUndo(now: now), let expiry = record.undoExpiresAt else { return nil }
        return "可撤销至 \(Self.timeFormatter.string(from: expiry))"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "HH:mm"
        return f
    }()
}

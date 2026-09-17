import Foundation

nonisolated enum AIReadToolRequest: Equatable, Sendable {
    case inventory(expiringOnly: Bool?)
    case tonightPlan
    case plannerWeek(weekStart: Date)
    case specialPlan(id: UUID)
    case resolveRecipe(query: String, recipeID: String?)
}

nonisolated enum AIConversationToolIntent: Equatable, Sendable {
    case read(AIReadToolRequest)
    case appendBlock(AIContentBlock)
    case proposeAction(AIActionProposal)
}

nonisolated struct AIConversationToolCall: Equatable, Sendable {
    let id: String
    let name: String
    let arguments: Data
}

/// The caller assigns stable local identities; this layer never invents them.
nonisolated struct AITransientRecipeIdentity: Sendable {
    let blockID: UUID
    let recipeID: String
}

/// Canonical snapshots and transient identities use paths recipe, replacement,
/// or changes.<index>.replacement. Transient CONTENT is decoded by this layer.
/// This is pure value input, not a store/resolver or another parsing interface.
nonisolated struct AIConversationInterpretationContext: Sendable {
    let blockID: UUID
    let rowIDs: [UUID]
    let recipesByPath: [String: AIRecipeBlock]
    let transientIdentitiesByPath: [String: AITransientRecipeIdentity]
    let calendar: Calendar

    init(blockID: UUID, rowIDs: [UUID], recipesByPath: [String: AIRecipeBlock],
         transientIdentitiesByPath: [String: AITransientRecipeIdentity] = [:], calendar: Calendar) {
        self.blockID = blockID
        self.rowIDs = rowIDs
        self.recipesByPath = recipesByPath
        self.transientIdentitiesByPath = transientIdentitiesByPath
        self.calendar = calendar
    }
}

nonisolated struct ConversationResponseInterpreter {
    private enum Invalid: Error { case arguments }

    func interpret(toolCall: AIConversationToolCall, context: AIConversationInterpretationContext) -> AIConversationToolIntent {
        do {
            guard !toolCall.id.isEmpty else { throw Invalid.arguments }
            let value = try JSONDecoder().decode(JSONAnyValue.self, from: toolCall.arguments)
            switch toolCall.name {
            case "read_inventory":
                let args = try object(value, allowed: ["expiringOnly"])
                let only: Bool?
                if let value = args["expiringOnly"] {
                    guard case .bool(let flag) = value else { throw Invalid.arguments }
                    only = flag
                } else { only = nil }
                return .read(.inventory(expiringOnly: only))
            case "read_tonight_plan":
                _ = try object(value, allowed: [])
                return .read(.tonightPlan)
            case "read_planner_week":
                let args = try object(value, allowed: ["weekStart"])
                return .read(.plannerWeek(weekStart: try date(string(args, "weekStart"), calendar: context.calendar)))
            case "read_special_plan":
                let args = try object(value, allowed: ["planID"])
                return .read(.specialPlan(id: try uuid(args, "planID")))
            case "resolve_recipe":
                let args = try object(value, allowed: ["query", "recipeID"])
                return .read(.resolveRecipe(query: try string(args, "query"), recipeID: try optionalString(args, "recipeID")))
            case "present_recipe_card":
                let args = try object(value, allowed: ["recipe"])
                return .appendBlock(.recipe(try recipe(args["recipe"], path: "recipe", context: context)))
            case "present_context_result":
                let args = try object(value, allowed: ["kind", "title", "rows"])
                let title = try string(args, "title")
                let kind: AIContextKind?
                if let raw = try optionalString(args, "kind") {
                    guard let parsed = AIContextKind(rawValue: raw) else { throw Invalid.arguments }
                    kind = parsed
                } else { kind = nil }
                let values = try array(args, "rows")
                guard context.rowIDs.count == values.count, Set(context.rowIDs).count == values.count else { throw Invalid.arguments }
                let rows = try values.enumerated().map { index, value in
                    let row = try object(value, allowed: ["label", "value"])
                    return AIContextRow(id: context.rowIDs[index], label: try string(row, "label"), detail: try string(row, "value", allowEmpty: true))
                }
                return .appendBlock(.contextResult(.init(id: context.blockID, title: title, rows: rows, kind: kind)))
            case "propose_add_recipe_to_tonight":
                let args = try object(value, allowed: ["recipe", "plannedServings"])
                // These existing proposal cases cannot carry servings. Refuse
                // explicit intent rather than silently discarding or guessing it.
                guard args["plannedServings"] == nil else { throw Invalid.arguments }
                return .proposeAction(.addRecipeToTonight(recipe: try recipe(args["recipe"], path: "recipe", context: context)))
            case "propose_replace_planned_meal":
                let args = try object(value, allowed: ["planID", "replacement", "plannedServings"])
                guard args["plannedServings"] == nil else { throw Invalid.arguments }
                return .proposeAction(.replacePlannedMeal(planID: try uuid(args, "planID"),
                    replacement: try recipe(args["replacement"], path: "replacement", context: context)))
            case "propose_apply_planner_changes":
                let args = try object(value, allowed: ["changes"])
                let changes = try array(args, "changes", nonempty: true).enumerated().map { index, value in
                    let row = try object(value, allowed: ["planID", "replacement", "plannedServings"])
                    let servings: Int?
                    if let value = row["plannedServings"] {
                        guard case .number(let n) = value, n.isFinite, n.rounded() == n, (1...12).contains(n) else { throw Invalid.arguments }
                        servings = Int(n)
                    } else { servings = nil }
                    return AIPlannerMealChange(planID: try uuid(row, "planID"),
                        replacement: try recipe(row["replacement"], path: "changes.\(index).replacement", context: context), plannedServings: servings)
                }
                return .proposeAction(.applyPlannerChanges(changes: changes))
            case "propose_special_plan_changes":
                let args = try object(value, allowed: ["planID", "changes"])
                let planID = try uuid(args, "planID")
                let changes = try array(args, "changes", nonempty: true).enumerated().map { index, value in
                    let row = try object(value, allowed: ["dishID", "replacement"])
                    return AISpecialPlanDishChange(dishID: try uuid(row, "dishID"),
                        replacement: try recipe(row["replacement"], path: "changes.\(index).replacement", context: context))
                }
                return .proposeAction(.replaceSpecialPlanDishes(planID: planID, changes: changes))
            case "propose_add_shopping_items":
                let args = try object(value, allowed: ["items"])
                let items = try array(args, "items", nonempty: true).map { value in
                    let row = try object(value, allowed: ["name", "quantity", "unit", "remark"])
                    guard case .number(let quantity) = row["quantity"], quantity.isFinite, quantity > 0 else { throw Invalid.arguments }
                    return AIShoppingItemProposal(name: try string(row, "name"), quantity: quantity,
                        unit: try string(row, "unit", allowEmpty: true), remark: try optionalString(row, "remark"))
                }
                return .proposeAction(.addShoppingItems(items: items))
            default: throw Invalid.arguments
            }
        } catch {
            return .appendBlock(.error(.init(id: context.blockID, message: "无法识别这次操作，没有改动。", retry: .interpretation)))
        }
    }

    private func recipe(_ value: JSONAnyValue?, path: String, context: AIConversationInterpretationContext) throws -> AIRecipeBlock {
        guard let value else { throw Invalid.arguments }
        let args = try object(value, allowed: ["recipeID", "title", "ingredients", "steps", "reason"])
        let title = try string(args, "title")
        let recipeID = try optionalString(args, "recipeID")
        let reason = try optionalString(args, "reason")
        let ingredients: [String]?
        if args["ingredients"] != nil {
            ingredients = try array(args, "ingredients", nonempty: true).map { value in
                let item = try object(value, allowed: ["item", "qty", "unit"])
                return try [string(item, "item"), optionalString(item, "qty"), optionalString(item, "unit")]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            }
        } else { ingredients = nil }
        let steps: [String]?
        if args["steps"] != nil {
            steps = try array(args, "steps", nonempty: true).map { value in
                guard case .string(let step) = value, !step.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Invalid.arguments }
                return step
            }
        } else { steps = nil }
        // Server has no isTransient field. A nonempty recipeID references a
        // caller-resolved canonical snapshot; otherwise explicit caller identity
        // authorizes a transient whose entire content is decoded here.
        if let recipeID, !recipeID.isEmpty {
            guard var resolved = context.recipesByPath[path], !resolved.isTransient,
                  context.transientIdentitiesByPath[path] == nil,
                  resolved.recipe.id == recipeID, resolved.recipe.title == title,
                  !resolved.recipe.ingredients.isEmpty, !resolved.recipe.steps.isEmpty,
                  (resolved.recipe.ingredients + resolved.recipe.seasonings + resolved.recipe.steps)
                    .allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw Invalid.arguments }
            if let ingredients {
                guard ingredients == resolved.recipe.ingredients + resolved.recipe.seasonings else { throw Invalid.arguments }
            }
            if let steps { guard steps == resolved.recipe.steps else { throw Invalid.arguments } }
            resolved.reason = reason
            return resolved
        }
        guard context.recipesByPath[path] == nil,
              let identity = context.transientIdentitiesByPath[path],
              !identity.recipeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let ingredients, let steps else { throw Invalid.arguments }
        let snapshot = Recipe(id: identity.recipeID, title: title, cookingTime: nil, difficulty: nil,
            tags: [], ingredients: ingredients, steps: steps)
        guard !snapshot.ingredients.isEmpty, snapshot.steps.count == steps.count,
              snapshot.ingredients.count + snapshot.seasonings.count == ingredients.count else { throw Invalid.arguments }
        return AIRecipeBlock(id: identity.blockID, recipe: snapshot, isTransient: true, reason: reason)
    }

    private func object(_ value: JSONAnyValue, allowed: Set<String>) throws -> [String: JSONAnyValue] {
        guard case .object(let fields) = value, Set(fields.keys).isSubset(of: allowed) else { throw Invalid.arguments }
        return fields
    }
    private func string(_ fields: [String: JSONAnyValue], _ key: String, allowEmpty: Bool = false) throws -> String {
        guard case .string(let value) = fields[key], allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Invalid.arguments }
        return value
    }
    private func optionalString(_ fields: [String: JSONAnyValue], _ key: String) throws -> String? {
        guard fields[key] != nil else { return nil }
        return try string(fields, key, allowEmpty: true)
    }
    private func array(_ fields: [String: JSONAnyValue], _ key: String, nonempty: Bool = false) throws -> [JSONAnyValue] {
        guard case .array(let values) = fields[key], !nonempty || !values.isEmpty else { throw Invalid.arguments }
        return values
    }
    private func uuid(_ fields: [String: JSONAnyValue], _ key: String) throws -> UUID {
        let raw = try string(fields, key)
        guard let id = UUID(uuidString: raw), raw.count == 36 else { throw Invalid.arguments }
        return id
    }
    private func date(_ raw: String, calendar: Calendar) throws -> Date {
        guard raw.count == 10, raw.utf8.count == 10 else { throw Invalid.arguments }
        let pieces = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              pieces.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let year = Int(pieces[0]), year > 0, let month = Int(pieces[1]), let day = Int(pieces[2]),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { throw Invalid.arguments }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard components.year == year, components.month == month, components.day == day else { throw Invalid.arguments }
        return date
    }
}

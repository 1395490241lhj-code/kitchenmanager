import Foundation

// MARK: - Conversation domain tools
//
// The finite surface a conversation is allowed to reach the kitchen through.
//
// Two rules give this file its shape. It owns no kitchen state — it holds
// references to `KitchenStore` and `RecipeStore` and answers every question from
// them at the moment it is asked, because a conversation that remembered an
// inventory reading would eventually recommend cooking something already eaten.
// And the surface is closed: five approved mutations and nothing else, so a
// capability the model merely asks for does not exist.
//
// What is deliberately *not* here: prompts. These reads return small values, not
// sentences. Serialization, budgeting and exclusion belong to the context
// assembler, which is also where a token budget can be reasoned about — a
// formatter hidden in the domain adapter would put that decision in the one
// place nobody looks for it.
//
// Nothing here names a provider, a transport or a wire format. A future
// on-device runtime uses these same values unchanged.

// MARK: - Read context values

/// One inventory row, reduced to what a turn can actually use.
///
/// The two flags are carried rather than flattened away: a staple is stocked
/// rather than dated, and ready-to-cook food is already a dish. An assistant
/// that could not tell them apart would happily propose cooking with a finished
/// meal, or warn that the soy sauce is expiring.
nonisolated struct AIInventoryItemContext: Codable, Equatable, Sendable {
    var name: String
    var quantity: Double
    var unit: String
    var isStaple: Bool
    var isReadyToCook: Bool
    /// Days until expiry, or `nil` when this row is not date-tracked at all.
    var remainingDays: Int?
}

nonisolated struct AIInventoryContext: Codable, Equatable, Sendable {
    /// When this read happened. Provenance for the turn, never a licence to
    /// reuse the payload on a later one.
    var readAt: Date
    /// Everything currently on hand.
    var available: [AIInventoryItemContext]
    /// The expiring subset, as the app itself defines expiring.
    var expiring: [AIInventoryItemContext]
}

/// One ordinary planned meal. `planID` is the canonical `MealPlanItem.id`, which
/// is what a later mutation names — a dish title never is.
nonisolated struct AIPlannedMealContext: Codable, Equatable, Sendable {
    var planID: UUID
    var recipeID: String
    var recipeName: String
    var date: Date
    var plannedServings: Int?
    var isCooked: Bool
}

nonisolated struct AITonightPlanContext: Codable, Equatable, Sendable {
    var readAt: Date
    /// The civil day this answers for, so a caller can tell an empty evening
    /// from a read of the wrong day.
    var day: Date
    var meals: [AIPlannedMealContext]
}

/// A Special Plan as it appears in a week listing. The menu itself is a separate
/// read: a week overview that inlined every dish would spend the turn's budget
/// on an event nobody asked about.
nonisolated struct AISpecialPlanSummaryContext: Codable, Equatable, Sendable {
    var planID: UUID
    var title: String
    var scheduledAt: Date
    var peopleCount: Int
    var dishCount: Int
}

nonisolated struct AIPlannerWeekContext: Codable, Equatable, Sendable {
    var readAt: Date
    var weekStart: Date
    /// Exclusive. The first instant that is no longer this week.
    var weekEnd: Date
    var meals: [AIPlannedMealContext]
    var specialPlans: [AISpecialPlanSummaryContext]
}

nonisolated struct AISpecialPlanDishContext: Codable, Equatable, Sendable {
    var dishID: UUID
    var recipeID: String
    var recipeName: String
    var isCooked: Bool
}

nonisolated struct AISpecialPlanContext: Codable, Equatable, Sendable {
    var readAt: Date
    var planID: UUID
    var title: String
    var scheduledAt: Date
    var peopleCount: Int
    var constraintNotes: [String]
    var notes: String
    /// Whether this meal is cooked from the home kitchen. Carried because it
    /// decides whether the home refrigerator is relevant to the event at all.
    var usesHomeInventory: Bool
    var dishes: [AISpecialPlanDishContext]
}

// MARK: - Tooling surface

/// Why a domain tool refused, in terms a user can be told the truth in.
///
/// Each case answers a different question, which is the point: "that dish is
/// gone" and "that event is gone" lead somewhere different, and a single
/// generic failure would invite a retry that can never succeed.
nonisolated enum AIDomainToolError: LocalizedError, Equatable {
    /// Nothing to do. A batch is a deliberate act, so an empty one is a caller
    /// mistake rather than a vacuous success.
    case emptyRequest
    case duplicateTargets([UUID])
    /// Ordinary plan rows current state does not hold.
    case planNotFound([UUID])
    /// The event itself is gone.
    case specialPlanNotFound(UUID)
    /// The event is there; these dishes are not.
    case dishNotFound([UUID])
    /// Rows a non-undone consumption record already covers. Not retryable:
    /// the meal was cooked and deducted, so it cannot be re-dished.
    case consumedPlans([UUID])
    case unnamedShoppingItem
    /// A quantity of nothing, or one that is not a number. Refused rather than
    /// coerced: the list's merge would silently turn both into 1.
    case invalidShoppingQuantity
    case recipeSaveFailed(title: String)
    /// The write was refused by storage. Nothing was published, so retrying the
    /// same request is the right answer.
    case persistenceFailed
    /// Undo found nothing to restore, because the row or event it describes is
    /// no longer there.
    case undoTargetMissing

    var errorDescription: String? {
        switch self {
        case .emptyRequest:
            return "没有需要修改的内容。"
        case .duplicateTargets:
            return "同一项被重复修改了，请重新确认后再试。"
        case .planNotFound:
            return "这顿饭已不在计划里，没有改动。"
        case .specialPlanNotFound:
            return "这个聚餐计划已不存在，没有改动。"
        case .dishNotFound:
            return "这道菜已不在菜单里，没有改动。"
        case .consumedPlans:
            return "这顿饭已经做过并扣过库存，不能再换菜了。"
        case .unnamedShoppingItem:
            return "有一项没有名称，购物清单未修改。"
        case .invalidShoppingQuantity:
            return "有一项的数量无效，购物清单未修改。"
        case .recipeSaveFailed(let title):
            return "保存「\(title)」失败，没有改动，请稍后重试。"
        case .persistenceFailed:
            return "保存失败，没有改动，请稍后重试。"
        case .undoTargetMissing:
            return "要撤销的内容已经不在了，没有改动。"
        }
    }
}

/// The bounded domain surface a conversation may use.
///
/// A protocol rather than a concrete type because the layers above it — context
/// assembly, the action coordinator — have to be testable without a live
/// kitchen. It is not an extension point: adding a case here is a product
/// decision with its own risk classification, not a runtime payload.
@MainActor
protocol AIConversationDomainTooling {
    /// The civil-day calendar this tooling reads and writes days with.
    ///
    /// Named on the protocol so a caller cannot ask about one calendar while the
    /// writes land in another. The `calendar:` overloads below exist for a
    /// caller genuinely asking about a different one; the convenience forms are
    /// the ordinary path and cannot disagree with a write.
    var calendar: Calendar { get }

    func inventoryContext(now: Date) -> AIInventoryContext
    func tonightPlanContext(now: Date, calendar: Calendar) -> AITonightPlanContext
    func plannerWeekContext(weekStart: Date, calendar: Calendar) -> AIPlannerWeekContext
    func specialPlanContext(id: UUID) -> AISpecialPlanContext?
    /// A supplied nonempty canonical ID wins; otherwise resolve one exact local title.
    func resolveRecipe(query: String, recipeID: String?) -> Recipe?

    func addRecipeToTonight(_ block: AIRecipeBlock, now: Date) throws -> AIDomainMutationReceipt
    func replacePlannedMeals(_ changes: [AIPlannerMealChange]) throws -> AIDomainMutationReceipt
    func replaceSpecialPlanDishes(planID: UUID, changes: [AISpecialPlanDishChange]) throws -> AIDomainMutationReceipt
    func addShoppingItems(_ items: [AIShoppingItemProposal]) throws -> AIDomainMutationReceipt
    func undo(_ receipt: AIDomainMutationReceipt) throws
}

extension AIConversationDomainTooling {
    func tonightPlanContext(now: Date) -> AITonightPlanContext {
        tonightPlanContext(now: now, calendar: calendar)
    }

    func plannerWeekContext(weekStart: Date) -> AIPlannerWeekContext {
        plannerWeekContext(weekStart: weekStart, calendar: calendar)
    }
}

// MARK: - Live implementation

/// The live adapter over the real stores.
///
/// Holds references, never copies. Every read below goes to the store on the
/// call, which is the property the conversation layer depends on and the reason
/// this type has no stored kitchen state of its own to go stale.
@MainActor
final class KitchenConversationDomainTools: AIConversationDomainTooling {
    private let kitchenStore: KitchenStore
    private let recipeStore: RecipeStore
    /// The civil-day calendar every write here normalizes with, and the one the
    /// reads use when they are not asked about another. One owner, so a plan
    /// written for tonight cannot land on a day the default read does not look at.
    let calendar: Calendar

    init(kitchenStore: KitchenStore, recipeStore: RecipeStore, calendar: Calendar = .current) {
        self.kitchenStore = kitchenStore
        self.recipeStore = recipeStore
        self.calendar = calendar
    }

    // MARK: Reads

    /// `now` stamps the read. It deliberately does not redefine expiry:
    /// `InventoryItem.expiryStatus` is the single owner of what "expiring" means,
    /// and a second threshold implemented here would drift from the one the user
    /// sees on the Inventory screen.
    func inventoryContext(now: Date) -> AIInventoryContext {
        AIInventoryContext(
            readAt: now,
            available: kitchenStore.availableInventory.map(Self.itemContext),
            expiring: kitchenStore.expiringItems.map(Self.itemContext)
        )
    }

    /// Today's ordinary schedule only.
    ///
    /// A Special Plan is not a meal slot. Its `scheduledAt` says when an event
    /// starts, not that it is tonight's dinner, and reading one into this answer
    /// is the inference the Home contract explicitly forbids.
    func tonightPlanContext(now: Date, calendar: Calendar) -> AITonightPlanContext {
        AITonightPlanContext(
            readAt: now,
            day: calendar.startOfDay(for: now),
            meals: kitchenStore.plans
                .filter { calendar.isDate($0.date, inSameDayAs: now) }
                .map(Self.mealContext)
        )
    }

    /// The canonical week: `KitchenStore.plans`, plus the events that fall in it.
    ///
    /// Never `weeklyPlan`, which is draft and receipt state for materialization
    /// rather than the schedule the rest of the app cooks from.
    func plannerWeekContext(weekStart: Date, calendar: Calendar) -> AIPlannerWeekContext {
        let start = calendar.startOfDay(for: weekStart)
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        let range = start..<end

        return AIPlannerWeekContext(
            readAt: Date(),
            weekStart: start,
            weekEnd: end,
            meals: kitchenStore.plans
                .filter { range.contains($0.date) }
                .map(Self.mealContext),
            specialPlans: kitchenStore.specialPlans
                .filter { range.contains($0.scheduledAt) }
                .map {
                    AISpecialPlanSummaryContext(
                        planID: $0.id,
                        title: $0.title,
                        scheduledAt: $0.scheduledAt,
                        peopleCount: $0.peopleCount,
                        dishCount: $0.dishes.count
                    )
                }
        )
    }

    /// The event as it stands now, or nil. An event that is gone is nil rather
    /// than an empty plan: those mean different things to whoever answers next.
    func specialPlanContext(id: UUID) -> AISpecialPlanContext? {
        guard let plan = kitchenStore.specialPlans.first(where: { $0.id == id }) else { return nil }
        return AISpecialPlanContext(
            readAt: Date(),
            planID: plan.id,
            title: plan.title,
            scheduledAt: plan.scheduledAt,
            peopleCount: plan.peopleCount,
            constraintNotes: plan.constraintNotes,
            notes: plan.notes,
            usesHomeInventory: plan.usesHomeInventory,
            dishes: plan.dishes.map {
                AISpecialPlanDishContext(
                    dishID: $0.id,
                    recipeID: $0.recipeID,
                    recipeName: $0.recipeName,
                    isCooked: $0.isCooked
                )
            }
        )
    }

    /// Read the current canonical library; never fetch, rank or guess a recipe.
    /// IDs use RecipeStore's existing lookup unchanged, including its fallback.
    /// Query-only reads use loaded recipes (with user overlays), not display samples.
    func resolveRecipe(query: String, recipeID: String?) -> Recipe? {
        if let recipeID, !recipeID.isEmpty { return recipeStore.recipe(id: recipeID) }
        // Unicode canonical equivalence, locale-independent case, and collapsed
        // whitespace only. Accents, punctuation and word order remain significant.
        func normalizedTitle(_ title: String) -> String {
            title.precomposedStringWithCanonicalMapping.lowercased()
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let title = normalizedTitle(query)
        guard !title.isEmpty else { return nil }
        let matches = recipeStore.recipes.filter { normalizedTitle($0.title) == title }
        return matches.count == 1 ? matches.first : nil
    }

    // MARK: Mutations

    /// The source every conversation-added shopping row carries.
    ///
    /// A stable product string, not a model-authored label and not a provider
    /// name: the list groups by this, and a source that changed with the routed
    /// provider would split one origin into several.
    static let shoppingSource = "Kitchen AI"

    /// Adds one resolved recipe to today's ordinary schedule.
    ///
    /// Order is the whole safety property. The recipe is made real first, so the
    /// plan only ever stores an id that already exists; then the plan is written
    /// durably; and if that write is refused, the recipes *this call* created are
    /// removed again, because a recipe nothing references is litter the user
    /// never asked for.
    ///
    /// The receipt names only ids this call created. A reused recipe is never in
    /// it — an Undo that deleted one would destroy a recipe the user already had.
    func addRecipeToTonight(_ block: AIRecipeBlock, now: Date) throws -> AIDomainMutationReceipt {
        let batch = try materialize([block])
        guard let recipe = batch.recipes.first else { throw AIDomainToolError.emptyRequest }

        // Deliberately no `plannedServings`: nobody stated a target, and the
        // recipe's own base yield is a different number. Guessing one here would
        // feed a fabricated denominator into every quantity derived from it.
        switch kitchenStore.addPlan(recipe: recipe, on: now, plannedServings: nil, calendar: calendar) {
        case .saved(let plan):
            return .tonightPlan(plan: plan, createdRecipeIDs: batch.createdRecipeIDs)
        case .persistenceFailed, .notFound:
            // `.notFound` is unreachable — an append has no target to miss. Mapped
            // to the retryable failure rather than trapped, and it still
            // compensates, which is the part that matters.
            GeneratedRecipeMaterializer.rollbackCreatedRecipes(batch.createdRecipeIDs, recipeStore: recipeStore)
            throw AIDomainToolError.persistenceFailed
        }
    }

    /// Restates which dish a set of ordinary plan rows refers to.
    ///
    /// Covers both the single replacement and the batch: one row or ten, it is
    /// the same durable write with the same all-or-none guarantee.
    ///
    /// Refusals current state can already determine are made *before* anything
    /// is materialized, so a stale request costs the recipe library nothing.
    func replacePlannedMeals(_ changes: [AIPlannerMealChange]) throws -> AIDomainMutationReceipt {
        try preflightPlanTargets(changes.map(\.planID))

        let before = changes.compactMap { change in
            kitchenStore.plans.first { $0.id == change.planID }
        }
        let batch = try materialize(changes.map(\.replacement))
        let replacements = zip(changes, batch.recipes).map { change, recipe in
            PlanRecipeReplacement(
                planID: change.planID,
                recipeID: recipe.id,
                recipeName: recipe.title,
                // A serving target the user chose for that slot is theirs. The
                // model restating the dish without restating the number is not a
                // request to forget it.
                plannedServings: change.plannedServings
                    ?? kitchenStore.plans.first { $0.id == change.planID }?.plannedServings
            )
        }

        switch kitchenStore.replacePlanRecipes(replacements) {
        case .saved(let after):
            return .plannerReplacement(before: before, after: after, createdRecipeIDs: batch.createdRecipeIDs)
        case .rejected(let reason):
            // Reachable despite the preflight: state can move between that read
            // and this write. Kept whole.
            GeneratedRecipeMaterializer.rollbackCreatedRecipes(batch.createdRecipeIDs, recipeStore: recipeStore)
            switch reason {
            case .empty: throw AIDomainToolError.emptyRequest
            case .duplicateTargets(let ids): throw AIDomainToolError.duplicateTargets(ids)
            case .missingTargets(let ids): throw AIDomainToolError.planNotFound(ids)
            case .consumedTargets(let ids): throw AIDomainToolError.consumedPlans(ids)
            }
        case .persistenceFailed:
            GeneratedRecipeMaterializer.rollbackCreatedRecipes(batch.createdRecipeIDs, recipeStore: recipeStore)
            throw AIDomainToolError.persistenceFailed
        }
    }

    /// Restates which recipe named dishes of one event point at.
    ///
    /// The store answers `.notFound` for a missing event and a missing dish
    /// alike, so both are resolved against live state here first. The user needs
    /// to hear that the gathering is gone, or that one dish is — those are not
    /// the same news.
    ///
    /// A dish named twice is refused here too, for the same reason the Planner
    /// path refuses one: the store would reject it anyway, and finding that out
    /// after materialization costs a recipe write nobody asked for.
    func replaceSpecialPlanDishes(
        planID: UUID,
        changes: [AISpecialPlanDishChange]
    ) throws -> AIDomainMutationReceipt {
        guard !changes.isEmpty else { throw AIDomainToolError.emptyRequest }
        guard let before = kitchenStore.specialPlans.first(where: { $0.id == planID }) else {
            throw AIDomainToolError.specialPlanNotFound(planID)
        }
        let repeated = Self.repeatedIDs(changes.map(\.dishID))
        guard repeated.isEmpty else { throw AIDomainToolError.duplicateTargets(repeated) }
        let present = Set(before.dishes.map(\.id))
        var missing: [UUID] = []
        for id in changes.map(\.dishID) where !present.contains(id) && !missing.contains(id) {
            missing.append(id)
        }
        guard missing.isEmpty else { throw AIDomainToolError.dishNotFound(missing) }

        let batch = try materialize(changes.map(\.replacement))
        let replacements = zip(changes, batch.recipes).map { change, recipe in
            SpecialPlanDishReplacement(dishID: change.dishID, recipeID: recipe.id, recipeName: recipe.title)
        }

        switch kitchenStore.replaceSpecialPlanDishes(planID: planID, replacements: replacements) {
        case .saved(let after):
            return .specialPlanMenu(before: before, after: after, createdRecipeIDs: batch.createdRecipeIDs)
        case .notFound:
            // The event was resolved a moment ago, so this is the event going
            // away underneath the write rather than the ambiguity above.
            GeneratedRecipeMaterializer.rollbackCreatedRecipes(batch.createdRecipeIDs, recipeStore: recipeStore)
            throw AIDomainToolError.specialPlanNotFound(planID)
        case .rejected(let reason):
            GeneratedRecipeMaterializer.rollbackCreatedRecipes(batch.createdRecipeIDs, recipeStore: recipeStore)
            switch reason {
            case .empty: throw AIDomainToolError.emptyRequest
            case .duplicateTargets(let ids): throw AIDomainToolError.duplicateTargets(ids)
            }
        case .persistenceFailed:
            GeneratedRecipeMaterializer.rollbackCreatedRecipes(batch.createdRecipeIDs, recipeStore: recipeStore)
            throw AIDomainToolError.persistenceFailed
        }
    }

    /// Adds a validated small set of rows to the shopping list.
    ///
    /// The merge is the app's existing one, so a pending row with a matching
    /// name and a compatible unit absorbs the addition instead of becoming a
    /// second line. A row with no name is refused rather than dropped silently:
    /// the merge would discard it, and the receipt would then claim a success
    /// covering nothing.
    func addShoppingItems(_ items: [AIShoppingItemProposal]) throws -> AIDomainMutationReceipt {
        guard !items.isEmpty else { throw AIDomainToolError.emptyRequest }
        guard items.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw AIDomainToolError.unnamedShoppingItem
        }
        guard items.allSatisfy({ $0.quantity.isFinite && $0.quantity > 0 }) else {
            throw AIDomainToolError.invalidShoppingQuantity
        }

        let additions = items.map {
            KitchenShoppingItem(
                name: $0.name,
                quantity: $0.quantity,
                unit: $0.unit,
                source: Self.shoppingSource,
                remark: $0.remark
            )
        }

        switch kitchenStore.addShoppingItemsPersisted(additions) {
        case .saved(let receipt):
            return .shoppingAdditions(before: receipt.before, after: receipt.after)
        case .rejected:
            // Unreachable: the only rejection is an empty batch, guarded above.
            throw AIDomainToolError.emptyRequest
        case .notFound:
            // Unreachable: an addition has no target to miss.
            throw AIDomainToolError.persistenceFailed
        case .persistenceFailed:
            throw AIDomainToolError.persistenceFailed
        }
    }

    /// Reverses exactly what a receipt describes, and nothing else.
    ///
    /// **This seam is deliberately policy-free, and must never be called
    /// directly by UI or by model-driven code.** It does not check freshness: it
    /// writes the receipt's `before` back, and for Special Plan and Shopping that
    /// is a whole-object restore, so calling it after the user edited the event
    /// or the list would discard that edit rather than undo the action.
    ///
    /// `ConversationActionCoordinator` owns that policy and is the only
    /// legitimate caller. Before restoring, it must verify that current
    /// canonical state still matches the receipt's post-state — Planner compares
    /// the affected current plan rows against `after`, Special Plan compares the
    /// current event against `after`, Shopping compares the current list against
    /// `after` — and when state diverged, refuse with a truthful,
    /// non-destructive answer instead of restoring.
    ///
    /// What this seam does guarantee: it never reports a reversal that did not
    /// happen, and it never deletes a recipe some current plan or event still
    /// references.
    func undo(_ receipt: AIDomainMutationReceipt) throws {
        switch receipt {
        case let .tonightPlan(plan, createdRecipeIDs):
            try requireRestored(kitchenStore.removePlan(id: plan.id))
            compensateCreatedRecipes(createdRecipeIDs)
        case let .plannerReplacement(before, _, createdRecipeIDs):
            try requireRestored(kitchenStore.restorePlanItems(before))
            compensateCreatedRecipes(createdRecipeIDs)
        case let .specialPlanMenu(before, _, createdRecipeIDs):
            try requireRestored(kitchenStore.restoreSpecialPlan(before))
            compensateCreatedRecipes(createdRecipeIDs)
        case let .shoppingAdditions(before, _):
            try requireRestored(kitchenStore.restoreShoppingItems(before))
        }
    }

    // MARK: Shared mutation helpers

    /// Refuses a Planner batch current state already answers, before a single
    /// recipe is written.
    ///
    /// **This does not replace `KitchenStore.replacePlanRecipes`' own checks and
    /// must never be "deduplicated" with them.** The store's copy is the
    /// guarantee: it validates against the state it is about to write, so it
    /// still catches a row that was deleted or consumed between this read and
    /// that write. This copy is only an optimization, and it buys one specific
    /// thing — a determinable refusal performs zero canonical recipe writes,
    /// instead of creating generated recipes and compensating them afterwards.
    /// That compensation can itself fail, and an orphan recipe in the user's
    /// library is a visible consequence of a request that was never valid.
    ///
    /// Order follows the store's: an id named twice describes no single
    /// outcome, an id that is not there cannot be consumed, and consumption is
    /// the last thing that can refuse a row that does exist.
    private func preflightPlanTargets(_ ids: [UUID]) throws {
        guard !ids.isEmpty else { throw AIDomainToolError.emptyRequest }

        let repeated = Self.repeatedIDs(ids)
        guard repeated.isEmpty else { throw AIDomainToolError.duplicateTargets(repeated) }

        let missing = ids.filter { id in !kitchenStore.plans.contains { $0.id == id } }
        guard missing.isEmpty else { throw AIDomainToolError.planNotFound(missing) }

        // R17: a row a non-undone consumption record already covers was cooked
        // and deducted, so it cannot be re-dished at all.
        let consumed = ids.filter { kitchenStore.hasConsumedPlan($0) }
        guard consumed.isEmpty else { throw AIDomainToolError.consumedPlans(consumed) }
    }

    /// The ids that appear more than once, each named once, in the order they
    /// first repeat — the same answer the store's own duplicate check gives.
    private static func repeatedIDs(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        var repeated: [UUID] = []
        for id in ids where !seen.insert(id).inserted {
            if !repeated.contains(id) { repeated.append(id) }
        }
        return repeated
    }

    /// Resolves every block to a real recipe, or leaves the library untouched.
    ///
    /// A non-transient block names a library recipe, so its id is offered for
    /// reuse. A transient one carries a model-authored id that means nothing to
    /// the library, so it is not offered: pointing at whatever happened to share
    /// that id would silently plan a different dish.
    private func materialize(_ blocks: [AIRecipeBlock]) throws -> MaterializedRecipeBatch {
        do {
            return try GeneratedRecipeMaterializer.materialize(
                blocks.map {
                    GeneratedRecipeCandidate(
                        existingRecipeID: $0.isTransient ? nil : $0.recipe.id,
                        recipe: $0.recipe
                    )
                },
                recipeStore: recipeStore
            )
        } catch GeneratedRecipeMaterializerError.saveFailed(let title) {
            throw AIDomainToolError.recipeSaveFailed(title: title)
        } catch {
            throw AIDomainToolError.recipeSaveFailed(title: blocks.first?.recipe.title ?? "")
        }
    }

    /// Deletes recipes this action created, and only while nothing still cooks
    /// them.
    ///
    /// Both current references are checked live, at undo time: an ordinary plan
    /// row and a Special Plan dish are equally good reasons to keep a recipe.
    /// Best effort by design — the reversal already happened, so a failed delete
    /// must not be reported as a failed Undo.
    private func compensateCreatedRecipes(_ ids: [String]) {
        for id in ids where !isReferencedByCurrentPlans(id) {
            try? recipeStore.deleteUserRecipe(id: id)
        }
    }

    private func isReferencedByCurrentPlans(_ recipeID: String) -> Bool {
        kitchenStore.plans.contains { $0.recipeID == recipeID }
            || kitchenStore.specialPlans.contains { plan in
                plan.dishes.contains { $0.recipeID == recipeID }
            }
    }

    private func requireRestored<Value>(_ outcome: PlanMutationOutcome<Value>) throws {
        switch outcome {
        case .saved: return
        case .notFound: throw AIDomainToolError.undoTargetMissing
        case .persistenceFailed: throw AIDomainToolError.persistenceFailed
        }
    }

    private func requireRestored<Value>(_ outcome: DomainMutationOutcome<Value>) throws {
        switch outcome {
        case .saved: return
        case .notFound: throw AIDomainToolError.undoTargetMissing
        // Unreachable: no restore seam rejects. Mapped to the retryable failure
        // rather than trapped, and never to a false success.
        case .rejected, .persistenceFailed: throw AIDomainToolError.persistenceFailed
        }
    }

    // MARK: Projections

    private static func itemContext(_ item: InventoryItem) -> AIInventoryItemContext {
        AIInventoryItemContext(
            name: item.name,
            quantity: item.quantity,
            unit: item.unit,
            isStaple: item.kind == .staple,
            isReadyToCook: item.kind == .readyToCook,
            remainingDays: item.remainingDays
        )
    }

    private static func mealContext(_ item: MealPlanItem) -> AIPlannedMealContext {
        AIPlannedMealContext(
            planID: item.id,
            recipeID: item.recipeID,
            recipeName: item.recipeName,
            date: item.date,
            plannedServings: item.plannedServings,
            isCooked: item.isCooked
        )
    }
}

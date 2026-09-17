import XCTest
import SwiftData
@testable import KitchenManager

@MainActor
final class ConversationActionCoordinatorTests: XCTestCase {
    private final class Persistence: ConversationPersistenceProtocol {
        var rows: [UUID: AIConversationActionRecord] = [:]
        var transitions: [AIActionStatus] = []
        var refuse: Set<AIActionStatus> = []
        func loadConversations() throws -> [AIConversation] { [] }
        func loadMessages(conversationID: UUID) throws -> [AIConversationMessage] { [] }
        func loadActions(conversationID: UUID) throws -> [AIConversationActionRecord] {
            rows.values.filter { $0.conversationID == conversationID }.sorted {
                $0.createdAt == $1.createdAt ? $0.actionID.uuidString > $1.actionID.uuidString : $0.createdAt > $1.createdAt
            }
        }
        func action(id: UUID) throws -> AIConversationActionRecord? { rows[id] }
        func action(idempotencyKey: String) throws -> AIConversationActionRecord? {
            let sorted = rows.values.filter { $0.idempotencyKey == idempotencyKey }.sorted {
                $0.createdAt == $1.createdAt ? $0.actionID.uuidString > $1.actionID.uuidString : $0.createdAt > $1.createdAt
            }
            return sorted.first { $0.status == .succeeded || $0.status == .undone } ?? sorted.first
        }
        func upsertAction(_ action: AIConversationActionRecord) throws {
            if refuse.contains(action.status) { throw AIActionExecutionError.storage }
            rows[action.id] = action; transitions.append(action.status)
        }
        func createConversationWithFirstMessage(_ conversation: AIConversation, message: AIConversationMessage) throws {}
        func upsertConversation(_ conversation: AIConversation) throws {}
        func upsertMessage(_ message: AIConversationMessage) throws {}
        func upsertContextSnapshot(_ snapshot: AIContextSnapshot, conversationID: UUID) throws {}
        func deleteConversation(id: UUID) throws {}
        func deleteAll() throws {}
        func recoverInterruptedMessages(now: Date) throws -> Int { 0 }
    }

    private final class Domain: AIConversationDomainTooling {
        let live: KitchenConversationDomainTools
        var writes = 0
        var undos = 0
        var failure: AIDomainToolError?
        var undoFailure = false
        var beforeWrite: (() -> Void)?
        var beforeUndo: (() -> Void)?
        init(_ kitchen: KitchenStore, _ recipes: RecipeStore) {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            live = KitchenConversationDomainTools(kitchenStore: kitchen, recipeStore: recipes, calendar: calendar)
        }
        var calendar: Calendar { live.calendar }
        func inventoryContext(now: Date) -> AIInventoryContext { live.inventoryContext(now: now) }
        func tonightPlanContext(now: Date, calendar: Calendar) -> AITonightPlanContext { live.tonightPlanContext(now: now, calendar: calendar) }
        func plannerWeekContext(weekStart: Date, calendar: Calendar) -> AIPlannerWeekContext { live.plannerWeekContext(weekStart: weekStart, calendar: calendar) }
        func specialPlanContext(id: UUID) -> AISpecialPlanContext? { live.specialPlanContext(id: id) }
        func resolveRecipe(query: String, recipeID: String?) -> Recipe? { live.resolveRecipe(query: query, recipeID: recipeID) }
        func plannedMeal(id: UUID) -> MealPlanItem? { live.plannedMeal(id: id) }
        func specialPlan(id: UUID) -> SpecialPlan? { live.specialPlan(id: id) }
        func mutationRecipes(_ blocks: [AIRecipeBlock]) -> [Recipe] { live.mutationRecipes(blocks) }
        func currentStateMatchesPostState(of receipt: AIDomainMutationReceipt) -> Bool { live.currentStateMatchesPostState(of: receipt) }
        func isCompletelyReversed(_ receipt: AIDomainMutationReceipt) -> Bool { live.isCompletelyReversed(receipt) }
        func write() throws { writes += 1; beforeWrite?(); if let failure { throw failure } }
        func addRecipeToTonight(_ block: AIRecipeBlock, now: Date) throws -> AIDomainMutationReceipt {
            try write(); return try live.addRecipeToTonight(block, now: now)
        }
        func replacePlannedMeals(_ changes: [AIPlannerMealChange]) throws -> AIDomainMutationReceipt {
            try write(); return try live.replacePlannedMeals(changes)
        }
        func replaceSpecialPlanDishes(planID: UUID, changes: [AISpecialPlanDishChange]) throws -> AIDomainMutationReceipt {
            try write(); return try live.replaceSpecialPlanDishes(planID: planID, changes: changes)
        }
        func addShoppingItems(_ items: [AIShoppingItemProposal]) throws -> AIDomainMutationReceipt {
            try write(); return try live.addShoppingItems(items)
        }
        func undo(_ receipt: AIDomainMutationReceipt) throws {
            undos += 1; beforeUndo?()
            if undoFailure { throw AIDomainToolError.persistenceFailed }
            try live.undo(receipt)
        }
    }

    private final class RecipePersistence: UserRecipePersistenceProtocol {
        var recipes: [Recipe] = []
        var refuse = false
        func loadRecipes() throws -> [Recipe] { recipes }
        func storedRecordCount() throws -> Int { recipes.count }
        func replaceRecipes(with recipes: [Recipe]) throws {
            if refuse { throw AIActionExecutionError.storage }
            self.recipes = recipes
        }
        func deleteAll() throws { recipes = [] }
    }

    @MainActor
    private final class Fixture {
        let p = Persistence()
        let kitchen = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let recipes: RecipeStore
        init(recipePersistence: (any UserRecipePersistenceProtocol)? = nil) {
            recipes = RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
                userRecipePersistence: recipePersistence,
                recipePreferencePersistence: recipePersistence == nil ? nil : KitchenPersistenceFactory.isolatedInMemory().recipePreferences)
        }
        lazy var domain = Domain(kitchen, recipes)
        let conversation = UUID()
        // A fixture represents one logical turn; retries and payload comparisons keep it.
        let turn = UUID()
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        lazy var c = coordinator()
        func coordinator(persistence: (any ConversationPersistenceProtocol)? = nil) -> ConversationActionCoordinator {
            ConversationActionCoordinator(domainTools: domain, persistence: persistence ?? p,
                now: { self.time }, undoExpiresAt: { $0.addingTimeInterval(60) })
        }
        func prepare(_ proposal: AIActionProposal) throws -> PreparedAIAction {
            try c.prepare(proposal, conversationID: conversation, turnID: turn)
        }
        func plan(_ title: String = "原来的菜") -> MealPlanItem {
            let row = MealPlanItem(recipeID: "old", recipeName: title, date: time, plannedServings: 3, isCooked: true)
            _ = kitchen.appendPlans([row], calendar: domain.calendar)
            return kitchen.plans.first { $0.id == row.id }!
        }
        func event() -> SpecialPlan {
            let event = SpecialPlan(title: "聚餐", scheduledAt: time, dishes: [
                .init(recipeID: "old-a", recipeName: "原菜一", isCooked: true),
                .init(recipeID: "old-b", recipeName: "原菜二")])
            kitchen.addSpecialPlan(event)
            return kitchen.specialPlans.first { $0.id == event.id }!
        }
    }
    private func recipe(_ id: String = "new", title: String = "新菜", source: RecipeSourceMetadata? = nil) -> Recipe {
        Recipe(id: id, title: title, cookingTime: 12, difficulty: "简单", tags: ["家常"],
               ingredients: ["鸡蛋 2 个"], seasonings: ["盐 少许"], steps: ["炒熟"], baseServings: 2, source: source)
    }
    private func block(_ transient: Bool = false, id: String = "new", title: String = "新菜") -> AIRecipeBlock {
        AIRecipeBlock(recipe: recipe(id, title: title), isTransient: transient)
    }
    private func tonight(_ transient: Bool = false) -> AIActionProposal { .addRecipeToTonight(recipe: block(transient)) }
    private func shopping(_ count: Int = 1) -> AIActionProposal {
        .addShoppingItems(items: (0..<count).map { .init(name: "鸡蛋\($0)", quantity: 2, unit: "个", remark: "备注") })
    }
    private func preview(_ action: PreparedAIAction) throws -> AIPlannerPreviewBlock {
        guard case let .plannerPreview(value) = action.preview else { throw AIActionExecutionError.notPrepared }
        return value
    }
    private func expect(_ error: AIActionExecutionError, _ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { XCTAssertEqual($0 as? AIActionExecutionError, error, file: file, line: line) }
    }

    // Risk / truthful diff. Every assertion uses the real store adapter.
    func testCanonicalTonightIsLowWithoutPreview() throws {
        let f = Fixture(); let a = try f.prepare(tonight()); XCTAssertEqual(a.risk, .low); XCTAssertNil(a.preview)
    }
    func testTransientTonightIsLowWithoutPreview() throws {
        let f = Fixture(); let a = try f.prepare(tonight(true)); XCTAssertEqual(a.risk, .low); XCTAssertNil(a.preview)
    }
    func testOneThroughFiveShoppingItemsAreLow() throws {
        let f = Fixture()
        for n in 1...5 { let a = try f.prepare(shopping(n)); XCTAssertEqual(a.risk, .low); XCTAssertNil(a.preview) }
    }
    func testBulkShoppingIsRejectedWithoutMutation() throws {
        let f = Fixture(); expect(.unsupported) { _ = try f.prepare(shopping(6)) }; XCTAssertEqual(f.domain.writes, 0)
    }
    func testOnePlannerReplacementIsMediumAndReadsLiveBefore() throws {
        let f = Fixture(); let row = f.plan("真实旧菜")
        let a = try f.prepare(.replacePlannedMeal(planID: row.id, replacement: block()))
        XCTAssertEqual(a.risk, .medium); let diff = try preview(a)
        XCTAssertEqual(diff.changes.count, 1); XCTAssertEqual(diff.changes[0].targetID, row.id)
        XCTAssertTrue(diff.changes[0].before.contains("真实旧菜")); XCTAssertTrue(diff.changes[0].before.contains("3"))
        XCTAssertTrue(diff.changes[0].before.contains("已做")); XCTAssertTrue(diff.changes[0].after.contains("未做"))
    }
    func testPreviewUsesCanonicalRecipeRatherThanModelSnapshot() throws {
        let f = Fixture(); let row = f.plan(); try f.recipes.saveUserRecipe(recipe(title: "真实新菜"))
        let a = try f.prepare(.replacePlannedMeal(planID: row.id, replacement: block()))
        XCTAssertTrue(try preview(a).changes[0].after.contains("真实新菜"))
        _ = try f.c.execute(a); XCTAssertEqual(f.kitchen.plans[0].recipeName, "真实新菜")
    }
    func testSingleSpecialDishRequiresConfirmation() throws {
        let f = Fixture(); let event = f.event()
        let a = try f.prepare(.replaceSpecialPlanDishes(planID: event.id, changes: [.init(dishID: event.dishes[0].id, replacement: block())]))
        XCTAssertEqual(a.risk, .medium); XCTAssertEqual(try preview(a).changes.count, 1)
        XCTAssertTrue(try preview(a).changes[0].before.contains("已做"))
    }
    func testMultipleSpecialDishesAreHighWithEveryRow() throws {
        let f = Fixture(); let event = f.event()
        let a = try f.prepare(.replaceSpecialPlanDishes(planID: event.id, changes: event.dishes.map { .init(dishID: $0.id, replacement: block()) }))
        XCTAssertEqual(a.risk, .high); XCTAssertEqual(try preview(a).changes.map(\.targetID), event.dishes.map(\.id))
        XCTAssertEqual(f.kitchen.specialPlans, [event]); XCTAssertEqual(f.domain.writes, 0)
    }
    func testBulkPlannerIsHighWithEveryRowAndNoPrepareWrites() throws {
        let f = Fixture(); let rows = [f.plan(), f.plan("另一道")]
        let a = try f.prepare(.applyPlannerChanges(changes: rows.map { .init(planID: $0.id, replacement: block()) }))
        XCTAssertEqual(a.risk, .high); XCTAssertEqual(try preview(a).changes.map(\.targetID), rows.map(\.id))
        XCTAssertEqual(f.domain.writes, 0); XCTAssertEqual(f.kitchen.plans, rows)
    }
    func testSingleBatchPlannerIsMedium() throws {
        let f = Fixture(); let a = try f.prepare(.applyPlannerChanges(changes: [.init(planID: f.plan().id, replacement: block())]))
        XCTAssertEqual(a.risk, .medium)
    }
    func testPreviewPendingActionIDMatchesPreparedID() throws {
        let f = Fixture(); let a = try f.prepare(.replacePlannedMeal(planID: f.plan().id, replacement: block()))
        XCTAssertEqual(try preview(a).pendingActionID, a.id)
    }
    func testStaleAffectedPlanRefusesApply() throws {
        let f = Fixture(); var row = f.plan(); let a = try f.prepare(.replacePlannedMeal(planID: row.id, replacement: block()))
        row.plannedServings = 7; _ = f.kitchen.restorePlanItems([row])
        expect(.stale) { _ = try f.c.execute(a) }; XCTAssertEqual(f.domain.writes, 0); XCTAssertEqual(f.kitchen.plans[0], row)
    }
    func testStaleCanonicalRecipeRefusesApply() throws {
        let f = Fixture(); let row = f.plan(); try f.recipes.saveUserRecipe(recipe())
        let a = try f.prepare(.replacePlannedMeal(planID: row.id, replacement: block()))
        try f.recipes.deleteUserRecipe(id: "new"); try f.recipes.saveUserRecipe(recipe(title: "后来改过"))
        expect(.stale) { _ = try f.c.execute(a) }; XCTAssertEqual(f.domain.writes, 0)
    }
    func testTransientFingerprintTwinDriftRefusesApply() throws {
        let f = Fixture(); let a = try f.prepare(.replacePlannedMeal(planID: f.plan().id, replacement: block(true)))
        try f.recipes.saveUserRecipe(recipe("another-id"))
        expect(.stale) { _ = try f.c.execute(a) }; XCTAssertEqual(f.domain.writes, 0)
    }

    func testNewTurnAfterManualShoppingRemovalExecutesWithRealDomainTools() throws {
        let f = Fixture()
        let c = ConversationActionCoordinator(domainTools: f.domain.live, persistence: f.p,
            now: { f.time }, undoExpiresAt: { $0.addingTimeInterval(60) })
        let firstTurn = UUID(); let nextTurn = UUID(); let proposal = shopping()
        let first = try c.prepare(proposal, conversationID: f.conversation, turnID: firstTurn)
        _ = try c.execute(first)
        let item = try XCTUnwrap(f.kitchen.shoppingItems.first)
        XCTAssertEqual(item.quantity, 2)
        f.kitchen.deleteShopping(item.id)
        XCTAssertTrue(f.kitchen.shoppingItems.isEmpty)

        let next = try c.prepare(proposal, conversationID: f.conversation, turnID: nextTurn)
        XCTAssertNotEqual(first.idempotencyKey, next.idempotencyKey)
        let result = try c.execute(next)
        XCTAssertEqual(result.record.id, next.id)
        XCTAssertEqual(result.record.turnID, nextTurn)
        XCTAssertEqual(result.record.status, .succeeded)
        XCTAssertEqual(f.kitchen.shoppingItems.count, 1)
        XCTAssertEqual(f.kitchen.shoppingItems.first?.quantity, 2)
    }

    func testDifferentTurnsWithSameProposalHaveDifferentKeys() throws {
        let f = Fixture(); let proposal = shopping(); let first = try f.prepare(proposal)
        let nextTurn = UUID()
        let next = try f.c.prepare(proposal, conversationID: f.conversation, turnID: nextTurn)
        XCTAssertNotEqual(first.idempotencyKey, next.idempotencyKey)
        XCTAssertEqual(f.p.rows[first.id]?.turnID, f.turn)
        XCTAssertEqual(f.p.rows[next.id]?.turnID, nextTurn)
    }

    func testNewTurnWithExistingShoppingResultMergesAgainWithRealDomainTools() throws {
        let f = Fixture()
        let c = ConversationActionCoordinator(domainTools: f.domain.live, persistence: f.p,
            now: { f.time }, undoExpiresAt: { $0.addingTimeInterval(60) })
        let proposal = shopping()
        let first = try c.prepare(proposal, conversationID: f.conversation, turnID: f.turn)
        _ = try c.execute(first)
        let before = try XCTUnwrap(f.kitchen.shoppingItems.first)
        XCTAssertEqual(before.quantity, 2)
        let nextTurn = UUID()
        let next = try c.prepare(proposal, conversationID: f.conversation, turnID: nextTurn)
        XCTAssertNotEqual(first.idempotencyKey, next.idempotencyKey)
        let result = try c.execute(next)
        XCTAssertEqual(result.record.id, next.id); XCTAssertEqual(result.record.turnID, nextTurn)
        XCTAssertEqual(result.record.status, .succeeded)
        XCTAssertEqual(f.kitchen.shoppingItems.count, 1)
        XCTAssertEqual(f.kitchen.shoppingItems.first?.id, before.id)
        XCTAssertEqual(f.kitchen.shoppingItems.first?.quantity, 4)
    }

    func testNewTurnAfterUndoHasNewKeyAndExecutes() throws {
        let f = Fixture(); let proposal = shopping(); let first = try f.prepare(proposal)
        _ = try f.c.execute(first); _ = try f.c.undo(actionID: first.id)
        XCTAssertTrue(f.kitchen.shoppingItems.isEmpty)
        let nextTurn = UUID()
        let next = try f.c.prepare(proposal, conversationID: f.conversation, turnID: nextTurn)
        XCTAssertNotEqual(first.idempotencyKey, next.idempotencyKey)
        let result = try f.c.execute(next)
        XCTAssertEqual(result.record.id, next.id); XCTAssertEqual(result.record.turnID, nextTurn)
        XCTAssertEqual(result.record.status, .succeeded)
        XCTAssertEqual(f.p.rows[first.id]?.status, .undone)
        XCTAssertEqual(f.domain.writes, 2); XCTAssertEqual(f.kitchen.shoppingItems.first?.quantity, 2)
    }

    func testStalePreparedActionCannotAcquireNewTurnIdentity() throws {
        let f = Fixture(); let proposal = shopping(); let first = try f.prepare(proposal)
        let stale = try f.prepare(proposal)
        _ = try f.c.execute(first); _ = try f.c.undo(actionID: first.id)
        let nextTurn = UUID()
        let next = try f.c.prepare(proposal, conversationID: f.conversation, turnID: nextTurn)
        let result = try f.c.execute(next)
        XCTAssertNotEqual(stale.idempotencyKey, next.idempotencyKey)
        expect(.stale) { _ = try f.c.execute(stale) }
        XCTAssertEqual(f.p.rows[stale.id]?.turnID, f.turn)
        XCTAssertEqual(f.p.rows[stale.id]?.status, .proposed)
        XCTAssertEqual(result.record.turnID, nextTurn)
        XCTAssertEqual(f.domain.writes, 2); XCTAssertEqual(f.kitchen.shoppingItems.first?.quantity, 2)
    }

    // Full payload hashing, including fields absent from relatedEntityIDs.
    func testCanonicalProposalKeyIsStableLowercaseSHA256() throws {
        let f = Fixture(); let one = try f.prepare(tonight()); let two = try f.prepare(tonight())
        XCTAssertNotEqual(one.id, two.id)
        XCTAssertEqual(f.p.rows[one.id]?.turnID, f.turn); XCTAssertEqual(f.p.rows[two.id]?.turnID, f.turn)
        XCTAssertEqual(one.idempotencyKey, two.idempotencyKey)
        XCTAssertNotNil(one.idempotencyKey.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
    }
    func testConversationChangesKey() throws {
        let f = Fixture(); let a = try f.prepare(tonight())
        let b = try f.c.prepare(tonight(), conversationID: UUID(), turnID: f.turn)
        XCTAssertNotEqual(a.idempotencyKey, b.idempotencyKey)
    }
    func testActionTypeChangesKey() throws {
        let f = Fixture(); let id = f.plan().id
        let a = try f.prepare(.replacePlannedMeal(planID: id, replacement: block()))
        let b = try f.prepare(.applyPlannerChanges(changes: [.init(planID: id, replacement: block())]))
        XCTAssertNotEqual(a.idempotencyKey, b.idempotencyKey)
    }
    func testPlannedServingsChangesKey() throws {
        let f = Fixture(); let id = f.plan().id
        let a = try f.prepare(.applyPlannerChanges(changes: [.init(planID: id, replacement: block(), plannedServings: 2)]))
        let b = try f.prepare(.applyPlannerChanges(changes: [.init(planID: id, replacement: block(), plannedServings: 4)]))
        XCTAssertNotEqual(a.idempotencyKey, b.idempotencyKey)
    }
    func testEveryShoppingMaterialFieldChangesKey() throws {
        let f = Fixture(); let original = AIShoppingItemProposal(name: "鸡蛋", quantity: 2, unit: "个", remark: "备注")
        let key = try f.prepare(.addShoppingItems(items: [original])).idempotencyKey
        var edits = [original, original, original, original]
        edits[0].name = "番茄"; edits[1].quantity = 2.5; edits[2].unit = "盒"; edits[3].remark = "新的备注"
        for edit in edits { XCTAssertNotEqual(key, try f.prepare(.addShoppingItems(items: [edit])).idempotencyKey) }
    }
    func testFullRecipePayloadChangesKey() throws {
        let f = Fixture(); let r = recipe(); let encoded = try JSONEncoder().encode(r)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let edits: [String: Any] = ["title": "另一道菜", "cookingTime": 30, "difficulty": "难", "tags": ["另一标签"],
                                  "ingredients": ["番茄 3 个"], "seasonings": ["生抽 1 勺"], "steps": ["蒸熟"], "baseServings": 4]
        let key = try f.prepare(.addRecipeToTonight(recipe: .init(recipe: r, isTransient: true))).idempotencyKey
        for (field, value) in edits {
            var changed = object; changed[field] = value
            let next = try JSONDecoder().decode(Recipe.self, from: JSONSerialization.data(withJSONObject: changed))
            XCTAssertNotEqual(key, try f.prepare(.addRecipeToTonight(recipe: .init(recipe: next, isTransient: true))).idempotencyKey, field)
        }
    }
    func testTransientSourceMetadataChangesKey() throws {
        let f = Fixture()
        let source = RecipeSourceMetadata(platform: "web", originalURL: "https://example.com/a", canonicalURL: "https://example.com/a", importedAt: f.time, title: "来源", author: "作者")
        let a = try f.prepare(.addRecipeToTonight(recipe: .init(recipe: recipe(source: source), isTransient: true)))
        let b = try f.prepare(tonight(true)); XCTAssertNotEqual(a.idempotencyKey, b.idempotencyKey)
    }
    func testPresentationAndReasonAndTransientRecipeIDDoNotChangeKey() throws {
        let f = Fixture(); var b = block(true, id: "random-two"); b.reason = "另一段解释"
        let a = try f.prepare(tonight(true)); let other = try f.prepare(.addRecipeToTonight(recipe: b))
        XCTAssertNotEqual(a.id, other.id); XCTAssertEqual(a.idempotencyKey, other.idempotencyKey)
    }
    func testBatchOrderIsPreservedInKey() throws {
        let f = Fixture(); let changes = [f.plan(), f.plan()].map { AIPlannerMealChange(planID: $0.id, replacement: block()) }
        XCTAssertNotEqual(try f.prepare(.applyPlannerChanges(changes: changes)).idempotencyKey,
                          try f.prepare(.applyPlannerChanges(changes: changes.reversed())).idempotencyKey)
    }
    func testNonFiniteShoppingQuantityIsRejected() throws {
        let f = Fixture()
        for quantity in [Double.infinity, .nan, 0, -1] {
            XCTAssertThrowsError(try f.prepare(.addShoppingItems(items: [.init(name: "蛋", quantity: quantity, unit: "个")]))) {
                XCTAssertEqual($0 as? AIDomainToolError, .invalidShoppingQuantity)
            }
        }
        XCTAssertEqual(f.domain.writes, 0)
    }
    func testTransientRetryDoesNotDuplicate() throws {
        let f = Fixture(); let a = try f.prepare(tonight(true)); _ = try f.c.execute(a)
        let retry = try f.prepare(.addRecipeToTonight(recipe: block(true, id: "different")))
        XCTAssertEqual(a.idempotencyKey, retry.idempotencyKey)
        XCTAssertEqual(try f.c.execute(retry).record.id, a.id); XCTAssertEqual(f.domain.writes, 1); XCTAssertEqual(f.kitchen.plans.count, 1)
    }
    func testSucceededKeyReturnsExistingSuccessWithoutWrites() throws {
        let f = Fixture(); let a = try f.prepare(shopping()); let success = try f.c.execute(a)
        let retry = try f.prepare(shopping())
        XCTAssertEqual(a.idempotencyKey, retry.idempotencyKey)
        XCTAssertEqual(f.p.rows[retry.id]?.turnID, f.turn)
        XCTAssertEqual(try f.c.execute(a), success); XCTAssertEqual(try f.c.execute(retry), success)
        XCTAssertEqual(f.domain.writes, 1); XCTAssertEqual(f.kitchen.shoppingItems.first?.quantity, 2)
    }
    func testFailedAttemptMayRetry() throws {
        let f = Fixture(); let a = try f.prepare(shopping()); f.domain.failure = .persistenceFailed
        XCTAssertThrowsError(try f.c.execute(a)); XCTAssertEqual(f.p.rows[a.id]?.status, .failed)
        f.domain.failure = nil; let retry = try f.prepare(shopping())
        XCTAssertEqual(a.idempotencyKey, retry.idempotencyKey)
        XCTAssertEqual(f.p.rows[retry.id]?.turnID, f.turn)
        XCTAssertEqual(try f.c.execute(retry).record.status, .succeeded)
        XCTAssertEqual(f.kitchen.shoppingItems.count, 1); XCTAssertEqual(f.domain.writes, 2)
    }
    func testSucceededUndoneNewPrepareExecutesAndLaterSuccessWins() throws {
        let f = Fixture(); let a = try f.prepare(shopping()); _ = try f.c.execute(a); _ = try f.c.undo(actionID: a.id)
        let repeatAction = try f.prepare(shopping())
        XCTAssertEqual(a.idempotencyKey, repeatAction.idempotencyKey)
        let latest = try f.c.execute(repeatAction)
        XCTAssertEqual(try f.p.action(idempotencyKey: a.idempotencyKey)?.id, repeatAction.id)
        XCTAssertEqual(try f.c.execute(try f.prepare(shopping())), latest)
        XCTAssertEqual(f.domain.writes, 2); XCTAssertEqual(f.kitchen.shoppingItems.count, 1)
    }
    func testOldPreparedActionCannotReplayAfterUndo() throws {
        let f = Fixture(); let a = try f.prepare(shopping()); let waiting = try f.prepare(shopping())
        _ = try f.c.execute(a); _ = try f.c.undo(actionID: a.id)
        expect(.stale) { _ = try f.c.execute(a) }; expect(.stale) { _ = try f.c.execute(waiting) }
        XCTAssertEqual(f.domain.writes, 1); XCTAssertTrue(f.kitchen.shoppingItems.isEmpty)
    }
    func testPreparedDuringSuccessCannotReplayAfterUndo() throws {
        let f = Fixture(); let a = try f.prepare(shopping()); _ = try f.c.execute(a)
        let waiting = try f.prepare(shopping()); _ = try f.c.undo(actionID: a.id)
        expect(.stale) { _ = try f.c.execute(waiting) }; XCTAssertEqual(f.domain.writes, 1)
    }
    func testOlderUndoneCannotHideNewerUncertainExecutingRecord() throws {
        let f = Fixture(); let a = try f.prepare(shopping()); _ = try f.c.execute(a); _ = try f.c.undo(actionID: a.id)
        let b = try f.prepare(shopping()); var uncertain = try XCTUnwrap(f.p.rows[b.id]); uncertain.status = .executing
        XCTAssertEqual(a.idempotencyKey, b.idempotencyKey)
        try f.p.upsertAction(uncertain)
        XCTAssertEqual(try f.p.action(idempotencyKey: b.idempotencyKey)?.status, .undone)
        expect(.uncertain) { _ = try f.coordinator().execute(b) }; XCTAssertEqual(f.domain.writes, 1)
    }
    func testExistingExecutingWithoutReceiptBlocksRelaunchRetry() throws {
        let f = Fixture(); let a = try f.prepare(shopping()); var row = try XCTUnwrap(f.p.rows[a.id]); row.status = .executing
        try f.p.upsertAction(row)
        expect(.uncertain) { _ = try f.coordinator().execute(a) }; XCTAssertEqual(f.domain.writes, 0)
    }

    // Persistence order and compensation.
    func testPreparePersistsProposedThenAwaitingConfirmationWithoutWrites() throws {
        let f = Fixture(); let a = try f.prepare(.replacePlannedMeal(planID: f.plan().id, replacement: block()))
        XCTAssertEqual(f.p.transitions, [.proposed, .awaitingConfirmation]); XCTAssertEqual(f.p.rows[a.id]?.status, .awaitingConfirmation)
        XCTAssertEqual(f.domain.writes, 0)
    }
    func testLowPersistsExecutingBeforeDomainWriteAndSuccessHasReceiptAndExpiry() throws {
        let f = Fixture(); let a = try f.prepare(shopping())
        f.domain.beforeWrite = { XCTAssertEqual(f.p.rows[a.id]?.status, .executing) }
        let result = try f.c.execute(a)
        XCTAssertEqual(f.p.transitions, [.proposed, .executing, .succeeded]); XCTAssertEqual(result.record.status, .succeeded)
        XCTAssertNotNil(result.record.undoReference); XCTAssertEqual(result.record.undoExpiresAt, f.time.addingTimeInterval(60))
    }
    func testApplyTransitionsDirectlyWithoutAnyProviderDependency() throws {
        let f = Fixture(); let a = try f.prepare(.replacePlannedMeal(planID: f.plan().id, replacement: block()))
        _ = try f.c.execute(a); XCTAssertEqual(f.p.transitions, [.proposed, .awaitingConfirmation, .executing, .succeeded])
        XCTAssertEqual(f.domain.writes, 1); XCTAssertEqual(f.kitchen.plans[0].recipeID, "new")
    }
    func testConsumedPlanFailureRemainsTruthfulAndNotRetryableCopy() throws {
        let f = Fixture(); let row = f.plan(); let a = try f.prepare(.replacePlannedMeal(planID: row.id, replacement: block()))
        f.domain.failure = .consumedPlans([row.id]); XCTAssertThrowsError(try f.c.execute(a))
        let failed = try XCTUnwrap(f.p.rows[a.id]); XCTAssertEqual(failed.status, .failed)
        XCTAssertTrue(failed.failureMessage?.contains("扣过库存") == true); XCTAssertFalse(failed.failureMessage?.contains("重试") == true)
        XCTAssertEqual(f.kitchen.plans, [row])
    }
    func testCreatedAtNeverChangesAcrossExecuteAndUndo() throws {
        let f = Fixture(); let a = try f.prepare(shopping()); let created = f.p.rows[a.id]?.createdAt
        f.domain.beforeWrite = { XCTAssertEqual(f.p.rows[a.id]?.createdAt, created) }
        f.time += 1; f.domain.failure = .persistenceFailed
        XCTAssertThrowsError(try f.c.execute(a)); XCTAssertEqual(f.p.rows[a.id]?.createdAt, created)
        f.domain.failure = nil
        f.time += 1; _ = try f.c.execute(a); XCTAssertEqual(f.p.rows[a.id]?.createdAt, created)
        f.domain.beforeUndo = { XCTAssertEqual(f.p.rows[a.id]?.createdAt, created) }
        f.time += 1; _ = try f.c.undo(actionID: a.id); XCTAssertEqual(f.p.rows[a.id]?.createdAt, created)
        XCTAssertEqual(f.p.rows[a.id]?.turnID, f.turn)
    }
    func testExecutingSaveFailureMakesZeroDomainWrites() throws {
        let f = Fixture(); let a = try f.prepare(shopping()); f.p.refuse = [.executing]
        XCTAssertThrowsError(try f.c.execute(a)); XCTAssertEqual(f.domain.writes, 0); XCTAssertTrue(f.kitchen.shoppingItems.isEmpty)
    }
    func testSuccessSaveFailureCompensatesBeforeSafeFailure() throws {
        let f = Fixture(); let a = try f.prepare(tonight(true)); f.p.refuse = [.succeeded]
        XCTAssertThrowsError(try f.c.execute(a)); XCTAssertEqual(f.domain.undos, 1)
        XCTAssertTrue(f.kitchen.plans.isEmpty); XCTAssertTrue(f.recipes.userRecipes.isEmpty); XCTAssertEqual(f.p.rows[a.id]?.status, .failed)
        f.p.refuse = []; let retry = try f.prepare(tonight(true))
        XCTAssertEqual(a.idempotencyKey, retry.idempotencyKey)
        _ = try f.c.execute(retry); XCTAssertEqual(f.kitchen.plans.count, 1)
    }
    func testCompensationFailureLeavesDurableUncertaintyAndBlocksReplay() throws {
        let f = Fixture(); let a = try f.prepare(shopping()); f.p.refuse = [.succeeded]; f.domain.undoFailure = true
        expect(.uncertain) { _ = try f.c.execute(a) }; XCTAssertEqual(f.p.rows[a.id]?.status, .executing)
        XCTAssertEqual(f.kitchen.shoppingItems.count, 1); f.p.refuse = []; f.domain.undoFailure = false
        expect(.uncertain) { _ = try f.coordinator().execute(a) }; XCTAssertEqual(f.domain.writes, 1)
    }
    func testCompensatedButFailureSaveRefusedRemainsUncertain() throws {
        let f = Fixture(); let a = try f.prepare(shopping()); f.p.refuse = [.succeeded, .failed]
        expect(.uncertain) { _ = try f.c.execute(a) }; XCTAssertTrue(f.kitchen.shoppingItems.isEmpty)
        f.p.refuse = []; expect(.uncertain) { _ = try f.coordinator().execute(a) }; XCTAssertEqual(f.domain.writes, 1)
    }

    // Exact current post-state, expiry, durable action-ID recovery.
    func testValidUndoRestoresExactShoppingBeforeAndMarksUndoneAfterWrite() throws {
        let f = Fixture(); _ = f.kitchen.addShoppingItemsPersisted([.init(name: "已有", quantity: 3, unit: "包", source: "手动")])
        let before = f.kitchen.shoppingItems; let a = try f.prepare(shopping()); _ = try f.c.execute(a)
        f.domain.beforeUndo = { XCTAssertNotEqual(f.p.rows[a.id]?.status, .undone) }
        let undone = try f.c.undo(actionID: a.id)
        XCTAssertEqual(f.kitchen.shoppingItems, before); XCTAssertEqual(undone.record.status, .undone)
        XCTAssertEqual(f.p.rows[a.id]?.status, .undone)
    }
    func testUndoAtExpiryBoundaryRefusesWithoutChangingSuccess() throws {
        let f = Fixture(); let a = try f.prepare(shopping()); _ = try f.c.execute(a); f.time += 60
        expect(.expired) { _ = try f.c.undo(actionID: a.id) }; XCTAssertEqual(f.domain.undos, 0); XCTAssertEqual(f.p.rows[a.id]?.status, .succeeded)
    }
    func testPlannerAffectedEditRefusesUndo() throws {
        let f = Fixture(); let a = try f.prepare(.replacePlannedMeal(planID: f.plan().id, replacement: block()))
        _ = try f.c.execute(a); var changed = f.kitchen.plans[0]; changed.plannedServings = 8; _ = f.kitchen.restorePlanItems([changed])
        expect(.stale) { _ = try f.c.undo(actionID: a.id) }; XCTAssertEqual(f.domain.undos, 0); XCTAssertEqual(f.kitchen.plans[0], changed)
    }
    func testUnrelatedPlannerEditDoesNotBlockExactAffectedUndo() throws {
        let f = Fixture(); let before = f.plan(); var unrelated = f.plan("另一顿")
        let a = try f.prepare(.replacePlannedMeal(planID: before.id, replacement: block())); _ = try f.c.execute(a)
        unrelated.plannedServings = 8; _ = f.kitchen.restorePlanItems([unrelated]); _ = try f.c.undo(actionID: a.id)
        XCTAssertEqual(f.kitchen.plans, [before, unrelated])
    }
    func testSpecialPlanLaterEditRefusesUndo() throws {
        let f = Fixture(); let event = f.event()
        let a = try f.prepare(.replaceSpecialPlanDishes(planID: event.id, changes: [.init(dishID: event.dishes[0].id, replacement: block())]))
        _ = try f.c.execute(a); var changed = f.kitchen.specialPlans[0]; changed.notes = "用户后来写的"; f.kitchen.updateSpecialPlan(changed)
        expect(.stale) { _ = try f.c.undo(actionID: a.id) }; XCTAssertEqual(f.domain.undos, 0); XCTAssertEqual(f.kitchen.specialPlans[0].notes, "用户后来写的")
    }
    func testShoppingDivergenceRefusesUndo() throws {
        let f = Fixture(); let a = try f.prepare(shopping()); _ = try f.c.execute(a)
        _ = f.kitchen.addShoppingItemsPersisted([.init(name: "后加", quantity: 1, unit: "个", source: "手动")])
        let later = f.kitchen.shoppingItems
        expect(.stale) { _ = try f.c.undo(actionID: a.id) }; XCTAssertEqual(f.domain.undos, 0); XCTAssertEqual(f.kitchen.shoppingItems, later)
    }
    func testChangedTonightPlanRefusesUndo() throws {
        let f = Fixture(); let a = try f.prepare(tonight()); _ = try f.c.execute(a)
        var row = f.kitchen.plans[0]; row.isCooked = true; _ = f.kitchen.restorePlanItems([row])
        expect(.stale) { _ = try f.c.undo(actionID: a.id) }; XCTAssertEqual(f.domain.undos, 0)
    }
    func testRemovedTonightPlanRefusesUndo() throws {
        let f = Fixture(); let a = try f.prepare(tonight()); _ = try f.c.execute(a); _ = f.kitchen.removePlan(id: f.kitchen.plans[0].id)
        expect(.stale) { _ = try f.c.undo(actionID: a.id) }; XCTAssertEqual(f.domain.undos, 0)
    }
    func testRawUndoFailureNeverMarksUndone() throws {
        let f = Fixture(); let a = try f.prepare(shopping()); _ = try f.c.execute(a); f.domain.undoFailure = true
        XCTAssertThrowsError(try f.c.undo(actionID: a.id)); XCTAssertEqual(f.p.rows[a.id]?.status, .succeeded); XCTAssertEqual(f.kitchen.shoppingItems.count, 1)
    }
    func testUndoRecordSaveFailureNeverReportsUndoneOrReplaysMutation() throws {
        let f = Fixture(); let a = try f.prepare(shopping()); _ = try f.c.execute(a); f.p.refuse = [.undone]
        expect(.uncertain) { _ = try f.c.undo(actionID: a.id) }; XCTAssertNotEqual(f.p.rows[a.id]?.status, .undone)
        f.p.refuse = []; expect(.uncertain) { _ = try f.coordinator().execute(a) }; XCTAssertEqual(f.domain.writes, 1)
    }
    func testTransientRecipeReferencedByAnotherPlannerRowSurvivesUndo() throws {
        let f = Fixture(); let a = try f.prepare(tonight(true)); _ = try f.c.execute(a)
        _ = f.kitchen.addPlan(recipe: try XCTUnwrap(f.recipes.userRecipes.first), on: f.time.addingTimeInterval(86400), calendar: f.domain.calendar)
        _ = try f.c.undo(actionID: a.id); XCTAssertEqual(f.recipes.userRecipes.count, 1); XCTAssertEqual(f.kitchen.plans.count, 1)
    }
    func testTransientRecipeReferencedBySpecialPlanSurvivesUndo() throws {
        let f = Fixture(); let a = try f.prepare(tonight(true)); _ = try f.c.execute(a)
        let r = try XCTUnwrap(f.recipes.userRecipes.first)
        f.kitchen.addSpecialPlan(SpecialPlan(title: "另一天", scheduledAt: f.time, dishes: [.init(recipeID: r.id, recipeName: r.title)]))
        _ = try f.c.undo(actionID: a.id); XCTAssertEqual(f.recipes.userRecipes.count, 1)
    }
    func testUndoWorksAfterCoordinatorReconstructionFromSwiftData() throws {
        let f = Fixture(); let container = try KitchenPersistenceFactory.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let p = SwiftDataConversationPersistence(container: container); let c = f.coordinator(persistence: p)
        let a = try c.prepare(shopping(), conversationID: f.conversation, turnID: f.turn); let success = try c.execute(a)
        let reloaded = SwiftDataConversationPersistence(container: container)
        XCTAssertEqual(try reloaded.action(id: a.id), success.record)
        XCTAssertEqual(try f.coordinator(persistence: reloaded).undo(actionID: a.id).record.status, .undone)
        XCTAssertTrue(f.kitchen.shoppingItems.isEmpty)
    }
    func testInvalidExpiryPolicyRefusesBeforeDomainWrite() throws {
        let f = Fixture(); let c = ConversationActionCoordinator(domainTools: f.domain, persistence: f.p, now: { f.time }, undoExpiresAt: { $0 })
        let a = try c.prepare(shopping(), conversationID: f.conversation, turnID: f.turn)
        expect(.invalidExpiry) { _ = try c.execute(a) }; XCTAssertEqual(f.domain.writes, 0)
    }
    func testShoppingCanonicalDigestMatchesIndependentSHA256Vector() throws {
        let f = Fixture()
        let a = try f.c.prepare(.addShoppingItems(items: [.init(name: "egg", quantity: 2, unit: "piece", remark: "fresh")]),
            conversationID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            turnID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        // SHA256 of hand-authored canonical JSON, independently computed using Python hashlib.
        XCTAssertEqual(a.idempotencyKey, "cc79d46e742eca7b8ef9a45c00c7e7a5b478730850004ac8902830c7d552c684")
    }
    func testSpecialPlanValidUndoRestoresExactSnapshot() throws {
        let f = Fixture(); let before = f.event()
        let a = try f.prepare(.replaceSpecialPlanDishes(planID: before.id,
            changes: before.dishes.map { .init(dishID: $0.id, replacement: block(true)) }))
        _ = try f.c.execute(a); _ = try f.c.undo(actionID: a.id)
        XCTAssertEqual(f.kitchen.specialPlans, [before]); XCTAssertTrue(f.recipes.userRecipes.isEmpty)
    }
    func testShoppingMergeUndoRestoresExistingRowExactly() throws {
        let f = Fixture()
        _ = f.kitchen.addShoppingItemsPersisted([.init(name: "鸡蛋0", quantity: 3, unit: "个", source: "手动", remark: "原备注")])
        let before = f.kitchen.shoppingItems; let a = try f.prepare(shopping()); _ = try f.c.execute(a)
        XCTAssertEqual(f.kitchen.shoppingItems.count, 1); XCTAssertEqual(f.kitchen.shoppingItems[0].quantity, 5)
        _ = try f.c.undo(actionID: a.id); XCTAssertEqual(f.kitchen.shoppingItems, before)
    }
    func testUnrelatedPlanChangeDoesNotInvalidatePreparedApply() throws {
        let f = Fixture(); let row = f.plan(); var other = f.plan("其他")
        let a = try f.prepare(.replacePlannedMeal(planID: row.id, replacement: block()))
        other.plannedServings = 8; _ = f.kitchen.restorePlanItems([other]); _ = try f.c.execute(a)
        XCTAssertEqual(f.kitchen.plans[1], other); XCTAssertEqual(f.kitchen.plans[0].recipeName, "新菜")
    }
    func testStaleSpecialPlanRefusesApply() throws {
        let f = Fixture(); var event = f.event()
        let a = try f.prepare(.replaceSpecialPlanDishes(planID: event.id, changes: [.init(dishID: event.dishes[0].id, replacement: block())]))
        event.peopleCount = 10; f.kitchen.updateSpecialPlan(event)
        expect(.stale) { _ = try f.c.execute(a) }; XCTAssertEqual(f.domain.writes, 0)
    }
    func testLaterExecutingAfterUndoneSurvivesSwiftDataReconstruction() throws {
        let f = Fixture(); let container = try KitchenPersistenceFactory.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let p = SwiftDataConversationPersistence(container: container); let c = f.coordinator(persistence: p)
        let a = try c.prepare(shopping(), conversationID: f.conversation, turnID: f.turn); _ = try c.execute(a); _ = try c.undo(actionID: a.id)
        let b = try c.prepare(shopping(), conversationID: f.conversation, turnID: f.turn)
        XCTAssertEqual(a.idempotencyKey, b.idempotencyKey)
        XCTAssertEqual(try p.action(id: b.id)?.turnID, f.turn)
        var pending = try XCTUnwrap(p.action(id: b.id)); pending.status = .executing; try p.upsertAction(pending)
        let reader = SwiftDataConversationPersistence(container: container)
        XCTAssertEqual(try reader.action(idempotencyKey: a.idempotencyKey)?.status, .undone)
        expect(.uncertain) { _ = try f.coordinator(persistence: reader).execute(b) }; XCTAssertEqual(f.domain.writes, 1)
    }
    func testEveryTransientSourceFieldParticipatesWhenRecipeWillBeSaved() throws {
        let f = Fixture()
        let source = RecipeSourceMetadata(platform: "web", originalURL: "https://a.test/1", canonicalURL: "https://a.test/2", importedAt: f.time, title: "来源", author: "作者")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
        let edits: [String: Any] = ["platform": "other", "originalURL": "https://b.test/1", "canonicalURL": "https://b.test/2",
                                  "importedAt": 123, "title": "另一来源", "author": "另一作者"]
        let key = try f.prepare(.addRecipeToTonight(recipe: .init(recipe: recipe(source: source), isTransient: true))).idempotencyKey
        for (field, value) in edits {
            var changed = object; changed[field] = value
            let next = try JSONDecoder().decode(RecipeSourceMetadata.self, from: JSONSerialization.data(withJSONObject: changed))
            XCTAssertNotEqual(key, try f.prepare(.addRecipeToTonight(recipe: .init(recipe: recipe(source: next), isTransient: true))).idempotencyKey, field)
        }
    }

    // Review round 1: actual target day, complete compensation, active consumption.
    func testTonightSameCivilDayDeduplicatesAcrossClockTimes() throws {
        let f = Fixture(); f.time = f.domain.calendar.startOfDay(for: f.time).addingTimeInterval(3600)
        let first = try f.prepare(tonight(true)); _ = try f.c.execute(first)
        f.time += 3600
        let retry = try f.prepare(tonight(true))
        XCTAssertEqual(first.idempotencyKey, retry.idempotencyKey)
        XCTAssertEqual(try f.c.execute(retry).record.id, first.id)
        XCTAssertEqual(f.kitchen.plans.count, 1); XCTAssertEqual(f.domain.writes, 1)
    }

    func testTonightNextCivilDayCreatesNewMeal() throws {
        let f = Fixture(); let first = try f.prepare(tonight(true)); _ = try f.c.execute(first)
        let yesterday = f.kitchen.plans[0]
        f.time = f.domain.calendar.date(byAdding: .day, value: 1, to: f.time)!
        let next = try f.prepare(tonight(true))
        XCTAssertNotEqual(first.idempotencyKey, next.idempotencyKey)
        XCTAssertEqual(try f.c.execute(next).record.id, next.id)
        XCTAssertEqual(f.kitchen.plans.count, 2); XCTAssertEqual(f.domain.writes, 2)
        XCTAssertTrue(f.kitchen.plans.contains(yesterday))
        XCTAssertTrue(f.kitchen.plans.contains { f.domain.calendar.isDate($0.date, inSameDayAs: f.time) })
    }

    func testYesterdayPreviewIsStaleEvenWhenYesterdayHasSucceededTwin() throws {
        let f = Fixture(); let first = try f.prepare(tonight(true)); let waiting = try f.prepare(tonight(true))
        _ = try f.c.execute(first)
        f.time = f.domain.calendar.date(byAdding: .day, value: 1, to: f.time)!
        expect(.stale) { _ = try f.c.execute(waiting) }
        XCTAssertEqual(f.kitchen.plans.count, 1); XCTAssertEqual(f.domain.writes, 1)
    }

    func testPartialRecipeCompensationRetainsSwiftDataReceiptAndBlocksReplay() throws {
        let recipes = RecipePersistence(); let f = Fixture(recipePersistence: recipes)
        let container = try KitchenPersistenceFactory.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let p = SwiftDataConversationPersistence(container: container); let c = f.coordinator(persistence: p)
        let a = try c.prepare(tonight(true), conversationID: f.conversation, turnID: f.turn)
        f.domain.beforeWrite = { p.failNextSaveForTesting = AIActionExecutionError.storage }
        f.domain.beforeUndo = { recipes.refuse = true }
        expect(.uncertain) { _ = try c.execute(a) }
        XCTAssertTrue(f.kitchen.plans.isEmpty)
        XCTAssertEqual(f.recipes.userRecipes.map(\.id), ["new"])
        XCTAssertEqual(try recipes.loadRecipes().map(\.id), ["new"])
        let reloaded = SwiftDataConversationPersistence(container: container)
        let record = try XCTUnwrap(reloaded.action(id: a.id))
        XCTAssertEqual(record.status, .executing); XCTAssertNotNil(record.undoReference)
        XCTAssertEqual(record.turnID, f.turn); XCTAssertEqual(record.idempotencyKey, a.idempotencyKey)
        XCTAssertNotNil(record.undoExpiresAt)
        recipes.refuse = false; f.domain.beforeWrite = nil; f.domain.beforeUndo = nil
        let resumed = f.coordinator(persistence: reloaded)
        expect(.uncertain) { _ = try resumed.execute(a) }
        expect(.uncertain) { _ = try resumed.prepare(self.tonight(true), conversationID: f.conversation, turnID: f.turn) }
        XCTAssertEqual(f.domain.writes, 1)
    }

    func testOrdinaryUndoStillAllowsBestEffortRecipeCleanupFailure() throws {
        let recipes = RecipePersistence(); let f = Fixture(recipePersistence: recipes)
        let a = try f.prepare(tonight(true)); _ = try f.c.execute(a)
        recipes.refuse = true
        XCTAssertEqual(try f.c.undo(actionID: a.id).record.status, .undone)
        XCTAssertTrue(f.kitchen.plans.isEmpty); XCTAssertEqual(f.recipes.userRecipes.map(\.id), ["new"])
    }

    func testConsumedPlannerRowEqualToReceiptRefusesUndoWithoutChangingHistory() throws {
        let f = Fixture(); let a = try f.prepare(.replacePlannedMeal(planID: f.plan().id, replacement: block()))
        let result = try f.c.execute(a); let after = f.kitchen.plans
        let row = after[0]
        _ = f.kitchen.applyConsumption([], planIDs: [row.id], recipeID: row.recipeID, recipeName: row.recipeName)
        XCTAssertTrue(f.kitchen.hasConsumedPlan(row.id)); XCTAssertFalse(row.isCooked)
        let history = f.kitchen.consumptionRecords; let inventory = f.kitchen.inventory
        expect(.stale) { _ = try f.c.undo(actionID: a.id) }
        XCTAssertEqual(f.kitchen.plans, after); XCTAssertEqual(f.kitchen.consumptionRecords, history)
        XCTAssertEqual(f.kitchen.inventory, inventory); XCTAssertEqual(f.p.rows[a.id], result.record)
        XCTAssertEqual(f.domain.undos, 0)
    }

    func testConsumedTonightRowEqualToReceiptRefusesUndoWithoutChangingHistory() throws {
        let f = Fixture(); let a = try f.prepare(tonight(true)); let result = try f.c.execute(a)
        let after = f.kitchen.plans; let row = after[0]
        _ = f.kitchen.applyConsumption([], planIDs: [row.id], recipeID: row.recipeID, recipeName: row.recipeName)
        XCTAssertTrue(f.kitchen.hasConsumedPlan(row.id)); XCTAssertFalse(row.isCooked)
        let history = f.kitchen.consumptionRecords; let inventory = f.kitchen.inventory
        expect(.stale) { _ = try f.c.undo(actionID: a.id) }
        XCTAssertEqual(f.kitchen.plans, after); XCTAssertEqual(f.kitchen.consumptionRecords, history)
        XCTAssertEqual(f.kitchen.inventory, inventory); XCTAssertEqual(f.p.rows[a.id], result.record)
        XCTAssertEqual(f.recipes.userRecipes.map(\.id), ["new"]); XCTAssertEqual(f.domain.undos, 0)
    }

    func testUnrelatedConsumptionDoesNotBlockAffectedPlannerUndo() throws {
        let f = Fixture(); let before = f.plan(); let other = f.plan("另一顿")
        let a = try f.prepare(.replacePlannedMeal(planID: before.id, replacement: block())); _ = try f.c.execute(a)
        _ = f.kitchen.applyConsumption([], planIDs: [other.id], recipeID: other.recipeID, recipeName: other.recipeName)
        let history = f.kitchen.consumptionRecords; let inventory = f.kitchen.inventory
        _ = try f.c.undo(actionID: a.id)
        XCTAssertEqual(f.kitchen.plans, [before, other]); XCTAssertEqual(f.kitchen.consumptionRecords, history)
        XCTAssertEqual(f.kitchen.inventory, inventory)
    }

    func testRecoveryReceiptIsDurableBeforeAutomaticUndoStarts() throws {
        let f = Fixture(); let a = try f.prepare(tonight(true)); f.p.refuse = [.succeeded]
        f.domain.beforeUndo = {
            XCTAssertEqual(f.p.rows[a.id]?.status, .executing)
            XCTAssertNotNil(f.p.rows[a.id]?.undoReference)
            XCTAssertNotNil(f.p.rows[a.id]?.undoExpiresAt)
        }
        expect(.storage) { _ = try f.c.execute(a) }
        XCTAssertEqual(f.p.rows[a.id]?.status, .failed)
        XCTAssertTrue(f.kitchen.plans.isEmpty); XCTAssertTrue(f.recipes.userRecipes.isEmpty)
    }

    func testRecoveryReceiptSaveFailureStopsBeforeCompensationAndBlocksReplay() throws {
        let f = Fixture(); let a = try f.prepare(tonight(true))
        f.domain.beforeWrite = { f.p.refuse = [.succeeded, .executing] }
        expect(.uncertain) { _ = try f.c.execute(a) }
        XCTAssertEqual(f.p.rows[a.id]?.status, .executing); XCTAssertEqual(f.domain.undos, 0)
        XCTAssertEqual(f.kitchen.plans.count, 1); XCTAssertEqual(f.recipes.userRecipes.count, 1)
        f.p.refuse = []; f.domain.beforeWrite = nil
        expect(.uncertain) { _ = try f.coordinator().execute(a) }
        XCTAssertEqual(f.domain.writes, 1)
    }

    func testNeverExecutedYesterdayPreviewRefusesToday() throws {
        let f = Fixture(); let a = try f.prepare(tonight(true))
        f.time = f.domain.calendar.date(byAdding: .day, value: 1, to: f.time)!
        expect(.stale) { _ = try f.c.execute(a) }
        XCTAssertTrue(f.kitchen.plans.isEmpty); XCTAssertEqual(f.domain.writes, 0)
    }

    func testCompleteAutomaticCompensationRestoresOtherReceiptKinds() throws {
        for kind in 0..<3 {
            let f = Fixture(); let proposal: AIActionProposal
            switch kind {
            case 0: proposal = .replacePlannedMeal(planID: f.plan().id, replacement: block(true))
            case 1:
                let event = f.event()
                proposal = .replaceSpecialPlanDishes(planID: event.id, changes: [.init(dishID: event.dishes[0].id, replacement: block(true))])
            default: proposal = shopping()
            }
            let plans = f.kitchen.plans; let events = f.kitchen.specialPlans; let items = f.kitchen.shoppingItems
            let a = try f.prepare(proposal); f.p.refuse = [.succeeded]
            expect(.storage) { _ = try f.c.execute(a) }
            XCTAssertEqual(f.p.rows[a.id]?.status, .failed)
            XCTAssertEqual(f.kitchen.plans, plans); XCTAssertEqual(f.kitchen.specialPlans, events)
            XCTAssertEqual(f.kitchen.shoppingItems, items); XCTAssertTrue(f.recipes.userRecipes.isEmpty)
        }
    }

}

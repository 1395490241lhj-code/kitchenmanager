import XCTest
@testable import KitchenManager

final class ConversationResponseInterpreterTests: XCTestCase {
    private let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let rowID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private var recipe: Recipe { Recipe(id: "canonical-eggs", title: "鸡蛋", cookingTime: 5, difficulty: "简单", tags: ["早餐"], ingredients: ["鸡蛋 2 个"], steps: ["煮熟"], baseServings: 2) }
    private var block: AIRecipeBlock { .init(id: id, recipe: recipe, isTransient: false) }
    private var reference: [String: Any] { ["recipeID": "canonical-eggs", "title": "鸡蛋"] }
    private var context: AIConversationInterpretationContext {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return .init(blockID: id, rowIDs: [rowID], recipesByPath: ["recipe": block, "replacement": block, "changes.0.replacement": block], calendar: calendar)
    }
    private func interpret(_ name: String, _ arguments: Any, context: AIConversationInterpretationContext? = nil) -> AIConversationToolIntent {
        let data = try! JSONSerialization.data(withJSONObject: arguments, options: [.fragmentsAllowed, .sortedKeys])
        return ConversationResponseInterpreter().interpret(toolCall: .init(id: "call-1", name: name, arguments: data), context: context ?? self.context)
    }
    private func reject(_ name: String, _ arguments: Any, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(interpret(name, arguments), .appendBlock(.error(.init(id: id, message: "无法识别这次操作，没有改动。", retry: .interpretation))), file: file, line: line)
    }
    private func valid(_ name: String) -> [String: Any] {
        switch name {
        case "read_inventory", "read_tonight_plan": return [:]
        case "read_planner_week": return ["weekStart": "2026-09-14"]
        case "read_special_plan": return ["planID": id.uuidString]
        case "resolve_recipe": return ["query": "鸡蛋", "recipeID": "canonical-eggs"]
        case "present_recipe_card", "propose_add_recipe_to_tonight": return ["recipe": reference]
        case "present_context_result": return ["kind": "inventory", "title": "库存", "rows": [["label": "鸡蛋", "value": "2个"]]]
        case "propose_replace_planned_meal": return ["planID": id.uuidString, "replacement": reference]
        case "propose_apply_planner_changes": return ["changes": [["planID": id.uuidString, "replacement": reference, "plannedServings": 3]]]
        case "propose_special_plan_changes": return ["planID": id.uuidString, "changes": [["dishID": rowID.uuidString, "replacement": reference]]]
        case "propose_add_shopping_items": return ["items": [["name": "鸡蛋", "quantity": 2.5, "unit": "个", "remark": "早餐"]]]
        default: fatalError("bad fixture")
        }
    }
    private func expected(_ name: String) -> AIConversationToolIntent {
        switch name {
        case "read_inventory": return .read(.inventory(expiringOnly: nil))
        case "read_tonight_plan": return .read(.tonightPlan)
        case "read_planner_week": return .read(.plannerWeek(weekStart: context.calendar.date(from: DateComponents(year: 2026, month: 9, day: 14))!))
        case "read_special_plan": return .read(.specialPlan(id: id))
        case "resolve_recipe": return .read(.resolveRecipe(query: "鸡蛋", recipeID: "canonical-eggs"))
        case "present_recipe_card": return .appendBlock(.recipe(block))
        case "present_context_result": return .appendBlock(.contextResult(.init(id: id, title: "库存", rows: [.init(id: rowID, label: "鸡蛋", detail: "2个")], kind: .inventory)))
        case "propose_add_recipe_to_tonight": return .proposeAction(.addRecipeToTonight(recipe: block))
        case "propose_replace_planned_meal": return .proposeAction(.replacePlannedMeal(planID: id, replacement: block))
        case "propose_apply_planner_changes": return .proposeAction(.applyPlannerChanges(changes: [.init(planID: id, replacement: block, plannedServings: 3)]))
        case "propose_special_plan_changes": return .proposeAction(.replaceSpecialPlanDishes(planID: id, changes: [.init(dishID: rowID, replacement: block)]))
        case "propose_add_shopping_items": return .proposeAction(.addShoppingItems(items: [.init(name: "鸡蛋", quantity: 2.5, unit: "个", remark: "早餐")]))
        default: fatalError("bad fixture")
        }
    }
    func test_read_inventory_valid() { XCTAssertEqual(interpret("read_inventory", valid("read_inventory")), expected("read_inventory")) }
    func test_read_inventory_malformedRequiredFieldOrType() { reject("read_inventory", ["expiringOnly": "true"]) }
    func test_read_tonight_plan_valid() { XCTAssertEqual(interpret("read_tonight_plan", valid("read_tonight_plan")), expected("read_tonight_plan")) }
    func test_read_tonight_plan_malformedRequiredFieldOrType() { reject("read_tonight_plan", ["unexpected": true]) }
    func test_read_planner_week_valid() { XCTAssertEqual(interpret("read_planner_week", valid("read_planner_week")), expected("read_planner_week")) }
    func test_read_planner_week_malformedRequiredFieldOrType() { reject("read_planner_week", ["weekStart": 20260914]) }
    func test_read_special_plan_valid() { XCTAssertEqual(interpret("read_special_plan", valid("read_special_plan")), expected("read_special_plan")) }
    func test_read_special_plan_malformedRequiredFieldOrType() { reject("read_special_plan", ["planID": "not-a-uuid"]) }
    func test_resolve_recipe_valid() { XCTAssertEqual(interpret("resolve_recipe", valid("resolve_recipe")), expected("resolve_recipe")) }
    func test_resolve_recipe_malformedRequiredFieldOrType() { reject("resolve_recipe", ["recipeID": "canonical-eggs"]) }
    func test_present_recipe_card_valid() { XCTAssertEqual(interpret("present_recipe_card", valid("present_recipe_card")), expected("present_recipe_card")) }
    func test_present_recipe_card_malformedRequiredFieldOrType() { reject("present_recipe_card", ["recipe": ["recipeID": "canonical-eggs"]]) }
    func test_present_context_result_valid() { XCTAssertEqual(interpret("present_context_result", valid("present_context_result")), expected("present_context_result")) }
    func test_present_context_result_malformedRequiredFieldOrType() { reject("present_context_result", ["title": "库存", "rows": [["label": "eggs", "value": 2]]]) }
    func test_propose_add_recipe_to_tonight_valid() { XCTAssertEqual(interpret("propose_add_recipe_to_tonight", valid("propose_add_recipe_to_tonight")), expected("propose_add_recipe_to_tonight")) }
    func test_propose_add_recipe_to_tonight_malformedRequiredFieldOrType() { reject("propose_add_recipe_to_tonight", ["recipe": ["title": 42]]) }
    func test_propose_replace_planned_meal_valid() { XCTAssertEqual(interpret("propose_replace_planned_meal", valid("propose_replace_planned_meal")), expected("propose_replace_planned_meal")) }
    func test_propose_replace_planned_meal_malformedRequiredFieldOrType() { reject("propose_replace_planned_meal", ["planID": NSNull(), "replacement": reference]) }
    func test_propose_apply_planner_changes_valid() { XCTAssertEqual(interpret("propose_apply_planner_changes", valid("propose_apply_planner_changes")), expected("propose_apply_planner_changes")) }
    func test_propose_apply_planner_changes_malformedRequiredFieldOrType() { reject("propose_apply_planner_changes", ["changes": [["planID": id.uuidString]]]) }
    func test_propose_special_plan_changes_valid() { XCTAssertEqual(interpret("propose_special_plan_changes", valid("propose_special_plan_changes")), expected("propose_special_plan_changes")) }
    func test_propose_special_plan_changes_malformedRequiredFieldOrType() { reject("propose_special_plan_changes", ["planID": id.uuidString, "changes": [["replacement": reference]]]) }
    func test_propose_add_shopping_items_valid() { XCTAssertEqual(interpret("propose_add_shopping_items", valid("propose_add_shopping_items")), expected("propose_add_shopping_items")) }
    func test_propose_add_shopping_items_malformedRequiredFieldOrType() { reject("propose_add_shopping_items", ["items": [["name": "eggs", "quantity": "2", "unit": "个"]]]) }
    func testUnknownToolFailsSafelyWithoutDiagnosticLeak() { reject("dump_authorization_SECRET", ["token": "PRIVATE"]) }
    func testArrayArgumentsRejected() { reject("read_inventory", []) }
    func testScalarArgumentsRejected() { reject("read_inventory", 12); reject("read_inventory", true); reject("read_inventory", "{}") }
    func testNullArgumentsRejected() { reject("read_inventory", NSNull()) }
    func testMalformedJSONRejected() {
        let result = ConversationResponseInterpreter().interpret(toolCall: .init(id: "x", name: "read_inventory", arguments: Data("{SECRET".utf8)), context: context)
        guard case .appendBlock(.error(let error)) = result else { return XCTFail("unsafe") }
        XCTAssertFalse(error.message.contains("SECRET")); XCTAssertEqual(error.retry, .interpretation)
    }
    func testInventoryBooleanExactAndAbsentDistinct() {
        XCTAssertEqual(interpret("read_inventory", ["expiringOnly": true]), .read(.inventory(expiringOnly: true)))
        XCTAssertEqual(interpret("read_inventory", ["expiringOnly": false]), .read(.inventory(expiringOnly: false)))
        reject("read_inventory", ["expiringOnly": 1]); reject("read_inventory", ["expiringOnly": NSNull()])
    }
    func testStrictDatesRejectRolloverAndNonCanonicalFormat() {
        for date in ["2026-02-30", "2026-13-01", "2026-9-14", "2026-09-14T00:00:00Z", "0000-01-01", "2026-00-01"] {
            reject("read_planner_week", ["weekStart": date])
        }
        XCTAssertEqual(interpret("read_planner_week", ["weekStart": "2024-02-29"]), .read(.plannerWeek(weekStart: context.calendar.date(from: DateComponents(year: 2024, month: 2, day: 29))!)))
    }
    func testRecipeCanonicalSnapshotRetainsIdentityAndAllFields() {
        guard case .appendBlock(.recipe(let result)) = interpret("present_recipe_card", valid("present_recipe_card")) else { return XCTFail() }
        XCTAssertEqual(result.recipe, recipe); XCTAssertFalse(result.isTransient); XCTAssertEqual(result.id, id)
    }
    func testRecipeTransientRequiresExplicitResolvedProvenanceAndFullPayload() {
        let c = AIConversationInterpretationContext(blockID: id, rowIDs: [], recipesByPath: [:],
            transientIdentitiesByPath: ["recipe": .init(blockID: rowID, recipeID: "generated-eggs")], calendar: context.calendar)
        let args: [String: Any] = ["recipe": ["title": "鸡蛋", "ingredients": [["item": "鸡蛋", "qty": "2", "unit": "个"]], "steps": ["煮熟"], "reason": "用掉临期食材"]]
        guard case .appendBlock(.recipe(let result)) = interpret("present_recipe_card", args, context: c) else { return XCTFail() }
        XCTAssertTrue(result.isTransient); XCTAssertEqual(result.id, rowID)
        XCTAssertEqual(result.recipe.id, "generated-eggs"); XCTAssertEqual(result.recipe.title, "鸡蛋")
        XCTAssertEqual(result.recipe.ingredients, ["鸡蛋 2 个"]); XCTAssertEqual(result.recipe.steps, ["煮熟"])
        XCTAssertNil(result.recipe.baseServings); XCTAssertNil(result.recipe.cookingTime)
        XCTAssertEqual(result.reason, "用掉临期食材")
    }
    func testIncompleteTransientRecipeRejected() {
        let c = AIConversationInterpretationContext(blockID: id, rowIDs: [], recipesByPath: [:], transientIdentitiesByPath: ["recipe": .init(blockID: id, recipeID: "generated-eggs")], calendar: context.calendar)
        for value: [String: Any] in [["title": "鸡蛋"], ["title": "鸡蛋", "steps": ["煮熟"]], ["title": "鸡蛋", "ingredients": [["item": "鸡蛋"]]]] {
            guard case .appendBlock(.error) = interpret("present_recipe_card", ["recipe": value], context: c) else { return XCTFail() }
        }
    }
    func testRecipeCannotInventIdentityOrTakeProvenanceFromArguments() {
        let empty = AIConversationInterpretationContext(blockID: id, rowIDs: [], recipesByPath: [:], calendar: context.calendar)
        guard case .appendBlock(.error) = interpret("present_recipe_card", valid("present_recipe_card"), context: empty) else { return XCTFail() }
        reject("present_recipe_card", ["recipe": ["title": "鸡蛋", "recipeID": "canonical-eggs", "isTransient": false]])
        reject("present_recipe_card", ["recipe": ["title": "鸡蛋", "recipeID": "other"]])
    }
    func testRecipeNestedFieldsStrictEvenWithResolvedSnapshot() {
        for extra: [String: Any] in [["ingredients": [["item": 2]]], ["ingredients": [["item": "鸡蛋", "qty": 2]]], ["ingredients": [["item": "鸡蛋", "unit": NSNull()]]], ["steps": [42]], ["reason": false], ["ingredients": []]] {
            reject("present_recipe_card", ["recipe": reference.merging(extra) { _, b in b }])
        }
    }
    func testRecipeMismatchCannotRewriteCanonicalSnapshot() {
        reject("present_recipe_card", ["recipe": ["recipeID": "canonical-eggs", "title": "changed"]])
        reject("present_recipe_card", ["recipe": reference.merging(["steps": ["different"]]) { _, b in b }])
    }
    func testSingleActionsRejectExplicitUnrepresentableServings() {
        for name in ["propose_add_recipe_to_tonight", "propose_replace_planned_meal"] {
            for servings: Any in [3, "3", NSNull()] { reject(name, valid(name).merging(["plannedServings": servings]) { _, b in b }) }
        }
    }
    func testBatchServingsRejectsCoercionFractionsAndOutOfRange() {
        for servings: Any in [true, "3", 1.5, 0, 13, NSNull()] {
            reject("propose_apply_planner_changes", ["changes": [["planID": id.uuidString, "replacement": reference, "plannedServings": servings]]])
        }
    }
    func testBatchFailureRejectsEntireProposal() {
        reject("propose_apply_planner_changes", ["changes": [["planID": id.uuidString, "replacement": reference], ["planID": "invalid", "replacement": reference]]])
        reject("propose_add_shopping_items", ["items": [["name": "valid", "quantity": 1, "unit": "个"], ["name": "invalid", "quantity": false, "unit": "个"]]])
    }
    func testContextResultRequiresCallerIdentitiesAndExactKind() {
        let c = AIConversationInterpretationContext(blockID: id, rowIDs: [], recipesByPath: [:], calendar: context.calendar)
        guard case .appendBlock(.error) = interpret("present_context_result", valid("present_context_result"), context: c) else { return XCTFail() }
        reject("present_context_result", valid("present_context_result").merging(["kind": "account"]) { _, b in b })
    }
    func testShoppingRequiresAllFieldsAndPositiveFiniteQuantity() {
        for row: [String: Any] in [["name": "x", "quantity": 1], ["name": "x", "unit": "g"], ["quantity": 1, "unit": "g"], ["name": "x", "quantity": 0, "unit": "g"], ["name": "x", "quantity": 1, "unit": "g", "remark": false]] {
            reject("propose_add_shopping_items", ["items": [row]])
        }
    }
    func testRepeatedInterpretationIsPureAndDeterministic() {
        let c = context
        for name in ["present_recipe_card", "present_context_result", "propose_add_recipe_to_tonight", "propose_replace_planned_meal", "propose_apply_planner_changes", "propose_special_plan_changes", "propose_add_shopping_items"] {
            XCTAssertEqual(interpret(name, valid(name), context: c), interpret(name, valid(name), context: c))
        }
        XCTAssertEqual(c.recipesByPath["recipe"], block)
    }
    func testTransientContentCannotBePartiallyDroppedByRecipeNormalization() {
        let c = AIConversationInterpretationContext(blockID: id, rowIDs: [], recipesByPath: [:],
            transientIdentitiesByPath: ["recipe": .init(blockID: id, recipeID: "generated")], calendar: context.calendar)
        let args: [String: Any] = ["recipe": ["title": "鸡蛋", "ingredients": [["item": "鸡蛋"], ["item": "鸡蛋"]], "steps": ["煮熟"]]]
        guard case .appendBlock(.error) = interpret("present_recipe_card", args, context: c) else { return XCTFail("Must reject a partial snapshot") }
    }
    func testTransientProposalDecodesContentWithoutCallerRecipeSnapshot() {
        let c = AIConversationInterpretationContext(blockID: id, rowIDs: [], recipesByPath: [:],
            transientIdentitiesByPath: ["recipe": .init(blockID: rowID, recipeID: "generated")], calendar: context.calendar)
        let args: [String: Any] = ["recipe": ["title": "鸡蛋", "ingredients": [["item": "鸡蛋"]], "steps": ["煮熟"]]]
        guard case .proposeAction(.addRecipeToTonight(let result)) = interpret("propose_add_recipe_to_tonight", args, context: c) else { return XCTFail() }
        XCTAssertTrue(result.isTransient); XCTAssertEqual(result.recipe.id, "generated"); XCTAssertEqual(result.id, rowID)
        XCTAssertEqual(result.recipe.ingredients, ["鸡蛋"]); XCTAssertEqual(result.recipe.steps, ["煮熟"])
    }

}

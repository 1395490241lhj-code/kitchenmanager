import XCTest
@testable import KitchenManager

/// The real scenarios prepared components exist for: a batch made at the
/// weekend doing the work a raw ingredient cannot.
@MainActor
final class QuickMealPreparedIntegrationTests: XCTestCase {
    private func item(_ name: String, expiringInDays days: Int? = nil) -> InventoryItem {
        InventoryItem(
            name: name,
            quantity: 1,
            unit: "份",
            expiryDate: days.map { Calendar.current.date(byAdding: .day, value: $0, to: Date())! },
            createdAt: Date()
        )
    }

    private func batch(
        _ name: String,
        _ state: PreparedComponentState,
        portions: Int = 3,
        expiringInDays days: Int = 3
    ) -> PreparedComponent {
        PreparedComponent(
            name: name,
            portionsRemaining: portions,
            state: state,
            storage: .refrigerated,
            preparedAt: Date(),
            expiryDate: Calendar.current.date(byAdding: .day, value: days, to: Date())!
        )
    }

    private func names(_ suggestion: QuickMealSuggestion) -> [String] {
        suggestion.components.map(\.name)
    }

    // MARK: - The headline scenario

    func testACookedBatchTurnsPlainStaplesIntoAMeal() {
        let result = QuickMealAssemblyEngine.assemble(
            inventory: [item("米饭"), item("上海青")],
            preparedComponents: [batch("卤牛肉", .cooked, portions: 3)]
        )

        let bowl = try? XCTUnwrap(result.suggestions.first { $0.template == .riceBowl })
        XCTAssertNotNil(bowl)
        XCTAssertEqual(bowl?.displayTitle, "牛肉青菜饭")
        XCTAssertEqual(Set(names(bowl!)), ["米饭", "卤牛肉", "上海青"])
    }

    func testWithoutTheBatchTheSameStaplesCannotMakeThatMeal() {
        // The batch is doing real work here, not decorating an existing result.
        let result = QuickMealAssemblyEngine.assemble(inventory: [item("米饭"), item("上海青")])
        XCTAssertFalse(result.suggestions.contains { $0.template == .riceBowl })
    }

    func testAPreppedBatchFollowsTheExistingPreppedEffortRule() {
        let result = QuickMealAssemblyEngine.assemble(
            inventory: [item("已熟米饭"), item("西兰花")],
            preparedComponents: [batch("腌鸡肉", .prepped)]
        )

        let bowl = try? XCTUnwrap(result.suggestions.first { $0.template == .riceBowl })
        XCTAssertEqual(bowl?.displayTitle, "鸡肉西兰花饭")
        XCTAssertEqual(
            bowl?.effort,
            .simpleCook,
            "the chicken needs a pan; that is the P0-3C rule, not a new one"
        )
    }

    func testANamelessPreppedBatchIsStillTreatedAsPrepped() {
        // 鸡肉 carries no 腌; only the stored state says it still needs cooking.
        let result = QuickMealAssemblyEngine.assemble(
            inventory: [item("米饭")],
            preparedComponents: [batch("鸡肉", .prepped)]
        )

        let bowl = try? XCTUnwrap(result.suggestions.first)
        XCTAssertEqual(bowl?.effort, .simpleCook)
        XCTAssertNotEqual(bowl?.effort, .readyToAssemble, "a prepped batch is never just plating up")
    }

    func testACookedBatchOfTheSameFoodIsReadyToAssemble() {
        let result = QuickMealAssemblyEngine.assemble(
            inventory: [item("米饭")],
            preparedComponents: [batch("鸡肉", .cooked)]
        )
        XCTAssertEqual(result.suggestions.first?.effort, .readyToAssemble)
    }

    // MARK: - Ranking comes from the existing rules

    func testABetterKnownStateImprovesTheExistingEffortRuleRatherThanAddingABonus() {
        let cooked = QuickMealAssemblyEngine.assemble(
            inventory: [item("米饭")], preparedComponents: [batch("鸡肉", .cooked)]
        )
        let prepped = QuickMealAssemblyEngine.assemble(
            inventory: [item("米饭")], preparedComponents: [batch("鸡肉", .prepped)]
        )

        // Same two components either way; only the preparation axis differs, and
        // the existing ladder reads it. No "prepared bonus" was added — a cooked
        // batch simply also satisfies the ready-made slot, which is why the
        // template it lands in differs too.
        XCTAssertEqual(Set(names(cooked.suggestions.first!)), Set(names(prepped.suggestions.first!)))
        XCTAssertLessThan(cooked.suggestions.first!.effort, prepped.suggestions.first!.effort)
        XCTAssertEqual(cooked.suggestions.first?.effort, .readyToAssemble)
        XCTAssertEqual(prepped.suggestions.first?.effort, .simpleCook)
    }

    func testAnExpiringBatchGetsTheExistingUrgencyPriority() {
        let soon = batch("卤牛肉", .cooked, expiringInDays: 1)
        let later = batch("卤鸡腿", .cooked, expiringInDays: 20)
        let result = QuickMealAssemblyEngine.assemble(
            inventory: [item("米饭")],
            preparedComponents: [later, soon]
        )

        let bowl = try? XCTUnwrap(result.suggestions.first)
        XCTAssertTrue(
            names(bowl!).contains("卤牛肉"),
            "the batch that needs using up is the one picked for the slot"
        )
        XCTAssertEqual(bowl?.urgencyScore, 1)
    }

    // MARK: - The two domains stay apart

    func testRawStockAndACookedBatchOfTheSameFoodCoexistWithoutMerging() {
        let raw = item("鸡腿")
        let prepared = batch("卤鸡腿", .cooked)
        let result = QuickMealAssemblyEngine.assemble(
            inventory: [raw, item("米饭")],
            preparedComponents: [prepared]
        )

        let bowl = try? XCTUnwrap(result.suggestions.first)
        XCTAssertNotNil(bowl)
        // Both records exist and neither was merged into the other. One slot
        // takes one candidate, so the cooked batch fills the non-staple slot and
        // the raw chicken is simply not part of this meal — it is still in the
        // kitchen, untouched.
        let nonStaple = bowl!.components.filter { $0.slot != .carb }
        XCTAssertEqual(nonStaple.map(\.source), [.preparedComponent(prepared.id)])
        XCTAssertFalse(names(bowl!).contains("鸡腿"))
        XCTAssertTrue(result.suggestions.allSatisfy { !names($0).contains("鸡腿") })
    }

    func testTheEngineNeverWritesToEitherDomain() {
        var inventory = [item("米饭"), item("上海青")]
        var prepared = [batch("卤牛肉", .cooked, portions: 3)]
        let inventoryBefore = inventory
        let preparedBefore = prepared

        _ = QuickMealAssemblyEngine.assemble(inventory: inventory, preparedComponents: prepared)

        XCTAssertEqual(inventory, inventoryBefore)
        XCTAssertEqual(prepared, preparedBefore)
        XCTAssertEqual(prepared.first?.portionsRemaining, 3, "assembling is not consuming")
        inventory = []
        prepared = []
    }

    func testProvenanceSurvivesAllTheWayToTheSuggestion() {
        let rice = item("米饭")
        let greens = item("上海青")
        let beef = batch("卤牛肉", .cooked)
        let result = QuickMealAssemblyEngine.assemble(
            inventory: [rice, greens],
            preparedComponents: [beef]
        )

        let bowl = try? XCTUnwrap(result.suggestions.first { $0.template == .riceBowl })
        XCTAssertEqual(
            Set(bowl!.components.map(\.source)),
            [.inventory(rice.id), .inventory(greens.id), .preparedComponent(beef.id)]
        )
    }

    // MARK: - Batches coming and going

    func testARemovedBatchSimplyStopsAppearing() {
        let beef = batch("卤牛肉", .cooked, portions: 1)
        let inventory = [item("米饭"), item("上海青")]

        let withBatch = QuickMealAssemblyEngine.assemble(inventory: inventory, preparedComponents: [beef])
        XCTAssertTrue(withBatch.suggestions.contains { $0.template == .riceBowl })

        // Eating the last portion deletes the record (P1-B); nothing else is needed.
        let afterEating = QuickMealAssemblyEngine.assemble(inventory: inventory, preparedComponents: [])
        XCTAssertFalse(afterEating.suggestions.contains { $0.template == .riceBowl })
    }

    func testAKitchenWithOnlyBatchesAndNoStapleReportsTheMissingCarb() {
        let result = QuickMealAssemblyEngine.assemble(
            inventory: [],
            preparedComponents: [batch("卤牛肉", .cooked)]
        )
        XCTAssertTrue(result.suggestions.isEmpty)
        XCTAssertEqual(result.gaps, [.missingCarb])
    }

    // MARK: - Backwards compatibility

    func testOmittingPreparedComponentsReproducesTheP0Behaviour() {
        let inventory = [item("挂面"), item("卤牛肉"), item("上海青")]
        let withoutArgument = QuickMealAssemblyEngine.assemble(inventory: inventory)
        let withEmptyArgument = QuickMealAssemblyEngine.assemble(inventory: inventory, preparedComponents: [])

        XCTAssertEqual(withoutArgument.suggestions.map(\.template), withEmptyArgument.suggestions.map(\.template))
        XCTAssertEqual(withoutArgument.suggestions.first?.displayTitle, "牛肉青菜面")
    }

    func testOrderingStillDoesNotDependOnInputOrder() {
        let inventory = [item("米饭"), item("上海青")]
        let batches = [batch("卤牛肉", .cooked), batch("腌鸡肉", .prepped)]

        let forward = QuickMealAssemblyEngine.assemble(inventory: inventory, preparedComponents: batches)
        let reversed = QuickMealAssemblyEngine.assemble(
            inventory: inventory.reversed(),
            preparedComponents: batches.reversed()
        )

        XCTAssertEqual(forward.suggestions.map(\.template), reversed.suggestions.map(\.template))
        XCTAssertEqual(
            forward.suggestions.map(\.displayTitle),
            reversed.suggestions.map(\.displayTitle)
        )
    }
}

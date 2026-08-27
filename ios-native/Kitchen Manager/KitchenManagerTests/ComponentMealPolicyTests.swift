import XCTest
@testable import KitchenManager

/// The weekday plate: 主食 + 蛋白 + 蔬菜, and nothing counted twice.
@MainActor
final class ComponentMealPolicyTests: XCTestCase {
    private func item(_ name: String, expiringInDays days: Int? = nil, quantity: Double = 1) -> InventoryItem {
        InventoryItem(
            name: name,
            quantity: quantity,
            unit: "份",
            expiryDate: days.map { Calendar.current.date(byAdding: .day, value: $0, to: Date())! },
            createdAt: Date()
        )
    }

    private func batch(
        _ name: String,
        _ state: PreparedComponentState = .cooked,
        portions: Int = 3,
        expiringInDays days: Int = 10
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

    private func assemble(
        _ inventory: [InventoryItem],
        _ prepared: [PreparedComponent] = []
    ) -> ComponentMealResult {
        ComponentMealPolicy.assemble(inventory: inventory, preparedComponents: prepared)
    }

    private func names(_ result: ComponentMealResult) -> [String] {
        result.suggestion?.components.map(\.name) ?? []
    }

    // MARK: - The headline scenario

    func testTheWeekdayPlateStandsUp() {
        let result = assemble([item("红薯"), item("西兰花")], [batch("卤鸡腿")])

        let suggestion = try? XCTUnwrap(result.suggestion)
        XCTAssertEqual(suggestion?.carb.name, "红薯")
        XCTAssertEqual(suggestion?.protein.name, "卤鸡腿")
        XCTAssertEqual(suggestion?.vegetable.name, "西兰花")
        XCTAssertEqual(suggestion?.componentsText, "红薯 · 卤鸡腿 · 西兰花")
        XCTAssertTrue(result.gaps.isEmpty)
    }

    func testAllThreePartsAreRequired() {
        // Each kitchen is one part short, and the gap names the missing part.
        XCTAssertEqual(assemble([item("卤牛肉"), item("上海青")]).gaps, [.missingCarb])
        XCTAssertEqual(assemble([item("米饭"), item("上海青")]).gaps, [.missingProtein])
        XCTAssertEqual(assemble([item("米饭"), item("卤牛肉")]).gaps, [.missingVegetable])
        XCTAssertNil(assemble([item("米饭"), item("卤牛肉")]).suggestion)
    }

    func testTwoPartsMissingAreBothReported() {
        XCTAssertEqual(assemble([item("米饭")]).gaps, [.missingProtein, .missingVegetable])
    }

    func testAKitchenWithNothingUsableSaysSo() {
        XCTAssertEqual(assemble([]).gaps, [.nothingUsable])
        XCTAssertEqual(assemble([item("盐"), item("生抽")]).gaps, [.nothingUsable])
    }

    func testItNeverReusesQuickMealsNothingQuickEnoughVocabulary() {
        // The gap enum is its own; this policy never judged how much work
        // anything is, so it has no way to say "not quick enough".
        for gap in [ComponentMealGap.nothingUsable, .missingCarb, .missingProtein, .missingVegetable] {
            XCTAssertFalse(gap.sheetMessage.isEmpty)
        }
        XCTAssertEqual(ComponentMealGap.missingCarb.sheetMessage, "差一样主食")
        XCTAssertEqual(ComponentMealGap.missingProtein.sheetMessage, "差一样蛋白")
        XCTAssertEqual(ComponentMealGap.missingVegetable.sheetMessage, "差一样蔬菜")
    }

    // MARK: - One record, one slot

    func testCornCannotFillBothTheStapleAndTheVegetableSlot() {
        // 玉米 carries both roles. One cob beside a chicken thigh is two things
        // on a plate, not three.
        let result = assemble([item("玉米")], [batch("卤鸡腿")])

        XCTAssertNil(result.suggestion)
        XCTAssertEqual(result.gaps, [.missingVegetable])
    }

    func testASweetPotatoCannotFillBothSlotsEither() {
        let result = assemble([item("红薯")], [batch("卤鸡腿")])

        XCTAssertNil(result.suggestion)
        XCTAssertEqual(result.gaps, [.missingVegetable])
    }

    func testADoubleRoleStapleStillLeavesRoomForADifferentVegetable() {
        let result = assemble([item("红薯"), item("西兰花")], [batch("卤鸡腿")])
        XCTAssertEqual(names(result).count, 3)
        XCTAssertEqual(Set(names(result)).count, 3, "three distinct records")
    }

    func testTwoDoubleRoleStaplesCanFillBothSlotsBecauseTheyAreTwoRecords() {
        // 红薯 as the base, 玉米 as the vegetable: different records, so this is
        // a real three-part plate.
        let result = assemble([item("红薯"), item("玉米")], [batch("卤鸡腿")])

        let suggestion = try? XCTUnwrap(result.suggestion)
        XCTAssertEqual(suggestion?.carb.name, "红薯", "tuber outranks corn for the base")
        XCTAssertEqual(suggestion?.vegetable.name, "玉米")
        XCTAssertNotEqual(suggestion?.carb.source, suggestion?.vegetable.source)
    }

    func testEverySlotHoldsADistinctSource() {
        let result = assemble([item("米饭"), item("上海青")], [batch("卤牛肉")])
        let sources = result.suggestion?.componentSources ?? []
        XCTAssertEqual(Set(sources).count, sources.count)
    }

    // MARK: - Which staples count

    func testCornIsAcceptedAsAStaple() {
        let result = assemble([item("玉米"), item("上海青")], [batch("卤鸡腿")])
        XCTAssertEqual(result.suggestion?.carb.name, "玉米")
    }

    func testNoodlesAreNotAComponentMealStaple() {
        let result = assemble([item("挂面"), item("上海青")], [batch("卤鸡腿")])

        XCTAssertNil(result.suggestion, "a bowl of noodles is a whole meal, not a plate")
        XCTAssertEqual(result.gaps, [.missingCarb])
    }

    func testRiceNoodlesAreNotAComponentMealStapleEither() {
        XCTAssertEqual(
            assemble([item("米粉"), item("上海青")], [batch("卤鸡腿")]).gaps,
            [.missingCarb]
        )
    }

    func testDumplingsNeitherBaseAPlateNorTopOne() {
        let result = assemble([item("冷冻饺子"), item("米饭"), item("上海青")])

        // The dumplings carry both a carb and a protein role, but they are a
        // dinner in their own right and must not stand in for either.
        XCTAssertNil(result.suggestion)
        XCTAssertEqual(result.gaps, [.missingProtein])
    }

    func testFlourIsNotAStaple() {
        XCTAssertEqual(
            assemble([item("面粉"), item("上海青"), item("卤牛肉")]).gaps,
            [.missingCarb]
        )
    }

    func testRiceAndBreadBothCountAndRiceComesFirst() {
        let result = assemble([item("馒头"), item("米饭"), item("上海青")], [batch("卤鸡腿")])
        XCTAssertEqual(result.suggestion?.carb.name, "米饭")

        let breadOnly = assemble([item("馒头"), item("上海青")], [batch("卤鸡腿")])
        XCTAssertEqual(breadOnly.suggestion?.carb.name, "馒头")
    }

    func testARawStapleIsFineHereUnlikeQuickMeal() {
        // Quick Meal requires a cooked base; a raw sweet potato is an ordinary
        // weekday base and this policy makes no claim about how long it takes.
        let result = assemble([item("红薯"), item("上海青")], [batch("卤鸡腿")])
        XCTAssertEqual(result.suggestion?.carb.name, "红薯")
        XCTAssertEqual(result.suggestion?.carb.profile.preparationState, .raw)
    }

    // MARK: - Choosing the protein

    func testAPreparedBatchWinsOverRawStockAtEqualUrgency() {
        let result = assemble(
            [item("米饭"), item("上海青"), item("鸡腿")],
            [batch("卤牛肉")]
        )
        XCTAssertEqual(result.suggestion?.protein.name, "卤牛肉")
    }

    func testRawStockThatTurnsSoonerBeatsABatchThatKeeps() {
        // Using something up outranks provenance.
        let result = assemble(
            [item("米饭"), item("上海青"), item("鸡腿", expiringInDays: 1)],
            [batch("卤牛肉", expiringInDays: 20)]
        )
        XCTAssertEqual(result.suggestion?.protein.name, "鸡腿")
    }

    func testBetweenTwoBatchesTheCookedOneComesFirst() {
        let result = assemble(
            [item("米饭"), item("上海青")],
            [batch("腌鸡肉", .prepped), batch("卤牛肉", .cooked)]
        )
        XCTAssertEqual(result.suggestion?.protein.name, "卤牛肉")
    }

    func testAStoredPreppedStateIsUsedRatherThanTheName() {
        // 鸡肉 carries no 腌 / 卤 hint; only the record says it still needs a pan.
        let prepped = assemble([item("米饭"), item("上海青")], [batch("鸡肉", .prepped)])
        XCTAssertEqual(prepped.suggestion?.protein.profile.preparationState, .prepped)

        let cooked = assemble([item("米饭"), item("上海青")], [batch("鸡肉", .cooked)])
        XCTAssertEqual(cooked.suggestion?.protein.profile.preparationState, .cooked)
    }

    func testRawStockOutranksNothingWhenItIsAllThereIs() {
        let result = assemble([item("米饭"), item("上海青"), item("鸡腿")])
        XCTAssertEqual(result.suggestion?.protein.name, "鸡腿")
    }

    // MARK: - Unclassified batches

    func testABatchWhoseNameMeansNothingProducesNoPlate() {
        // No guessing: a name that places nowhere stays nowhere, rather than
        // standing in as a generic protein.
        let result = assemble([item("米饭"), item("上海青")], [batch("周日备的那份")])

        XCTAssertNil(result.suggestion)
        XCTAssertEqual(result.gaps, [.missingProtein])
    }

    func testAnUnclassifiedBatchDoesNotDisplaceAUsableOne() {
        let result = assemble(
            [item("米饭"), item("上海青")],
            [batch("周日备的那份"), batch("卤牛肉")]
        )
        XCTAssertEqual(result.suggestion?.protein.name, "卤牛肉")
    }

    // MARK: - Urgency and stability

    func testTheVegetableThatTurnsSoonestIsChosen() {
        let result = assemble(
            [item("米饭"), item("上海青", expiringInDays: 10), item("西兰花", expiringInDays: 1)],
            [batch("卤牛肉")]
        )
        XCTAssertEqual(result.suggestion?.vegetable.name, "西兰花")
    }

    func testTheResultDoesNotDependOnInputOrder() {
        let inventory = [item("米饭"), item("红薯"), item("上海青"), item("西兰花"), item("鸡腿")]
        let batches = [batch("卤牛肉"), batch("腌鸡肉", .prepped)]

        let forward = ComponentMealPolicy.assemble(inventory: inventory, preparedComponents: batches)
        let reversed = ComponentMealPolicy.assemble(
            inventory: inventory.reversed(),
            preparedComponents: batches.reversed()
        )

        XCTAssertEqual(names(forward), names(reversed))
        XCTAssertFalse(names(forward).isEmpty)
    }

    func testDepletedInventoryIsNotOffered() {
        var empty = item("上海青")
        empty.quantity = 0
        XCTAssertEqual(
            assemble([item("米饭"), empty], [batch("卤牛肉")]).gaps,
            [.missingVegetable]
        )
    }

    // MARK: - It writes nothing

    func testAssemblingChangesNeitherDomain() {
        let inventory = [item("红薯"), item("西兰花")]
        let prepared = [batch("卤鸡腿", portions: 3)]
        let inventoryBefore = inventory
        let preparedBefore = prepared

        _ = ComponentMealPolicy.assemble(inventory: inventory, preparedComponents: prepared)

        XCTAssertEqual(inventory, inventoryBefore)
        XCTAssertEqual(prepared, preparedBefore)
        XCTAssertEqual(prepared.first?.portionsRemaining, 3, "assembling is not eating")
    }

    func testNoEffortOrTimingIsProduced() {
        // The suggestion exposes only what it is made of. If a tier or a number
        // of minutes ever appears here, this test stops compiling — which is the
        // point.
        let suggestion = assemble([item("红薯"), item("西兰花")], [batch("卤鸡腿")]).suggestion
        let mirror = Mirror(reflecting: try! XCTUnwrap(suggestion))
        XCTAssertEqual(mirror.children.compactMap(\.label).sorted(), ["carb", "protein", "vegetable"])
    }
}

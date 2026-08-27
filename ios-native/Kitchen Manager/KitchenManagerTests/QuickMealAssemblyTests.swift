import XCTest
@testable import KitchenManager

final class QuickFoodProfileClassifierTests: XCTestCase {
    private func profile(_ name: String) -> QuickFoodProfile {
        QuickFoodProfileClassifier.profile(for: name)
    }

    // MARK: - The pinned cases
    //
    // These are the exact examples the three-axis model exists for: each one
    // carries facts that a single mutually-exclusive role enum would have to
    // throw away.

    func testCookedProteinKeepsBothItsRoleAndItsPreparation() {
        let braisedBeef = profile("卤牛肉")
        XCTAssertEqual(braisedBeef.roles, [.protein])
        XCTAssertEqual(braisedBeef.preparationState, .cooked)
    }

    func testMarinatedProteinIsPreppedNotCooked() {
        let marinatedChicken = profile("腌鸡肉")
        XCTAssertEqual(marinatedChicken.roles, [.protein])
        XCTAssertEqual(marinatedChicken.preparationState, .prepped)
    }

    func testCookedRiceAndRawRiceShareRoleAndFormButNotPreparation() {
        let cooked = profile("米饭")
        let raw = profile("大米")

        XCTAssertEqual(cooked.roles, [.carb])
        XCTAssertEqual(cooked.form, .rice)
        XCTAssertEqual(cooked.preparationState, .cooked)

        XCTAssertEqual(raw.roles, [.carb])
        XCTAssertEqual(raw.form, .rice)
        XCTAssertEqual(raw.preparationState, .raw)

        // Same role, same form — only the preparation axis separates them, which
        // is precisely why it is a separate axis.
        XCTAssertEqual(cooked.roles, raw.roles)
        XCTAssertEqual(cooked.form, raw.form)
        XCTAssertNotEqual(cooked.preparationState, raw.preparationState)
    }

    func testNoodleAndRiceNoodleAreDistinctCarbForms() {
        let driedNoodle = profile("挂面")
        XCTAssertEqual(driedNoodle.roles, [.carb])
        XCTAssertEqual(driedNoodle.form, .noodle)

        let riceNoodle = profile("米粉")
        XCTAssertEqual(riceNoodle.roles, [.carb])
        XCTAssertEqual(riceNoodle.form, .riceNoodle, "米粉 must not be classified as rice")
    }

    func testFrozenDumplingIsConvenienceNotReadyToEat() {
        let dumpling = profile("冷冻饺子")
        XCTAssertEqual(dumpling.form, .dumpling)
        XCTAssertEqual(dumpling.preparationState, .convenience)
        XCTAssertNotEqual(dumpling.preparationState, .cooked, "a frozen dumpling still needs boiling")
    }

    // MARK: - Multiple dimensions at once

    func testOneItemCanHoldSeveralRolesRatherThanPickingOne() {
        let dumpling = profile("速冻饺子")
        XCTAssertTrue(dumpling.has(.carb))
        XCTAssertTrue(dumpling.has(.protein))

        let potato = profile("土豆")
        XCTAssertEqual(potato.roles, [.carb, .vegetable])
        XCTAssertEqual(potato.form, .tuber)
        XCTAssertEqual(potato.preparationState, .raw)
    }

    // MARK: - Ordering hazards

    func testSeasoningsAreNotMistakenForTheirNamesake() {
        XCTAssertEqual(profile("番茄酱").roles, [.seasoning])
        XCTAssertEqual(profile("牛肉酱").roles, [.seasoning])
        XCTAssertEqual(profile("生抽").roles, [.seasoning])
        // …while the real vegetable and the real protein still classify.
        XCTAssertTrue(profile("番茄").has(.vegetable))
        XCTAssertTrue(profile("牛肉").has(.protein))
    }

    func testPickledVegetablesAreReadyToEatRatherThanMarinatedProtein() {
        let pickle = profile("泡菜")
        XCTAssertEqual(pickle.roles, [.vegetable])
        XCTAssertEqual(pickle.preparationState, .cooked)
    }

    func testCornIsBothAStapleAndAVegetableAndNotSweptUpByTheRiceTerms() {
        let corn = profile("玉米")
        XCTAssertTrue(corn.has(.vegetable))
        XCTAssertTrue(corn.has(.carb), "a cob is an ordinary weekday staple")
        // The original point of this test still stands: 玉米 must not be rice.
        XCTAssertEqual(corn.form, .corn)
        XCTAssertNotEqual(corn.form, .rice)
    }

    func testCornOilIsASeasoningRatherThanAStaple() {
        // Added with the corn role: without it, a bottle of oil would inherit
        // 玉米's new carb role and could be offered as the base of a plate.
        let oil = profile("玉米油")
        XCTAssertEqual(oil.roles, [.seasoning])
        XCTAssertNil(oil.form)
    }

    func testFlourIsACarbButNotAnAssemblableForm() {
        let flour = profile("面粉")
        XCTAssertEqual(flour.roles, [.carb])
        XCTAssertNil(flour.form, "no quick meal starts from flour")
    }

    func testLeftoversAreAPreparedDishWithUnknownComposition() {
        let leftovers = profile("剩菜")
        XCTAssertEqual(leftovers.form, .preparedDish)
        XCTAssertEqual(leftovers.preparationState, .cooked)
        XCTAssertTrue(leftovers.roles.isEmpty, "剩菜 says nothing about what is in it")
    }

    func testUnknownItemsFallBackSafelyInsteadOfBeingForced() {
        let mystery = profile("神秘食材")
        XCTAssertTrue(mystery.isUnclassified)
        XCTAssertEqual(mystery.preparationState, .unknown)
        XCTAssertTrue(mystery.roles.isEmpty)
        XCTAssertNil(mystery.form)
    }
}

@MainActor
final class QuickMealAssemblyEngineTests: XCTestCase {
    private func item(_ name: String, expiringInDays days: Int? = nil) -> InventoryItem {
        InventoryItem(
            name: name,
            quantity: 1,
            unit: "份",
            expiryDate: days.map { Calendar.current.date(byAdding: .day, value: $0, to: Date())! },
            createdAt: Date()
        )
    }

    private func names(_ suggestion: QuickMealSuggestion) -> [String] {
        suggestion.components.map(\.name)
    }

    private func suggestion(
        _ result: QuickMealAssemblyResult,
        _ template: QuickMealTemplate
    ) -> QuickMealSuggestion? {
        result.suggestions.first { $0.template == template }
    }

    // MARK: - The pinned fixtures

    func testDriedNoodleWithBraisedBeefAndGreensAssemblesANoodleBowl() {
        let result = QuickMealAssemblyEngine.assemble(
            inventory: [item("挂面"), item("卤牛肉"), item("上海青")]
        )

        let bowl = try? XCTUnwrap(suggestion(result, .noodleBowl))
        XCTAssertNotNil(bowl)
        XCTAssertEqual(Set(names(bowl!)), ["挂面", "卤牛肉", "上海青"])
        XCTAssertEqual(bowl?.components.first?.slot, .carb)
    }

    func testRiceNoodleWithEggAndLettuceAssemblesANoodleBowl() {
        let result = QuickMealAssemblyEngine.assemble(
            inventory: [item("米粉"), item("鸡蛋"), item("生菜")]
        )

        let bowl = try? XCTUnwrap(suggestion(result, .noodleBowl))
        XCTAssertNotNil(bowl)
        XCTAssertEqual(Set(names(bowl!)), ["米粉", "鸡蛋", "生菜"])
    }

    func testCookedRiceWithMarinatedChickenAndBroccoliAssemblesARiceBowl() {
        let result = QuickMealAssemblyEngine.assemble(
            inventory: [item("已熟米饭"), item("腌鸡肉"), item("西兰花")]
        )

        let bowl = try? XCTUnwrap(suggestion(result, .riceBowl))
        XCTAssertNotNil(bowl)
        XCTAssertEqual(Set(names(bowl!)), ["已熟米饭", "腌鸡肉", "西兰花"])
    }

    func testRawRiceAndRawBeefIsNeverPresentedAsAReadyRiceBowl() {
        let result = QuickMealAssemblyEngine.assemble(
            inventory: [item("大米"), item("牛肉")]
        )

        XCTAssertTrue(result.suggestions.isEmpty, "raw rice plus raw beef is dinner, but not a quick one")
        XCTAssertEqual(result.gaps, [.nothingQuickEnough])
    }

    func testFrozenDumplingsAloneAreACompleteMeal() {
        let result = QuickMealAssemblyEngine.assemble(inventory: [item("冷冻饺子")])

        let bowl = try? XCTUnwrap(suggestion(result, .dumplingBowl))
        XCTAssertNotNil(bowl)
        XCTAssertEqual(names(bowl!), ["冷冻饺子"])
        XCTAssertEqual(bowl?.components.first?.slot, .main, "a dumpling is the meal, not just its staple")
        XCTAssertTrue(result.gaps.isEmpty)
    }

    func testFrozenDumplingsTakeAnOptionalVegetableWhenOneIsAround() {
        let result = QuickMealAssemblyEngine.assemble(inventory: [item("冷冻饺子"), item("上海青")])

        let bowl = try? XCTUnwrap(suggestion(result, .dumplingBowl))
        XCTAssertEqual(Set(names(bowl!)), ["冷冻饺子", "上海青"])
    }

    func testSeasoningsAloneNeverProduceAMeal() {
        let result = QuickMealAssemblyEngine.assemble(
            inventory: [item("盐"), item("生抽"), item("食用油")]
        )

        XCTAssertTrue(result.suggestions.isEmpty)
        XCTAssertEqual(result.gaps, [.nothingUsable])
    }

    func testUnclassifiedItemsAreSkippedRatherThanForcedIntoAMeal() {
        let result = QuickMealAssemblyEngine.assemble(inventory: [item("神秘食材"), item("某种粉末")])

        XCTAssertTrue(result.suggestions.isEmpty)
        XCTAssertEqual(result.gaps, [.nothingUsable])
    }

    // MARK: - Templates that do not need the full three-piece meal

    func testLeftoversPlusAQuickStapleStandUp() {
        let result = QuickMealAssemblyEngine.assemble(inventory: [item("剩菜"), item("米饭")])

        let plate = try? XCTUnwrap(suggestion(result, .preparedWithCarb))
        XCTAssertNotNil(plate)
        XCTAssertEqual(Set(names(plate!)), ["剩菜", "米饭"])
    }

    func testLeftoversWithOnlyRawRiceDoNotCount() {
        let result = QuickMealAssemblyEngine.assemble(inventory: [item("剩菜"), item("大米")])

        XCTAssertTrue(result.suggestions.isEmpty)
        XCTAssertEqual(result.gaps, [.nothingQuickEnough])
    }

    func testPreppedProteinWithBreadStandsUpWithoutAVegetable() {
        let result = QuickMealAssemblyEngine.assemble(inventory: [item("腌鸡肉"), item("馒头")])

        let plate = try? XCTUnwrap(suggestion(result, .preppedProteinWithCarb))
        XCTAssertNotNil(plate)
        XCTAssertEqual(Set(names(plate!)), ["腌鸡肉", "馒头"])
    }

    // MARK: - Gaps

    func testStapleOnlyReportsTheMissingCompanion() {
        let result = QuickMealAssemblyEngine.assemble(inventory: [item("挂面")])
        XCTAssertEqual(result.gaps, [.missingProteinOrVegetable])
    }

    func testCookedDishWithNoStapleReportsTheMissingCarb() {
        let result = QuickMealAssemblyEngine.assemble(inventory: [item("卤牛肉")])
        XCTAssertEqual(result.gaps, [.missingCarb])
    }

    func testGapsAreEmptyWheneverSomethingCouldBeAssembled() {
        let result = QuickMealAssemblyEngine.assemble(inventory: [item("挂面"), item("鸡蛋")])
        XCTAssertFalse(result.suggestions.isEmpty)
        XCTAssertTrue(result.gaps.isEmpty)
    }

    // MARK: - The prepared-with-carb boundary

    func testDriedNoodlesAreNotAMealBaseForAFinishedDish() {
        let result = QuickMealAssemblyEngine.assemble(
            inventory: [item("挂面"), item("卤牛肉"), item("上海青")]
        )

        XCTAssertNil(
            suggestion(result, .preparedWithCarb),
            "挂面 still needs boiling, so 卤牛肉 + 挂面 is a noodle bowl and nothing else"
        )
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.template, .noodleBowl)
    }

    func testRawRiceIsNotAMealBaseEither() {
        let result = QuickMealAssemblyEngine.assemble(inventory: [item("卤牛肉"), item("大米")])

        XCTAssertNil(suggestion(result, .preparedWithCarb))
        XCTAssertTrue(result.suggestions.isEmpty)
        XCTAssertEqual(result.gaps, [.nothingQuickEnough])
    }

    func testCookedRiceAndBreadAreMealBases() {
        for base in ["米饭", "馒头"] {
            let result = QuickMealAssemblyEngine.assemble(inventory: [item("卤牛肉"), item(base)])
            XCTAssertNotNil(
                suggestion(result, .preparedWithCarb),
                "\(base) is already cooked, so it can carry a finished dish"
            )
        }
    }

    func testAFinishedDishOverFreshlyBoiledNoodlesIsStillANoodleBowl() {
        let result = QuickMealAssemblyEngine.assemble(inventory: [item("剩菜"), item("挂面")])

        let bowl = try? XCTUnwrap(suggestion(result, .noodleBowl))
        XCTAssertNotNil(bowl, "tightening preparedWithCarb must not drop this meal entirely")
        XCTAssertEqual(Set(names(bowl!)), ["剩菜", "挂面"])
        XCTAssertNil(suggestion(result, .preparedWithCarb))
    }

    // MARK: - Effort tiers

    func testEffortIsDerivedFromTheComponentsThatWereActuallyChosen() {
        // Everything already cooked — nothing left but the plate.
        let assembled = QuickMealAssemblyEngine.assemble(inventory: [item("米饭"), item("卤牛肉")])
        XCTAssertEqual(assembled.suggestions.first?.effort, .readyToAssemble)

        // The very same template, plus raw greens: no longer "just plate it up".
        let withGreens = QuickMealAssemblyEngine.assemble(
            inventory: [item("米饭"), item("卤牛肉"), item("上海青")]
        )
        let riceWithGreens = try? XCTUnwrap(suggestion(withGreens, .riceBowl))
        XCTAssertEqual(riceWithGreens?.effort, .minimalCook)
        XCTAssertNotEqual(riceWithGreens?.effort, .readyToAssemble, "raw greens still need dealing with")

        let boiled = QuickMealAssemblyEngine.assemble(inventory: [item("冷冻饺子")])
        XCTAssertEqual(boiled.suggestions.first?.effort, .minimalCook)

        let panRequired = QuickMealAssemblyEngine.assemble(inventory: [item("米饭"), item("腌鸡肉")])
        XCTAssertEqual(panRequired.suggestions.first?.effort, .simpleCook)

        let ordinary = QuickMealAssemblyEngine.assemble(inventory: [item("挂面"), item("鸡蛋")])
        XCTAssertEqual(ordinary.suggestions.first?.effort, .standardQuick)
    }

    func testCookedRiceWithPreppedChickenAndRawBroccoliIsNeverReadyToAssemble() {
        let result = QuickMealAssemblyEngine.assemble(
            inventory: [item("已熟米饭"), item("腌鸡肉"), item("西兰花")]
        )

        let bowl = try? XCTUnwrap(suggestion(result, .riceBowl))
        XCTAssertNotEqual(bowl?.effort, .readyToAssemble)
        XCTAssertEqual(bowl?.effort, .simpleCook, "the chicken needs a pan; the broccoli rides along in it")
    }

    func testGreensBlanchedAlongsideDumplingsStayLowEffortByRule() {
        let alone = QuickMealAssemblyEngine.assemble(inventory: [item("冷冻饺子")])
        let withGreens = QuickMealAssemblyEngine.assemble(inventory: [item("冷冻饺子"), item("上海青")])

        XCTAssertEqual(alone.suggestions.first?.effort, .minimalCook)
        XCTAssertEqual(
            withGreens.suggestions.first?.effort,
            .minimalCook,
            "greens go into the pot that is already boiling — an explicit rule, not a coincidence"
        )
    }

    func testAVegetableThatNeedsItsOwnPanRaisesTheTier() {
        // 土豆 cannot be blanched alongside; it is real cooking.
        let result = QuickMealAssemblyEngine.assemble(
            inventory: [item("米饭"), item("卤牛肉"), item("土豆")]
        )
        let bowl = try? XCTUnwrap(suggestion(result, .riceBowl))
        XCTAssertEqual(bowl?.effort, .simpleCook)
    }

    func testAnExpiringVegetableIsKeptEvenThoughItRaisesTheTier() {
        let result = QuickMealAssemblyEngine.assemble(
            inventory: [item("米饭"), item("卤牛肉"), item("上海青", expiringInDays: 1)]
        )

        let bowl = try? XCTUnwrap(suggestion(result, .riceBowl))
        XCTAssertTrue(names(bowl!).contains("上海青"), "never drop food that needs using up just to look easier")
        XCTAssertEqual(bowl?.effort, .minimalCook)
        XCTAssertEqual(bowl?.displayTitle, "牛肉青菜饭")
    }

    func testAThreeComponentPlateIsNotRankedBelowATwoComponentOneJustForHavingMoreParts() {
        let withVegetable = QuickMealAssemblyEngine.assemble(
            inventory: [item("米饭"), item("卤牛肉"), item("上海青")]
        )
        let withoutVegetable = QuickMealAssemblyEngine.assemble(
            inventory: [item("米饭"), item("卤牛肉")]
        )

        let richer = try? XCTUnwrap(suggestion(withVegetable, .riceBowl))
        XCTAssertEqual(richer?.components.count, 3)
        XCTAssertLessThanOrEqual(
            richer!.effort.rawValue,
            QuickMealEffort.simpleCook.rawValue,
            "an extra vegetable may raise the tier by one step, but must not be treated as a whole extra dish"
        )
        XCTAssertFalse(withoutVegetable.suggestions.isEmpty)
    }

    func testASingleConvenienceItemStaysVisibleInAFullFridge() {
        let result = QuickMealAssemblyEngine.assemble(inventory: [
            item("挂面"), item("米饭"), item("冷冻饺子"), item("卤牛肉"),
            item("腌鸡肉"), item("鸡蛋"), item("上海青", expiringInDays: 1),
            item("土豆"), item("生抽")
        ])

        XCTAssertTrue(
            result.suggestions.contains { $0.template == .dumplingBowl },
            "one dumpling packet must not be crowded out by meals that merely have more parts"
        )
    }

    func testLeanerOptionSurvivesOnlyWhenItIsGenuinelyLessWork() {
        let result = QuickMealAssemblyEngine.assemble(
            inventory: [item("米饭"), item("卤牛肉"), item("上海青")]
        )

        // Eating the beef with rice needs no cooking at all; adding the greens
        // means a pot. Both are worth offering, and the easier one leads.
        XCTAssertEqual(result.suggestions.count, 2)
        XCTAssertEqual(result.suggestions[0].effort, .readyToAssemble)
        XCTAssertEqual(Set(names(result.suggestions[0])), ["米饭", "卤牛肉"])
        XCTAssertEqual(result.suggestions[1].effort, .minimalCook)
        XCTAssertEqual(Set(names(result.suggestions[1])), ["米饭", "卤牛肉", "上海青"])
    }

    func testAnEqualEffortSubsetIsStillCollapsedAway() {
        // Without the greens there is no effort difference to justify two
        // descriptions of the same two items.
        let result = QuickMealAssemblyEngine.assemble(inventory: [item("米饭"), item("卤牛肉")])
        XCTAssertEqual(result.suggestions.count, 1)
    }

    func testAPacketOfDumplingsIsNeverUsedAsSomeoneElsesTopping() {
        let result = QuickMealAssemblyEngine.assemble(
            inventory: [item("冷冻饺子"), item("挂面"), item("鸡蛋")]
        )

        let noodles = try? XCTUnwrap(suggestion(result, .noodleBowl))
        XCTAssertFalse(
            names(noodles!).contains("冷冻饺子"),
            "dumplings are a whole dinner, not a garnish for noodles"
        )
        XCTAssertTrue(result.suggestions.contains { $0.template == .dumplingBowl })
    }

    // MARK: - Display titles

    func testTitlesReadLikeSomethingAPersonWouldOrder() {
        let cases: [([InventoryItem], String)] = [
            ([item("挂面"), item("卤牛肉"), item("上海青")], "牛肉青菜面"),
            ([item("米粉"), item("鸡蛋"), item("生菜")], "鸡蛋生菜米粉"),
            ([item("米饭"), item("腌鸡肉"), item("西兰花")], "鸡肉西兰花饭"),
            ([item("冷冻饺子")], "煮饺子"),
            ([item("米饭"), item("剩菜")], "剩菜配饭")
        ]
        for (inventory, expected) in cases {
            let result = QuickMealAssemblyEngine.assemble(inventory: inventory)
            XCTAssertEqual(result.suggestions.first?.displayTitle, expected)
        }
    }

    func testTitleNeverExposesTheInternalTemplateNameWhenItCanCompose() {
        let result = QuickMealAssemblyEngine.assemble(inventory: [item("挂面"), item("鸡蛋")])
        XCTAssertEqual(result.suggestions.first?.displayTitle, "鸡蛋面")
        XCTAssertNotEqual(result.suggestions.first?.displayTitle, QuickMealTemplate.noodleBowl.title)
    }

    func testLongButNaturalCompositionsAreStillComposed() {
        let result = QuickMealAssemblyEngine.assemble(inventory: [item("挂面"), item("香菇鸡肉丸子")])
        XCTAssertEqual(result.suggestions.first?.displayTitle, "香菇鸡肉丸子面")
    }

    func testAnUnwieldyCompositionFallsBackToThePlainTemplateName() {
        let long = QuickMealAssemblyEngine.assemble(inventory: [
            item("挂面"), item("手工香菇鸡肉丸子"), item("金针菇")
        ])
        XCTAssertEqual(
            long.suggestions.first?.displayTitle,
            QuickMealTemplate.noodleBowl.title,
            "an unwieldy composition should read as the plain template name, not as an inventory list"
        )
    }

    func testAShortNameIsNeverStrippedDownToASingleCharacter() {
        let result = QuickMealAssemblyEngine.assemble(inventory: [item("挂面"), item("鸡蛋"), item("腌菜")])
        XCTAssertEqual(result.suggestions.first?.displayTitle, "鸡蛋腌菜面")
    }

    func testATitleNamesEveryComponentItActuallyUses() {
        let withVegetable = QuickMealAssemblyEngine.assemble(
            inventory: [item("腌鸡肉"), item("米饭"), item("上海青")]
        )
        XCTAssertEqual(withVegetable.suggestions.first?.displayTitle, "鸡肉青菜饭")

        let withoutVegetable = QuickMealAssemblyEngine.assemble(inventory: [item("腌鸡肉"), item("馒头")])
        XCTAssertEqual(withoutVegetable.suggestions.first?.displayTitle, "鸡肉配馒头")
    }

    func testWontonGetsItsOwnTitle() {
        let result = QuickMealAssemblyEngine.assemble(inventory: [item("速冻馄饨")])
        XCTAssertEqual(result.suggestions.first?.displayTitle, "煮馄饨")
    }

    // MARK: - Ordering

    func testExpiringComponentsAreUsedBeforeFreshOnesInTheSameSlot() {
        let result = QuickMealAssemblyEngine.assemble(
            inventory: [item("挂面"), item("鸡蛋"), item("上海青", expiringInDays: 8), item("菠菜", expiringInDays: 1)]
        )

        let bowl = try? XCTUnwrap(suggestion(result, .noodleBowl))
        XCTAssertTrue(names(bowl!).contains("菠菜"), "the greens about to expire should be the ones used")
        XCTAssertFalse(names(bowl!).contains("上海青"))
    }

    func testLowerEffortMealsRankAboveOnesThatNeedMoreHandling() {
        let result = QuickMealAssemblyEngine.assemble(
            inventory: [item("冷冻饺子"), item("挂面"), item("鸡蛋")]
        )

        XCTAssertEqual(result.suggestions.first?.template, .dumplingBowl)
    }

    func testOrderingDoesNotDependOnInventoryOrder() {
        let forward = [item("挂面"), item("卤牛肉"), item("上海青")]
        let reversed = Array(forward.reversed())

        let a = QuickMealAssemblyEngine.assemble(inventory: forward)
        let b = QuickMealAssemblyEngine.assemble(inventory: reversed)

        XCTAssertEqual(a.suggestions.map(\.template), b.suggestions.map(\.template))
        XCTAssertEqual(
            a.suggestions.map { Set(names($0)) },
            b.suggestions.map { Set(names($0)) }
        )
    }

    func testTwoTemplatesDescribingTheSamePlateCollapseToOne() {
        // 米饭 + 腌鸡肉 fits both riceBowl and preppedProteinWithCarb; the same
        //食物 must not be offered twice under two names.
        let result = QuickMealAssemblyEngine.assemble(inventory: [item("米饭"), item("腌鸡肉")])

        let itemSets = result.suggestions.map(\.componentSources)
        XCTAssertEqual(Set(itemSets).count, itemSets.count)
        XCTAssertEqual(result.suggestions.first?.template, .riceBowl)
    }

    func testDepletedItemsNeverTakePart() {
        var emptyNoodle = item("挂面")
        emptyNoodle.quantity = 0
        let result = QuickMealAssemblyEngine.assemble(inventory: [emptyNoodle, item("鸡蛋")])

        XCTAssertTrue(result.suggestions.isEmpty)
        XCTAssertEqual(result.gaps, [.missingCarb])
    }
}

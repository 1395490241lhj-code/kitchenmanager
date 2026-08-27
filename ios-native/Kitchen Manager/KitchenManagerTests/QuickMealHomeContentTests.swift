import XCTest
@testable import KitchenManager

@MainActor
final class QuickMealHomeContentTests: XCTestCase {
    private func item(_ name: String) -> InventoryItem {
        InventoryItem(name: name, quantity: 1, unit: "份", expiryDate: nil, createdAt: Date())
    }

    private func result(_ names: [String]) -> QuickMealAssemblyResult {
        QuickMealAssemblyEngine.assemble(inventory: names.map(item))
    }

    private func content(
        _ names: [String],
        eatingOut: Bool = false,
        index: Int = 0
    ) -> QuickMealHomeContent {
        QuickMealHomeContent.resolve(
            result: result(names),
            isEatingOutTonight: eatingOut,
            storedIndex: index
        )
    }

    /// For comparing suggestions across calls: identity lives in the inventory
    /// items, so the same fixture has to be built once and reused.
    private func content(
        inventory: [InventoryItem],
        eatingOut: Bool = false,
        index: Int = 0
    ) -> QuickMealHomeContent {
        QuickMealHomeContent.resolve(
            result: QuickMealAssemblyEngine.assemble(inventory: inventory),
            isEatingOutTonight: eatingOut,
            storedIndex: index
        )
    }

    private func shown(_ content: QuickMealHomeContent) -> QuickMealSuggestion? {
        if case .suggestion(let suggestion, _) = content { return suggestion }
        return nil
    }

    // MARK: - Which slot the day type asks for

    func testOnlyAQuickDaySwapsTheRecommendationSlot() {
        XCTAssertEqual(HomeRecommendationSlot.slot(for: .quick), .quickMeal)
        XCTAssertEqual(HomeRecommendationSlot.slot(for: .cooking), .recipeRecommendation)
        XCTAssertEqual(HomeRecommendationSlot.slot(for: .flexible), .recipeRecommendation)
    }

    func testMealPrepStillUsesOrdinaryRecipeRecommendationForNow() {
        XCTAssertEqual(
            HomeRecommendationSlot.slot(for: .mealPrep),
            .recipeRecommendation,
            "batch cooking gets its own surface later; it must not borrow the quick one"
        )
    }

    func testEveryDayTypeResolvesToExactlyOneSlot() {
        // Home must never end up rendering both, so the mapping has to be total.
        for dayType in DayType.allCases {
            let slot = HomeRecommendationSlot.slot(for: dayType)
            XCTAssertTrue(slot == .quickMeal || slot == .recipeRecommendation)
        }
    }

    // MARK: - What the quick slot shows

    func testTheFixtureShowsItsSpokenName() {
        let shown = shown(content(["挂面", "卤牛肉", "上海青"]))
        XCTAssertEqual(shown?.displayTitle, "牛肉青菜面")
        XCTAssertEqual(
            shown?.components.map(\.name),
            ["挂面", "卤牛肉", "上海青"],
            "the components line shows what is actually being used, in slot order"
        )
    }

    func testASingleSuggestionOffersNoRotation() {
        guard case .suggestion(_, let canRotate) = content(["挂面", "卤牛肉", "上海青"]) else {
            return XCTFail("expected a suggestion")
        }
        XCTAssertFalse(canRotate)
    }

    func testSeveralSuggestionsOfferRotation() {
        guard case .suggestion(_, let canRotate) = content(["米饭", "卤牛肉", "上海青"]) else {
            return XCTFail("expected a suggestion")
        }
        XCTAssertTrue(canRotate)
    }

    // MARK: - Rotation

    func testRotationStepsThroughAndWrapsAround() {
        let names = ["米饭", "卤牛肉", "上海青"]
        let count = result(names).suggestions.count
        XCTAssertGreaterThan(count, 1)

        var index = 0
        var seen: [String] = []
        for _ in 0..<count {
            seen.append(shown(content(names, index: index))?.displayTitle ?? "")
            index = QuickMealRotation.nextIndex(stored: index, count: count)
        }

        XCTAssertEqual(Set(seen).count, count, "each rotation shows a different meal")
        XCTAssertEqual(index, 0, "rotating past the end comes back to the easiest one")
        XCTAssertEqual(shown(content(names, index: index))?.displayTitle, seen.first)
    }

    func testResolvingTwiceWithTheSameIndexShowsTheSameMeal() {
        // A body refresh must not quietly jump back to the first suggestion.
        let inventory = ["米饭", "卤牛肉", "上海青"].map(item)
        let first = shown(content(inventory: inventory, index: 1))
        let again = shown(content(inventory: inventory, index: 1))
        XCTAssertEqual(first, again)
        XCTAssertNotEqual(first, shown(content(inventory: inventory, index: 0)))
    }

    func testAStaleIndexIsClampedRatherThanCrashingOrEmptying() {
        let inventory = ["米饭", "卤牛肉", "上海青"].map(item)
        let count = QuickMealAssemblyEngine.assemble(inventory: inventory).suggestions.count

        // The inventory shrank underneath a rotated index.
        XCTAssertNotNil(shown(content(inventory: inventory, index: count + 5)))
        XCTAssertEqual(
            shown(content(inventory: inventory, index: count + 5)),
            shown(content(inventory: inventory, index: count - 1)),
            "an out-of-range index falls back to the last real suggestion"
        )
        XCTAssertNotNil(shown(content(inventory: inventory, index: -3)))
    }

    func testAnIndexPastASingleSuggestionStillShowsThatSuggestion() {
        let shrunk = shown(content(["挂面", "卤牛肉", "上海青"], index: 4))
        XCTAssertEqual(shrunk?.displayTitle, "牛肉青菜面")
    }

    func testRotationHelpersAreSafeOnAnEmptyList() {
        XCTAssertEqual(QuickMealRotation.visibleIndex(stored: 3, count: 0), 0)
        XCTAssertEqual(QuickMealRotation.nextIndex(stored: 3, count: 0), 0)
    }

    // MARK: - Dinner eaten out

    func testAnEveningEatenOutHidesTheSuggestion() {
        let names = ["挂面", "卤牛肉", "上海青"]
        XCTAssertEqual(content(names, eatingOut: true), .eatingOut)
        XCTAssertNil(shown(content(names, eatingOut: true)))
    }

    func testTheSuggestionComesBackWhenDinnerReturnsToTheHousehold() {
        let names = ["挂面", "卤牛肉", "上海青"]
        XCTAssertEqual(content(names, eatingOut: true), .eatingOut)
        // Same inventory, same index — nothing was deleted while it was hidden.
        XCTAssertEqual(shown(content(names, eatingOut: false))?.displayTitle, "牛肉青菜面")
    }

    func testEatingOutIsShownEvenWhenThereWouldBeNothingToSuggestAnyway() {
        XCTAssertEqual(content(["盐"], eatingOut: true), .eatingOut)
    }

    // MARK: - Empty states

    func testNothingUsableExplainsItselfWithoutFallingBackToRecipes() {
        XCTAssertEqual(
            content(["盐", "生抽"]),
            .unavailable("库存里暂时没有适合快手组合的食材")
        )
    }

    func testNothingQuickEnoughSaysSoRatherThanOfferingARecipe() {
        XCTAssertEqual(
            content(["大米", "牛肉"]),
            .unavailable("现有食材更适合正常做饭")
        )
    }

    func testEveryGapHasPlainNonBlamingCopy() {
        let messages: [String] = [
            QuickMealGap.nothingUsable, .nothingQuickEnough, .missingCarb, .missingProteinOrVegetable
        ].map(\.homeMessage)

        XCTAssertEqual(Set(messages).count, messages.count, "each gap reads differently")
        for message in messages {
            XCTAssertFalse(message.isEmpty)
            XCTAssertLessThanOrEqual(message.count, 20, "a status line, not a paragraph")
        }
    }

    func testAMissingStapleIsNamedSpecifically() {
        XCTAssertEqual(content(["卤牛肉"]), .unavailable("有现成的菜，还差一样主食"))
    }

    func testAMissingCompanionIsNamedSpecifically() {
        XCTAssertEqual(content(["挂面"]), .unavailable("有主食，还差一样配菜"))
    }
}

import XCTest
@testable import KitchenManager

/// A 备餐日 shows what was put by, in the order it needs eating.
@MainActor
final class MealPrepBoardTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private lazy var now = calendar.startOfDay(for: Date())

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: now)!
    }

    private func batch(
        _ name: String,
        portions: Int = 3,
        expiresIn days: Int,
        preparedDaysAgo: Int = 0
    ) -> PreparedComponent {
        PreparedComponent(
            name: name,
            portionsRemaining: portions,
            state: .cooked,
            storage: .refrigerated,
            preparedAt: day(-preparedDaysAgo),
            expiryDate: day(days)
        )
    }

    private func entries(_ components: [PreparedComponent]) -> [MealPrepBoardEntry] {
        MealPrepBoard.entries(from: components, now: now, calendar: calendar)
    }

    // MARK: - The slot

    func testAMealPrepDayShowsTheBoardRatherThanRecipeRecommendation() {
        XCTAssertEqual(HomeRecommendationSlot.slot(for: .mealPrep), .mealPrepBoard)
    }

    func testTheOtherDaysAreUnchanged() {
        XCTAssertEqual(HomeRecommendationSlot.slot(for: .quick), .quickMeal)
        XCTAssertEqual(HomeRecommendationSlot.slot(for: .cooking), .recipeRecommendation)
        XCTAssertEqual(HomeRecommendationSlot.slot(for: .flexible), .recipeRecommendation)
    }

    func testEveryDayTypeStillMapsToExactlyOneSlot() {
        // Component Meal is deliberately absent: it belongs to no DayType.
        let slots = DayType.allCases.map(HomeRecommendationSlot.slot(for:))
        XCTAssertEqual(slots.count, DayType.allCases.count)
        XCTAssertEqual(Set(slots).count, 3)
    }

    // MARK: - Ordering

    func testTheSoonestToFinishComesFirst() {
        let later = batch("腌鸡肉", expiresIn: 4)
        let sooner = batch("卤鸡腿", expiresIn: 1)

        XCTAssertEqual(entries([later, sooner]).map(\.name), ["卤鸡腿", "腌鸡肉"])
    }

    func testSameExpiryFallsBackToWhenItWasMade() {
        let newer = batch("B", expiresIn: 3, preparedDaysAgo: 0)
        let older = batch("A", expiresIn: 3, preparedDaysAgo: 2)

        XCTAssertEqual(entries([newer, older]).map(\.name), ["A", "B"])
    }

    func testIdenticalDatesStillOrderStably() {
        let first = batch("腌鸡肉", expiresIn: 2)
        let second = batch("卤鸡腿", expiresIn: 2)

        // Same expiry, same preparedAt — the name breaks the tie, and doing it
        // twice in different input orders gives the same answer.
        XCTAssertEqual(entries([first, second]).map(\.name), entries([second, first]).map(\.name))
        XCTAssertEqual(entries([first, second]).count, 2)
    }

    func testOrderingNeverDependsOnInputOrder() {
        let batches = [
            batch("卤鸡腿", expiresIn: 1),
            batch("腌鸡肉", expiresIn: 4),
            batch("卤牛肉", expiresIn: 2)
        ]
        XCTAssertEqual(entries(batches).map(\.id), entries(batches.reversed()).map(\.id))
    }

    // MARK: - What a row says

    func testARowNamesTheBatchThePortionsAndWhenToFinishIt() {
        let entry = try? XCTUnwrap(entries([batch("卤鸡腿", portions: 3, expiresIn: 1)]).first)
        XCTAssertEqual(entry?.summary, "卤鸡腿 · 剩 3 份 · 建议明天前吃完")
    }

    func testNearDatesReadAsWordsAndFurtherOnesAsADate() {
        XCTAssertEqual(MealPrepBoard.expiryText(for: day(1), now: now, calendar: calendar), "建议明天前吃完")
        XCTAssertEqual(MealPrepBoard.expiryText(for: day(0), now: now, calendar: calendar), "建议今天吃完")
        XCTAssertEqual(MealPrepBoard.expiryText(for: day(-1), now: now, calendar: calendar), "建议尽快吃完")

        let further = MealPrepBoard.expiryText(for: day(4), now: now, calendar: calendar)
        XCTAssertTrue(further.hasPrefix("建议 "))
        XCTAssertTrue(further.hasSuffix(" 前吃完"))
    }

    func testAFurtherDateIsWrittenInChineseRegardlessOfDeviceLocale() {
        // `.formatted(.dateTime…)` follows the device locale and rendered
        // "Aug 31" on an English simulator, beside Home's own 8月27日 星期四.
        let text = MealPrepBoard.expiryText(for: day(4), now: now, calendar: calendar)
        XCTAssertTrue(text.contains("月"), "\(text) must use the Chinese date form")
        XCTAssertTrue(text.contains("日"))
        XCTAssertEqual(MealPrepBoard.dateText(for: day(4), calendar: calendar).last, "日")
    }

    func testTheWordingNeverClaimsFoodSafety() {
        // The date is the user's own note, seeded from a conservative starting
        // point. No branch may promise anything about spoilage.
        let forbidden = ["安全", "变质", "有害", "保证", "食品安全", "过期不能"]
        for offset in [-3, -1, 0, 1, 2, 5, 30] {
            let text = MealPrepBoard.expiryText(for: day(offset), now: now, calendar: calendar)
            XCTAssertTrue(text.contains("建议"), "\(text) must stay a suggestion")
            for word in forbidden {
                XCTAssertFalse(text.contains(word), "\(text) must not contain \(word)")
            }
        }
    }

    // MARK: - Empty

    func testAnEmptyKitchenProducesNoRows() {
        XCTAssertTrue(entries([]).isEmpty)
    }

    // MARK: - No plan model

    func testTheBoardIsBuiltOnlyFromExistingRecords() {
        // One entry per stored batch, nothing added and nothing invented: the
        // board records what was made, it does not plan what to make.
        let batches = [batch("A", expiresIn: 1), batch("B", expiresIn: 2), batch("C", expiresIn: 3)]
        XCTAssertEqual(entries(batches).map(\.id), batches.map(\.id))
    }
}

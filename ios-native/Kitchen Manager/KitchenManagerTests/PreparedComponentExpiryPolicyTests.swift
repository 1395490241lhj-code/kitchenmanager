import XCTest
@testable import KitchenManager

/// The Home urgency boundary for prepared batches, pinned explicitly.
///
/// To be clear about what these tests are *not*: nothing here is a food-safety
/// claim. `PreparedComponent.expiryDate` is the user's own editable note about
/// when they mean to finish a batch. This file only fixes how Home decides
/// whether that note is urgent enough to occupy a slot in 需要处理 today.
final class PreparedComponentExpiryPolicyTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    /// Mid-afternoon, so a naive `timeIntervalSince` would give fractional days
    /// and a "tomorrow" date would measure as less than one day away. The policy
    /// works in whole days from the start of today, which is why it does not.
    private lazy var now: Date = calendar.date(
        from: DateComponents(year: 2026, month: 8, day: 27, hour: 15, minute: 40)
    )!

    private func date(dayOffset: Int, hour: Int = 9) -> Date {
        let day = calendar.date(byAdding: .day, value: dayOffset, to: now)!
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    }

    private func isUrgent(dayOffset: Int, hour: Int = 9) -> Bool {
        PreparedComponentExpiryPolicy.isUrgentForHomeAttention(
            expiryDate: date(dayOffset: dayOffset, hour: hour),
            now: now,
            calendar: calendar
        )
    }

    // MARK: - The boundary

    func testAlreadyPastTodayAndTomorrowAreUrgent() {
        XCTAssertTrue(isUrgent(dayOffset: -5), "已经过期")
        XCTAssertTrue(isUrgent(dayOffset: -1), "昨天")
        XCTAssertTrue(isUrgent(dayOffset: 0), "今天")
        XCTAssertTrue(isUrgent(dayOffset: 1), "明天")
    }

    func testTheDayAfterTomorrowAndBeyondAreNotUrgent() {
        XCTAssertFalse(isUrgent(dayOffset: 2), "后天不进入普通 Home 的需要处理")
        XCTAssertFalse(isUrgent(dayOffset: 3))
        XCTAssertFalse(isUrgent(dayOffset: 30))
    }

    /// The boundary is whole calendar days, not elapsed time. A batch dated
    /// tomorrow morning is still tomorrow even when "now" is late tonight.
    func testTheBoundaryIsWholeDaysNotElapsedHours() {
        let lateTonight = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 27, hour: 23, minute: 55)
        )!
        let tomorrowEarly = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 28, hour: 0, minute: 30)
        )!
        let dayAfterEarly = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 29, hour: 0, minute: 30)
        )!

        XCTAssertTrue(
            PreparedComponentExpiryPolicy.isUrgentForHomeAttention(
                expiryDate: tomorrowEarly, now: lateTonight, calendar: calendar
            ),
            "35 分钟之后，但仍然是明天"
        )
        XCTAssertFalse(
            PreparedComponentExpiryPolicy.isUrgentForHomeAttention(
                expiryDate: dayAfterEarly, now: lateTonight, calendar: calendar
            ),
            "24 小时多一点，但已经是后天"
        )
    }

    func testTheHorizonIsNamedRatherThanInlined() {
        XCTAssertEqual(
            PreparedComponentExpiryPolicy.homeAttentionHorizonDays,
            1,
            "Through tomorrow. Changing this changes a product rule, so it has to be changed here."
        )
    }

    // MARK: - Day arithmetic is shared, not re-derived

    func testDaysRemainingCountsWholeDaysFromTheStartOfToday() {
        XCTAssertEqual(PreparedComponentExpiryPolicy.daysRemaining(until: date(dayOffset: -2), now: now, calendar: calendar), -2)
        XCTAssertEqual(PreparedComponentExpiryPolicy.daysRemaining(until: date(dayOffset: 0), now: now, calendar: calendar), 0)
        XCTAssertEqual(PreparedComponentExpiryPolicy.daysRemaining(until: date(dayOffset: 4), now: now, calendar: calendar), 4)
    }

    /// The board's wording and the attention threshold must agree about what day
    /// it is, or a row could read 建议明天前吃完 while being filtered out as
    /// "further away than tomorrow".
    func testTheBoardsWordingAgreesWithThePolicysDayCount() {
        XCTAssertEqual(MealPrepBoard.expiryText(for: date(dayOffset: -1), now: now, calendar: calendar), "建议尽快吃完")
        XCTAssertEqual(MealPrepBoard.expiryText(for: date(dayOffset: 0), now: now, calendar: calendar), "建议今天吃完")
        XCTAssertEqual(MealPrepBoard.expiryText(for: date(dayOffset: 1), now: now, calendar: calendar), "建议明天前吃完")

        // Everything the board words as 今天/明天/尽快 is exactly what the policy
        // calls urgent — no row can be phrased as imminent and then dropped.
        for offset in -3...5 {
            let text = MealPrepBoard.expiryText(for: date(dayOffset: offset), now: now, calendar: calendar)
            let readsAsImminent = ["建议尽快吃完", "建议今天吃完", "建议明天前吃完"].contains(text)
            XCTAssertEqual(readsAsImminent, isUrgent(dayOffset: offset), "offset \(offset): \(text)")
        }
    }

    // MARK: - The board is not filtered by the policy

    /// A 备餐日 is about the whole stock, not about today's urgency, so the board
    /// keeps every batch and only orders them.
    func testTheMealPrepBoardStillListsBatchesBeyondTheHomeHorizon() {
        let soon = PreparedComponent(
            name: "卤鸡腿", portionsRemaining: 3, state: .cooked, storage: .refrigerated,
            preparedAt: now, expiryDate: date(dayOffset: 1)
        )
        let later = PreparedComponent(
            name: "腌鸡肉", portionsRemaining: 2, state: .prepped, storage: .refrigerated,
            preparedAt: now, expiryDate: date(dayOffset: 4)
        )

        let entries = MealPrepBoard.entries(from: [later, soon], now: now, calendar: calendar)

        XCTAssertEqual(entries.map(\.name), ["卤鸡腿", "腌鸡肉"], "soonest first, and nothing dropped")
        XCTAssertFalse(isUrgent(dayOffset: 4), "腌鸡肉 is past the Home horizon…")
        XCTAssertEqual(entries.count, 2, "…and still on the board")
    }

    // MARK: - End to end through the Home projection

    func testHomeAttentionAppliesTheHorizonToRealBatches() {
        let summary = HomeDashboardSummary(
            inventory: [],
            todayPlans: [],
            shoppingItems: [],
            preparedComponents: [
                PreparedComponent(name: "过期的", portionsRemaining: 1, state: .cooked, storage: .refrigerated, preparedAt: now, expiryDate: date(dayOffset: -1)),
                PreparedComponent(name: "今天的", portionsRemaining: 1, state: .cooked, storage: .refrigerated, preparedAt: now, expiryDate: date(dayOffset: 0)),
                PreparedComponent(name: "明天的", portionsRemaining: 1, state: .cooked, storage: .refrigerated, preparedAt: now, expiryDate: date(dayOffset: 1)),
                PreparedComponent(name: "后天的", portionsRemaining: 1, state: .cooked, storage: .refrigerated, preparedAt: now, expiryDate: date(dayOffset: 2)),
                PreparedComponent(name: "下周的", portionsRemaining: 1, state: .cooked, storage: .refrigerated, preparedAt: now, expiryDate: date(dayOffset: 7))
            ],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(
            summary.attentionItems.map(\.name),
            ["过期的", "今天的", "明天的"],
            "已过期 / 今天 / 明天 enter Home attention; 后天及以后 do not."
        )
    }
}

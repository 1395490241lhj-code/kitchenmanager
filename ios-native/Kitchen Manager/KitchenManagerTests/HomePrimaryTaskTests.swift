import XCTest
@testable import KitchenManager

/// Home V2's central contract: one screen, one primary task, and a visible
/// difference between "help me decide" and "help me execute".
///
/// These tests are the authoritative definition of that precedence. Changing
/// the order here changes what Home is for, so a change should arrive with a
/// product reason rather than as a side effect.
final class HomePrimaryTaskTests: XCTestCase {
    // A stable reference so day-boundary tests never depend on the day the
    // suite runs. 2026-09-11 is a Thursday, noon in a fixed calendar.
    private var testCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto") ?? TimeZone.current
        calendar.locale = Locale(identifier: "zh_Hans_CN")
        return calendar
    }

    private var testNow: Date {
        testCalendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 12))!
    }

    /// A Special Plan fixture. Zero dishes keeps it pending by definition;
    /// dishes exist and are uncooked unless cooked flips them all.
    private func plan(
        _ title: String = "家宴",
        dayOffset: Int = 0,
        hour: Int = 18,
        people: Int = 6,
        cooked: Bool = false,
        dishCount: Int = 2
    ) -> SpecialPlan {
        let dish = SpecialPlanDish(recipeID: "sample-mapotofu", recipeName: "麻婆豆腐", isCooked: cooked)
        return SpecialPlan(
            title: title,
            // hour sets the clock on that civil day; adding hour components
            // from noon would drift across the day boundary.
            scheduledAt: {
                let thatDay = testCalendar.date(bySettingHour: hour, minute: 0, second: 0, of: testNow)!
                return testCalendar.date(byAdding: .day, value: dayOffset, to: thatDay)!
            }(),
            peopleCount: people,
            dishes: dishCount == 0 ? [] : Array(repeating: dish, count: dishCount)
        )
    }

    private func resolve(
        dayType: DayType,
        dinnerIntent: MealIntent = .household,
        planState: HomeTodayPlanState = .empty,
        total: Int = 0,
        completed: Int = 0,
        specialPlans: [SpecialPlan] = []
    ) -> HomePrimaryTask {
        HomePrimaryTask.resolve(
            dayType: dayType,
            dinnerIntent: dinnerIntent,
            planState: planState,
            totalPlanCount: total,
            completedPlanCount: completed,
            specialPlans: specialPlans,
            now: testNow,
            calendar: testCalendar
        )
    }

    // MARK: - One task per state

    func testQuickDayMakesQuickMealThePrimaryTask() {
        let task = resolve(dayType: .quick)

        XCTAssertEqual(task.kind, .quickMeal)
        XCTAssertEqual(task.title, "今天怎么吃")
        XCTAssertNil(task.detail)
    }

    func testCookingDayWithoutAPlanIsDecisionMode() {
        let task = resolve(dayType: .cooking)

        XCTAssertEqual(task.kind, .recipeRecommendation)
        XCTAssertEqual(task.title, "今天做什么")
        XCTAssertEqual(task.detail, "还没决定")
        XCTAssertTrue(task.isDecisionMode)
        XCTAssertFalse(task.showsRecommendationLink, "The full card is already the primary content.")
    }

    func testCookingDayWithAPlanIsExecutionMode() {
        let task = resolve(dayType: .cooking, planState: .active, total: 2, completed: 0)

        XCTAssertEqual(task.kind, .planExecution)
        XCTAssertEqual(task.title, "今天做这些")
        XCTAssertEqual(task.detail, "已完成 0/2")
        XCTAssertFalse(task.isDecisionMode)
    }

    func testExecutionModeKeepsRecommendationReachableButNotProminent() {
        let task = resolve(dayType: .cooking, planState: .partial, total: 3, completed: 1)

        XCTAssertEqual(task.detail, "已完成 1/3")
        XCTAssertFalse(task.isDecisionMode, "The full recommendation card must not sit beside the plan.")
        XCTAssertTrue(task.showsRecommendationLink, "更多推荐 keeps the capability; only its weight is reduced.")
    }

    func testAFullyCookedPlanStaysInExecutionModeRatherThanReopeningTheDecision() {
        let task = resolve(dayType: .cooking, planState: .completed, total: 2, completed: 2)

        XCTAssertEqual(task.kind, .planExecution)
        XCTAssertEqual(task.detail, "已完成 2/2")
    }

    func testMealPrepDayMakesTheBoardThePrimaryTask() {
        let task = resolve(dayType: .mealPrep)

        XCTAssertEqual(task.kind, .mealPrepBoard)
        XCTAssertEqual(task.title, "今天备的菜")
        XCTAssertEqual(task.detail, "先吃快到期的")
    }

    func testFlexibleDayAsksTheSofterQuestionAndStillRecommends() {
        let task = resolve(dayType: .flexible)

        XCTAssertEqual(task.kind, .recipeRecommendation)
        XCTAssertEqual(task.title, "今天怎么吃")
        XCTAssertNil(task.detail, "自由日 has no fixed plan to be missing, so it must not imply the user is behind.")
    }

    // MARK: - Eating out

    func testDinnerEatenOutBecomesThePrimaryTaskAndInventsNoWork() {
        let task = resolve(dayType: .cooking, dinnerIntent: .eatOut)

        XCTAssertEqual(task.kind, .eatOut)
        XCTAssertEqual(task.title, "今晚")
        XCTAssertEqual(task.detail, "已安排外食")
    }

    func testDinnerEatenOutOutranksQuickMealAndRecommendation() {
        XCTAssertEqual(resolve(dayType: .quick, dinnerIntent: .eatOut).kind, .eatOut)
        XCTAssertEqual(resolve(dayType: .flexible, dinnerIntent: .eatOut).kind, .eatOut)
    }

    /// The exact contradiction Home V2 exists to remove: it must never claim
    /// 今晚外食 and offer a prominent 开始准备 in the same breath.
    func testAStalePlanUnderAnEatOutDinnerIsSecondaryNotPrimary() {
        let task = resolve(dayType: .cooking, dinnerIntent: .eatOut, planState: .active, total: 2, completed: 0)

        XCTAssertEqual(task.kind, .eatOut)
        XCTAssertEqual(task.secondaryPlanCount, 2, "The plan is never deleted — only demoted to a context fact.")
        XCTAssertFalse(task.showsRecommendationLink)
    }

    func testACompletedPlanUnderAnEatOutDinnerOffersNoLeftoverWork() {
        let task = resolve(dayType: .cooking, dinnerIntent: .eatOut, planState: .completed, total: 2, completed: 2)

        XCTAssertEqual(task.kind, .eatOut)
        XCTAssertEqual(task.secondaryPlanCount, 0, "Nothing is still pending.")
    }

    // MARK: - Suppressed ordinary-plan context (D-042 / FR-011)

    /// Exact copy, for both tasks that displace an ordinary plan. Never the
    /// misleading 今日计划已全部完成.
    func testOtherPlansLineStatesTheSuppressedPlansAsAFact() {
        for (dayType, intent) in [(DayType.mealPrep, MealIntent.household), (.cooking, .eatOut)] {
            let pending = resolve(dayType: dayType, dinnerIntent: intent, planState: .partial, total: 3, completed: 1)
            XCTAssertEqual(pending.otherPlansLine, "今天另有 3 道计划", "\(dayType) \(intent)")
            let cooked = resolve(dayType: dayType, dinnerIntent: intent, planState: .completed, total: 2, completed: 2)
            XCTAssertEqual(cooked.otherPlansLine, "今天另有 2 道计划 · 已完成", "\(dayType) \(intent)")
            let none = resolve(dayType: dayType, dinnerIntent: intent, planState: .empty, total: 0, completed: 0)
            XCTAssertNil(none.otherPlansLine, "\(dayType) \(intent)")
        }
    }

    func testOtherPlansLineIsNeverShownWhenThePlanIsThePrimaryTask() {
        XCTAssertNil(resolve(dayType: .cooking, planState: .partial, total: 3, completed: 1).otherPlansLine)
        XCTAssertNil(resolve(dayType: .quick, planState: .completed, total: 2, completed: 2).otherPlansLine)
        XCTAssertNil(resolve(dayType: .cooking).otherPlansLine)
    }

    // MARK: - Precedence between day types and plans

    /// A prep day is a production day (D-018). Eating out tonight does not undo
    /// the batches made this afternoon, so 记一笔今天做的 still stands.
    func testAPrepDayKeepsItsBoardEvenWhenDinnerIsEatenOut() {
        let task = resolve(dayType: .mealPrep, dinnerIntent: .eatOut)

        XCTAssertEqual(task.kind, .mealPrepBoard)
    }

    /// A decision the user made outranks a suggestion the app assembled. This is
    /// what makes the decision → execution switch real on every day type rather
    /// than only on a 做饭日.
    func testAnExplicitPlanOutranksTheQuickMealSuggestion() {
        let task = resolve(dayType: .quick, planState: .active, total: 1, completed: 0)

        XCTAssertEqual(task.kind, .planExecution)
        XCTAssertEqual(task.title, "今天做这些")
    }

    func testAPrepDayWithAPlanShowsTheBoardAndKeepsThePlanReachable() {
        let task = resolve(dayType: .mealPrep, planState: .active, total: 1, completed: 0)

        XCTAssertEqual(task.kind, .mealPrepBoard)
        XCTAssertEqual(task.secondaryPlanCount, 1)
    }

    // MARK: - Special Plan today (D-042 / FR-012)

    func testTodaySpecialPlanBecomesThePrimaryTask() {
        let event = plan()
        let task = resolve(dayType: .cooking, specialPlans: [event])

        XCTAssertEqual(task.kind, .specialPlanToday)
        XCTAssertEqual(task.title, "家宴")
        XCTAssertEqual(task.detail, "18:00 · 6 人")
        XCTAssertEqual(task.specialPlanID, event.id)
        XCTAssertNil(task.otherPlansLine, "no ordinary plans to state")
        XCTAssertNil(task.specialPlanLine, "the line is only for the days that suppress the event")
        XCTAssertFalse(task.showsRecommendationLink)
    }

    func testYesterdayAndTomorrowDoNotParticipate() {
        let task = resolve(dayType: .cooking, specialPlans: [plan(dayOffset: -1), plan("明天", dayOffset: 1)])

        XCTAssertEqual(task.kind, .recipeRecommendation, "decision mode with no event today")
        XCTAssertNil(task.specialPlanID)

        let planned = resolve(dayType: .cooking, planState: .active, total: 2, completed: 0,
                              specialPlans: [plan(dayOffset: -1)])
        XCTAssertEqual(planned.kind, .planExecution, "the ordinary plan keeps the primary slot")
    }

    func testEarliestPlanWinsAndTheRestAreCounted() {
        let early = plan("中午聚餐", hour: 12, people: 4)
        let late = plan("晚间聚餐", hour: 18)
        let task = resolve(dayType: .cooking, specialPlans: [late, early])

        XCTAssertEqual(task.kind, .specialPlanToday)
        XCTAssertEqual(task.title, "中午聚餐")
        // Owner copy ruling: later same-day events stay on Planner; the
        // primary detail describes the winning event only.
        XCTAssertEqual(task.detail, "12:00 · 4 人")
        XCTAssertEqual(task.specialPlanID, early.id, "earliest scheduledAt wins regardless of array order")
    }

    func testEqualTimesFallBackToArrayOrder() {
        let first = plan("先排上的")
        let second = plan("后排上的")
        let task = resolve(dayType: .cooking, specialPlans: [first, second])

        XCTAssertEqual(task.title, "先排上的")
        XCTAssertEqual(task.specialPlanID, first.id)
    }

    func testACompletedSpecialPlanStaysTodaysPrimaryTask() {
        let task = resolve(dayType: .cooking, specialPlans: [plan(cooked: true)])

        XCTAssertEqual(task.kind, .specialPlanToday, "it must not disappear once cooked")
        XCTAssertEqual(task.detail, "18:00 · 6 人 · 已完成")
        XCTAssertNotNil(task.specialPlanID, "查看聚餐 stays reachable")
    }

    func testAPlanWithNoDishesIsPendingNotCompleted() {
        let task = resolve(dayType: .cooking, specialPlans: [plan(dishCount: 0)])

        XCTAssertEqual(task.kind, .specialPlanToday)
        XCTAssertEqual(task.detail, "18:00 · 6 人")
    }

    func testSpecialPlanOutranksEveryLowerTier() {
        let event = [plan()]

        XCTAssertEqual(resolve(dayType: .cooking, planState: .active, total: 2, completed: 0, specialPlans: event).kind,
                       .specialPlanToday, "an ordinary plan is displaced for the day")
        XCTAssertEqual(resolve(dayType: .quick, specialPlans: event).kind, .specialPlanToday)
        XCTAssertEqual(resolve(dayType: .flexible, specialPlans: event).kind, .specialPlanToday,
                       "the recommendation answer yields to the concrete event")
    }

    func testPrepAndEatOutStillWinAndReduceTheEventToAContextLine() {
        let prep = resolve(dayType: .mealPrep, specialPlans: [plan()])
        XCTAssertEqual(prep.kind, .mealPrepBoard)
        XCTAssertEqual(prep.specialPlanLine, "今天有聚餐 · 18:00 家宴")

        let eatOut = resolve(dayType: .cooking, dinnerIntent: .eatOut, specialPlans: [plan()])
        XCTAssertEqual(eatOut.kind, .eatOut)
        XCTAssertEqual(eatOut.specialPlanLine, "今天有聚餐 · 18:00 家宴")
        XCTAssertNil(eatOut.otherPlansLine, "no ordinary plans on this fixture")
    }

    func testPrepDayStatesBothFactsWithoutTurningEitherIntoNavigation() {
        let task = resolve(dayType: .mealPrep, total: 2, completed: 2, specialPlans: [plan()])

        XCTAssertEqual(task.specialPlanLine, "今天有聚餐 · 18:00 家宴")
        XCTAssertEqual(task.otherPlansLine, "今天另有 2 道计划 · 已完成")
    }

    /// Owner copy ruling: completion is a suffix on the factual context,
    /// not a replacement of the time/guest facts, and never a new action.
    func testACompletedEventUnderASuppressingDayKeepsItsFactsAndCompletion() {
        let prep = resolve(dayType: .mealPrep, specialPlans: [plan(cooked: true)])
        XCTAssertEqual(prep.kind, .mealPrepBoard)
        XCTAssertEqual(prep.specialPlanLine, "今天有聚餐 · 18:00 家宴 · 已完成")

        let eatOut = resolve(dayType: .cooking, dinnerIntent: .eatOut, specialPlans: [plan(cooked: true)])
        XCTAssertEqual(eatOut.kind, .eatOut)
        XCTAssertEqual(eatOut.specialPlanLine, "今天有聚餐 · 18:00 家宴 · 已完成")
    }

    func testSpecialPlanDayStatesTheSuppressedOrdinaryPlans() {
        let pending = resolve(dayType: .cooking, planState: .partial, total: 2, completed: 1,
                              specialPlans: [plan()])
        XCTAssertEqual(pending.otherPlansLine, "今天另有 2 道计划")

        let cooked = resolve(dayType: .cooking, planState: .completed, total: 2, completed: 2,
                             specialPlans: [plan()])
        XCTAssertEqual(cooked.otherPlansLine, "今天另有 2 道计划 · 已完成")
    }

    func testClockTimeNeverBecomesAMealSlot() {
        // 18:00 sits inside the evening and 00:00 starts the day; neither may
        // bend the day type or dinner intent. The event owns the primary
        // slot by civil-day eligibility alone.
        for hour in [0, 18, 23] {
            let task = resolve(dayType: .cooking, specialPlans: [plan(hour: hour)])
            XCTAssertEqual(task.kind, .specialPlanToday, "hour \(hour)")
            XCTAssertTrue(task.detail?.contains("人") ?? false, "hour \(hour) must state people, not a slot")
        }
        let midnight = resolve(dayType: .cooking, specialPlans: [plan(hour: 0)])
        XCTAssertEqual(midnight.detail, "00:00 · 6 人")
    }

    func testOtherPlansLineStaysNilWhenTheEventHasNoCompany() {
        XCTAssertNil(resolve(dayType: .cooking, specialPlans: [plan()]).otherPlansLine)
    }

    // MARK: - Exhaustiveness

    /// Every combination resolves to exactly one task, and only plan execution
    /// ever offers the demoted recommendation link. A state that produced two
    /// primary regions — or none — is the failure mode this whole file guards.
    func testEveryCombinationProducesExactlyOnePrimaryTask() {
        let planStates: [(HomeTodayPlanState, Int, Int)] = [
            (.empty, 0, 0), (.active, 2, 0), (.partial, 2, 1), (.completed, 2, 2)
        ]
        // The Special Plan input adds one more axis: none today, one today,
        // several today, and a cooked one today. Every prior combination
        // must keep its result, and no new combination may yield an empty
        // title, two primary claims, or a second recommendation route.
        let eventSets: [(String, [SpecialPlan])] = [
            ("none", []),
            ("single", [plan()]),
            ("multiple", [plan("早场", hour: 12), plan("晚场", hour: 19)]),
            ("cooked", [plan(cooked: true)])
        ]
        for dayType in DayType.allCases {
            for intent in [MealIntent.household, .eatOut] {
                for (state, total, completed) in planStates {
                    for (eventName, events) in eventSets {
                        let task = resolve(
                            dayType: dayType, dinnerIntent: intent, planState: state,
                            total: total, completed: completed, specialPlans: events
                        )
                        XCTAssertFalse(task.title.isEmpty, "\(dayType) \(intent) \(state) \(eventName)")
                        XCTAssertEqual(
                            task.showsRecommendationLink,
                            task.kind == .planExecution,
                            "Only execution mode demotes recommendation to a link: \(dayType) \(intent) \(state) \(eventName)"
                        )
                        if task.kind == .planExecution {
                            XCTAssertEqual(task.secondaryPlanCount, 0, "The plan is the primary task; it needs no secondary link.")
                        }
                        if task.kind == .specialPlanToday {
                            XCTAssertNotNil(task.specialPlanID, "the CTA needs its route: \(eventName)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Needs attention must not restate the primary region

    private func attentionItem(_ kind: HomeAttentionItem.Kind, _ name: String) -> HomeAttentionItem {
        HomeAttentionItem(id: "\(kind.rawValue).\(name)", kind: kind, name: name, detail: "detail")
    }

    func testAPrepDayDropsPreparedRowsBecauseTheBoardAlreadyListsThem() {
        let items = [
            attentionItem(.expiredInventory, "过期生菜"),
            attentionItem(.preparedExpiring, "卤鸡腿"),
            attentionItem(.expiringInventory, "上海青")
        ]
        let shown = resolve(dayType: .mealPrep).needsAttention(from: items)

        XCTAssertEqual(shown.visible.map(\.name), ["过期生菜", "上海青"])
        XCTAssertEqual(shown.additional, 0)
    }

    func testEveryOtherDayKeepsPreparedRowsBecauseNothingElseShowsThem() {
        let items = [attentionItem(.preparedExpiring, "卤鸡腿")]

        for dayType in [DayType.cooking, .quick, .flexible] {
            let shown = resolve(dayType: dayType).needsAttention(from: items)
            XCTAssertEqual(shown.visible.map(\.name), ["卤鸡腿"], "\(dayType)")
        }
    }

    func testTheCapIsAppliedAfterDeduplicationAndTheRemainderIsReported() {
        let items = (1...6).map { attentionItem(.expiringInventory, "临期\($0)") }
            + [attentionItem(.preparedExpiring, "卤鸡腿")]
        let shown = resolve(dayType: .mealPrep).needsAttention(from: items)

        XCTAssertEqual(shown.visible.count, HomeDashboardSummary.maximumVisibleAttentionItems)
        // Old contract: 6 relevant rows minus the 4 shown left 2 hidden.
        // New contract: the cap is 2, so 4 are hidden. The property under test
        // is unchanged and is still the sharp one — the prep-day batch is
        // dropped as redundant with the board *before* the cap runs, so it is
        // never counted as merely hidden.
        XCTAssertEqual(shown.additional, 4, "6 inventory rows minus the 2 shown — the dropped batch is not counted as hidden.")
    }

    // MARK: - Day type copy

    /// The four rhythms had no explanation anywhere in the app before Home V2 —
    /// the picker offered 做饭 / 快手 / 备餐 / 自由 and Home printed 快手日.
    func testEveryDayTypeExplainsItselfInPlainLanguage() {
        XCTAssertEqual(DayType.cooking.homeExplanation, "今天按正常做饭安排")
        XCTAssertEqual(DayType.quick.homeExplanation, "优先用现有食物，少做几步")
        XCTAssertEqual(DayType.mealPrep.homeExplanation, "今天集中准备未来几天的食物")
        XCTAssertEqual(DayType.flexible.homeExplanation, "今天没有固定安排")

        for dayType in DayType.allCases {
            XCTAssertFalse(dayType.homeExplanation.isEmpty)
            XCTAssertFalse(
                dayType.homeExplanation.contains(dayType.rawValue),
                "The internal term must never reach the reader."
            )
        }
    }
}

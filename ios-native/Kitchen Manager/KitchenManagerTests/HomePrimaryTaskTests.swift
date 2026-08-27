import XCTest
@testable import KitchenManager

/// Home V2's central contract: one screen, one primary task, and a visible
/// difference between "help me decide" and "help me execute".
///
/// These tests are the authoritative definition of that precedence. Changing
/// the order here changes what Home is for, so a change should arrive with a
/// product reason rather than as a side effect.
final class HomePrimaryTaskTests: XCTestCase {
    private func resolve(
        dayType: DayType,
        dinnerIntent: MealIntent = .household,
        planState: HomeTodayPlanState = .empty,
        total: Int = 0,
        completed: Int = 0
    ) -> HomePrimaryTask {
        HomePrimaryTask.resolve(
            dayType: dayType,
            dinnerIntent: dinnerIntent,
            planState: planState,
            totalPlanCount: total,
            completedPlanCount: completed
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
        XCTAssertTrue(task.showsRecommendationLink, "想再加一道 keeps the capability; only its weight is reduced.")
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
        XCTAssertEqual(task.secondaryPlanCount, 2, "The plan is never deleted — only demoted to a reachable link.")
        XCTAssertFalse(task.showsRecommendationLink)
    }

    func testACompletedPlanUnderAnEatOutDinnerOffersNoLeftoverWork() {
        let task = resolve(dayType: .cooking, dinnerIntent: .eatOut, planState: .completed, total: 2, completed: 2)

        XCTAssertEqual(task.kind, .eatOut)
        XCTAssertEqual(task.secondaryPlanCount, 0, "Nothing is still pending, so there is nothing to link to.")
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

    // MARK: - Exhaustiveness

    /// Every combination resolves to exactly one task, and only plan execution
    /// ever offers the demoted recommendation link. A state that produced two
    /// primary regions — or none — is the failure mode this whole file guards.
    func testEveryCombinationProducesExactlyOnePrimaryTask() {
        let planStates: [(HomeTodayPlanState, Int, Int)] = [
            (.empty, 0, 0), (.active, 2, 0), (.partial, 2, 1), (.completed, 2, 2)
        ]
        for dayType in DayType.allCases {
            for intent in [MealIntent.household, .eatOut] {
                for (state, total, completed) in planStates {
                    let task = resolve(dayType: dayType, dinnerIntent: intent, planState: state, total: total, completed: completed)
                    XCTAssertFalse(task.title.isEmpty, "\(dayType) \(intent) \(state)")
                    XCTAssertEqual(
                        task.showsRecommendationLink,
                        task.kind == .planExecution,
                        "Only execution mode demotes recommendation to a link: \(dayType) \(intent) \(state)"
                    )
                    if task.kind == .planExecution {
                        XCTAssertEqual(task.secondaryPlanCount, 0, "The plan is the primary task; it needs no secondary link.")
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
        XCTAssertEqual(shown.additional, 2, "6 inventory rows minus the 4 shown — the dropped batch is not counted as hidden.")
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

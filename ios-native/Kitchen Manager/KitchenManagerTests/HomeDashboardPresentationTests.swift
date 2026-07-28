import XCTest
@testable import KitchenManager

@MainActor
final class HomeDashboardPresentationTests: XCTestCase {
    private func plan(_ name: String, cooked: Bool = false) -> MealPlanItem {
        MealPlanItem(recipeID: name, recipeName: name, isCooked: cooked)
    }

    func testTodayPlanActionsIgnorePurchasedReminderPriority() {
        XCTAssertEqual(HomeDashboardPresentation.todayPlanPrimaryAction(for: .empty), .addTodayPlan)
        XCTAssertEqual(HomeDashboardPresentation.todayPlanPrimaryAction(for: .active), .viewTodayPlan)
        XCTAssertEqual(HomeDashboardPresentation.todayPlanPrimaryAction(for: .partial), .viewTodayPlan)
        XCTAssertEqual(HomeDashboardPresentation.todayPlanPrimaryAction(for: .completed), .browseRecipes)
    }

    func testChineseDateDoesNotDependOnCurrentLocale() {
        let date = Date(timeIntervalSince1970: 1_784_678_400)
        XCTAssertEqual(HomeDatePresentation.text(for: date, timeZone: TimeZone(secondsFromGMT: 0)!), "7月22日 星期三")
    }

    func testPurchasedReminderStaysSeparateFromEveryTodayPlanAction() {
        let purchased = [KitchenShoppingItem(name: "牛奶", isDone: true)]
        let cases: [([MealPlanItem], HomePrimaryAction)] = [
            ([], .addTodayPlan),
            ([plan("待完成")], .viewTodayPlan),
            ([plan("已完成", cooked: true), plan("待完成")], .viewTodayPlan),
            ([plan("已完成", cooked: true)], .browseRecipes)
        ]

        for (plans, expectedAction) in cases {
            let summary = HomeDashboardSummary(
                inventory: [],
                todayPlans: plans,
                shoppingItems: purchased
            )

            XCTAssertEqual(summary.highestPriorityReminder, .purchasedAwaitingStockIn(count: 1))
            XCTAssertEqual(
                HomeDashboardPresentation.todayPlanPrimaryAction(for: summary.todayPlanState),
                expectedAction
            )
        }
    }

    func testReminderPrecedesClipboardAndModuleIssues() {
        XCTAssertEqual(
            HomeDashboardPresentation.supplementarySections(
                hasReminder: true,
                showsClipboardPrompt: true,
                hasModuleIssues: true
            ),
            [.reminder, .clipboardPrompt, .moduleIssues]
        )
    }

    func testAbsentPresentationSectionsAreNotInsertedAsPlaceholders() {
        XCTAssertEqual(
            HomeDashboardPresentation.supplementarySections(
                hasReminder: false,
                showsClipboardPrompt: true,
                hasModuleIssues: false
            ),
            [.clipboardPrompt]
        )
    }
}

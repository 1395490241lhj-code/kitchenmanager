import XCTest

/// The production weekly-menu result screen: what it says, what the one
/// materialization action does, and how it recovers when a previous attempt
/// left the plan and the menu record disagreeing.
final class WeeklyMenuMaterializationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ state: String, size: String = "UICTContentSizeCategoryLarge") -> XCUIApplication {
        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchArguments = [
            "UITEST_SEED_PLANNER_REGRESSION",
            state,
            "-UIPreferredContentSizeCategoryName", size
        ]
        app.launch()
        XCTAssertTrue(app.navigationBars["生成的菜单"].waitForExistence(timeout: 10), "result screen never appeared")
        return app
    }

    private func diagnostics(_ element: XCUIElement, in app: XCUIApplication) -> String {
        let window = app.windows.firstMatch.frame
        let lists = app.collectionViews.count
        let tables = app.tables.count
        return "exists=\(element.exists) hittable=\(element.isHittable) frame=\(element.frame) window=\(window) collectionViews=\(lists) tables=\(tables)"
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// A `Label` renders as an image plus text sharing one identifier, so the
    /// query has to name which one it wants.
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func isAddedStateVisible(_ app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
        element(app, "weekly.result.materialized").waitForExistence(timeout: timeout)
    }

    /// Scrolls the list until the element is fully inside the viewport, the way
    /// the other regression suites do it — the app itself does not scroll.
    @discardableResult
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let list = app.collectionViews.firstMatch
        for _ in 0..<20 {
            if element.exists && element.isHittable {
                let window = app.windows.firstMatch.frame
                if element.frame.minY >= window.minY && element.frame.maxY <= window.maxY { return true }
            }
            if list.exists { list.swipeUp() } else { app.swipeUp() }
        }
        return element.exists && element.isHittable
    }

    // MARK: - Truthful copy

    func testTheResultNamesTheDaysItCoversAndOffersOneWayToAddThem() {
        let app = launch("PLANNER_DATA_WEEKLY_PLAIN")

        XCTAssertTrue(app.staticTexts["菜单概览"].waitForExistence(timeout: 5))
        let range = element(app, "weekly.result.range")
        XCTAssertTrue(range.exists, "the result states the days it covers")
        XCTAssertTrue(
            range.label.contains("月") && range.label.contains("–"),
            "expected an explicit date range, got \(range.label)"
        )

        XCTAssertTrue(app.buttons["weekly.result.materialize"].exists)
        XCTAssertEqual(app.buttons["weekly.result.materialize"].label, "加入用餐计划")

        // The retired vocabulary and the retired shortcuts are both gone.
        XCTAssertFalse(app.navigationBars["本周菜单"].exists)
        XCTAssertFalse(app.staticTexts["本周概览"].exists)
        XCTAssertFalse(app.buttons["把今天加入计划"].exists)
        capture("Weekly-01-Result", app)

        app.buttons["更多"].tap()
        XCTAssertTrue(app.buttons["weekly.result.regenerate"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["保存本周计划"].exists, "the menu no longer claims to save a schedule")
        XCTAssertFalse(app.buttons["生成本周购物清单"].exists)
        XCTAssertTrue(app.buttons["生成购物清单"].exists)
        capture("Weekly-02-Actions", app)
        app.buttons["重新生成"].firstMatch.tap()
        XCTAssertTrue(app.alerts["重新生成菜单？"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.alerts["重新生成菜单？"].staticTexts.element(
                matching: NSPredicate(format: "label CONTAINS %@", "不会更改已经加入用餐计划的菜品")
            ).exists,
            "regeneration must say it leaves added meals alone"
        )
        app.alerts["重新生成菜单？"].buttons["取消"].tap()
    }

    func testNoDishOffersToAddItselfToToday() {
        let app = launch("PLANNER_DATA_WEEKLY_PLAIN")
        let dishMenus = app.buttons.matching(identifier: "更多操作")
        _ = dishMenus

        XCTAssertFalse(app.buttons["加入今日计划"].exists)
        XCTAssertFalse(app.buttons["已在今天"].exists)
    }

    func testEditingStopsOnceTheMenuIsOnThePlan() {
        // Still a draft: a dish can be swapped, moved or removed.
        var app = launch("PLANNER_DATA_WEEKLY_PLAIN")
        openFirstDishMenu(app)
        XCTAssertTrue(app.buttons["替换这道"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["替换这道"].isEnabled)

        // Partly on the plan: the ids are bound to this dish set, so editing is
        // locked until the member settles the menu one way or the other.
        app = launch("PLANNER_DATA_WEEKLY_PARTIAL")
        openFirstDishMenu(app)
        XCTAssertTrue(app.buttons["替换这道"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["替换这道"].isEnabled)

        // On the plan: the Planner owns the meals now. The dish stays
        // inspectable, and nothing here can make the draft differ from what
        // was added.
        app = launch("PLANNER_DATA_WEEKLY_ADDED")
        XCTAssertTrue(isAddedStateVisible(app, timeout: 5))
        openFirstDishMenu(app)
        XCTAssertTrue(app.buttons["查看菜谱"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["替换这道"].exists)
        XCTAssertFalse(app.buttons["移到其他天"].exists)
        XCTAssertFalse(app.buttons["从计划移除"].exists)
    }

    private func openFirstDishMenu(_ app: XCUIApplication) {
        let menu = app.buttons.matching(identifier: "weekly.result.dish.menu").firstMatch
        XCTAssertTrue(reveal(menu, in: app), "dish menu never became reachable")
        menu.tap()
    }

    // MARK: - Adding the menu

    func testAddingTheMenuReportsItAndCannotBeRepeated() {
        let app = launch("PLANNER_DATA_WEEKLY_PLAIN")

        let cta = app.buttons["weekly.result.materialize"]
        XCTAssertTrue(cta.waitForExistence(timeout: 5))
        cta.tap()

        XCTAssertTrue(isAddedStateVisible(app), "the result never confirmed the menu was added")
        XCTAssertTrue(app.staticTexts["已加入用餐计划"].exists)
        XCTAssertFalse(app.buttons["weekly.result.materialize"].exists, "adding it again must not be offered")
        capture("Weekly-03-Added", app)
    }

    // MARK: - Collision

    func testAnOccupiedDayAsksBeforeAddingAndCancelWritesNothing() {
        let app = launch("PLANNER_DATA_WEEKLY_COLLISION")

        app.buttons["weekly.result.materialize"].tap()

        let alert = app.alerts["已有安排"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(
            alert.staticTexts.element(
                matching: NSPredicate(format: "label CONTAINS %@", "其中 1 天已经有安排")
            ).exists,
            "the count comes from the menu itself"
        )
        XCTAssertTrue(
            alert.staticTexts.element(
                matching: NSPredicate(format: "label CONTAINS %@", "保留现有安排")
            ).exists
        )
        capture("Weekly-04-Collision", app)

        alert.buttons["weekly.collision.cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["weekly.result.materialize"].waitForExistence(timeout: 5))
        XCTAssertFalse(
            element(app, "weekly.result.materialized").exists,
            "cancelling writes nothing"
        )
    }

    func testContinuingAppendsAlongsideWhatWasAlreadyPlanned() {
        let app = launch("PLANNER_DATA_WEEKLY_COLLISION")

        app.buttons["weekly.result.materialize"].tap()
        let alert = app.alerts["已有安排"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["weekly.collision.confirm"].firstMatch.tap()

        XCTAssertTrue(isAddedStateVisible(app))
    }

    // MARK: - Recovery

    func testAMenuWhoseMealsAreAlreadyThereReadsAsAddedWithoutAskingAgain() {
        let app = launch("PLANNER_DATA_WEEKLY_REPAIR")

        // The receipt was still pending, but every meal is on the plan, so the
        // screen must say so rather than offer to add them a second time.
        XCTAssertTrue(isAddedStateVisible(app))
        XCTAssertFalse(app.buttons["weekly.result.materialize"].exists)
        XCTAssertFalse(app.alerts["已有安排"].exists, "no confirmation for a menu already on the plan")
    }

    func testAMenuAlreadyAddedStaysAdded() {
        let app = launch("PLANNER_DATA_WEEKLY_ADDED")

        XCTAssertTrue(isAddedStateVisible(app, timeout: 5))
        XCTAssertFalse(app.buttons["weekly.result.materialize"].exists)
    }

    func testAPartlyPresentMenuOffersBothChoicesAndNeitherRuns() {
        let app = launch("PLANNER_DATA_WEEKLY_PARTIAL")

        let addMissing = app.buttons["weekly.result.recover.add"]
        let keep = app.buttons["weekly.result.recover.keep"]
        XCTAssertTrue(addMissing.waitForExistence(timeout: 5))
        XCTAssertTrue(keep.exists)
        XCTAssertEqual(addMissing.label, "重新加入缺少的 1 道")
        XCTAssertEqual(keep.label, "保留当前安排")
        XCTAssertTrue(
            app.staticTexts.element(
                matching: NSPredicate(format: "label CONTAINS %@", "只保留了这份菜单的一部分")
            ).exists,
            "the situation is explained in plain words"
        )
        XCTAssertFalse(app.staticTexts["标记为已加入"].exists, "no internal vocabulary reaches the screen")
        XCTAssertFalse(app.buttons["weekly.result.materialize"].exists, "normal adding is not offered here")
        capture("Weekly-05-Partial", app)
    }

    func testPuttingBackTheMissingDishCompletesTheMenu() {
        let app = launch("PLANNER_DATA_WEEKLY_PARTIAL")

        let addMissing = app.buttons["weekly.result.recover.add"]
        XCTAssertTrue(addMissing.waitForExistence(timeout: 5))
        addMissing.tap()

        XCTAssertTrue(isAddedStateVisible(app))
    }

    func testKeepingTheCurrentArrangementRecreatesNothing() {
        let app = launch("PLANNER_DATA_WEEKLY_PARTIAL")

        let keep = app.buttons["weekly.result.recover.keep"]
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        keep.tap()

        XCTAssertTrue(isAddedStateVisible(app))
        XCTAssertFalse(app.buttons["weekly.result.recover.add"].exists)
    }

    // MARK: - Failures

    func testAChangedMenuSaysSoInsteadOfGuessing() {
        let app = launch("PLANNER_DATA_WEEKLY_STALE")

        app.buttons["weekly.result.materialize"].tap()

        let alert = app.alerts["这份菜单已发生变化"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(
            alert.staticTexts.element(
                matching: NSPredicate(format: "label CONTAINS %@", "请重新生成菜单")
            ).exists
        )
        alert.buttons["好"].tap()
        XCTAssertFalse(
            element(app, "weekly.result.materialized").exists,
            "a changed menu is never reported as added"
        )
    }

    func testADishWhoseRecipeIsGoneIsNamed() {
        let app = launch("PLANNER_DATA_WEEKLY_MISSING_RECIPE")

        app.buttons["weekly.result.materialize"].tap()

        let alert = app.alerts["未能加入用餐计划"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(
            alert.staticTexts.element(
                matching: NSPredicate(format: "label CONTAINS %@", "已不在菜谱库")
            ).exists,
            "the member is told which dish is the problem"
        )
        alert.buttons["好"].tap()
        XCTAssertFalse(element(app, "weekly.result.materialized").exists)
    }

    // MARK: - Accessibility

    func testTheAddActionStaysReachableAtAccessibilitySizes() {
        let app = launch("PLANNER_DATA_WEEKLY_PLAIN", size: "UICTContentSizeCategoryAccessibilityXXXL")

        // At accessibility sizes the summary rows fill the first screen, and a
        // SwiftUI List only builds what it shows — so the action is scrolled to
        // rather than waited for. Reachable is the requirement, not on-screen
        // from the start.
        let cta = app.buttons["weekly.result.materialize"]
        XCTAssertTrue(
            reveal(cta, in: app),
            "the one way to add the menu must stay reachable — \(diagnostics(cta, in: app))"
        )
        XCTAssertGreaterThanOrEqual(cta.frame.height, 43.5, "the add action keeps a usable target")
    }

    func testRecoveryChoicesStayReachableAtAccessibilitySizes() {
        let app = launch("PLANNER_DATA_WEEKLY_PARTIAL", size: "UICTContentSizeCategoryAccessibilityXXXL")

        let addMissing = app.buttons["weekly.result.recover.add"]
        XCTAssertTrue(
            reveal(addMissing, in: app),
            "recovery must not be buried at large sizes — \(diagnostics(addMissing, in: app))"
        )
        let keep = app.buttons["weekly.result.recover.keep"]
        XCTAssertTrue(reveal(keep, in: app), "both choices stay reachable — \(diagnostics(keep, in: app))")
    }
}

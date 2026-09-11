import XCTest

@MainActor
final class PlannerRegressionUITests: XCTestCase {
    private var dark = false
    private var accessibility = false
    private var prefix = "Planner-Light-Normal-"
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(_ state: String) -> XCUIApplication {
        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_PLANNER_REGRESSION", "PLANNER_DATA_" + state,
                               "-UIPreferredContentSizeCategoryName", accessibility ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryLarge", "UITEST_SPECIAL_PLAN_AI_MENU"]
        if dark { app.launchArguments.append("UITEST_FORCE_DARK_APPEARANCE") }
        app.launch()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10))
        return app
    }
    private func capture(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = prefix + name; shot.lifetime = .keepAlways; add(shot)
        let tree = XCTAttachment(string: app.debugDescription); tree.name = prefix + name + "-accessibility"; tree.lifetime = .keepAlways; add(tree)
    }
    private func reveal(_ key: String, _ app: XCUIApplication, type: XCUIElement.ElementType = .staticText) {
        reveal(app.descendants(matching: type).matching(NSPredicate(format: "identifier == %@ OR label == %@", key, key)).firstMatch, app, name: key)
    }
    private func reveal(_ target: XCUIElement, _ app: XCUIApplication, name: String = "element") {
        var seen = Set<String>()
        while true {
            let list = app.collectionViews.firstMatch
            let top = app.navigationBars.firstMatch.frame.maxY
            let frame = list.frame.intersection(app.windows.firstMatch.frame)
            let viewport = CGRect(x: frame.minX, y: top + 8, width: frame.width, height: frame.maxY - top - 16)
            if target.exists, target.isHittable, target.frame.minY >= viewport.minY, target.frame.maxY <= viewport.maxY { return }
            let position = list.cells.allElementsBoundByIndex.map { "\($0.label):\(Int($0.frame.minY))" }.joined(separator: "|")
            guard seen.insert(position).inserted else { XCTFail("No scroll progress for \(name): \(app.debugDescription)"); return }
            // Start the drag well inside the scroll viewport: the bottom/top
            // edges belong to the home indicator and navigation chrome, where a
            // press becomes a system gesture instead of a list scroll.
            let margin = min(80, viewport.height * 0.2)
            let limit = viewport.height - margin * 2
            let delta = target.exists ? max(-limit, min(limit, target.frame.midY - viewport.midY)) : limit
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let y = delta > 0 ? viewport.maxY - margin : viewport.minY + margin
            origin.withOffset(CGVector(dx: viewport.midX, dy: y)).press(forDuration: 0.1,
                thenDragTo: origin.withOffset(CGVector(dx: viewport.midX, dy: y - delta)), withVelocity: .slow, thenHoldForDuration: 0.1)
        }
    }
    func testLightNormalMatrix() { matrix() }
    func testDarkNormalMatrix() { dark = true; prefix = "Planner-Dark-Normal-"; matrix() }
    func testLightAccessibilityMatrix() { accessibility = true; prefix = "Planner-Light-AXXXL-"; matrix() }
    func testDarkAccessibilityMatrix() { dark = true; accessibility = true; prefix = "Planner-Dark-AXXXL-"; matrix() }
    /// Small-phone Light/normal gate: core states only (run on an iPhone 17e destination).
    func testSmallPhoneCoreStates() {
        prefix = "Planner-Small-Light-Normal-"
        let multi = launch("MULTI"); capture("04-Four-Dishes", multi)
        let mixed = launch("MIXED"); capture("06-Mixed-Week", mixed)
        let detail = launch("DETAIL"); capture("08-Special-Detail", detail)
        let draft = launch("DRAFT"); reveal("茄汁土豆胡萝卜炖牛腩", draft); capture("09-Draft-Actions", draft)
        let weekly = launch("WEEKLY"); capture("10-Weekly-Generation", weekly)
        let empty = launch("EMPTY"); capture("12-Empty-Week", empty)
        openComposer(in: empty)
        XCTAssertTrue(empty.buttons["planner.compose.generate"].waitForExistence(timeout: 5))
        empty.textFields["planner.compose.request"].typeText("周三四个人吃晚饭")
        XCTAssertTrue(empty.buttons["planner.compose.generate"].isHittable)
        capture("13-Composer", empty)
        let result = launch("RESULT"); reveal("麻婆豆腐", result); capture("14-Weekly-Result", result)
    }

    /// The empty-week CTA now starts ordinary meal creation, so the composer is
    /// reached through the toolbar menu instead.
    private func openComposer(in app: XCUIApplication) {
        app.buttons["planner.create.menu"].tap()
        app.buttons["planner.special.create"].tap()
    }

    private func matrix() {
        let week = launch("WEEK"); XCTAssertTrue(week.buttons["planner.meal.63000000-0000-0000-0000-000000000001"].label.contains("已完成"))
        capture("01-Week", week)
        reveal("planner.day.9", week); XCTAssertTrue(week.staticTexts["planner.day.9"].label.contains("今天"))
        capture("02-Current-Day", week)
        let one = launch("ONE"); capture("03-One-Dish", one)
        let multi = launch("MULTI"); for index in 1...4 {
            let key = String(format: "planner.meal.63000000-0000-0000-0000-%012d", index)
            reveal(key, multi, type: .button)
            XCTAssertTrue(multi.buttons[key].isHittable)
        }
        reveal("planner.day.7", multi)
        capture("04-Four-Dishes", multi)
        let mixed = launch("MIXED"); capture("05-Empty-Day", mixed)
        reveal("planner.day.9", mixed); capture("06-Mixed-Week", mixed)
        let special = launch("SPECIAL"); reveal("planner.special.entry.61000000-0000-0000-0000-000000000001", special, type: .button); capture("07-Special-Projection", special)
        special.buttons["planner.special.entry.61000000-0000-0000-0000-000000000001"].tap()
        XCTAssertTrue(special.navigationBars["周三家常晚餐"].waitForExistence(timeout: 5))
        reveal("planner.dish.done.62000000-0000-0000-0000-000000000003", special, type: .button)
        for id in ["planner.special.edit", "planner.special.add.dish"] { XCTAssertTrue(special.buttons[id].isHittable) }
        XCTAssertGreaterThanOrEqual(special.buttons["planner.dish.done.62000000-0000-0000-0000-000000000003"].frame.height, 44 - 1e-9)
        capture("08-Completed", special)
        special.buttons["planner.dish.done.62000000-0000-0000-0000-000000000003"].tap()
        XCTAssertEqual(special.buttons["planner.dish.done.62000000-0000-0000-0000-000000000003"].label, "标记完成")
        let draft = launch("DRAFT"); reveal("茄汁土豆胡萝卜炖牛腩", draft); capture("09-Draft-Actions", draft)
        let replace = draft.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "planner.menu.draft.replace.")).firstMatch
        reveal(replace.identifier, draft, type: .button)
        XCTAssertTrue(draft.buttons[replace.identifier].isHittable)
        draft.buttons[replace.identifier].tap(); XCTAssertTrue(draft.staticTexts["清蒸鲈鱼"].waitForExistence(timeout: 10))
        let weekly = launch("WEEKLY"); capture("10-Weekly-Generation", weekly)
        let detail = launch("DETAIL"); detail.buttons["planner.special.add.dish"].tap()
        XCTAssertTrue(detail.navigationBars["添加菜品"].waitForExistence(timeout: 5)); capture("11-Add-Picker", detail)
        // The picker is a lazy List whose last recipe is off screen at accessibility
        // sizes; picker rows carry a cooking time, unlike the detail's own dish rows.
        let pick = detail.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "麻婆豆腐", "分钟")).firstMatch
        reveal(pick, detail, name: "picker 麻婆豆腐")
        XCTAssertTrue(pick.isHittable)
        pick.tap()
        XCTAssertTrue(detail.navigationBars["周三家常晚餐"].waitForExistence(timeout: 5))
        let empty = launch("EMPTY"); capture("12-Empty-Week", empty)
        openComposer(in: empty)
        XCTAssertTrue(empty.buttons["planner.compose.generate"].waitForExistence(timeout: 5)); let request = empty.textFields["planner.compose.request"]
        XCTAssertTrue(request.isHittable)
        request.typeText("周三四个人吃晚饭")
        let generate = empty.buttons["planner.compose.generate"]
        XCTAssertTrue(generate.isEnabled)
        XCTAssertTrue(generate.isHittable)
        XCTAssertGreaterThanOrEqual(generate.frame.height, 44 - 1e-9)
        capture("13-Composer", empty)
        weeklyResult()
    }
    private func weeklyResult() {
        let app = launch("RESULT")
        XCTAssertTrue(app.staticTexts["菜单概览"].waitForExistence(timeout: 5))
        // Lazy List: at accessibility sizes the overview fills the first screen.
        reveal("麻婆豆腐", app)
        XCTAssertTrue(app.staticTexts["麻婆豆腐"].isHittable)
        capture("14-Weekly-Result", app)
        app.buttons["更多"].tap()
        XCTAssertTrue(app.buttons["weekly.result.regenerate"].waitForExistence(timeout: 5))
        capture("15-Weekly-Actions", app)
    }
}

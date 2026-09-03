import XCTest

/// One ordinary user session against the real production backend, at a real
/// user's pace: design a menu once, swap a single dish, save, come back to it.
/// Deliberately not a stress run — the point is to measure what a genuine
/// Special Plan actually costs and whether it holds together end to end.
final class SpecialPlanNormalSessionUITests: XCTestCase {
    private func draftRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@",
            "planner.menu.draft.dish."
        ))
    }

    private func openSeededPlan(in app: XCUIApplication) {
        // Home's own unconditional planner route — the same one a user takes,
        // and no longer dependent on today happening to have a plan.
        XCTAssertTrue(app.buttons["home.planner.link"].waitForExistence(timeout: 15))
        app.buttons["home.planner.link"].tap()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 10))
        let entry = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "planner.special.entry.")
        ).firstMatch
        for _ in 0..<8 where !entry.exists { app.swipeUp() }
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        for _ in 0..<4 where !entry.isHittable { app.swipeUp() }
        entry.tap()
        XCTAssertTrue(app.navigationBars["朋友聚餐"].waitForExistence(timeout: 10))
    }

    /// Waits for a real provider round trip. Returns the dish names, or the
    /// error text if the request surfaced one.
    private func waitForDraft(in app: XCUIApplication, timeout: TimeInterval = 120) -> (names: [String], error: String) {
        let loading = app.descendants(matching: .any)["planner.menu.generating"]
        let deadline = Date().addingTimeInterval(timeout)
        var sawLoading = false
        var settledAt: Date?
        while Date() < deadline {
            let names = draftRows(in: app).allElementsBoundByIndex.map(\.label)
            if !names.isEmpty { return (names, "") }
            let errorRow = app.staticTexts["planner.menu.error"]
            if errorRow.exists { return ([], errorRow.label) }
            sawLoading = sawLoading || loading.exists
            if sawLoading, !loading.exists {
                settledAt = settledAt ?? Date()
                if Date().timeIntervalSince(settledAt!) >= 3 { return ([], "request settled without a draft") }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        return ([], "timed out")
    }

    func testNormalUserSessionEndToEnd() {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_SPECIAL_PLAN", "UITEST_SEED_SPECIAL_PLAN_EMPTY_MENU"]
        app.launch()
        openSeededPlan(in: app)

        // 1. Generate once, the way a user would.
        let generateStart = Date()
        app.buttons["planner.menu.generate"].tap()
        let generated = waitForDraft(in: app)
        let generateMs = Int(Date().timeIntervalSince(generateStart) * 1_000)
        print("E2E_GENERATE ms=\(generateMs) dishes=\(generated.names.count) "
            + "error=\(generated.error) menu=\(generated.names.joined(separator: " | "))")
        XCTAssertFalse(generated.names.isEmpty, "generation failed: \(generated.error)")

        // 2. Swap exactly one dish; every other dish must survive untouched.
        let before = draftRows(in: app).allElementsBoundByIndex.map(\.label)
        let replaceStart = Date()
        let replace = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "planner.menu.draft.replace.")
        ).firstMatch
        XCTAssertTrue(replace.waitForExistence(timeout: 10))
        replace.tap()
        var after = before
        let replaceDeadline = Date().addingTimeInterval(120)
        while Date() < replaceDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            after = draftRows(in: app).allElementsBoundByIndex.map(\.label)
            if after != before { break }
        }
        let replaceMs = Int(Date().timeIntervalSince(replaceStart) * 1_000)
        print("E2E_REPLACE ms=\(replaceMs) changed=\(after != before) menu=\(after.joined(separator: " | "))")
        XCTAssertNotEqual(after, before, "replacement did not change the menu")
        XCTAssertEqual(after.count, before.count, "replacement must not change the dish count")
        XCTAssertEqual(
            Set(after).subtracting(before).count, 1,
            "exactly one dish may be new"
        )

        // 3. Save: only now may the draft become canonical recipes.
        let save = app.buttons["planner.menu.save"]
        for _ in 0..<8 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        save.tap()
        XCTAssertTrue(
            app.buttons["planner.shopping.open"].waitForExistence(timeout: 20),
            "saving did not produce a canonical menu"
        )
        XCTAssertEqual(draftRows(in: app).count, 0, "the draft must be cleared after saving")
        let savedMenu = after

        // 4. Back to the planner, then terminate and relaunch: the menu is
        //    persisted state, not view state.
        app.navigationBars["朋友聚餐"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments = []   // no seeding: prove it came off disk
        app.launch()
        openSeededPlan(in: app)
        for name in savedMenu {
            XCTAssertTrue(
                app.staticTexts[name].waitForExistence(timeout: 10),
                "\(name) did not survive a relaunch"
            )
        }
        print("E2E_REOPEN survived=\(savedMenu.joined(separator: " | "))")

        // 5. Shopping preview reads the accepted recipes.
        let shopping = app.buttons["planner.shopping.open"]
        for _ in 0..<8 where !shopping.isHittable { app.swipeUp() }
        XCTAssertTrue(shopping.waitForExistence(timeout: 10))
        shopping.tap()
        let addToList = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "加入买菜清单（")
        ).firstMatch
        XCTAssertTrue(addToList.waitForExistence(timeout: 30), "shopping preview never opened")
        print("E2E_SHOPPING action=\(addToList.label)")

        // 6. Confirming must switch to the shopping list without crashing —
        //    the regression that the earlier crash fix addressed.
        addToList.tap()
        let imported = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "shopping.section.")
        ).firstMatch
        XCTAssertTrue(imported.waitForExistence(timeout: 20), "confirming shopping crashed or stalled")
        print("E2E_SHOPPING_CONFIRMED ok=true")
    }
}

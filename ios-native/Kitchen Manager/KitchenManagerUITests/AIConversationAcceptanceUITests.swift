import XCTest

final class AIConversationAcceptanceUITests: XCTestCase {
    func testScenarioD_SpecialPlanTwoDishReplacementPreservesConstraints() throws {
        let app = launchScenario("D")
        openPlanner(app)
        let event = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "七人聚餐")).firstMatch
        XCTAssertTrue(event.waitForExistence(timeout: 5))
        guard event.exists else { return }
        openKitchenAIFromPlanner(app)
        send("把聚餐里的两道辣菜换掉，人数和忌口保持不变。", in: app)
        let apply = app.buttons["kitchenAI.planner.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 8))
        guard apply.exists else { return }
        XCTAssertEqual(apply.label, "应用 2 项修改")
        for title in ["麻辣豆腐", "辣子鸡", "清蒸豆腐", "清炒菠菜"] {
            XCTAssertTrue(app.staticTexts[title + " · 未做"].exists)
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        event.tap()
        let originalDishIDs = assertSpecialMenu(["麻辣豆腐", "辣子鸡", "白米饭"], in: app)
        for title in ["麻辣豆腐", "辣子鸡", "白米饭", "7 人", "不吃辣 · 不吃花生"] {
            XCTAssertTrue(app.staticTexts[title].exists)
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        openKitchenAIFromPlanner(app)
        let requests = app.staticTexts["kitchenAI.fixture.requests"].label
        XCTAssertEqual(requests, "3")
        apply.tap()
        XCTAssertFalse(apply.waitForExistence(timeout: 2))
        XCTAssertEqual(app.staticTexts["kitchenAI.fixture.requests"].label, requests)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        event.tap()
        XCTAssertEqual(assertSpecialMenu(["清蒸豆腐", "清炒菠菜", "白米饭"], in: app), originalDishIDs)
        for title in ["清蒸豆腐", "清炒菠菜", "白米饭", "7 人", "不吃辣 · 不吃花生"] {
            XCTAssertTrue(app.staticTexts[title].exists)
        }
        XCTAssertFalse(app.staticTexts["麻辣豆腐"].exists)
        XCTAssertFalse(app.staticTexts["辣子鸡"].exists)
    }

    func testScenarioC_ExpiredConversationReactivatesWithFreshInventoryTruth() throws {
        let app = launchScenario("C")
        openKitchenAIFromHome(app)
        app.buttons["kitchenAI.overflowMenu"].tap()
        app.buttons["历史记录"].tap()
        let history = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "过期库存记录")).firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        guard history.exists else { return }
        history.tap()
        XCTAssertTrue(app.staticTexts["库存里只有旧土豆 1 个"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["kitchenAI.send"].exists)
        app.buttons["kitchenAI.reactivate"].tap()
        send("现在库存里还有什么？", in: app)
        XCTAssertTrue(app.staticTexts["当前库存有新鲜菠菜 2 把。"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["kitchenAI.fixture.requests"].label, "2")
        XCTAssertTrue(app.staticTexts["kitchenAI.fixture.usedContexts"].label.contains("inventory"))
        XCTAssertFalse(app.staticTexts["当前库存有旧土豆。"].exists)
    }

    private func launchScenario(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_AI_CONVERSATION_ACCEPTANCE_\(scenario)"]
        app.launch()
        return app
    }

    private func openKitchenAIFromHome(_ app: XCUIApplication) {
        app.buttons["home.kitchenAI.open"].tap()
        XCTAssertTrue(app.navigationBars["Kitchen AI"].waitForExistence(timeout: 5))
    }

    private func send(_ text: String, in app: XCUIApplication) {
        let composer = app.textViews["kitchenAI.composer"].exists
            ? app.textViews["kitchenAI.composer"] : app.textFields["kitchenAI.composer"]
        composer.tap()
        composer.typeText(text)
        app.buttons["kitchenAI.send"].tap()
    }

    private func openPlanner(_ app: XCUIApplication) {
        app.buttons["home.planner.link"].tap()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 5))
        // Navigate the real Planner to the fixed fixture week, independent of run date.
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let target = calendar.date(from: DateComponents(year: 2026, month: 9, day: 14))!
        let current = calendar.dateInterval(of: .weekOfYear, for: Date())!.start
        let weeks = calendar.dateComponents([.day], from: current, to: target).day! / 7
        for _ in 0..<abs(weeks) {
            app.buttons["切换周"].tap()
            app.buttons[weeks < 0 ? "上一周" : "下一周"].tap()
        }
        XCTAssertEqual(app.staticTexts["planner.week.range"].label, "9月14日 – 9月20日")
    }

    private func assertSpecialMenu(_ names: [String], in app: XCUIApplication) -> [String] {
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "planner.dish.recipe."))
        XCTAssertEqual(rows.count, 3)
        let sorted = rows.allElementsBoundByIndex.sorted { $0.identifier < $1.identifier }
        for (row, name) in zip(sorted, names) {
            XCTAssertEqual(row.label, name + ", 待准备")
        }
        return sorted.map(\.identifier)
    }

    private func openKitchenAIFromPlanner(_ app: XCUIApplication) {
        app.buttons["planner.tools.menu"].tap()
        app.buttons["planner.kitchenAI.open"].tap()
        XCTAssertTrue(app.navigationBars["Kitchen AI"].waitForExistence(timeout: 5))
    }

    func testScenarioB_PlannerPreviewRequiresApplyAndMatchesPlannerTruth() throws {
        let app = launchScenario("B")
        openPlanner(app)
        let original = app.staticTexts["香辣鸡丁"]
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        guard original.exists else { return }
        openKitchenAIFromPlanner(app)
        send("把周三晚餐换清淡一点。", in: app)
        let apply = app.buttons["kitchenAI.planner.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["香辣鸡丁 · 未做"].exists)
        XCTAssertTrue(app.staticTexts["清蒸豆腐 · 未做"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(original.exists)
        XCTAssertFalse(app.staticTexts["清蒸豆腐"].exists)
        openKitchenAIFromPlanner(app)
        XCTAssertTrue(apply.waitForExistence(timeout: 5), "Reopening the same conversation must retain its pending prepared action")
        guard apply.exists else { return }
        let requests = app.staticTexts["kitchenAI.fixture.requests"].label
        XCTAssertEqual(requests, "2")
        apply.tap()
        XCTAssertFalse(apply.waitForExistence(timeout: 2))
        XCTAssertEqual(app.staticTexts["kitchenAI.fixture.requests"].label, requests)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["清蒸豆腐"].waitForExistence(timeout: 5))
        XCTAssertFalse(original.exists)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "清蒸豆腐")).count, 1)
    }

    func testScenarioA_HomeRecommendationExecutesExactlyOnceAndResumes() throws {
        let app = launchScenario("A")
        let isolation = app.staticTexts["kitchenAI.fixture.isolation"]
        XCTAssertTrue(isolation.waitForExistence(timeout: 5))
        guard isolation.exists else { return }
        XCTAssertEqual(isolation.label, "fake transport; local metadata; in-memory persistence")
        openKitchenAIFromHome(app)
        XCTAssertTrue(app.buttons["kitchenAI.starter.用快过期的食材做饭"].exists)
        send("今晚想吃清淡一点，把快过期的先用掉。", in: app)
        XCTAssertTrue(app.staticTexts["清蒸豆腐"].waitForExistence(timeout: 8))
        send("第二个加入今晚。", in: app)
        XCTAssertTrue(app.staticTexts["已加入今晚计划"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(app.buttons["kitchenAI.planner.apply"].exists)
        XCTAssertTrue(app.buttons["kitchenAI.action.undo"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.today.plan.row."))
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows.firstMatch.label.contains("清蒸豆腐"))
        openKitchenAIFromHome(app)
        XCTAssertTrue(app.staticTexts["第二个加入今晚。"].exists)
        XCTAssertTrue(app.staticTexts["已加入今晚计划"].exists)
    }
}

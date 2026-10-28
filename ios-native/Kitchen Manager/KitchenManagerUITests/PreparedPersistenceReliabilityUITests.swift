import XCTest

/// All fixtures use isolated SwiftData and defaults, never the device kitchen.
final class PreparedPersistenceReliabilityUITests: XCTestCase {
    private let batchID = "77000000-0000-0000-0000-000000000001"
    private let failureMessage = "备餐记录保存失败，请稍后重试。"

    private func launch(quick: Bool = false, final: Bool = false, unreadable: Bool = false,
                        extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_PREPARED_RELIABILITY",
                               quick ? "UITEST_FORCE_QUICK_DAY" : "UITEST_FORCE_MEAL_PREP_DAY"] + extra
        if final { app.launchArguments.append("UITEST_PREPARED_FINAL_PORTION") }
        if unreadable { app.launchArguments.append("UITEST_PREPARED_UNREADABLE") }
        app.launch()
        return app
    }

    private func openList(_ app: XCUIApplication) {
        let entry = app.buttons["home.mealPrep.add"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        XCTAssertTrue(app.buttons["prepared.add.button"].waitForExistence(timeout: 5))
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func successFeedback(_ app: XCUIApplication, _ message: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "成功：" + message)).firstMatch
    }

    private func assertSuccess(_ app: XCUIApplication, _ message: String, line: UInt = #line) {
        // Query the real semantic label before waiting on persistent counts:
        // these existing transient toasts intentionally last only two seconds.
        XCTAssertTrue(successFeedback(app, message).waitForExistence(timeout: 2), line: line)
    }

    private func listConsume(_ app: XCUIApplication) -> XCUIElement {
        // SwiftUI also exposes the containing row button with the child's id.
        app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@",
                                        "prepared.consume.\(batchID)", "吃掉一份")).firstMatch
    }

    private func dismissFailure(_ app: XCUIApplication, capture name: String) {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3), "failed writes must give actionable failure feedback")
        XCTAssertTrue(alert.staticTexts[failureMessage].exists)
        capture(app, name)
        alert.buttons["好"].tap()
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "成功：")).firstMatch.exists,
                       "a failed operation must not leave success feedback behind")
    }

    func testAddFailureKeepsEditorInputAndRetrySavesOnce() {
        let app = launch()
        openList(app)
        app.buttons["prepared.add.button"].tap()
        let name = app.textFields["prepared.editor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText("新备的鸡腿")
        app.buttons["prepared.editor.save"].tap()
        dismissFailure(app, capture: "prepared-add-failure")
        XCTAssertEqual(name.value as? String, "新备的鸡腿")
        XCTAssertTrue(app.buttons["prepared.editor.save"].exists, "failure keeps editor open")
        app.buttons["prepared.editor.save"].tap()
        XCTAssertTrue(app.buttons["prepared.add.button"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts.matching(identifier: "新备的鸡腿").count, 1)
        capture(app, "prepared-add-retry-success")
    }

    func testEditFailureKeepsEditorInputAndRetrySaves() {
        let app = launch(extra: ["UITEST_FORCE_DARK_APPEARANCE"])
        openList(app)
        app.staticTexts["卤鸡腿"].tap()
        let name = app.textFields["prepared.editor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText("改名")
        let edited = name.value as? String
        app.buttons["prepared.editor.save"].tap()
        dismissFailure(app, capture: "prepared-edit-failure-dark")
        XCTAssertEqual(name.value as? String, edited)
        XCTAssertTrue(app.buttons["prepared.editor.save"].exists)
        app.buttons["prepared.editor.save"].tap()
        XCTAssertTrue(app.buttons["prepared.add.button"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts[edited!].exists)
    }

    func testListConsumptionFailureKeepsCountsAndRetryConsumesOnce() {
        let app = launch()
        openList(app)
        listConsume(app).tap()
        dismissFailure(app, capture: "prepared-list-consume-failure")
        XCTAssertTrue(app.staticTexts["剩 3 份"].exists)
        listConsume(app).tap()
        assertSuccess(app, "已吃掉一份，还剩 2 份")
        XCTAssertTrue(app.staticTexts["剩 2 份"].waitForExistence(timeout: 3))
    }

    func testListFinalConsumptionFailureKeepsBatchAndRetryRemovesIt() {
        let app = launch(final: true)
        openList(app)
        listConsume(app).tap()
        dismissFailure(app, capture: "prepared-list-final-failure")
        XCTAssertTrue(app.staticTexts["卤鸡腿"].exists)
        XCTAssertTrue(app.staticTexts["剩 1 份"].exists)
        listConsume(app).tap()
        XCTAssertTrue(app.staticTexts["还没有备餐"].waitForExistence(timeout: 3))
        XCTAssertFalse(listConsume(app).exists)
    }

    func testDeleteFailureKeepsBatchAndRetryDeletesIt() {
        let app = launch()
        openList(app)
        deleteBatch(app)
        dismissFailure(app, capture: "prepared-delete-failure")
        XCTAssertTrue(app.staticTexts["卤鸡腿"].exists)
        XCTAssertTrue(app.staticTexts["剩 3 份"].exists)
        deleteBatch(app)
        XCTAssertTrue(app.staticTexts["还没有备餐"].waitForExistence(timeout: 3))
    }

    private func deleteBatch(_ app: XCUIApplication) {
        let delete = app.buttons.matching(NSPredicate(format: "label IN %@", ["删除", "Delete"])).firstMatch
        if delete.exists && delete.isHittable {
            delete.tap()
            return
        }
        let row = app.cells.containing(.staticText, identifier: "卤鸡腿").firstMatch
        XCTAssertTrue(row.exists)
        // Swipe the full cell, not its short name label (which is a button).
        // Stop short of a full swipe so the native destructive action is explicit.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).press(
            forDuration: 0.05,
            thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        )
        XCTAssertTrue(delete.waitForExistence(timeout: 2))
        delete.tap()
    }

    func testHomeQuickMealFailureKeepsCountsAndRetryConsumesOnce() {
        quickMealFailure(final: false)
    }

    func testHomeQuickMealFinalFailureKeepsBatchAndRetryRemovesIt() {
        quickMealFailure(final: true)
    }

    private func quickMealFailure(final: Bool) {
        let app = launch(quick: true, final: final)
        let use = app.buttons["home.quickMeal.usePrepared.\(batchID)"]
        XCTAssertTrue(use.waitForExistence(timeout: 10))
        use.tap()
        dismissFailure(app, capture: final ? "prepared-quick-final-failure" : "prepared-quick-failure")
        XCTAssertTrue(app.staticTexts["卤牛肉 · 备餐剩 \(final ? 1 : 3) 份"].exists)
        use.tap()
        if final {
            assertSuccess(app, "卤牛肉已用完")
            XCTAssertFalse(use.exists)
        } else {
            assertSuccess(app, "已使用 1 份卤牛肉，还剩 2 份")
            XCTAssertTrue(app.staticTexts["卤牛肉 · 备餐剩 2 份"].waitForExistence(timeout: 3))
        }
    }

    func testComponentMealFailureKeepsCountsAndRetryConsumesOnce() {
        componentMealFailure(final: false)
    }

    func testComponentMealFinalFailureKeepsBatchAndRetryRemovesIt() {
        componentMealFailure(final: true)
    }

    private func componentMealFailure(final: Bool) {
        let app = launch(final: final)
        openList(app)
        app.buttons["prepared.assemble"].tap()
        let use = app.buttons["componentMeal.usePrepared.\(batchID)"]
        XCTAssertTrue(use.waitForExistence(timeout: 5))
        use.tap()
        dismissFailure(app, capture: final ? "prepared-component-final-failure" : "prepared-component-failure")
        XCTAssertTrue(app.staticTexts["卤鸡腿 · 备餐剩 \(final ? 1 : 3) 份"].exists)
        use.tap()
        if final {
            assertSuccess(app, "卤鸡腿已用完")
            XCTAssertFalse(use.exists)
        } else {
            assertSuccess(app, "已使用 1 份卤鸡腿，还剩 2 份")
            XCTAssertTrue(app.staticTexts["卤鸡腿 · 备餐剩 2 份"].waitForExistence(timeout: 3))
        }
    }

    func testUnreadableIsNotEmptyAndFailedReloadStaysBlockedUntilSuccessfulReload() {
        let app = launch(unreadable: true, extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        openList(app)
        XCTAssertTrue(app.staticTexts["prepared.unavailable"].exists)
        XCTAssertFalse(app.staticTexts["还没有备餐"].exists)
        app.buttons["prepared.reload"].tap()
        XCTAssertTrue(app.staticTexts["prepared.unavailable"].exists)
        capture(app, "prepared-unreadable-failed-reload-axxxl")
        app.buttons["prepared.reload"].tap()
        XCTAssertTrue(app.staticTexts["卤鸡腿"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["剩 3 份"].exists)
        XCTAssertFalse(app.staticTexts["prepared.unavailable"].exists)
    }

    func testSettingsReportsUnreadableClearRefusal() {
        let app = launch(unreadable: true)
        let settings = app.tabBars.buttons["我的"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let clear = app.buttons["settings.cleardata.button"]
        for _ in 0..<5 {
            if clear.exists && clear.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(clear.isHittable)
        clear.tap()
        app.alerts["清除全部本地数据？"].buttons["清除"].tap()
        XCTAssertTrue(app.alerts["未能清除本地数据"].waitForExistence(timeout: 3))
        capture(app, "prepared-settings-clear-refused")
    }
}

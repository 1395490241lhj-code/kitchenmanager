import XCTest

/// What `AI 做菜` shows while a whole-recipe request is running, and what
/// taking the way out actually does. The stubbed request waits fifteen
/// seconds, which is long enough to read the screen and cancel it on purpose.
final class AIRecipeWaitStateUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(size: String = "UICTContentSizeCategoryLarge") -> XCUIApplication {
        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchArguments = [
            "UITEST_SEED_EMPTY_HOME",
            "UITEST_AI_STUB_GENERATION",
            "-UIPreferredContentSizeCategoryName", size
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["home.primary.title"].waitForExistence(timeout: 10), "home did not open")
        // 菜谱库 is a visible Plan toolbar action now, not a tab of its own.
        app.tabBars.buttons["计划"].tap()
        app.buttons["planner.recipes.open"].tap()
        let add = app.buttons["添加菜谱"]
        XCTAssertTrue(add.waitForExistence(timeout: 8), "the recipe tab did not settle")
        add.tap()
        let entry = app.buttons["AI 做菜"]
        XCTAssertTrue(entry.waitForExistence(timeout: 8), "no AI 做菜 entry")
        entry.tap()
        XCTAssertTrue(app.navigationBars["AI 做菜"].waitForExistence(timeout: 8), "the generator did not open")
        return app
    }

    /// Enters the confirmation surface with a seeded draft and a regeneration
    /// already in flight, which is the state the 更多操作 menu would produce.
    private func launchRegenerating(size: String = "UICTContentSizeCategoryLarge") -> XCUIApplication {
        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchArguments = [
            "UITEST_SEED_EMPTY_HOME",
            "UITEST_AI_STUB_GENERATION",
            "UITEST_SEED_AI_REGENERATING",
            "-UIPreferredContentSizeCategoryName", size
        ]
        app.launch()
        XCTAssertTrue(app.navigationBars["确认菜谱"].waitForExistence(timeout: 10), "the confirmation screen did not open")
        return app
    }

    /// The manual-ingredients field, addressed by position rather than by its
    /// placeholder: a SwiftUI text field stops matching its placeholder once it
    /// holds a value, which is exactly when this has to be asserted. It is the
    /// form's first text element — the inventory section renders no field when
    /// the fridge is empty. The vertical axis means SwiftUI may expose it as
    /// either kind of text element.
    private func ingredientField(_ app: XCUIApplication) -> XCUIElement {
        let field = app.textFields.firstMatch
        return field.exists ? field : app.textViews.firstMatch
    }

    private func reveal(_ app: XCUIApplication, _ element: XCUIElement, swipingUp: Bool = true) {
        var attempts = 0
        while !element.isHittable && attempts < 8 {
            if swipingUp { app.swipeUp() } else { app.swipeDown() }
            attempts += 1
        }
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout) == .completed
    }

    /// Names one ingredient so the request has something to ask for, then
    /// starts generation and returns once the waiting state is up.
    private func startGeneration(_ app: XCUIApplication) {
        let field = ingredientField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no ingredient field")
        field.tap()
        field.typeText("鸡蛋")
        app.navigationBars["AI 做菜"].tap()      // resign the keyboard

        let generate = app.buttons["生成菜谱"]
        reveal(app, generate)
        XCTAssertTrue(generate.waitForExistence(timeout: 5), "no generate button")
        generate.tap()
    }

    // MARK: - Initial generation

    /// G1 / G2 / G3 — the wait says what is happening and offers the way out;
    /// taking it leaves the member on their own form with what they typed, and
    /// the request they cancelled never arrives behind them.
    func testInitialGenerationSaysWhatIsHappeningAndCanBeCancelled() {
        let app = launch()
        startGeneration(app)

        // G1: words, not a bare spinner — and nothing invented about progress.
        let waiting = app.staticTexts["正在生成菜谱…"]
        XCTAssertTrue(waiting.waitForExistence(timeout: 5), "the wait must name itself")
        let cancel = app.buttons["ai.generate.cancel"]
        XCTAssertTrue(cancel.exists, "the wait must offer a way out")
        XCTAssertEqual(cancel.label, "取消")
        XCTAssertFalse(app.buttons["生成菜谱"].exists, "the generate action is busy, so it is not offered twice")
        XCTAssertFalse(app.staticTexts["正在重新生成…"].exists, "this is the first recipe, not a replacement")

        // G2: the way out is real, and it keeps what was entered.
        cancel.tap()
        XCTAssertTrue(waitForDisappearance(waiting, timeout: 5), "the wait must end when it is cancelled")
        XCTAssertTrue(app.buttons["生成菜谱"].waitForExistence(timeout: 5), "the generator must be usable again")
        XCTAssertEqual(app.alerts.count, 0, "cancelling is not a failure")

        let field = ingredientField(app)
        reveal(app, field, swipingUp: false)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the form must still be there")
        XCTAssertEqual(field.value as? String, "鸡蛋", "cancelling must not throw away what was typed")

        // G3: the cancelled request cannot present a draft behind the member.
        XCTAssertFalse(app.navigationBars["确认菜谱"].waitForExistence(timeout: 20),
                       "a cancelled request must never present a draft")
    }
    // MARK: - Regeneration
    //
    // Regeneration is entered through the seeded confirmation surface rather
    // than through 更多操作: that Form-row Menu does not open under XCUITest
    // (the element resolves and reports hittable and enabled, but no tap,
    // coordinate tap, cell tap, type-agnostic query or short press ever
    // produces its items, while the weekly toolbar Menu opens normally). The
    // fixture starts the same production request the menu would; the view,
    // the store and the menu itself are untouched.

    /// C1 / C2 / C3 — the draft being replaced stays on screen and stays
    /// editable, the wait says so exactly once, and cancelling keeps the edit
    /// the member made while waiting.
    func testRegenerationKeepsTheDraftVisibleAndEditableAndCancelKeepsTheEdit() {
        let app = launchRegenerating()

        // C1: the seeded draft, the sentence and the way out, together.
        let title = app.textFields.firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the seeded draft is not on screen")
        XCTAssertEqual(title.value as? String, "番茄炒蛋（UI 测试）", "the draft being replaced is not shown")

        let waiting = app.staticTexts["正在重新生成…"]
        XCTAssertTrue(
            waiting.waitForExistence(timeout: 10),
            "the replacement must announce itself; alerts=" + String(app.alerts.count)
                + " firstAlert=" + (app.alerts.firstMatch.exists ? app.alerts.firstMatch.label : "none")
        )
        let cancel = app.buttons["ai.regenerate.cancel"]
        XCTAssertTrue(cancel.exists, "the replacement must offer a way out")
        XCTAssertEqual(cancel.label, "取消")
        XCTAssertTrue(cancel.isHittable, "the way out must be reachable")
        XCTAssertEqual(app.staticTexts.matching(identifier: "正在重新生成…").count, 1,
                       "exactly one waiting state, not one per region")
        XCTAssertFalse(app.staticTexts["正在生成菜谱…"].exists, "this is a replacement, not a first recipe")
        XCTAssertEqual(app.navigationBars["确认菜谱"].activityIndicators.count, 0,
                       "the toolbar spinner must be gone, not doubled up")

        // C2: a real draft field, edited with the real editor, while the
        // request is still running.
        title.tap()
        title.typeText("（我改的）")
        // The field is trailing-aligned, so tapping it puts the caret before
        // the text and what is typed lands in front.
        XCTAssertEqual(title.value as? String, "（我改的）番茄炒蛋（UI 测试）",
                       "the draft must accept edits while its replacement is prepared")
        XCTAssertTrue(waiting.exists, "the request must still be running after the edit")

        // C3: the way out keeps what was just typed.
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(waitForDisappearance(waiting, timeout: 5), "the waiting state must end")
        XCTAssertEqual(app.alerts.count, 0, "cancelling is not a failure")
        XCTAssertTrue(app.navigationBars["确认菜谱"].exists, "the draft screen must stay")
        XCTAssertEqual(title.value as? String, "（我改的）番茄炒蛋（UI 测试）",
                       "cancellation must not undo the edit made while waiting")

        // The deliberate way back to regeneration is available again.
        let more = app.buttons["更多操作"]
        reveal(app, more)
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        XCTAssertTrue(more.isEnabled, "a deliberate regeneration must be offered again")
    }

    /// C4 — the same surface at the largest text size.
    func testRegenerationWaitStateSurvivesAccessibilitySizes() {
        let app = launchRegenerating(size: "UICTContentSizeCategoryAccessibilityXXXL")

        let waiting = app.staticTexts["正在重新生成…"]
        XCTAssertTrue(
            waiting.waitForExistence(timeout: 12),
            "the sentence must survive the largest text size; alerts=" + String(app.alerts.count)
                + " alertLabel=" + (app.alerts.firstMatch.exists ? app.alerts.firstMatch.label : "none")
                + " cancelExists=" + String(app.buttons["ai.regenerate.cancel"].exists)
                + " spinners=" + String(app.activityIndicators.count)
                + " texts=" + app.staticTexts.allElementsBoundByIndex.prefix(12)
                    .map { $0.label }.joined(separator: "|")
        )
        let cancel = app.buttons["ai.regenerate.cancel"]
        XCTAssertTrue(cancel.exists, "the way out must survive the largest text size")
        reveal(app, cancel, swipingUp: false)
        XCTAssertTrue(cancel.isHittable, "the way out must stay tappable at accessibility sizes")
        XCTAssertGreaterThanOrEqual(cancel.frame.height, 44, "the target must meet the project minimum")

        let title = app.textFields.firstMatch
        reveal(app, title, swipingUp: false)
        XCTAssertTrue(title.exists, "the waiting row must not push the draft out of reach")
        XCTAssertEqual(title.value as? String, "番茄炒蛋（UI 测试）", "the draft is still readable")
    }

    /// The wait is text and a button, so the largest accessibility size is the
    /// one that decides whether it still works. Nothing here is carried by the
    /// spinner alone.
    func testTheWaitingStateStaysReadableAndReachableAtAccessibilitySizes() {
        let app = launch(size: "UICTContentSizeCategoryAccessibilityXXXL")
        startGeneration(app)

        let waiting = app.staticTexts["正在生成菜谱…"]
        XCTAssertTrue(waiting.waitForExistence(timeout: 5), "the sentence must survive the largest text size")
        let cancel = app.buttons["ai.generate.cancel"]
        XCTAssertTrue(cancel.exists, "the way out must survive the largest text size")
        XCTAssertEqual(cancel.label, "取消", "VoiceOver reads the button by its own word")
        reveal(app, cancel)
        XCTAssertTrue(cancel.isHittable, "the way out must stay tappable at accessibility sizes")
        XCTAssertGreaterThanOrEqual(cancel.frame.height, 44, "the target must meet the project minimum")

        // Stop the request before inspecting the rest of the form: scrolling a
        // form this tall takes longer than the stubbed request, and a finished
        // one would carry the screen to the draft mid-assertion.
        cancel.tap()
        XCTAssertTrue(waitForDisappearance(waiting, timeout: 5), "the waiting state must end")

        // The surrounding form is neither clipped nor emptied by the wait.
        let field = ingredientField(app)
        reveal(app, field, swipingUp: false)
        XCTAssertTrue(field.exists, "the form must remain reachable at the largest text size")
        XCTAssertEqual(field.value as? String, "鸡蛋", "what was typed is still there")
    }
}

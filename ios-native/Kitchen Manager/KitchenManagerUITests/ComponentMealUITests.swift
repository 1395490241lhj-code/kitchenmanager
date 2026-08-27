import XCTest

/// Drives the two P1-F surfaces on a real screen: the meal-prep board that a
/// 备餐日 puts in the recommendation slot, and the component-meal sheet reached
/// from the prepared-components page.
final class ComponentMealUITests: XCTestCase {
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 红薯 + 西兰花 in stock, 卤鸡腿 ×3 due tomorrow and 腌鸡肉 ×2 due later.
    private func launchSeeded(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "UITEST_SEED_COMPONENT_MEAL", "UITEST_FORCE_MEAL_PREP_DAY"
        ] + extraArguments
        app.launch()
        XCTAssertTrue(
            app.staticTexts["home.mealPrep.section"].waitForExistence(timeout: 10),
            "the meal prep board must be showing before anything else is asserted"
        )
        return app
    }

    /// Home board → 添加备餐 → the existing management page.
    private func openPreparedPage(_ app: XCUIApplication) {
        app.buttons["home.mealPrep.add"].tap()
        XCTAssertTrue(
            app.buttons["prepared.assemble"].waitForExistence(timeout: 5),
            "添加备餐 lands on the existing prepared-components page"
        )
    }

    private func openAssembleSheet(_ app: XCUIApplication) {
        openPreparedPage(app)
        app.buttons["prepared.assemble"].tap()
        XCTAssertTrue(app.staticTexts["componentMeal.title"].waitForExistence(timeout: 5))
    }

    private func useButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "componentMeal.usePrepared."))
            .firstMatch
    }

    /// A 44pt constraint can measure 43.99999999999997 once the layout engine
    /// has been through a ScrollView. Rounding keeps the assertion about the
    /// contract rather than about subpixel arithmetic.
    private func assertClearsHitTarget(
        _ element: XCUIElement,
        _ message: String,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(element.frame.height.rounded(), 44, message, line: line)
    }

    private func text(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
    }

    // MARK: - Part A: the meal prep board

    func testAMealPrepDayShowsTheBoardInsteadOfRecipeRecommendation() throws {
        let app = launchSeeded()

        XCTAssertFalse(
            app.staticTexts["home.recommendation.section"].exists,
            "the board replaces the slot rather than adding a section"
        )
        XCTAssertFalse(app.staticTexts["home.quickMeal.section"].exists)
        attachScreenshot(of: app, named: "meal-prep-board-standard")
    }

    func testTheBoardListsBatchesSoonestToFinishFirst() throws {
        let app = launchSeeded()

        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.mealPrep.entry."))
        XCTAssertEqual(rows.count, 2)
        // 卤鸡腿 is due tomorrow, 腌鸡肉 later.
        XCTAssertEqual(rows.element(boundBy: 0).label, "卤鸡腿 · 剩 3 份 · 建议明天前吃完")
        XCTAssertTrue(rows.element(boundBy: 1).label.hasPrefix("腌鸡肉 · 剩 2 份 · 建议 "))
        XCTAssertTrue(rows.element(boundBy: 1).label.hasSuffix(" 前吃完"))
    }

    func testTheAddEntryOpensTheExistingManagementPage() throws {
        let app = launchSeeded()
        openPreparedPage(app)

        // The real page, not a rebuilt editor: its own add button is there.
        XCTAssertTrue(app.buttons["prepared.add.button"].exists)
    }

    func testAnEmptyBoardStillOffersTheAddEntry() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_EMPTY_KITCHEN", "UITEST_FORCE_MEAL_PREP_DAY"]
        app.launch()

        XCTAssertTrue(app.staticTexts["home.mealPrep.section"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["home.mealPrep.empty"].exists)
        XCTAssertEqual(app.staticTexts["home.mealPrep.empty"].label, "还没有备餐")
        XCTAssertTrue(app.buttons["home.mealPrep.add"].exists)
        attachScreenshot(of: app, named: "meal-prep-board-empty")
    }

    // MARK: - Part B: the component meal sheet

    func testTheSheetShowsThreeComponentsAndOnlyOffersThePreparedOne() throws {
        let app = launchSeeded()
        openAssembleSheet(app)

        XCTAssertEqual(app.staticTexts["componentMeal.title"].label, "今天可以这样配")
        XCTAssertEqual(app.staticTexts["componentMeal.components"].label, "红薯 · 卤鸡腿 · 西兰花")

        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "componentMeal.prepared."))
        XCTAssertEqual(rows.count, 1, "the sweet potato and the broccoli have no portion model")
        XCTAssertEqual(rows.firstMatch.label, "卤鸡腿 · 备餐剩 3 份")

        attachScreenshot(of: app, named: "component-meal-standard")
    }

    func testTheSharedRowKeepsItsHitTargetAndItsVoiceOverLabel() throws {
        let app = launchSeeded()
        openAssembleSheet(app)

        let button = useButton(in: app)
        XCTAssertTrue(button.exists)
        XCTAssertEqual(button.label, "使用 1 份卤鸡腿", "the batch is named, so two rows are never ambiguous")
        assertClearsHitTarget(button, "the shared row carries P1-D's fix")
    }

    func testUsingAPortionMovesTheCountAndThenRetiresTheBatch() throws {
        let app = launchSeeded()
        openAssembleSheet(app)

        useButton(in: app).tap()
        XCTAssertTrue(
            text(app, "卤鸡腿 · 备餐剩 2 份").waitForExistence(timeout: 5),
            "3 → 2 follows what happened in the kitchen"
        )
        attachScreenshot(of: app, named: "component-meal-after-use")

        useButton(in: app).tap()
        XCTAssertTrue(text(app, "卤鸡腿 · 备餐剩 1 份").waitForExistence(timeout: 5))

        // The last portion removes the record, and the plate rebuilds itself
        // around the batch that is left rather than showing a stale card.
        useButton(in: app).tap()
        XCTAssertTrue(text(app, "腌鸡肉 · 备餐剩 2 份").waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["componentMeal.components"].label, "红薯 · 腌鸡肉 · 西兰花")
    }

    func testWhenEveryBatchIsGoneTheSheetSaysWhatIsMissing() throws {
        let app = launchSeeded()
        openAssembleSheet(app)

        // Three portions of 卤鸡腿, then two of 腌鸡肉.
        for _ in 0..<5 {
            let button = useButton(in: app)
            guard button.waitForExistence(timeout: 3) else { break }
            button.tap()
        }

        XCTAssertTrue(app.descendants(matching: .any)["componentMeal.empty"].waitForExistence(timeout: 5))
        XCTAssertTrue(text(app, "差一样蛋白").exists, "红薯 and 西兰花 alone are not a plate")
        attachScreenshot(of: app, named: "component-meal-exhausted")
    }

    // MARK: - The management page's own button

    func testTheManagementPagesEatAPortionButtonClearsTheSameBar() throws {
        let app = launchSeeded()
        openPreparedPage(app)

        let consume = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "prepared.consume."))
            .firstMatch
        XCTAssertTrue(consume.waitForExistence(timeout: 5))
        // P1-E found this row carrying the same 18pt shape P1-D fixed on Home.
        assertClearsHitTarget(consume, "吃掉一份 must clear the same bar")
    }

    // MARK: - The editor's name hint

    func testAVagueNameWarnsWithoutBlockingTheSave() throws {
        let app = launchSeeded()
        openPreparedPage(app)

        app.buttons["prepared.add.button"].tap()
        let field = app.textFields["prepared.editor.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("周日备的那份")

        XCTAssertTrue(
            app.staticTexts["prepared.editor.nameHint"].waitForExistence(timeout: 3),
            "a name that places nowhere says so"
        )
        attachScreenshot(of: app, named: "component-meal-name-hint")

        // Advisory only: saving works and the record keeps the name as typed.
        let save = app.buttons["prepared.editor.save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.staticTexts["周日备的那份"].waitForExistence(timeout: 5))
    }

    func testARecognisableNameShowsNoHint() throws {
        let app = launchSeeded()
        openPreparedPage(app)

        app.buttons["prepared.add.button"].tap()
        let field = app.textFields["prepared.editor.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("卤鸡腿")

        XCTAssertFalse(app.staticTexts["prepared.editor.nameHint"].exists)
    }

    // MARK: - Appearance

    func testBothSurfacesReadCorrectlyInDarkMode() throws {
        let app = launchSeeded(extraArguments: ["UITEST_FORCE_DARK_APPEARANCE"])
        attachScreenshot(of: app, named: "meal-prep-board-dark")

        openAssembleSheet(app)
        XCTAssertTrue(useButton(in: app).exists)
        attachScreenshot(of: app, named: "component-meal-dark")
    }

    func testBothSurfacesStayUsableAtAccessibilitySizes() throws {
        let app = launchSeeded(extraArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        XCTAssertTrue(app.buttons["home.mealPrep.add"].exists)
        assertClearsHitTarget(app.buttons["home.mealPrep.add"], "添加备餐 stays reachable")
        attachScreenshot(of: app, named: "meal-prep-board-accessibility-xxxl")

        openAssembleSheet(app)
        let button = useButton(in: app)
        XCTAssertTrue(button.exists)
        assertClearsHitTarget(button, "the action keeps its target at accessibility sizes")
        attachScreenshot(of: app, named: "component-meal-accessibility-xxxl")

        // And it still works at that size.
        button.tap()
        XCTAssertTrue(text(app, "卤鸡腿 · 备餐剩 2 份").waitForExistence(timeout: 5))
    }
}

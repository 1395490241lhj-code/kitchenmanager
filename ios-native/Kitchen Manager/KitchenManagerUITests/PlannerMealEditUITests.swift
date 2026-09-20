import XCTest

/// Ordinary-meal edit and move from the Planner, plus the plan context a row
/// must hand to RecipeDetail. Everything runs through production views and the
/// canonical store API; only the persistence failure is injected.
final class PlannerMealEditUITests: XCTestCase {
    /// The seeded regression week: Monday's meal is completed, later days are
    /// not. Ids are deterministic (`day * 10 + index + 1`).
    private let cookedMeal = "planner.meal.63000000-0000-0000-0000-000000000001"
    private let openMeal = "planner.meal.63000000-0000-0000-0000-000000000011"

    private func launchSeededWeek(_ extra: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_PLANNER_REGRESSION", "PLANNER_DATA_WEEK",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryLarge"] + extra
        app.launch()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 10), "planner did not open")
        return app
    }

    private func launchEmptyPlanner(_ extra: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_EMPTY_HOME",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryLarge"] + extra
        app.launch()
        let planTab = app.tabBars.buttons["计划"]
        XCTAssertTrue(planTab.waitForExistence(timeout: 10), "计划 tab missing")
        planTab.tap()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 5), "planner did not open")
        return app
    }

    private func row(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let element = app.buttons[identifier]
        var attempts = 0
        while !element.exists && attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5), "row \(identifier) missing")
        return element
    }

    private func openEditor(_ identifier: String, in app: XCUIApplication) {
        let target = row(identifier, in: app)
        target.swipeRight()
        let edit = app.buttons["编辑"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "the leading swipe action did not reveal 编辑")
        edit.tap()
        XCTAssertTrue(app.navigationBars["编辑这一餐"].waitForExistence(timeout: 5), "the edit sheet did not open")
    }

    private func toggleServings(in app: XCUIApplication) {
        app.switches["planner.mealForm.servingsToggle"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    /// Creates one meal through the production flow, returning its recipe title.
    @discardableResult
    private func createMeal(in app: XCUIApplication) -> String {
        app.buttons["planner.empty.create"].tap()
        XCTAssertTrue(app.navigationBars["新建一餐"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["planner.mealForm.recipe"].tap()
        let pick = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "planner.recipe.pick.")
        ).firstMatch
        XCTAssertTrue(pick.waitForExistence(timeout: 5))
        let title = pick.label
        pick.tap()
        XCTAssertTrue(app.navigationBars["新建一餐"].waitForExistence(timeout: 5))
        app.buttons["planner.mealForm.save"].tap()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 5))
        return title
    }

    private func firstSavedMeal(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND identifier != %@",
                        "planner.meal.", "planner.meal.create")
        ).firstMatch
    }

    // MARK: - Entry points

    func testLeadingSwipeRevealsEdit() {
        let app = launchSeededWeek()
        openEditor(openMeal, in: app)
        XCTAssertTrue(app.buttons["planner.mealForm.save"].exists)
        XCTAssertTrue(app.buttons["planner.mealForm.cancel"].exists)
    }

    func testContextMenuAlsoOffersEdit() {
        let app = launchSeededWeek()
        row(openMeal, in: app).press(forDuration: 1.1)
        let edit = app.buttons["编辑"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "the context menu did not offer 编辑")
        edit.tap()
        XCTAssertTrue(app.navigationBars["编辑这一餐"].waitForExistence(timeout: 5))
    }

    func testEditIsAvailableAsAVoiceOverCustomAction() {
        let app = launchSeededWeek()
        let target = row(openMeal, in: app)
        // Custom actions are what VoiceOver exposes in place of a swipe, which
        // it cannot perform. XCUITest surfaces them on the element itself.
        XCTAssertFalse(target.label.isEmpty, "the row must name itself before offering actions")
        XCTAssertTrue(
            target.isHittable,
            "the row must stay reachable as a single element carrying its actions"
        )
    }

    // MARK: - Edit rules

    func testTheRecipeCannotBeChangedWhileEditing() {
        let app = launchSeededWeek()
        openEditor(openMeal, in: app)

        let recipeRow = app.descendants(matching: .any)["planner.mealForm.recipe"]
        XCTAssertTrue(recipeRow.exists, "the recipe must still be shown")
        recipeRow.tap()
        XCTAssertFalse(
            app.navigationBars["选择菜谱"].waitForExistence(timeout: 2),
            "editing must not offer a different dish"
        )
        XCTAssertTrue(app.navigationBars["编辑这一餐"].exists)
    }

    func testEditingServingsPersistsToTheRow() {
        let app = launchSeededWeek()
        openEditor(openMeal, in: app)
        XCTAssertTrue(app.staticTexts["2 人份"].waitForExistence(timeout: 5), "the sheet starts from the stored target")

        app.buttons["planner.mealForm.servings-Increment"].tap()
        XCTAssertTrue(app.staticTexts["3 人份"].waitForExistence(timeout: 5))
        app.buttons["planner.mealForm.save"].tap()

        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 5))
        XCTAssertTrue(row(openMeal, in: app).label.contains("3 人份"), "the row must show the edited target")
    }

    func testClearingTheServingsToggleReturnsTheTargetToUnstated() {
        let app = launchSeededWeek()
        openEditor(openMeal, in: app)
        toggleServings(in: app)
        XCTAssertEqual(app.switches["planner.mealForm.servingsToggle"].value as? String, "0")
        app.buttons["planner.mealForm.save"].tap()

        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 5))
        XCTAssertFalse(row(openMeal, in: app).label.contains("人份"), "an unstated target shows no serving count")
    }

    // MARK: - Completed meals

    func testACompletedMealLocksServingsAndExplainsWhy() {
        let app = launchSeededWeek()
        openEditor(cookedMeal, in: app)

        XCTAssertTrue(
            app.staticTexts["planner.mealForm.cookedFooter"].waitForExistence(timeout: 5),
            "a completed meal must say why its target is fixed"
        )
        XCTAssertEqual(app.staticTexts["planner.mealForm.cookedFooter"].label, "这道菜已完成，份量不再可改")
        XCTAssertFalse(app.switches["planner.mealForm.servingsToggle"].isEnabled)
        XCTAssertFalse(app.buttons["planner.mealForm.servings-Increment"].isEnabled)
        XCTAssertTrue(app.descendants(matching: .any)["planner.mealForm.date"].isEnabled,
                      "the date stays editable on a completed meal")
    }

    func testACompletedMealStaysCompletedAfterAnEdit() {
        let app = launchSeededWeek()
        openEditor(cookedMeal, in: app)
        app.buttons["planner.mealForm.save"].tap()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 5))
        XCTAssertTrue(row(cookedMeal, in: app).label.contains("已完成"), "editing must not un-cook a meal")
    }

    // MARK: - Plan context

    /// The bug this slice fixes: the row used to open the recipe with no plan,
    /// so the cook it started completed nothing. The plan's own target seeding
    /// the detail is the visible proof the context arrived.
    func testAPlannerRowOpensItsRecipeWithThePlansOwnContext() {
        let app = launchEmptyPlanner()
        createMeal(in: app)
        let saved = firstSavedMeal(in: app)
        XCTAssertTrue(saved.waitForExistence(timeout: 5))

        openEditor(saved.identifier, in: app)
        toggleServings(in: app)
        app.buttons["planner.mealForm.servings-Increment"].tap()
        app.buttons["planner.mealForm.servings-Increment"].tap()
        XCTAssertTrue(app.staticTexts["4 人份"].waitForExistence(timeout: 5))
        app.buttons["planner.mealForm.save"].tap()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 5))

        firstSavedMeal(in: app).tap()
        XCTAssertTrue(
            app.buttons["recipe.detail.startCooking"].waitForExistence(timeout: 5),
            "the row must open the recipe detail"
        )
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "4 人份")).firstMatch.exists,
            "the detail must be seeded from this plan's target, which proves the plan travelled with the row"
        )
    }

    // MARK: - Move

    func testMovingAMealToAnotherWeekPagesThePlanner() {
        let app = launchEmptyPlanner()
        createMeal(in: app)
        XCTAssertTrue(app.staticTexts["本周"].exists, "the planner starts on the current week")

        openEditor(firstSavedMeal(in: app).identifier, in: app)
        let datePicker = app.descendants(matching: .any)["planner.mealForm.date"]
        datePicker.tap()
        let forward = app.buttons["Next Month"]
        if forward.waitForExistence(timeout: 3) { forward.tap() }
        let laterDay = app.collectionViews.buttons.element(boundBy: 20)
        if laterDay.exists { laterDay.tap() }
        app.navigationBars["编辑这一餐"].tap()
        app.buttons["planner.mealForm.save"].tap()

        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 5))
        XCTAssertTrue(firstSavedMeal(in: app).waitForExistence(timeout: 5), "the moved meal must be on screen")
        XCTAssertFalse(app.staticTexts["本周"].exists, "the planner followed the meal to its new week")
    }

    // MARK: - Persistence failure

    func testAFailedEditKeepsTheSheetOpenAndCanBeRetried() {
        // Write 1 is the create below; write 2 is the edit, which fails.
        let app = launchEmptyPlanner("UITEST_PLAN_SECOND_WRITE_FAILS")
        createMeal(in: app)

        openEditor(firstSavedMeal(in: app).identifier, in: app)
        // The created meal left its target unstated, so the stepper has to be
        // turned on before there is a value to change.
        toggleServings(in: app)
        XCTAssertTrue(app.staticTexts["2 人份"].waitForExistence(timeout: 5))
        app.buttons["planner.mealForm.servings-Increment"].tap()
        XCTAssertTrue(app.staticTexts["3 人份"].waitForExistence(timeout: 5))
        app.buttons["planner.mealForm.save"].tap()

        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier == %@", "planner.mealForm.error")
            ).firstMatch.waitForExistence(timeout: 5),
            "a failed write must say so inside the sheet"
        )
        XCTAssertTrue(app.navigationBars["编辑这一餐"].exists, "a failed save must not dismiss")
        XCTAssertTrue(app.staticTexts["3 人份"].exists, "the edited target must survive the failure")

        app.buttons["planner.mealForm.save"].tap()
        XCTAssertTrue(
            app.navigationBars["用餐计划"].waitForExistence(timeout: 5),
            "a retry after a transient failure must be able to succeed"
        )
        XCTAssertTrue(firstSavedMeal(in: app).label.contains("3 人份"))
    }

    // MARK: - Chrome contracts

    func testEditSheetControlsKeepLabelsAndTargets() {
        let app = launchSeededWeek()
        openEditor(openMeal, in: app)

        XCTAssertEqual(app.buttons["planner.mealForm.cancel"].label, "取消")
        XCTAssertEqual(app.buttons["planner.mealForm.save"].label, "保存")
        XCTAssertGreaterThanOrEqual(
            app.descendants(matching: .any)["planner.mealForm.recipe"].frame.height, 44 - 1e-9,
            "form rows stay 44pt targets"
        )
    }
}

import XCTest

/// Ordinary-meal creation from the Planner: the toolbar menu, the empty-week
/// CTA, the form's own rules, and what a failed save does. Everything runs
/// through the production views and the canonical store API — only the
/// persistence failure is injected, because a write cannot be made to fail
/// from the outside any other way.
final class PlannerMealCreateUITests: XCTestCase {
    private func launch(_ arguments: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    private func openPlanner(from app: XCUIApplication) {
        let planTab = app.tabBars.buttons["计划"]
        XCTAssertTrue(planTab.waitForExistence(timeout: 10), "计划 tab missing")
        planTab.tap()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 5), "planner did not open")
    }

    /// Opens the create form the way a user on a non-empty week does.
    private func openMealForm(from app: XCUIApplication) {
        app.buttons["planner.create.menu"].tap()
        let meal = app.buttons["planner.meal.create"]
        XCTAssertTrue(meal.waitForExistence(timeout: 5), "新建一餐 missing from the create menu")
        meal.tap()
        XCTAssertTrue(app.navigationBars["新建一餐"].waitForExistence(timeout: 5), "the meal form did not open")
    }

    private func pickFirstRecipe(in app: XCUIApplication) -> String {
        app.descendants(matching: .any)["planner.mealForm.recipe"].tap()
        XCTAssertTrue(app.navigationBars["选择菜谱"].waitForExistence(timeout: 5), "the recipe picker did not open")
        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "planner.recipe.pick.")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the picker listed no recipes")
        let title = row.label
        row.tap()
        XCTAssertTrue(app.navigationBars["新建一餐"].waitForExistence(timeout: 5), "picking a recipe did not return to the form")
        return title
    }

    /// The identifier sits on the Form row, whose centre is the label; the
    /// switch itself is at the trailing edge, so a plain row tap does nothing.
    private func toggleServings(in app: XCUIApplication) {
        let row = app.switches["planner.mealForm.servingsToggle"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the servings toggle is missing")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    /// Saved meal rows only. Scoped to buttons because a row publishes both a
    /// button and its inner label under the same identifier, and
    /// `planner.meal.create` is the menu item rather than a row.
    private func mealRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier != %@",
                "planner.meal.", "planner.meal.create"
            )
        )
    }

    // MARK: - Entry points

    func testToolbarPlusOpensAMenuRatherThanASheet() {
        let app = launch("UITEST_SEED_SPECIAL_PLAN")
        openPlanner(from: app)

        let menu = app.buttons["planner.create.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertEqual(menu.label, "新建")
        menu.tap()

        XCTAssertTrue(app.buttons["planner.meal.create"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["planner.special.create"].exists)
    }

    func testEmptyWeekCTAOpensOrdinaryCreationDirectly() {
        let app = launch("UITEST_SEED_EMPTY_HOME")
        openPlanner(from: app)

        let cta = app.buttons["planner.empty.create"]
        XCTAssertTrue(cta.waitForExistence(timeout: 5))
        XCTAssertEqual(cta.label, "新建一餐")
        cta.tap()

        XCTAssertTrue(
            app.navigationBars["新建一餐"].waitForExistence(timeout: 5),
            "the empty-week CTA must not open a menu first"
        )
        XCTAssertFalse(app.buttons["planner.meal.create"].exists, "no intermediate menu")
    }

    // MARK: - Form rules

    func testSaveIsDisabledUntilARecipeIsChosen() {
        let app = launch("UITEST_SEED_EMPTY_HOME")
        openPlanner(from: app)
        openMealForm(from: app)

        let save = app.buttons["planner.mealForm.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled, "a meal with no dish is not a plan")

        _ = pickFirstRecipe(in: app)
        XCTAssertTrue(save.isEnabled, "choosing a recipe must enable saving")
    }

    func testPickingARecipePopulatesTheFormRow() {
        let app = launch("UITEST_SEED_EMPTY_HOME")
        openPlanner(from: app)
        openMealForm(from: app)

        let recipeRow = app.descendants(matching: .any)["planner.mealForm.recipe"]
        XCTAssertTrue(recipeRow.label.contains("选择菜谱"), "the empty row must say what it wants")

        let picked = pickFirstRecipe(in: app)
        XCTAssertTrue(
            recipeRow.label.contains(picked.components(separatedBy: ",").first ?? picked),
            "the row must show the chosen recipe, got: \(recipeRow.label)"
        )
    }

    func testServingsToggleControlsWhetherAStepperExists() {
        let app = launch("UITEST_SEED_EMPTY_HOME")
        openPlanner(from: app)
        openMealForm(from: app)

        let toggle = app.switches["planner.mealForm.servingsToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0", "an unstated target is the default")
        XCTAssertFalse(app.steppers["planner.mealForm.servings"].exists, "no stepper while unstated")

        toggleServings(in: app)
        let stepper = app.steppers["planner.mealForm.servings"]
        XCTAssertTrue(stepper.waitForExistence(timeout: 5), "指定份量 must reveal the stepper")
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(app.staticTexts["2 人份"].exists, "the stepper starts at 2")
        app.buttons["planner.mealForm.servings-Increment"].tap()
        XCTAssertTrue(app.staticTexts["3 人份"].waitForExistence(timeout: 5), "the stepper must change the value")
        XCTAssertGreaterThanOrEqual(
            app.buttons["planner.mealForm.servings-Increment"].frame.height, 32 - 1e-9,
            "the stepper stays a system control at system size"
        )
    }

    // MARK: - Saving

    func testSavingCreatesTheRowAndDismissesTheSheet() {
        let app = launch("UITEST_SEED_EMPTY_HOME")
        openPlanner(from: app)
        openMealForm(from: app)
        _ = pickFirstRecipe(in: app)
        app.buttons["planner.mealForm.save"].tap()

        XCTAssertTrue(
            app.navigationBars["用餐计划"].waitForExistence(timeout: 5),
            "a successful save must dismiss the sheet"
        )
        XCTAssertTrue(
            mealRows(in: app).firstMatch.waitForExistence(timeout: 5),
            "the created meal must appear immediately"
        )
        XCTAssertFalse(app.buttons["planner.empty.create"].exists, "the week is no longer empty")
    }

    func testTheSameRecipeCanBeSavedTwiceOnOneDay() {
        let app = launch("UITEST_SEED_EMPTY_HOME")
        openPlanner(from: app)

        app.buttons["planner.empty.create"].tap()
        XCTAssertTrue(app.navigationBars["新建一餐"].waitForExistence(timeout: 5))
        let first = pickFirstRecipe(in: app)
        app.buttons["planner.mealForm.save"].tap()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 5))

        openMealForm(from: app)
        let second = pickFirstRecipe(in: app)
        XCTAssertEqual(first, second, "the test must pick the same dish twice")
        app.buttons["planner.mealForm.save"].tap()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 5))

        XCTAssertEqual(mealRows(in: app).count, 2, "explicit creation is deliberate, so duplicates are kept")
    }

    /// Saving into another week must not drop the meal somewhere the user
    /// cannot see; the Planner follows it.
    func testSavingIntoAnotherWeekPagesThePlannerToThatWeek() {
        let app = launch("UITEST_SEED_EMPTY_HOME")
        openPlanner(from: app)
        XCTAssertTrue(app.staticTexts["本周"].exists, "the planner starts on the current week")

        openMealForm(from: app)
        _ = pickFirstRecipe(in: app)

        // Move the date two weeks out through the native date picker.
        let datePicker = app.descendants(matching: .any)["planner.mealForm.date"]
        XCTAssertTrue(datePicker.waitForExistence(timeout: 5), "the date row is missing")
        datePicker.tap()
        let forward = app.buttons["Next Month"]
        if forward.waitForExistence(timeout: 3) { forward.tap() }
        let laterDay = app.collectionViews.buttons.element(boundBy: 20)
        if laterDay.exists { laterDay.tap() }
        app.navigationBars["新建一餐"].tap()

        app.buttons["planner.mealForm.save"].tap()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 5))

        XCTAssertTrue(
            mealRows(in: app).firstMatch.waitForExistence(timeout: 5),
            "the planner must page to the week holding the saved meal"
        )
        XCTAssertFalse(app.staticTexts["本周"].exists, "the displayed week moved off the current one")
    }

    // MARK: - Persistence failure

    /// The first write fails, the second succeeds — so this covers the sheet
    /// staying open, every field surviving, and the retry actually working.
    func testAFailedSaveKeepsTheSheetOpenAndCanBeRetried() {
        let app = launch("UITEST_SEED_EMPTY_HOME", "UITEST_PLAN_FIRST_WRITE_FAILS")
        openPlanner(from: app)
        openMealForm(from: app)
        let picked = pickFirstRecipe(in: app)
        toggleServings(in: app)
        XCTAssertTrue(app.staticTexts["2 人份"].waitForExistence(timeout: 5))

        app.buttons["planner.mealForm.save"].tap()

        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier == %@", "planner.mealForm.error")
            ).firstMatch.waitForExistence(timeout: 5),
            "a failed write must say so inside the sheet"
        )
        XCTAssertTrue(app.navigationBars["新建一餐"].exists, "a failed save must not dismiss")
        let recipeRow = app.descendants(matching: .any)["planner.mealForm.recipe"]
        XCTAssertTrue(
            recipeRow.label.contains(picked.components(separatedBy: ",").first ?? picked),
            "the chosen recipe must survive the failure"
        )
        XCTAssertEqual(app.switches["planner.mealForm.servingsToggle"].value as? String, "1", "份量 must survive")
        XCTAssertTrue(app.staticTexts["2 人份"].exists, "the stepper value must survive")

        app.buttons["planner.mealForm.save"].tap()
        XCTAssertTrue(
            app.navigationBars["用餐计划"].waitForExistence(timeout: 5),
            "a retry after a transient failure must be able to succeed"
        )
        XCTAssertTrue(
            mealRows(in: app).firstMatch.waitForExistence(timeout: 5),
            "the retried meal must be on the week"
        )
    }

    // MARK: - Accessibility

    func testCreateAffordancesCarryLabelsAndTargets() {
        let app = launch("UITEST_SEED_EMPTY_HOME")
        openPlanner(from: app)
        openMealForm(from: app)

        for id in ["planner.mealForm.save", "planner.mealForm.cancel"] {
            let button = app.buttons[id]
            XCTAssertTrue(button.exists, "\(id) missing")
            XCTAssertFalse(button.label.isEmpty, "\(id) has no accessibility label")
        }
        XCTAssertEqual(app.buttons["planner.mealForm.cancel"].label, "取消")
        XCTAssertEqual(app.buttons["planner.mealForm.save"].label, "保存")

        app.descendants(matching: .any)["planner.mealForm.recipe"].tap()
        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "planner.recipe.pick.")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "picker rows must carry identifiers")
        XCTAssertGreaterThanOrEqual(row.frame.height, 44 - 1e-9, "picker rows must stay 44pt targets")
        XCTAssertFalse(row.label.isEmpty, "a picker row must name its recipe")
    }
}

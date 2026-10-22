import XCTest

/// Uses isolated recipe persistence. These tests exercise ImportRecipeView's
/// real save/error/retry path; the fixture keeps the result screen open solely
/// so its genuine success state can be inspected without delaying production navigation.
final class NativeMotionUITests: XCTestCase {
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testImportSaveFailureRetryAndStableResultInAppearanceAndTypeMatrix() {
        for dark in [false, true] {
            for large in [false, true] {
                let app = XCUIApplication()
                app.launchArguments = [
                    "UITEST_MOTION_IMPORT", "UITEST_MOTION_FAIL_FIRST_SAVE", "UITEST_SEED_IMPORT_RESULT",
                    dark ? "UITEST_FORCE_DARK_APPEARANCE" : "UITEST_FORCE_LIGHT_APPEARANCE",
                    "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                    "-UIPreferredContentSizeCategoryName",
                    large ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryLarge"
                ]
                app.launch()
                XCTAssertTrue(app.staticTexts["基本信息"].waitForExistence(timeout: 8))
                let save = app.buttons["import.result.save"]
                for _ in 0..<12 where !save.isHittable { app.swipeUp() }
                XCTAssertTrue(save.isHittable)
                XCTAssertEqual(save.label, "保存到菜谱库")
                let before = save.frame
                XCTAssertGreaterThanOrEqual(before.height, 43.5)
                let variant = "\(dark ? "dark" : "light")-\(large ? "axxxl" : "normal")"
                capture(app, "motion-save-idle-\(variant)")
                save.tap()
                let alert = app.alerts["无法保存菜谱"]
                XCTAssertTrue(alert.waitForExistence(timeout: 5))
                XCTAssertFalse(app.staticTexts["已保存"].exists)
                capture(app, "motion-save-failure-\(variant)")
                alert.buttons["好"].tap()
                XCTAssertTrue(save.isEnabled)
                XCTAssertEqual(save.label, "保存到菜谱库")
                save.tap()
                expectation(for: NSPredicate(format: "label == %@", "已保存"), evaluatedWith: save)
                waitForExpectations(timeout: 5)
                XCTAssertFalse(save.isEnabled)
                XCTAssertFalse(app.alerts.firstMatch.exists)
                XCTAssertEqual(save.frame.width, before.width, accuracy: 0.5)
                XCTAssertEqual(save.frame.height, before.height, accuracy: 0.5)
                capture(app, "motion-save-success-\(variant)")
                app.terminate()
            }
        }
    }

    func testHomeBrowsingDetailAndBackInAppearanceAndTypeMatrix() {
        for dark in [false, true] {
            for large in [false, true] {
                let app = XCUIApplication()
                app.launchArguments = [
                    "UITEST_SEED_EMPTY_HOME",
                    dark ? "UITEST_FORCE_DARK_APPEARANCE" : "UITEST_FORCE_LIGHT_APPEARANCE",
                    "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                    "-UIPreferredContentSizeCategoryName",
                    large ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryLarge"
                ]
                app.launch()
                XCTAssertTrue(app.staticTexts["home.recommendation.title"].waitForExistence(timeout: 8))
                XCTAssertFalse(app.buttons["home.recommendation.more"].exists)
                let variant = "\(dark ? "dark" : "light")-\(large ? "axxxl" : "normal")"
                capture(app, "motion-home-first-\(variant)")
                let shelf = app.descendants(matching: .any)["home.recommendation.shelf"]
                if large {
                    XCTAssertFalse(shelf.exists, "Accessibility text must keep vertical discovery")
                } else {
                    XCTAssertTrue(shelf.exists)
                    shelf.swipeLeft()
                }
                let nextActions = app.buttons.matching(NSPredicate(
                    format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@ AND identifier != %@",
                    "home.recommendation.", ".viewRecipe", "home.recommendation.viewRecipe"
                ))
                for _ in 0..<8 where !nextActions.allElementsBoundByIndex.contains(where: \.isHittable) {
                    if large { app.swipeUp() } else { shelf.swipeLeft() }
                }
                guard let action = nextActions.allElementsBoundByIndex.first(where: \.isHittable) else {
                    XCTFail("Another recipe's detail action must be reachable")
                    app.terminate()
                    continue
                }
                XCTAssertGreaterThanOrEqual(action.frame.height, 43.5)
                let titleID = String(action.identifier.dropLast("viewRecipe".count)) + "title"
                let recipeTitle = app.staticTexts[titleID].label
                XCTAssertFalse(recipeTitle.isEmpty)
                capture(app, "motion-home-next-\(variant)")
                action.tap()
                XCTAssertTrue(app.navigationBars["菜谱详情"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.staticTexts[recipeTitle].exists)
                app.navigationBars.buttons.element(boundBy: 0).tap()
                XCTAssertTrue(app.navigationBars["今天"].waitForExistence(timeout: 5))
                XCTAssertFalse(app.buttons["home.recommendation.more"].exists)
                capture(app, "motion-home-return-\(variant)")
                app.terminate()
            }
        }
    }

    /// Orchestration enables the actual simulator accessibility preference and
    /// restores its original value afterward. There is no SwiftUI override.
    func testSystemReduceMotionSaveFailureRetryAndSuccess() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "UITEST_MOTION_IMPORT", "UITEST_MOTION_FAIL_FIRST_SAVE", "UITEST_SEED_IMPORT_RESULT",
            "UITEST_FORCE_DARK_APPEARANCE",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        app.launch()
        let environment = app.descendants(matching: .any)["motion.environment"]
        XCTAssertTrue(environment.waitForExistence(timeout: 5))
        guard environment.value as? String == "reduced" else {
            app.terminate()
            throw XCTSkip("Requires actual simulator Reduce Motion enabled by the validation flow")
        }
        XCTAssertEqual(environment.value as? String, "reduced", "UIKit and SwiftUI must both observe the system setting")
        let save = app.buttons["import.result.save"]
        for _ in 0..<12 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isHittable)
        let before = save.frame
        capture(app, "motion-reduced-idle-dark-axxxl")
        save.tap()
        let alert = app.alerts["无法保存菜谱"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        capture(app, "motion-reduced-failure-dark-axxxl")
        alert.buttons["好"].tap()
        XCTAssertEqual(save.label, "保存到菜谱库")
        save.tap()
        expectation(for: NSPredicate(format: "label == %@", "已保存"), evaluatedWith: save)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(save.isEnabled)
        XCTAssertEqual(save.frame.size, before.size)
        capture(app, "motion-reduced-success-dark-axxxl")
        app.terminate()
    }

    func testExecutionRecommendationControlsAndAccessibilityRegeneration() {
        for (dark, large) in [(false, false), (false, true), (true, false), (true, true)] {
            let app = XCUIApplication()
            app.launchArguments = [
                "UITEST_SEED_HOME_DASHBOARD",
                dark ? "UITEST_FORCE_DARK_APPEARANCE" : "UITEST_FORCE_LIGHT_APPEARANCE",
                "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                "-UIPreferredContentSizeCategoryName",
                large ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryLarge"
            ]
            app.launch()
            XCTAssertTrue(app.buttons["home.today.plan.start"].waitForExistence(timeout: 5))
            let actions = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                "home.recommendation.", ".viewRecipe"
            ))
            for _ in 0..<12 where !actions.allElementsBoundByIndex.contains(where: \.isHittable) { app.swipeUp() }
            guard let view = actions.allElementsBoundByIndex.first(where: \.isHittable) else {
                XCTFail("Secondary recommendation action is unreachable")
                app.terminate()
                continue
            }
            XCTAssertGreaterThanOrEqual(view.frame.height, 43.5)
            let addID = String(view.identifier.dropLast("viewRecipe".count)) + "addToday"
            let add = app.buttons[addID]
            XCTAssertTrue(add.exists)
            XCTAssertGreaterThanOrEqual(add.frame.height, 43.5)
            if large { XCTAssertGreaterThanOrEqual(view.frame.minY, add.frame.maxY) }
            capture(app, "motion-home-execution-\(dark ? "dark" : "light")-\(large ? "axxxl" : "normal")")
            // Exercise the top edge of the effective target, not just the text.
            view.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
            XCTAssertTrue(app.navigationBars["菜谱详情"].waitForExistence(timeout: 5))
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars["今天"].waitForExistence(timeout: 5))
            if large {
                let regenerate = app.buttons["home.recommendation.regenerate"]
                for _ in 0..<14 where !regenerate.isHittable { app.swipeUp() }
                XCTAssertTrue(regenerate.isHittable)
                XCTAssertTrue(regenerate.isEnabled)
                XCTAssertGreaterThanOrEqual(regenerate.frame.height, 43.5)
                capture(app, "motion-home-execution-terminal-\(dark ? "dark" : "light")-axxxl")
            }
            app.terminate()
        }
    }

    func testComponentPhaseGalleryInAppearanceAndTypeMatrix() {
        for (dark, large) in [(false, false), (false, true), (true, false), (true, true)] {
            let app = XCUIApplication()
            app.launchArguments = [
                "UITEST_MOTION_LABELS",
                dark ? "UITEST_FORCE_DARK_APPEARANCE" : "UITEST_FORCE_LIGHT_APPEARANCE",
                "-UIPreferredContentSizeCategoryName",
                large ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryLarge"
            ]
            app.launch()
            XCTAssertTrue(app.navigationBars["组件状态预览"].waitForExistence(timeout: 5))
            for (phase, title) in [("idle", "保存到菜谱库"), ("processing", "正在保存"), ("success", "已保存"), ("failure", "重试保存")] {
                let button = app.buttons["motion.preview.\(phase)"]
                for _ in 0..<8 where !button.isHittable { app.swipeUp() }
                XCTAssertTrue(button.isHittable)
                XCTAssertEqual(button.label, title)
                capture(app, "motion-gallery-\(dark ? "dark" : "light")-\(large ? "axxxl" : "normal")-\(phase)")
            }
            app.terminate()
        }
    }
}

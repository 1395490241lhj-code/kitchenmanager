#if DEBUG
import XCTest

/// Eight-state visual gate over the real Phase 1C screens. The only extra
/// launch argument selects color/material geometry; fixtures, navigation and
/// accessibility nodes are the same ones used by the behavioral suites.
final class Phase1DArtDirectionUITests: XCTestCase {
    private struct State {
        let suffix: String
        let fixture: String
        let marker: String
        let primaryAction: String?
    }

    private let states = [
        State(
            suffix: "Home-Recommendation",
            fixture: "UITEST_SEED_EMPTY_HOME",
            marker: "home.recommendation.title",
            primaryAction: "home.recommendation.addToday"
        ),
        State(
            suffix: "Home-Planned",
            fixture: "UITEST_SEED_HOME_FULL_DAY",
            marker: "home.hero.title",
            primaryAction: "home.today.plan.start"
        ),
        State(
            suffix: "Inventory-Normal",
            fixture: "UITEST_SEED_INVENTORY_TONIGHT",
            marker: "上海青",
            primaryAction: nil
        ),
        State(
            suffix: "Inventory-Attention",
            fixture: "UITEST_SEED_INVENTORY_LARGE",
            marker: "嫩豆腐",
            primaryAction: nil
        )
    ]

    @MainActor
    func testWarmPrecisionScreensRender() {
        capture(direction: "PHASE1D_WARM_PRECISION", name: "A-Warm-Precision")
    }

    @MainActor
    func testBoldUtilityScreensRender() {
        capture(direction: "PHASE1D_BOLD_UTILITY", name: "B-Bold-Utility")
    }

    @MainActor
    func testFinalRefinementScreensRender() {
        capture(direction: "PHASE1D_FINAL_REFINEMENT", name: "Final-Refinement")
    }

    @MainActor
    func testFinalValidationStandardMatrix() {
        for appearance in ["Light", "Dark"] {
            for size in ["Normal", "Accessibility-XXXL"] {
                captureValidationMatrix(appearance: appearance, size: size)
            }
        }
    }

    /// Run on the smallest supported iPhone simulator. The same four real
    /// fixtures prove that compact height changes reachability, not behavior.
    @MainActor
    func testFinalValidationSmallPhone() {
        captureValidationMatrix(appearance: "Light", size: "Normal", smallPhone: true)
    }

    @MainActor
    private func capture(direction: String, name: String) {
        for state in states {
            let app = XCUIApplication()
            app.launchArguments = [
                state.fixture,
                direction,
                "UITEST_FORCE_LIGHT_APPEARANCE",
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryLarge"
            ]
            app.launch()

            let marker = app.descendants(matching: .any)[state.marker]
            XCTAssertTrue(marker.waitForExistence(timeout: 6), "Missing \(state.suffix)")

            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "\(name)-\(state.suffix)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.terminate()
        }
    }

    @MainActor
    private func captureValidationMatrix(appearance: String, size: String, smallPhone: Bool = false) {
        for state in states {
            let app = XCUIApplication()
            app.launchArguments = [
                state.fixture,
                "PHASE1D_FINAL_REFINEMENT",
                appearance == "Dark" ? "UITEST_FORCE_DARK_APPEARANCE" : "UITEST_FORCE_LIGHT_APPEARANCE",
                "-UIPreferredContentSizeCategoryName",
                size == "Accessibility-XXXL"
                    ? "UICTContentSizeCategoryAccessibilityXXXL"
                    : "UICTContentSizeCategoryLarge"
            ]
            app.launch()

            let marker = app.descendants(matching: .any)[state.marker]
            XCTAssertTrue(marker.waitForExistence(timeout: 6), "Missing \(state.suffix)")

            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "Phase1D2-\(state.suffix)-\(appearance)-\(size)\(smallPhone ? "-Small" : "")"
            screenshot.lifetime = .keepAlways
            add(screenshot)

            if let identifier = state.primaryAction {
                let action = app.buttons[identifier]
                XCTAssertTrue(action.exists, "\(state.suffix): primary action missing")
                for _ in 0..<2 where !action.isHittable {
                    app.swipeUp()
                }
                XCTAssertTrue(action.isHittable, "\(state.suffix): primary action needs more than two scrolls")
            } else if size == "Accessibility-XXXL" {
                XCTAssertTrue(marker.isHittable, "\(state.suffix): first ingredient is not visible at Accessibility XXXL")
            }

            app.terminate()
        }
    }
}
#endif

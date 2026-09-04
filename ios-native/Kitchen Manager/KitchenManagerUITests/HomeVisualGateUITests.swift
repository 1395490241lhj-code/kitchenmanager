#if DEBUG
import XCTest

/// Phase 1A visual-acceptance capture. Drives the production Home into the
/// states a static launch screenshot cannot reach — scrolled to the bottom of
/// a busy day — and asserts the contracts those states have to keep.
final class HomeVisualGateUITests: XCTestCase {

    @MainActor
    func testBusyDayKeepsTheAttentionCapAndReachesItsEnd() {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_HOME_FULL_DAY", "UITEST_FORCE_LIGHT_APPEARANCE"]
        app.launch()

        XCTAssertTrue(app.staticTexts["home.primary.title"].waitForExistence(timeout: 5))
        attach(name: "Gate-BusyDay-Top")

        app.swipeUp(velocity: .fast)
        attach(name: "Gate-BusyDay-Middle")
        app.swipeUp(velocity: .fast)
        attach(name: "Gate-BusyDay-Bottom")

        // The cap still holds: four named rows, then a statement of what is
        // left rather than an unbounded list.
        let attentionRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.attention."))
        XCTAssertLessThanOrEqual(attentionRows.count, 5, "At most four named rows plus the overflow row.")
        XCTAssertTrue(app.buttons["home.attention.overflow"].exists, "More items than the cap must be stated, not dropped.")
    }

    @MainActor
    private func attach(name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
#endif

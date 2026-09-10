#if DEBUG
import XCTest

/// Production rendering only. Fixtures seed existing product states; appearance
/// and Dynamic Type arguments never choose a different presentation.
final class ProductionDesignLanguageUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testLightNormal() { capture(dark: false, accessibility: false) }
    @MainActor func testDarkNormal() { capture(dark: true, accessibility: false) }
    @MainActor func testLightAccessibilityXXXL() { capture(dark: false, accessibility: true) }
    @MainActor func testDarkAccessibilityXXXL() { capture(dark: true, accessibility: true) }

    @MainActor
    private func capture(dark: Bool, accessibility: Bool) {
        let states = [
            ("Home-Recommendation", "UITEST_SEED_EMPTY_HOME", "home.recommendation.title"),
            ("Home-Planned", "UITEST_SEED_HOME_FULL_DAY", "home.hero.title"),
            ("Inventory-Normal", "UITEST_SEED_INVENTORY_TONIGHT", "上海青"),
            ("Inventory-Attention", "UITEST_SEED_INVENTORY_LARGE", "嫩豆腐")
        ]
        for (name, fixture, marker) in states {
            let app = XCUIApplication()
            app.launchArguments = [
                fixture,
                dark ? "UITEST_FORCE_DARK_APPEARANCE" : "UITEST_FORCE_LIGHT_APPEARANCE",
                "-UIPreferredContentSizeCategoryName",
                accessibility ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryLarge"
            ]
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)[marker].waitForExistence(timeout: 8))
            // Existing inventory seeding can briefly show its real import toast.
            // Wait for natural dismissal; never hide controls or alter fixture data.
            if name.hasPrefix("Inventory") {
                let notice = app.descendants(matching: .any).matching(
                    NSPredicate(format: "label BEGINSWITH %@", "成功：已添加")
                ).firstMatch
                XCTAssertTrue(notice.waitForNonExistence(timeout: 5))
            }
            let width = Int(app.windows.firstMatch.frame.width)
            let prefix = "Production-\(width)-\(dark ? "Dark" : "Light")-\(accessibility ? "AXXXL" : "Normal")-\(name)"
            attach(prefix)

            if name.hasPrefix("Inventory") {
                let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "inventory.item.")).firstMatch
                XCTAssertTrue(row.isHittable, "A real ingredient must remain visible on launch.")
                // List exposes a full-width row hit area; inspect the actual
                // visible name, not that intentionally generous hit region.
                let visibleName = app.staticTexts[name == "Inventory-Normal" ? "过期酸奶" : "嫩豆腐"]
                XCTAssertGreaterThanOrEqual(visibleName.frame.minX, 19)
                XCTAssertLessThanOrEqual(visibleName.frame.maxX, app.windows.firstMatch.frame.maxX - 19)
                // Old contract: a read-only count row published its own
                // inventory.summary.* controls above the picker.
                // New contract: there is one filter surface, and the counts live
                // on the choices. At Accessibility sizes that surface is the
                // compact Menu, exactly as InventoryNavigationUITests pins it.
                //
                // Not weaker: the same two states are still driven through a
                // real hittable control and the render is still captured either
                // side of the change; the control asserted is now the one that
                // actually applies the filter.
                if accessibility {
                    let menu = app.buttons["inventory.filter.menu"]
                    XCTAssertTrue(menu.waitForExistence(timeout: 5))
                    XCTAssertGreaterThanOrEqual(menu.frame.height, 43.5)
                } else {
                    let picker = app.segmentedControls["inventory.filter.picker"]
                    let all = picker.buttons["inventory.filter.option.all"]
                    let expiring = picker.buttons["inventory.filter.option.expiringSoon"]
                    XCTAssertTrue(all.waitForExistence(timeout: 5))
                    // The documented, narrowly scoped native-segment exception:
                    // this unmodified SwiftUI Picker publishes ~32pt segments.
                    // 44pt remains the app target for custom controls.
                    XCTAssertGreaterThanOrEqual(all.frame.height, 28)
                    expiring.tap()
                    XCTAssertTrue(all.isHittable)
                    all.tap()
                }
                // Supplementary evidence for the common-staple rail and tab clearance.
                app.swipeUp()
                attach(prefix + "-Rows")
            } else {
                let action = app.buttons[name == "Home-Planned" ? "home.today.plan.start" : "home.recommendation.addToday"]
                let target = action
                for _ in 0..<6 {
                    if target.isHittable { break }
                    app.swipeUp()
                }
                XCTAssertTrue(target.isHittable)
                // Half-point tolerance for XCTest floating-point frame conversion.
                XCTAssertGreaterThanOrEqual(target.frame.height, 43.5)
                if name == "Home-Planned" {
                    let toggle = app.buttons["home.meal.menu.toggle"]
                    for _ in 0..<6 {
                        if toggle.isHittable { break }
                        app.swipeUp()
                    }
                    XCTAssertTrue(toggle.isHittable)
                    // Old contract: the disclosure header repeated the whole
                    // menu s dish count. New contract: the count is stated once,
                    // on the hero own status line, and the disclosure names
                    // only what it holds — the dishes the hero did not.
                    //
                    // Not weaker: the number is still asserted on this render,
                    // on the element that now owns it, and the disclosure is
                    // additionally pinned to its own contract.
                    XCTAssertTrue(toggle.label.hasPrefix("另有"), toggle.label)
                    let status = app.descendants(matching: .any)["home.hero.status"]
                    XCTAssertTrue(status.waitForExistence(timeout: 5))
                    XCTAssertTrue(status.label.contains("4 道菜"), status.label)
                    toggle.tap()
                    toggle.tap()
                }
                attach(prefix + "-Actions")
            }
            app.terminate()
        }
    }

    @MainActor private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif

import XCTest

@MainActor
final class ShoppingRegressionUITests: XCTestCase {
    private var capturePrefix = "Shopping-Regression-"
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ state: String = "", dark: Bool = false, accessibility: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_SHOPPING_REGRESSION", state,
                               "-UIPreferredContentSizeCategoryName",
                               accessibility ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryLarge"]
        app.launchArguments.append(dark ? "UITEST_FORCE_DARK_APPEARANCE" : "UITEST_FORCE_LIGHT_APPEARANCE")
        app.launch()
        XCTAssertTrue(app.navigationBars.staticTexts["买菜"].waitForExistence(timeout: 10))
        return app
    }

    private func capture(_ state: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = capturePrefix + state
        attachment.lifetime = .keepAlways
        add(attachment)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = capturePrefix + state + "-accessibility"
        tree.lifetime = .keepAlways
        add(tree)
    }

    private func reveal(_ key: String, in app: XCUIApplication, fullyVisible: Bool = false,
                        type: XCUIElement.ElementType = .button) {
        let scroll = app.collectionViews.firstMatch
        var positions = Set<String>()
        while true {
            // Section identifiers propagate to rows; resolve the requested label/ID anew.
            let element = app.descendants(matching: type)
                .matching(NSPredicate(format: "identifier == %@ OR label == %@", key, key)).element
            let bar = scroll.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Vertical scroll bar")).firstMatch
            var viewport = scroll.frame.intersection(app.windows.firstMatch.frame)
            if bar.exists { viewport = CGRect(x: viewport.minX, y: bar.frame.minY, width: viewport.width, height: bar.frame.height) }
            let top = max(viewport.minY, app.navigationBars.firstMatch.frame.maxY)
            var bottom = viewport.maxY
            if app.tabBars.firstMatch.exists { bottom = min(bottom, app.tabBars.firstMatch.frame.minY) }
            if app.keyboards.firstMatch.exists { bottom = min(bottom, app.keyboards.firstMatch.frame.minY) }
            // Leave room for the native pinned category header when scrolling rows.
            let headerHeight = scroll.staticTexts.allElementsBoundByIndex
                .filter { $0.identifier.hasPrefix("shopping.section.") }
                .map { $0.frame.height }.max() ?? 0
            viewport = CGRect(x: viewport.minX, y: top + headerHeight, width: viewport.width,
                              height: bottom - top - headerHeight)
            XCTAssertGreaterThan(viewport.height, 0)
            if element.exists && element.isHittable,
               !fullyVisible || (element.frame.minY >= viewport.minY && element.frame.maxY <= viewport.maxY) { return }

            let visible = scroll.cells.allElementsBoundByIndex.filter { $0.frame.intersects(viewport) }
            let position = visible.map { "\($0.label):\(Int(($0.frame.minY / 4).rounded()))" }.joined(separator: "|")
            guard positions.insert(position).inserted else {
                XCTFail("No scroll progress while revealing \(key): \(element.debugDescription)")
                return
            }
            let limit = viewport.height * 0.6
            let delta = element.exists ? max(-limit, min(limit, element.frame.midY - viewport.midY)) : limit
            let startY = delta >= 0 ? viewport.maxY - 10 : viewport.minY + 10
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: viewport.midX, dy: startY))
                .press(forDuration: 0.1,
                       thenDragTo: origin.withOffset(CGVector(dx: viewport.midX, dy: startY - delta)),
                       withVelocity: .slow, thenHoldForDuration: 0.1)
        }
    }

    func testActiveListAndShoppingModeKeepCompletionContract() {
        let app = launch()
        let item = app.buttons["上海青，2 把，未购买"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(item.frame.height, 44 - 1e-9)
        capture("01-Active", in: app)
        app.buttons["shopping.mode.toggle"].tap()
        XCTAssertTrue(app.buttons["shopping.mode.exit"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["shopping.add.button"].isHittable)
        XCTAssertTrue(app.searchFields.firstMatch.exists)
        XCTAssertFalse(app.buttons["shopping.bulk.menu"].exists)
        app.buttons["上海青，2 把，未购买"].tap()
        let purchased = app.buttons["shopping.mode.purchased.toggle"]
        reveal("shopping.mode.purchased.toggle", in: app)
        purchased.tap()
        let completed = app.buttons["上海青，2 把，已购买"]
        reveal("上海青，2 把，已购买", in: app)
        completed.tap()
        XCTAssertFalse(app.buttons["上海青，2 把，已购买"].exists)
    }

    func testMixedListAndDestructiveConfirmation() {
        let app = launch("SHOPPING_DATA_MIXED")
        let toggle = app.buttons["shopping.purchased.toggle"]
        reveal("shopping.purchased.toggle", in: app)
        toggle.tap()
        XCTAssertTrue(app.buttons["牛奶，2 L，已购买"].waitForExistence(timeout: 5))
        capture("02-Mixed", in: app)
        app.buttons["shopping.bulk.menu"].tap()
        app.buttons["清除已购买"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        capture("07-Bulk-Confirmation", in: app)
        alert.buttons["取消"].tap()
        XCTAssertTrue(toggle.exists)
    }

    func testDenseNamesAndLastRowRemainReachable() {
        let app = launch("SHOPPING_DATA_DENSE")
        XCTAssertTrue(app.buttons["意大利整颗去皮番茄罐头（无添加盐），3 罐，未购买"].waitForExistence(timeout: 5))
        capture("03-Dense", in: app)
        let last = app.buttons["厨房纸，12 卷，未购买"]
        reveal("厨房纸，12 卷，未购买", in: app)
        last.tap()
        XCTAssertFalse(last.exists)
    }

    func testEmptyAddAndEnteredQuantityUnit() {
        let app = launch("SHOPPING_DATA_EMPTY")
        let add = app.buttons["shopping.empty.add.button"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        capture("04-Empty", in: app)
        add.tap()
        let name = app.textFields["名称"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        capture("05-Add-Form", in: app)
        name.tap()
        name.typeText("无糖希腊酸奶")
        replace("数量", with: "12", in: app)
        replace("单位", with: "杯", in: app)
        app.navigationBars.buttons["添加"].tap()
        // The entered quantity must reach `save()`: a stale binding fails the
        // validation guard and leaves this form open on a screen that already
        // shows a valid number.
        XCTAssertTrue(app.navigationBars["添加买菜项目"].waitForNonExistence(timeout: 5), "添加 did not close the form")
        XCTAssertTrue(app.buttons["无糖希腊酸奶，12 杯，未购买"].waitForExistence(timeout: 5))
        capture("06-Entered-Quantity-Unit", in: app)
    }

    func testStoredSourceContext() {
        let app = launch("SHOPPING_DATA_SOURCES")
        XCTAssertTrue(app.buttons["上海青，2 把，今日计划，未购买"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["番茄，4 个，菜谱，未购买"].exists)
        capture("08-Sources", in: app)
    }

    private func replace(_ key: String, with text: String, in app: XCUIApplication) {
        var positions = Set<String>()
        while true {
            let field = app.textFields[key]
            let navigation = app.navigationBars["添加买菜项目"]
            let form = app.collectionViews.containing(.textField, identifier: key).firstMatch
            guard field.exists, navigation.exists, form.exists else {
                XCTFail("Missing presented Form or field \(key): \(app.debugDescription)")
                return
            }
            var viewport = form.frame.intersection(app.windows.firstMatch.frame)
            let bar = form.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Vertical scroll bar")).firstMatch
            if bar.exists { viewport = viewport.intersection(CGRect(x: viewport.minX, y: bar.frame.minY, width: viewport.width, height: bar.frame.height)) }
            let top = max(viewport.minY, navigation.frame.maxY)
            var bottom = viewport.maxY
            if app.keyboards.firstMatch.exists {
                bottom = min(bottom, app.keyboards.firstMatch.frame.minY)
                // The input surface includes the candidate bar above Keyboard.
                for id in ["inputView", "SystemInputAssistantView"] {
                    let input = app.otherElements[id].firstMatch
                    if input.exists { bottom = min(bottom, input.frame.minY) }
                }
            }
            viewport = CGRect(x: viewport.minX, y: top, width: viewport.width, height: bottom - top).insetBy(dx: 8, dy: 8)
            guard viewport.height > 0 else {
                XCTFail("No interactive Form viewport for \(key): \(viewport)")
                return
            }
            let frame = field.frame
            // Native LabeledContent exposes label + editable value as one field.
            // Use its current value-area point, never a cached screen coordinate.
            let offset = CGVector(dx: 0.99, dy: 0.8)
            let point = CGPoint(x: frame.minX + frame.width * offset.dx, y: frame.minY + frame.height * offset.dy)
            if viewport.contains(point), field.isHittable {
                print("[ShoppingFormEdit] \(key) frame=\(frame) viewport=\(viewport) point=\(point)")
                field.coordinate(withNormalizedOffset: offset).tap()
                let current = app.textFields[key]
                guard navigation.exists, current.exists else {
                    XCTFail("Form disappeared while focusing \(key): \(app.debugDescription)")
                    return
                }
                let old = current.value as? String ?? ""
                current.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + text)
                XCTAssertTrue(app.navigationBars["添加买菜项目"].exists, "Add must not fire during field editing")
                XCTAssertEqual(app.textFields[key].value as? String, text)
                return
            }
            let position = "\(Int(frame.minY.rounded())):\(Int(viewport.minY.rounded())):\(Int(viewport.maxY.rounded()))"
            guard positions.insert(position).inserted else {
                XCTFail("No Form scroll progress for \(key), frame=\(frame), viewport=\(viewport): \(app.debugDescription)")
                return
            }
            let limit = viewport.height * 0.5
            let delta = max(-limit, min(limit, point.y - viewport.midY))
            let startY = delta >= 0 ? viewport.maxY : viewport.minY
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: viewport.midX, dy: startY))
                .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: viewport.midX, dy: startY - delta)),
                       withVelocity: .slow, thenHoldForDuration: 0.1)
        }
    }

    func testProductionLightNormalMatrix() { matrix(dark: false, accessibility: false) }
    func testProductionDarkNormalMatrix() { matrix(dark: true, accessibility: false) }
    func testProductionLightAccessibilityMatrix() { matrix(dark: false, accessibility: true) }
    func testProductionDarkAccessibilityMatrix() { matrix(dark: true, accessibility: true) }

    private func matrix(dark: Bool, accessibility: Bool) {
        var app = launch(dark: dark, accessibility: accessibility)
        let small = app.windows.firstMatch.frame.width < 390
        capturePrefix = "Shopping-\(small ? "Small" : "Pro")-\(dark ? "Dark" : "Light")-\(accessibility ? "AXXXL" : "Normal")-"
        XCTAssertTrue(app.buttons["shopping.add.button"].isHittable)
        XCTAssertTrue(app.buttons["shopping.bulk.menu"].isHittable)
        if !small { capture("01-Active", in: app) }

        app = launch("SHOPPING_DATA_DENSE", dark: dark, accessibility: accessibility)
        let long = app.buttons["意大利整颗去皮番茄罐头（无添加盐），3 罐，未购买"]
        reveal("意大利整颗去皮番茄罐头（无添加盐），3 罐，未购买", in: app, fullyVisible: true)
        XCTAssertGreaterThanOrEqual(long.frame.height, 44 - 1e-9)
        capture("03-Dense", in: app)
        let last = app.buttons["厨房纸，12 卷，未购买"]
        reveal("厨房纸，12 卷，未购买", in: app, fullyVisible: true)
        XCTAssertLessThanOrEqual(last.frame.maxY, app.windows.firstMatch.frame.maxY)
        last.tap()
        XCTAssertFalse(last.exists)

        app = launch("SHOPPING_DATA_MIXED", dark: dark, accessibility: accessibility)
        let toggle = app.buttons["shopping.purchased.toggle"]
        reveal("shopping.purchased.toggle", in: app)
        toggle.tap()
        let milk = app.buttons["牛奶，2 L，已购买"]
        reveal("牛奶，2 L，已购买", in: app, fullyVisible: true)
        XCTAssertGreaterThanOrEqual(milk.frame.height, 44 - 1e-9)
        capture("02-Mixed", in: app)
        if !small {
            app.buttons["shopping.bulk.menu"].tap()
            app.buttons["清除已购买"].tap()
            let alert = app.alerts.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 5))
            capture("07-Bulk-Confirmation", in: app)
            alert.buttons["取消"].tap()
            XCTAssertTrue(toggle.exists)
        }

        app = launch("SHOPPING_DATA_EMPTY", dark: dark, accessibility: accessibility)
        let add = app.buttons["shopping.empty.add.button"]
        reveal("shopping.empty.add.button", in: app)
        capture("04-Empty", in: app)
        add.tap()
        let name = app.textFields["名称"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("无糖希腊酸奶")
        reveal("数量", in: app, type: .textField)
        replace("数量", with: "12", in: app)
        reveal("单位", in: app, type: .textField)
        replace("单位", with: "杯", in: app)
        capture("05-Add-Form", in: app)
        let save = app.navigationBars.buttons["添加"]
        XCTAssertTrue(save.isHittable)
        save.tap()
        let entered = app.buttons["无糖希腊酸奶，12 杯，未购买"]
        reveal("无糖希腊酸奶，12 杯，未购买", in: app, fullyVisible: true)
        if !small { capture("06-Entered-Quantity-Unit", in: app) }

        app = launch("SHOPPING_DATA_SOURCES", dark: dark, accessibility: accessibility)
        let sourced = app.buttons["上海青，2 把，今日计划，未购买"]
        reveal("上海青，2 把，今日计划，未购买", in: app, fullyVisible: true)
        capture("08-Sources", in: app)
        sourced.tap()
        XCTAssertFalse(sourced.exists)
    }
}

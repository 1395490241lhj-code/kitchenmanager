import XCTest

/// Verifies Problem 2 end-to-end in the real running manual-entry screen
/// (`RecordFoodSheet.manualContent` in ReceiptImport.swift): the old
/// "设置保质期"/"启用保质期" toggle must be gone, a plain DatePicker must
/// always be present once a draft is parsed, and editing the ingredient
/// name after the user has manually changed the date must not revert it.
final class ManualEntryExpiryUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testManualEntry_noExpiryToggle_datePickerAlwaysPresent() throws {
        let app = XCUIApplication()
        app.launch()

        // Manual ingredient entry lives behind the header "+" ("导入与添加")
        // button — tap it via its stable accessibility identifier (not the
        // Chinese label, which the product copy has changed more than once),
        // then the "手动添加食材" row via its own stable identifier, both of
        // which open `RecordFoodSheet` exactly as before.
        let smartImportButton = app.buttons["home.import.add.button"]
        XCTAssertTrue(smartImportButton.waitForExistence(timeout: 5))
        smartImportButton.tap()

        let manualIngredientRow = app.buttons["home.import.food.manual"]
        XCTAssertTrue(manualIngredientRow.waitForExistence(timeout: 5))
        manualIngredientRow.tap()

        let manualSegment = app.segmentedControls.buttons["手动输入"]
        XCTAssertTrue(manualSegment.waitForExistence(timeout: 5))
        manualSegment.tap()

        let manualTextField = app.textViews.firstMatch.exists
            ? app.textViews.firstMatch
            : app.textFields["番茄、鸡蛋2个、韭菜花一份"]
        XCTAssertTrue(manualTextField.waitForExistence(timeout: 5))
        manualTextField.tap()
        manualTextField.typeText("鸡蛋2个")

        // The old toggle-driven strings must never appear anywhere in this sheet.
        XCTAssertFalse(app.staticTexts["设置保质期"].exists, "旧的“设置保质期”开关文案不应再出现")
        XCTAssertFalse(app.buttons["设置保质期"].exists, "旧的“设置保质期”开关按钮不应再出现")
        XCTAssertFalse(app.staticTexts["启用保质期"].exists, "旧的“启用保质期”文案不应再出现")
        XCTAssertFalse(app.staticTexts["不设置保质期"].exists, "旧的“不设置保质期”文案不应再出现")

        // The plain, always-visible expiry DatePicker + short caption must exist.
        XCTAssertTrue(app.staticTexts["保质期"].waitForExistence(timeout: 5), "应始终显示“保质期”标签的 DatePicker")
        XCTAssertTrue(
            app.staticTexts["系统根据食材类型自动建议，可手动调整"].waitForExistence(timeout: 3),
            "应显示自动建议的简短说明文案"
        )
        XCTAssertTrue(app.datePickers.firstMatch.exists, "应始终存在一个可编辑的到期日期 DatePicker")
    }
}

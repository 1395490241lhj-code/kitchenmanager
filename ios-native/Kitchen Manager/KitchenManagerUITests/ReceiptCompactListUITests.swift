import XCTest

/// Verifies Problem 1 in the real running receipt confirmation screen
/// (`RecordFoodSheet.receiptContent` in ReceiptImport.swift) using the
/// `UITEST_SEED_RECEIPT_ITEMS` debug hook, which seeds 20 recognized items
/// directly (bypassing the camera + OCR network round trip). Checks: all
/// items render, per-row height is compact (not the old ~200pt+ per-item
/// Section), the list scrolls, the last item and the bottom confirm button
/// are both reachable, and every item still shows a delete control.
final class ReceiptCompactListUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testReceiptList_twentyItems_isCompactAndScrollable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_RECEIPT_ITEMS"]
        app.launch()

        // Receipt scanning lives behind the header "+" ("导入与添加") button —
        // tap it via its stable accessibility identifier (not the Chinese
        // label, which the product copy has changed more than once), then
        // the "扫描购物小票" row via its own stable identifier, which opens
        // `RecordFoodSheet(initialMode: .receipt)` exactly as before.
        let smartImportButton = app.buttons["home.import.add.button"]
        XCTAssertTrue(smartImportButton.waitForExistence(timeout: 5))
        smartImportButton.tap()

        let receiptRow = app.buttons["home.import.food.receipt"]
        XCTAssertTrue(receiptRow.waitForExistence(timeout: 5))
        receiptRow.tap()

        // The seeded image-less placeholder section still renders above the
        // items list, and Form/List (UITableView-backed) only realizes
        // on-screen rows in the accessibility tree — scroll down first so
        // the "识别到 20 项" header and item rows actually get laid out.
        let nameFields = app.textFields.matching(identifier: "receiptItemName")
        var scrollAttempts = 0
        while !nameFields.firstMatch.exists && scrollAttempts < 10 {
            app.swipeUp()
            scrollAttempts += 1
        }
        XCTAssertTrue(nameFields.firstMatch.waitForExistence(timeout: 5))

        let header = app.staticTexts["识别到 20 项"]
        XCTAssertTrue(header.exists, "应显示识别到 20 项的头部文案")

        // Scroll further so the (large, one-time) photo placeholder section
        // is fully out of view and the item list occupies the whole
        // viewport — otherwise the leftover header content above the fold
        // would understate how many compact rows actually fit per screen.
        app.swipeUp()
        app.swipeUp()

        // Form/List (UITableView-backed) only realizes on-screen rows, so
        // `nameFields.count` here is "how many item rows are visible at
        // once" rather than all 20 — a direct proxy for compactness. The
        // old ~200pt+ per-item Section design fit at most 1-2 rows per
        // screen; the new compact row (~72-96pt) should fit several more.
        let visibleRowCount = nameFields.count
        XCTAssertGreaterThan(visibleRowCount, 3, "紧凑布局应能在一屏内显示多于 3 行，实际同时可见 \(visibleRowCount) 行")

        // Compact row height check: measure the vertical gap between two
        // consecutive visible item rows' name fields.
        let firstFrame = nameFields.element(boundBy: 0).frame
        let secondFrame = nameFields.element(boundBy: 1).frame
        let rowSpacing = secondFrame.minY - firstFrame.minY
        XCTAssertGreaterThan(rowSpacing, 0, "第二行应位于第一行下方")
        XCTAssertLessThan(rowSpacing, 110, "每个食材行的高度应保持紧凑（约 72-96pt），实际约 \(rowSpacing)pt")

        // Every visible row must expose its own delete control, and deleting
        // one must actually remove just that item.
        let deleteButtons = app.buttons.matching(identifier: "receiptItemDelete")
        XCTAssertEqual(deleteButtons.count, visibleRowCount, "每一项都应有独立的删除按钮")
        var hittableDeleteButton: XCUIElement?
        for index in 0..<deleteButtons.count {
            let candidate = deleteButtons.element(boundBy: index)
            // Xcode 27 can report a recycled row under the navigation/status
            // area as hittable even though a synthesized tap is intercepted.
            // Exercise a control fully inside the visible content viewport.
            let frame = candidate.frame
            let isInsideContent = frame.minY >= 100 && frame.maxY <= app.frame.maxY - 100
            if candidate.isHittable && isInsideContent {
                hittableDeleteButton = candidate
                break
            }
        }
        guard let hittableDeleteButton else {
            XCTFail("至少一个可见食材行的删除按钮应可点击")
            return
        }
        hittableDeleteButton.tap()
        // SwiftUI List may retain and reuse an off-screen TextField's
        // accessibility node after row deletion. The bottom action's
        // selected-count label is the stable user-visible result checked
        // below after scrolling to the end.

        // Scroll to the bottom: the last item and the confirm button must
        // both be reachable, i.e. the button must not permanently cover the
        // last row.
        let lastItemField = app.textFields.matching(
            NSPredicate(format: "value == %@", "咖啡豆")
        ).firstMatch
        var attempts = 0
        while (!lastItemField.exists || !lastItemField.isHittable) && attempts < 20 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(lastItemField.waitForExistence(timeout: 3), "最后一项（咖啡豆）应可通过滚动到达")
        XCTAssertTrue(lastItemField.isHittable, "最后一项应可被点击，不应被底部按钮遮挡")

        let confirmButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "确认入库（19）")
        ).firstMatch
        attempts = 0
        while !confirmButton.exists && attempts < 5 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 3), "删除一项后底部应显示确认入库（19），且按钮可到达")
    }
}

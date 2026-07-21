import XCTest
@testable import KitchenManager

final class UIFeedbackTests: XCTestCase {
    func testFeedbackStylesUseDistinctSemanticIconsAndVoiceOverPrefixes() {
        XCTAssertEqual(AppFeedbackStyle.success.systemImage, "checkmark.circle.fill")
        XCTAssertEqual(AppFeedbackStyle.warning.systemImage, "exclamationmark.triangle.fill")
        XCTAssertEqual(AppFeedbackStyle.error.systemImage, "xmark.circle.fill")
        XCTAssertEqual(AppFeedbackStyle.error.accessibilityLabel(for: "库存保存失败"), "错误：库存保存失败")
    }

    func testInventoryNoticePresentationKeepsKnownSuccessCopySuccessful() {
        XCTAssertEqual(
            InventoryNoticePresentation.style(for: "已添加 2 项食材"),
            .success
        )
        XCTAssertEqual(
            InventoryNoticePresentation.style(for: "库存保存失败，请稍后重试。"),
            .error
        )
    }

    func testUnknownInventoryNoticeDefaultsToError() {
        XCTAssertEqual(
            InventoryNoticePresentation.style(for: "持久化服务返回未知错误"),
            .error
        )
    }
}

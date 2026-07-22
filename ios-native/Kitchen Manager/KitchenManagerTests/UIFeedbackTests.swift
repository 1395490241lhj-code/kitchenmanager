import XCTest
@testable import KitchenManager

@MainActor
final class UIFeedbackTests: XCTestCase {
    func testFeedbackStylesUseDistinctSemanticIconsAndVoiceOverPrefixes() {
        let expected: [(AppFeedbackStyle, String, String)] = [
            (.success, "checkmark.circle.fill", "成功"),
            (.warning, "exclamationmark.triangle.fill", "提醒"),
            (.error, "xmark.circle.fill", "错误"),
            (.informational, "info.circle.fill", "提示")
        ]

        for (style, symbol, prefix) in expected {
            XCTAssertEqual(style.systemImage, symbol)
            XCTAssertEqual(style.accessibilityLabel(for: "库存保存失败"), "\(prefix)：库存保存失败")
        }
    }

    func testInventoryNoticePresentationRecognizesOnlyTheSharedImportSuccessFormat() {
        XCTAssertEqual(
            InventoryNoticePresentation.style(for: InventoryNoticeText.importedItemsMessage(count: 2)),
            .success
        )
        XCTAssertEqual(InventoryNoticeText.importedItemsCount(from: "已添加 0 项食材"), nil)
        XCTAssertEqual(InventoryNoticeText.importedItemsCount(from: "已添加 两 项食材"), nil)
        XCTAssertEqual(InventoryNoticeText.importedItemsCount(from: "已添加 2 项食材，请稍后重试。"), nil)
    }

    func testInventoryNoticePresentationTreatsEveryKnownFailureAndUnknownMessageAsError() {
        [
            "库存保存失败，请稍后重试。",
            "厨房数据暂时无法清除，请稍后重试。",
            "迁移库存时发生未知错误。",
            "持久化服务返回未知错误"
        ].forEach {
            XCTAssertEqual(InventoryNoticePresentation.style(for: $0), .error)
        }
    }

    func testAnnouncementGateAnnouncesOncePerPresentationAndResetsAfterDisappearance() {
        var gate = FeedbackAnnouncementGate()
        XCTAssertTrue(gate.shouldAnnounce("库存保存失败"))
        XCTAssertFalse(gate.shouldAnnounce("库存保存失败"))
        XCTAssertTrue(gate.shouldAnnounce("请稍后重试"))
        gate.reset()
        XCTAssertTrue(gate.shouldAnnounce("库存保存失败"))
    }
}

import XCTest
import SwiftUI
import UIKit
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

    func testP0SemanticColorPairsMeetNormalTextContrast() {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)

        assertContrast(AppTheme.onCookingAction, AppTheme.cookingActionFill, traits: light)
        assertContrast(AppTheme.onCookingAction, AppTheme.cookingActionFill, traits: dark)
        assertContrast(AppTheme.onManagementAction, AppTheme.managementActionFill, traits: light)
        assertContrast(AppTheme.onManagementAction, AppTheme.managementActionFill, traits: dark)
        assertContrast(AppTheme.cookingAccentForeground, Color(uiColor: .systemGroupedBackground), traits: light)
        assertContrast(AppTheme.cookingAccentForeground, Color(uiColor: .systemGroupedBackground), traits: dark)
        assertContrast(AppTheme.cookingAccentForeground, AppTheme.secondarySurface, traits: light)
        assertContrast(AppTheme.cookingAccentForeground, AppTheme.secondarySurface, traits: dark)
        assertContrast(AppTheme.aiAccentForeground, Color(uiColor: .systemGroupedBackground), traits: light)
        assertContrast(AppTheme.aiAccentForeground, Color(uiColor: .systemGroupedBackground), traits: dark)
        assertContrast(AppTheme.aiAccentForeground, AppTheme.secondarySurface, traits: light)
        assertContrast(AppTheme.aiAccentForeground, AppTheme.secondarySurface, traits: dark)
        assertContrast(AppTheme.successInk, AppTheme.surface, traits: light)
        assertContrast(AppTheme.warningInk, AppTheme.surface, traits: light)
    }

    private func assertContrast(
        _ foreground: Color,
        _ background: Color,
        traits: UITraitCollection,
        minimum: CGFloat = 4.5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let foregroundColor = UIColor(foreground).resolvedColor(with: traits)
        let backgroundColor = UIColor(background).resolvedColor(with: traits)
        XCTAssertGreaterThanOrEqual(
            foregroundColor.contrastRatio(with: backgroundColor),
            minimum,
            file: file,
            line: line
        )
    }
}

private extension UIColor {
    func contrastRatio(with other: UIColor) -> CGFloat {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    var relativeLuminance: CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: nil)

        func linearized(_ component: CGFloat) -> CGFloat {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * linearized(red)
            + 0.7152 * linearized(green)
            + 0.0722 * linearized(blue)
    }
}

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
        // KitchenButtonStyle(role: .primary) fills with this token, not the
        // AppTheme one above, though both are #3866D6 today.
        assertContrast(.white, KitchenTheme.cookingFill, traits: light)
        assertContrast(.white, KitchenTheme.cookingFill, traits: dark)
        assertContrast(AppTheme.cookingAccentForeground, Color(uiColor: .systemGroupedBackground), traits: light)
        assertContrast(AppTheme.cookingAccentForeground, Color(uiColor: .systemGroupedBackground), traits: dark)
        assertContrast(AppTheme.cookingAccentForeground, AppTheme.secondarySurface, traits: light)
        assertContrast(AppTheme.cookingAccentForeground, AppTheme.secondarySurface, traits: dark)
        // KitchenButtonStyle(role: .secondary): foreground on its own fill.
        assertContrast(KitchenTheme.cookingGreen, KitchenTheme.elevatedSurface, traits: light)
        assertContrast(KitchenTheme.cookingGreen, KitchenTheme.elevatedSurface, traits: dark)
        assertContrast(AppTheme.successInk, AppTheme.surface, traits: light)
        assertContrast(AppTheme.warningInk, AppTheme.surface, traits: light)
    }

    /// Home's card lighting is a property of the surface. Drawn on top of the
    /// content it washed the 加入今天 fill under white text to ~2.9:1 and
    /// greyed every line of the recommendation card (found on the simulator).
    /// Token-level contrast checks above cannot see a layer composited over
    /// the token, so this one reads the rendered pixel.
    func testHomeSurfaceLightingNeverTintsTheContentAbove() throws {
        let surfaces: [(String, (AnyView) -> AnyView)] = [
            ("decision", { AnyView($0.kitchenHomeDecisionSurface()) }),
            ("task", { AnyView($0.kitchenHomeTaskSurface()) })
        ]
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let expected = UIColor(KitchenTheme.cookingFill).resolvedColor(with: traits)
            for (name, surface) in surfaces {
                let sentinel = AnyView(
                    Rectangle()
                        .fill(KitchenTheme.cookingFill)
                        .frame(width: 200, height: 120)
                        .padding(KitchenTheme.heroPadding)
                )
                let image = try renderedImage(
                    surface(sentinel).environment(\.colorScheme, style == .dark ? .dark : .light),
                    style: style
                )
                let sample = try pixel(of: image, x: 116, y: 76)
                let label = "\(name) surface, \(style == .dark ? "Dark" : "Light")"
                XCTAssertTrue(sample.matches(expected), "\(label): content was tinted to \(sample)")
                XCTAssertGreaterThanOrEqual(UIColor.white.contrastRatio(with: sample), 4.5, label)

                // D-049's weak vertical lighting must survive: the decision
                // card's padding is lighter at the top than at the bottom.
                // Sampled below the 1pt top highlight at y = 2-3.
                if name == "decision" && style == .light {
                    let top = try pixel(of: image, x: 116, y: 8)
                    let bottom = try pixel(of: image, x: 116, y: 146)
                    XCTAssertGreaterThan(top.relativeLuminance, bottom.relativeLuminance,
                                         "decision surface lost its vertical lighting")
                }
            }
        }
    }

    private func renderedImage<Content: View>(_ content: Content, style: UIUserInterfaceStyle) throws -> UIImage {
        let host = UIHostingController(rootView: content)
        host.overrideUserInterfaceStyle = style
        // The window sits at the screen origin; without this the device's
        // top inset shifts the content and every sampled point with it.
        host.safeAreaRegions = []
        let size = host.sizeThatFits(in: CGSize(width: 390, height: 2_000))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = style
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
    }

    /// One pixel read through a 1x1 sRGB context, so the bytes do not depend
    /// on the renderer's backing format.
    private func pixel(of image: UIImage, x: Int, y: Int) throws -> UIColor {
        let cgImage = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(cgImage, in: CGRect(x: -x, y: y - cgImage.height + 1,
                                             width: cgImage.width, height: cgImage.height))
        }
        return UIColor(red: CGFloat(bytes[0]) / 255, green: CGFloat(bytes[1]) / 255,
                       blue: CGFloat(bytes[2]) / 255, alpha: 1)
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
    /// Same colour within one 8-bit step per channel.
    func matches(_ other: UIColor) -> Bool {
        var a: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        var b: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        getRed(&a.0, green: &a.1, blue: &a.2, alpha: nil)
        other.getRed(&b.0, green: &b.1, blue: &b.2, alpha: nil)
        let step: CGFloat = 1.5 / 255
        return abs(a.0 - b.0) <= step && abs(a.1 - b.1) <= step && abs(a.2 - b.2) <= step
    }

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

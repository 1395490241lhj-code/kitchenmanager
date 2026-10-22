import SwiftUI
import XCTest
@testable import KitchenManager

@MainActor
final class KitchenActionLabelTests: XCTestCase {
    func testSaveLabelKeepsItsFootprintAcrossEveryPhaseAndTextSize() {
        for size in [DynamicTypeSize.large, .accessibility5] {
            let dimensions = KitchenActionPhase.allCases.map { phase in
                let host = UIHostingController(rootView:
                    KitchenActionLabel(phase: phase, idleTitle: "保存到菜谱库", idleSymbol: "square.and.arrow.down")
                        .environment(\.dynamicTypeSize, size)
                )
                return host.sizeThatFits(in: CGSize(width: 300, height: 1_000))
            }
            for dimension in dimensions {
                XCTAssertEqual(dimension.width, dimensions[0].width, accuracy: 0.5)
                XCTAssertEqual(dimension.height, dimensions[0].height, accuracy: 0.5)
                XCTAssertGreaterThan(dimension.height, 0)
            }
        }
    }

    func testEveryPhaseRendersDistinctVisibleContent() throws {
        var images: [Data] = []
        for phase in KitchenActionPhase.allCases {
            let image = try snapshot(
                KitchenActionLabel(phase: phase, idleTitle: "保存到菜谱库", idleSymbol: "square.and.arrow.down")
                    .foregroundStyle(.white)
                    .padding(16)
                    .background(.blue)
                    .environment(\.colorScheme, .light)
            )
            images.append(try XCTUnwrap(image.pngData()))
        }
        // Geometry-only and accessibility-label tests would stay green if the
        // visible overlay were accidentally deleted. Pixel output must differ.
        XCTAssertEqual(Set(images).count, KitchenActionPhase.allCases.count)
    }

    private func snapshot<Content: View>(_ content: Content) throws -> UIImage {
        let host = UIHostingController(rootView: content)
        let size = host.sizeThatFits(in: CGSize(width: 390, height: 2_000))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        // SwiftUI ImageRenderer substitutes an unavailable glyph for the native
        // ProgressView. Render the hosted hierarchy to include the real spinner.
        return UIGraphicsImageRenderer(size: size).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
    }
}

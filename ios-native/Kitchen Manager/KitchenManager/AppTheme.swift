import SwiftUI
import UIKit

/// The single source of truth for the user's chosen appearance. Backed by
/// `@AppStorage("appearance")` wherever it's read/written so every screen stays in sync
/// without a dedicated settings store.
enum AppAppearance: String, CaseIterable, Identifiable, Codable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum AppTheme {
    static let primary = adaptive(light: 0x007AFF, dark: 0x0A84FF)
    static let primaryDark = adaptive(light: 0x005ECB, dark: 0x409CFF)
    static let primarySoft = adaptive(light: 0xEAF4FF, dark: 0x10243A)
    static let success = adaptive(light: 0x34C759, dark: 0x30D158)
    static let warning = adaptive(light: 0xFF9500, dark: 0xFFB340)
    static let shopping = adaptive(light: 0x14B8A6, dark: 0x2DD4BF)
    static let textPrimary = adaptive(light: 0x1D1D1F, dark: 0xF5F5F7)
    static let textSecondary = adaptive(light: 0x6E6E73, dark: 0xC7C7CC)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x1C1C1E)
    static let secondarySurface = adaptive(light: 0xF5F5F7, dark: 0x2C2C2E)
    static let separator = adaptive(light: 0xD2D2D7, dark: 0x48484A)

    // Inventory lifecycle surfaces mirror the PWA's calm green → amber → orange
    // → red hierarchy, while retaining contrast in both system appearances.
    static let inventoryFreshBackground = adaptive(light: 0xECF9F0, dark: 0x143421)
    static let inventoryUpcomingBackground = adaptive(light: 0xFFF8DE, dark: 0x3A3013)
    static let inventoryExpiringBackground = adaptive(light: 0xFFF1E2, dark: 0x3D2614)
    static let inventoryTodayBackground = adaptive(light: 0xFFE9DF, dark: 0x472018)
    static let inventoryExpiredBackground = adaptive(light: 0xFCE8E6, dark: 0x461E20)
    static let inventoryUnknownBackground = adaptive(light: 0xF2F2F7, dark: 0x2C2C2E)
    static let inventoryUpcoming = adaptive(light: 0xC58B00, dark: 0xFFD60A)
    static let inventoryToday = adaptive(light: 0xD95C1A, dark: 0xFF9F0A)
    static let inventoryExpired = adaptive(light: 0xD92D2A, dark: 0xFF6961)

    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    /// Card/panel drop shadows read as elevation in light mode but just muddy a dark
    /// background, so this cancels them out under dark mode instead of leaving a fixed
    /// black shadow that no longer means anything.
    static func cardShadow(opacity: Double) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.black.withAlphaComponent(0)
                : UIColor.black.withAlphaComponent(opacity)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

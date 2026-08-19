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
    /// Shared minimum touch target for compact controls that still need to be
    /// reachable at every Dynamic Type size.
    static let minimumHitTarget: CGFloat = 44

    // MARK: Accent boundaries
    //
    // Kitchen Manager maintains two distinct accent colours. They look
    // different and carry different semantic weight — do not collapse them
    // into a single accent.
    //
    // `primary` (blue):  Inventory, Shopping, Settings, and
    //   administrative/system-level actions.
    // `brand` (green):   Home, Recommendation, Today Plan, Recipe, Cooking
    //   Mode — the cooking-journey path.

    /// Administrative blue: Inventory, Shopping, Settings, system actions.
    static let primary = adaptive(light: 0x007AFF, dark: 0x0A84FF)

    /// Cooking-journey green: Home, Recommendations, Plan, Recipe, Cooking.
    /// Deliberately separate from `primary` so the cooking path and admin
    /// path each carry their own visual signature.
    static let brand = adaptive(light: 0x2F6F4E, dark: 0x4E9970)

    // MARK: Semantic tokens
    //
    // `success` means a genuine completed / achieved / confirmed state.
    // Source attribution labels ("AI recommended", "from 大众川菜") and
    // origin tags are NOT success; use `neutral` or a low-emphasis `brand`
    // presentation for those.

    /// Genuine success, completion, or confirmed state only.
    static let success = adaptive(light: 0x34C759, dark: 0x30D158)

    /// Caution / upcoming / attention — unchanged from existing semantics.
    static let warning = adaptive(light: 0xFF9500, dark: 0xFFB340)

    /// Destruction, irreversible actions, hard errors.
    /// Domain tokens (e.g. `inventoryExpired`) reference this rather than
    /// duplicating the colour values.
    static let danger = adaptive(light: 0xD92D2A, dark: 0xFF6961)

    // MARK: Neutral palette

    static let textPrimary = adaptive(light: 0x1D1D1F, dark: 0xF5F5F7)
    static let textSecondary = adaptive(light: 0x6E6E73, dark: 0xC7C7CC)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x1C1C1E)
    static let secondarySurface = adaptive(light: 0xF5F5F7, dark: 0x2C2C2E)
    static let separator = adaptive(light: 0xD2D2D7, dark: 0x48484A)

    // MARK: Radius tokens
    //
    // Three sizes only. No new arbitrary values.

    /// Compact controls, search fields, small chips, pill buttons. 10pt.
    static let radiusCompact: CGFloat = 10
    /// Cards, panels, toasts, medium containers. 16pt.
    static let radiusCard: CGFloat = 16
    /// Primary hero/dashboard card only. 20pt. Do not spread to other surfaces.
    static let radiusHero: CGFloat = 20

    // MARK: Inventory lifecycle domain tokens
    //
    // Mirror the PWA's calm green → amber → orange → red hierarchy while
    // retaining contrast in both system appearances.

    // Inventory lifecycle surfaces mirror the PWA's calm green → amber → orange
    // → red hierarchy, while retaining contrast in both system appearances.
    static let inventoryFreshBackground = adaptive(light: 0xECF9F0, dark: 0x143421)
    static let inventoryUpcomingBackground = adaptive(light: 0xFFF8DE, dark: 0x3A3013)
    static let inventoryExpiringBackground = adaptive(light: 0xFFF1E2, dark: 0x3D2614)
    static let inventoryTodayBackground = adaptive(light: 0xFFE9DF, dark: 0x472018)
    static let inventoryExpiredBackground = adaptive(light: 0xFCE8E6, dark: 0x461E20)
    static let inventoryUnknownBackground = adaptive(light: 0xF2F2F7, dark: 0x2C2C2E)
    static let inventoryFresh = adaptive(light: 0x237A42, dark: 0x30D158)
    static let inventoryUpcoming = adaptive(light: 0x8A6500, dark: 0xFFD60A)
    static let inventoryExpiring = adaptive(light: 0xA04B00, dark: 0xFFB340)
    static let inventoryToday = adaptive(light: 0xB33A00, dark: 0xFF9F0A)
    /// Domain alias for `danger`. Keep the domain name so callers express
    /// intent ("expired") rather than colour opinion ("red").
    static let inventoryExpired = danger

    // MARK: Helpers

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

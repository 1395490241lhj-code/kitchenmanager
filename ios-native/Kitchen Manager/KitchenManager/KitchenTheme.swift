import SwiftUI

/// Semantic motion. Call sites pass nil when accessibilityReduceMotion is enabled.
enum KitchenMotion {
    static let quick: Animation = .snappy(duration: 0.2)
    static let standard: Animation = .smooth(duration: 0.28)
    static let emphasis: Animation = .smooth(duration: 0.32, extraBounce: 0.05)
}

/// The approved Kitchen Manager visual language for Home and Inventory:
/// neutral warm canvas, one dominant feature surface, and a single
/// primary / secondary / utility control hierarchy.
///
/// Scoped by design: other surfaces keep the plain system palette until this
/// language is deliberately extended to them.
enum KitchenTheme {
    // Quiet Kitchen R3.1 (research branch): native system typography is the
    // approved direction; no serif hero face and no forced tracking.
    static let heroFontDesign: Font.Design = .default
    static let featureRadius: CGFloat = 20
    static let functionalRadius: CGFloat = 16
    static let compactRadius: CGFloat = 12
    static let borderOpacity = 0.55
    static let shadowOpacity = 0.055
    static let shadowRadius: CGFloat = 12
    static let shadowY: CGFloat = 6
    static let canvas = AppTheme.adaptive(light: 0xF2F3F6, dark: 0x16181D)
    static let surface = AppTheme.adaptive(light: 0xFFFFFF, dark: 0x24272E)
    static let elevatedSurface = AppTheme.adaptive(light: 0xF0F2F6, dark: 0x30343D)
    static let filterSurface = AppTheme.adaptive(light: 0xE7E9ED, dark: 0x333842)
    static let statusSurface = elevatedSurface

    // Shared layout coordinates; row and section marks start at pageGutter.
    static let pageGutter: CGFloat = 20
    static let heroPadding: CGFloat = 16
    static let modulePadding: CGFloat = 14
    static let rowVerticalInset: CGFloat = 6
    static let sectionSpacing: CGFloat = 24
    static let heroSpacing: CGFloat = 14
    static let railTextGap: CGFloat = 6
    static let contextRailLength: CGFloat = 12
    static let stateRailLength: CGFloat = 28
    static let railThickness: CGFloat = 3
    static let iconSize: CGFloat = 26
    static let destinationIconSize: CGFloat = 24
    static let statusIconSize: CGFloat = 22
    static let controlHeight: CGFloat = 44
    static let consolePadding: CGFloat = 16
    static let consoleVerticalPadding: CGFloat = 8

    static let statusNeutral = AppTheme.adaptive(light: 0x222731, dark: 0xF2F4F8)
    static let statusTerracotta = AppTheme.adaptive(light: 0xA6452D, dark: 0xF08A6D)
    static let statusOchre = AppTheme.adaptive(light: 0x806019, dark: 0xE2B85A)
    static let textPrimary = AppTheme.adaptive(light: 0x222731, dark: 0xF2F4F8)
    static let textSecondary = AppTheme.adaptive(light: 0x59616F, dark: 0xAFB7C5)
    static let separator = AppTheme.adaptive(light: 0xDCDFE6, dark: 0x3A3F49)
    // R3.1: #3866D6 is the single product accent. Green survives only as a
    // semantic status colour; the former cooking-journey greens become the
    // shared blue at the token layer so every screen inherits it.
    static let cookingGreen = AppTheme.adaptive(light: 0x3866D6, dark: 0xA5BDFF)
    static let cookingFill = AppTheme.adaptive(light: 0x3866D6, dark: 0x3866D6)
    static let sage = AppTheme.adaptive(light: 0x59616F, dark: 0xAFB7C5)
    static let terracotta = AppTheme.adaptive(light: 0xA6452D, dark: 0xF08A6D)
    static let ochre = AppTheme.adaptive(light: 0x806019, dark: 0xE2B85A)
    static let aiIndigo = AppTheme.adaptive(light: 0x58538F, dark: 0xABA5E8)
    static let managementBlue = AppTheme.adaptive(light: 0x3866D6, dark: 0xA5BDFF)
}

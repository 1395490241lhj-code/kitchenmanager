import SwiftUI

/// The approved Kitchen Manager visual language for Home and Inventory:
/// neutral warm canvas, one dominant feature surface, and a single
/// primary / secondary / utility control hierarchy.
///
/// Scoped by design: other surfaces keep the plain system palette until this
/// language is deliberately extended to them.
enum KitchenTheme {
    static let heroFontDesign: Font.Design = .serif
    static let featureRadius: CGFloat = 24
    static let functionalRadius: CGFloat = 16
    static let compactRadius: CGFloat = 12
    static let borderOpacity = 0.55
    static let shadowOpacity = 0.055
    static let shadowRadius: CGFloat = 12
    static let shadowY: CGFloat = 6
    static let canvas = AppTheme.adaptive(light: 0xF7F7F4, dark: 0x181A17)
    static let surface = AppTheme.adaptive(light: 0xFFFFFD, dark: 0x222420)
    static let elevatedSurface = AppTheme.adaptive(light: 0xF0F1ED, dark: 0x2B2D28)
    static let filterSurface = AppTheme.adaptive(light: 0xE7E9E5, dark: 0x333630)
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

    static let statusNeutral = AppTheme.adaptive(light: 0x20231F, dark: 0xF5F4EE)
    static let statusTerracotta = AppTheme.adaptive(light: 0xA6452D, dark: 0xF08A6D)
    static let statusOchre = AppTheme.adaptive(light: 0x806019, dark: 0xE2B85A)
    static let textPrimary = AppTheme.adaptive(light: 0x20231F, dark: 0xF5F4EE)
    static let textSecondary = AppTheme.adaptive(light: 0x646862, dark: 0xC7C5BC)
    static let separator = AppTheme.adaptive(light: 0xD9DCD6, dark: 0x444740)
    static let cookingGreen = AppTheme.adaptive(light: 0x315C3A, dark: 0x84B88B)
    static let cookingFill = AppTheme.adaptive(light: 0x365F3F, dark: 0x45694B)
    static let sage = AppTheme.adaptive(light: 0x6D8167, dark: 0x9CAE92)
    static let terracotta = AppTheme.adaptive(light: 0xA6452D, dark: 0xF08A6D)
    static let ochre = AppTheme.adaptive(light: 0x806019, dark: 0xE2B85A)
    static let aiIndigo = AppTheme.adaptive(light: 0x58538F, dark: 0xABA5E8)
    static let managementBlue = AppTheme.adaptive(light: 0x2F628D, dark: 0x78AADA)
}

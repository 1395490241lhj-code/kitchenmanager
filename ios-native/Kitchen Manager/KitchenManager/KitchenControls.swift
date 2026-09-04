import SwiftUI

/// Button material and geometry for the approved control hierarchy.
/// Primary is decisive and filled; secondary is a quieter elevated neutral;
/// utility is borderless and low-mass. The difference a user sees is material,
/// not just tint.
enum KitchenButtonRole {
    case primary
    case secondary
    case utility
}

struct KitchenButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let role: KitchenButtonRole
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        let radius = role == .primary ? KitchenTheme.functionalRadius : KitchenTheme.compactRadius
        configuration.label
            .foregroundStyle(foreground)
            .padding(.horizontal, role == .utility ? 4 : 16)
            .frame(minHeight: AppTheme.minimumHitTarget)
            .background(background, in: .rect(cornerRadius: radius, style: .continuous))
            .overlay {
                if role != .primary && role != .utility {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(KitchenTheme.separator.opacity(KitchenTheme.borderOpacity), lineWidth: 0.75)
                }
            }
            .shadow(
                color: role == .primary ? AppTheme.cardShadow(opacity: KitchenTheme.shadowOpacity * 0.7) : .clear,
                radius: KitchenTheme.shadowRadius * 0.45,
                y: KitchenTheme.shadowY * 0.35
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(isEnabled ? 1 : 0.52)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch role {
        case .primary: .white
        case .secondary: KitchenTheme.cookingGreen
        case .utility: tint ?? KitchenTheme.textSecondary
        }
    }

    private var background: Color {
        switch role {
        case .primary: KitchenTheme.cookingFill
        case .secondary: KitchenTheme.elevatedSurface
        case .utility: .clear
        }
    }
}

/// The 3pt semantic rail shared by Home and Inventory. Color carries meaning,
/// never decoration: sage = readiness/tonight, terracotta = urgent freshness,
/// ochre = replenishment, neutral = ordinary.
struct KitchenStatusRail: View {
    let color: Color
    var length: CGFloat = 32
    var vertical = false

    var body: some View {
        Capsule()
            .fill(color)
            .frame(width: vertical ? 3 : length, height: vertical ? length : 3)
            .accessibilityHidden(true)
    }
}

extension View {
    func kitchenUtilityButton(tint: Color) -> some View {
        buttonStyle(KitchenButtonStyle(role: .utility, tint: tint))
    }

    func kitchenFeatureSurface() -> some View {
        background(KitchenTheme.surface, in: .rect(cornerRadius: KitchenTheme.featureRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: KitchenTheme.featureRadius, style: .continuous)
                    .stroke(KitchenTheme.separator.opacity(KitchenTheme.borderOpacity), lineWidth: 0.75)
            }
            .shadow(
                color: AppTheme.cardShadow(opacity: KitchenTheme.shadowOpacity),
                radius: KitchenTheme.shadowRadius,
                y: KitchenTheme.shadowY
            )
    }

    /// The quiet grouping material for needs-attention and lightweight rows:
    /// a hairline underneath, not another card.
    func kitchenGroupedSurface() -> some View {
        overlay(alignment: .bottom) {
            Rectangle()
                .fill(KitchenTheme.separator)
                .frame(height: 0.5)
        }
    }
}

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
            .frame(minHeight: KitchenTheme.controlHeight)
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
    var length: CGFloat = KitchenTheme.contextRailLength
    var vertical = false

    var body: some View {
        Capsule()
            .fill(color)
            .frame(width: vertical ? KitchenTheme.railThickness : length, height: vertical ? length : KitchenTheme.railThickness)
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

struct KitchenIconBadge: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = KitchenTheme.iconSize

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(
                tint.opacity(0.12),
                in: .rect(cornerRadius: size * 0.32, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

struct KitchenContextualLabel: View {
    let text: String
    var tint: Color = KitchenTheme.sage

    var body: some View {
        HStack(spacing: KitchenTheme.railTextGap) {
            KitchenStatusRail(color: tint, length: KitchenTheme.contextRailLength)
            Text(text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .dynamicTypeSize(...ChromeMetrics.headerTypeLimit)
        .accessibilityAddTraits(.isHeader)
    }
}

struct KitchenReadinessChip: View {
    let readiness: HomeMealReadiness

    var body: some View {
        HStack(spacing: 7) {
            KitchenIconBadge(
                systemImage: readiness.ready >= readiness.total && readiness.total > 0
                    ? "checkmark.circle.fill"
                    : "basket.fill",
                tint: KitchenTheme.sage,
                size: KitchenTheme.statusIconSize
            )
            Text(readiness.summary)
                .font(.footnote.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(KitchenTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            KitchenTheme.elevatedSurface.opacity(0.65),
            in: .rect(cornerRadius: KitchenTheme.compactRadius, style: .continuous)
        )
    }
}

struct KitchenSectionLabel: View {
    let title: String
    let count: Int
    var tint: Color = KitchenTheme.sage

    var body: some View {
        HStack(spacing: KitchenTheme.railTextGap) {
            KitchenStatusRail(color: tint, length: KitchenTheme.contextRailLength)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text("\(count) 项")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .textCase(nil)
        .dynamicTypeSize(...ChromeMetrics.headerTypeLimit)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct KitchenPressFeedbackStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

/// Metadata wraps as text at larger sizes; numbers retain emphasis within
/// each group without splitting units into independent layout children.
struct KitchenMetadataText: View {
    let text: String

    private var attributed: AttributedString {
        var result = AttributedString()
        var token = ""
        var numeric = false
        func appendToken() {
            guard !token.isEmpty else { return }
            var part = AttributedString(token)
            part.font = numeric ? .footnote.monospacedDigit().weight(.semibold) : .footnote
            part.foregroundColor = numeric ? KitchenTheme.textPrimary : KitchenTheme.textSecondary
            result.append(part)
        }
        for character in text {
            let nextNumeric = character.isNumber || character == ":"
            if nextNumeric != numeric {
                appendToken()
                token = ""
                numeric = nextNumeric
            }
            token.append(character)
        }
        appendToken()
        return result
    }

    var body: some View {
        Text(attributed)
            .fixedSize(horizontal: false, vertical: true)
    }
}

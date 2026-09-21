import SwiftUI
import ThinkingOrbs

/// Presentation size options for `KitchenAIActivityIndicator`.
enum KitchenAIActivitySize: Sendable, Equatable {
    /// Small inline presentation (20 pt) for conversation rows and status lines.
    case small
    /// Regular prominent presentation (64 pt) for hero moments or empty states.
    case regular

    var orbSize: OrbSize {
        switch self {
        case .small: return .small
        case .regular: return .regular
        }
    }

    var points: CGFloat {
        orbSize.points
    }
}

/// A Kitchen-owned AI activity indicator visual primitive.
///
/// Wraps `ThinkingOrbs` so feature code never touches package-specific
/// types, designs, or animation presets directly.
struct KitchenAIActivityIndicator: View {
    let phase: KitchenAIActivityPhase
    let size: KitchenAIActivitySize
    let diameter: CGFloat?
    let speed: Double
    let isPaused: Bool

    init(
        phase: KitchenAIActivityPhase,
        size: KitchenAIActivitySize = .small,
        diameter: CGFloat? = nil,
        speed: Double = 1.0,
        isPaused: Bool = false
    ) {
        self.phase = phase
        self.size = size
        self.diameter = diameter
        self.speed = speed
        self.isPaused = isPaused
    }

    private var orbDesign: OrbDesign {
        switch phase {
        case .waiting:
            return .breathing
        case .searching:
            return .searching
        case .reasoning:
            return .solving
        case .toolCall:
            return .connecting
        case .planning:
            return .weaving
        case .composing:
            return .composing
        }
    }

    var body: some View {
        ThinkingOrb(
            orbDesign,
            size: size.orbSize,
            diameter: diameter,
            speed: speed,
            isPaused: isPaused
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(phase.accessibilityLabel)
        .accessibilityAddTraits(.isImage)
    }
}

#Preview("Kitchen AI Activity Indicator - Light & Dark") {
    VStack(spacing: 20) {
        ForEach(KitchenAIActivityPhase.allCases, id: \.self) { phase in
            HStack(spacing: 16) {
                KitchenAIActivityIndicator(phase: phase, size: .regular)
                KitchenAIActivityIndicator(phase: phase, size: .small)
                Text(phase.rawValue.capitalized)
                    .font(.subheadline)
                    .foregroundStyle(KitchenTheme.textPrimary)
                Spacer()
            }
        }
    }
    .padding()
    .background(KitchenTheme.canvas)
}

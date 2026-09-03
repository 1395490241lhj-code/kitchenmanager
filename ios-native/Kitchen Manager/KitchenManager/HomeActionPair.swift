import SwiftUI

/// Home's action hierarchy: exactly one dominant control, and one alternative
/// that stays text-level so it reads as a choice rather than a rival call to
/// action. Two filled pills side by side is the shape this replaced.
struct HomeActionPair: View {
    let primaryTitle: String
    let primarySymbol: String
    let primaryIdentifier: String
    let primaryAction: () -> Void
    /// Disables only the primary control. The alternative must stay usable:
    /// a dish already added to today can still have its recipe opened.
    var isPrimaryDisabled = false
    let secondaryTitle: String
    let secondaryTint: Color
    let secondaryIdentifier: String
    let secondaryAction: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            // A deliberate accessibility composition rather than a wrapped row:
            // at large sizes the two controls stack and each keeps a full line.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) { content }
            } else {
                HStack(spacing: 20) { content }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        Button(action: primaryAction) {
            Label(primaryTitle, systemImage: primarySymbol)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 4)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .buttonBorderShape(.capsule)
        .tint(AppTheme.cookingActionFill)
        .foregroundStyle(AppTheme.onCookingAction)
        .frame(minHeight: AppTheme.minimumHitTarget)
        .disabled(isPrimaryDisabled)
        .accessibilityIdentifier(primaryIdentifier)

        Button(secondaryTitle, action: secondaryAction)
            .font(.callout)
            .tint(secondaryTint)
            .frame(minHeight: AppTheme.minimumHitTarget)
            .accessibilityIdentifier(secondaryIdentifier)
    }
}

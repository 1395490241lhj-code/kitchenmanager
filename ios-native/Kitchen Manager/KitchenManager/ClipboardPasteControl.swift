import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// How the shared paste control presents itself.
///
/// The default is deliberately `.iconAndLabel`: this control is shared, and a
/// single hardcoded `displayMode` is exactly how the Home clipboard-banner work
/// silently turned the recipe-import paste affordance into a bare icon. Making
/// the style explicit means a call site can only become icon-only on purpose.
///
enum ClipboardPasteControlStyle {
    /// Native icon plus the system's own localized paste label.
    case iconAndLabel
    /// Icon only. Only for call sites that supply their own visible label.
    case iconOnly
    /// Native interaction with a shared custom visual label.
    case customLabeled(String)

    var displayMode: UIPasteControl.DisplayMode {
        switch self {
        case .iconAndLabel: .iconAndLabel
        case .iconOnly, .customLabeled: .iconOnly
        }
    }

    /// `.iconAndLabel` sizes itself around the system label, so it hugs its
    /// content. `.iconOnly` is only used where the call site draws its own visible
    /// label over the control, and there the control must *fill* the frame it is
    /// given — otherwise it stays at its ~41pt intrinsic icon width inside a wider
    /// visible capsule and the edges of that capsule tap nothing.
    var horizontalContentHugging: UILayoutPriority {
        switch self {
        case .iconAndLabel: .required
        case .iconOnly, .customLabeled: .defaultLow
        }
    }

    var minimumWidth: CGFloat {
        switch self {
        case .iconAndLabel: 44
        case .iconOnly: 44
        case .customLabeled: 118
        }
    }

    var usesCustomVisualLabel: Bool {
        if case .customLabeled = self { return true }
        return false
    }
}

/// Minimal SwiftUI bridge for UIKit's privacy-preserving, user-initiated
/// paste affordance. It returns raw pasted URL/text to its caller and owns no
/// URL parsing, navigation, network, queue, or import state.
struct ClipboardPasteControl: View {
    let accessibilityLabel: String
    var style: ClipboardPasteControlStyle = .iconAndLabel
    var isEnabled = true
    var usesManagementSecondaryVisual = false
    let onPaste: @MainActor @Sendable (String) -> Void

    var body: some View {
        ZStack {
            NativeClipboardPasteControl(
                accessibilityLabel: accessibilityLabel,
                style: style,
                isEnabled: isEnabled,
                onPaste: { pastedText in onPaste(pastedText) }
            )
            .frame(maxWidth: .infinity, minHeight: AppTheme.minimumHitTarget)
            .opacity(style.usesCustomVisualLabel ? 0.02 : 1)

            if case .customLabeled(let label) = style {
                Label {
                    Text(label)
                        .foregroundStyle(
                            usesManagementSecondaryVisual
                                ? AppTheme.textPrimary
                                : AppTheme.onCookingAction
                        )
                } icon: {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundStyle(
                            usesManagementSecondaryVisual
                                ? AppTheme.managementAccentForeground
                                : AppTheme.onCookingAction
                        )
                }
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12)
                    .frame(minWidth: style.minimumWidth, minHeight: AppTheme.minimumHitTarget)
                    .background(
                        usesManagementSecondaryVisual
                            ? AppTheme.managementAccentForeground.opacity(0.08)
                            : AppTheme.cookingActionFill,
                        in: Capsule()
                    )
                    .overlay {
                        if usesManagementSecondaryVisual {
                            Capsule()
                                .stroke(AppTheme.managementAccentForeground.opacity(0.25), lineWidth: 0.5)
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(minWidth: style.minimumWidth, minHeight: AppTheme.minimumHitTarget)
        .accessibilityLabel(accessibilityLabel)
    }

    private struct NativeClipboardPasteControl: UIViewRepresentable {
        let accessibilityLabel: String
        let style: ClipboardPasteControlStyle
        let isEnabled: Bool
        let onPaste: @MainActor @Sendable (String) -> Void

        func makeCoordinator() -> PasteRecipient {
            PasteRecipient(isEnabled: isEnabled) { pastedText in
                onPaste(pastedText)
            }
        }

        func makeUIView(context: Context) -> UIPasteControl {
            let configuration = UIPasteControl.Configuration()
            configuration.displayMode = style.displayMode
            configuration.cornerStyle = .capsule

            let control = UIPasteControl(configuration: configuration)
            control.target = context.coordinator
            control.accessibilityIdentifier = "clipboard.paste.control"
            control.setContentHuggingPriority(style.horizontalContentHugging, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
            applyAccessibility(to: control)
            return control
        }

        func updateUIView(_ control: UIPasteControl, context: Context) {
            context.coordinator.isEnabled = isEnabled
            context.coordinator.onPaste = { pastedText in
                onPaste(pastedText)
            }
            control.isEnabled = isEnabled
            // UIPasteControl can restore its system label during layout; keep the
            // explicit localized accessibility name on every update.
            applyAccessibility(to: control)
        }

        private func applyAccessibility(to control: UIPasteControl) {
            control.accessibilityLabel = accessibilityLabel
        }

        @MainActor
        final class PasteRecipient: NSObject, UIPasteConfigurationSupporting {
            var pasteConfiguration: UIPasteConfiguration? = UIPasteConfiguration(
                acceptableTypeIdentifiers: [
                    UTType.url.identifier,
                    UTType.plainText.identifier
                ]
            )
            var isEnabled: Bool
            var onPaste: @MainActor @Sendable (String) -> Void

            init(isEnabled: Bool, onPaste: @escaping @MainActor @Sendable (String) -> Void) {
                self.isEnabled = isEnabled
                self.onPaste = onPaste
            }

            func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
                isEnabled && itemProviders.contains(where: Self.supportsImportContent)
            }

            func paste(itemProviders: [NSItemProvider]) {
                guard isEnabled else { return }
                Task { @MainActor [weak self] in
                    let text = await Self.firstText(from: itemProviders)
                    guard !Task.isCancelled, let self, let text else { return }
                    onPaste(text)
                }
            }

            private static func supportsImportContent(_ provider: NSItemProvider) -> Bool {
                provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                    || provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            }

            private static func firstText(from providers: [NSItemProvider]) async -> String? {
                for provider in providers where supportsImportContent(provider) {
                    if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                        if let url = await loadObject(from: provider, ofClass: NSURL.self) {
                            return url.absoluteString
                        }
                        if let text = await loadObject(from: provider, ofClass: NSString.self) as String? {
                            return text
                        }
                    }

                    if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                       let text = await loadObject(from: provider, ofClass: NSString.self) as String? {
                        return text
                    }
                }
                return nil
            }

            private static func loadObject<T>(
                from provider: NSItemProvider,
                ofClass objectClass: T.Type
            ) async -> T? where T: NSItemProviderReading {
                await withCheckedContinuation { continuation in
                    provider.loadObject(ofClass: objectClass) { object, _ in
                        continuation.resume(returning: object as? T)
                    }
                }
            }
        }
    }
}

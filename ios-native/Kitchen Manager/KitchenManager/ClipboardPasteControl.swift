import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Minimal SwiftUI bridge for UIKit's privacy-preserving, user-initiated
/// paste affordance. It returns raw pasted URL/text to its caller and owns no
/// URL parsing, navigation, network, queue, or import state.
struct ClipboardPasteControl: UIViewRepresentable {
    let accessibilityLabel: String
    var isEnabled = true
    let onPaste: @MainActor @Sendable (String) -> Void

    func makeCoordinator() -> PasteRecipient {
        PasteRecipient(isEnabled: isEnabled) { pastedText in
            onPaste(pastedText)
        }
    }

    func makeUIView(context: Context) -> UIPasteControl {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconAndLabel
        configuration.cornerStyle = .capsule

        let control = UIPasteControl(configuration: configuration)
        control.target = context.coordinator
        control.accessibilityLabel = accessibilityLabel
        control.accessibilityIdentifier = "clipboard.paste.control"
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        return control
    }

    func updateUIView(_ control: UIPasteControl, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onPaste = { pastedText in
            onPaste(pastedText)
        }
        control.isEnabled = isEnabled
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

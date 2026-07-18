import Foundation
import UniformTypeIdentifiers

/// Pulls a URL and/or plain text out of whatever `NSExtensionItem`/
/// `NSItemProvider` combination the host app handed to the share sheet.
///
/// Kept free of UIKit/SwiftUI so it can be unit tested without a live
/// extension context.
enum ShareItemExtractor {
    struct Extracted {
        let url: URL?
        let text: String?
    }

    /// Walks every extension item and every attachment on each item,
    /// stopping as soon as a usable URL is found (priority 1), otherwise
    /// collecting the first usable plain-text attachment (priority 2/3).
    /// Never throws: attachments the app can't use are simply skipped.
    static func extract(from items: [NSExtensionItem]?) async -> Extracted {
        guard let items, !items.isEmpty else {
            return Extracted(url: nil, text: nil)
        }

        var foundURL: URL?
        var foundText: String?

        for item in items {
            guard let attachments = item.attachments, !attachments.isEmpty else { continue }
            for provider in attachments {
                if foundURL == nil, let url = await loadURL(from: provider) {
                    foundURL = url
                    continue
                }
                if foundText == nil, let text = await loadText(from: provider) {
                    foundText = text
                }
            }
            if foundURL != nil, foundText != nil { break }
        }

        return Extracted(url: foundURL, text: foundText)
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) else { return nil }
        if let nsURL = await loadObject(from: provider, ofClass: NSURL.self) {
            return SharedImportRequestBuilder.normalize(url: nsURL as URL)
        }
        // Some hosts register a public.url provider but only vend an
        // NSString at load time — accept that shape too.
        if let string = await loadObject(from: provider, ofClass: NSString.self) as String?,
           let url = URL(string: string) {
            return SharedImportRequestBuilder.normalize(url: url)
        }
        return nil
    }

    private static func loadText(from provider: NSItemProvider) async -> String? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.text.identifier)
        else { return nil }

        guard let text = await loadObject(from: provider, ofClass: NSString.self) as String? else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func loadObject<T>(from provider: NSItemProvider, ofClass objectClass: T.Type) async -> T?
    where T: NSItemProviderReading {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: objectClass) { object, _ in
                continuation.resume(returning: object as? T)
            }
        }
    }
}

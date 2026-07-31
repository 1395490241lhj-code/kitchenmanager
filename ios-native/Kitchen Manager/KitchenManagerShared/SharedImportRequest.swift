import Foundation

/// The kind of content the system share sheet handed to the extension.
///
/// This does not distinguish *platforms* (Xiaohongshu, YouTube, ...) — that
/// classification stays inside the main app's existing import pipeline.
///
/// Phase 1 only ever *produces* `.sharedURL` and `.sharedTextAndURL` —
/// both always carry a resolved http/https URL. `.sharedText` (a bare-text
/// request with no URL) is kept only so `Codable` can still decode a
/// request written by some future/older build without crashing; the
/// current `SharedImportRequestBuilder` never constructs one, and any
/// value with a `nil` url is treated as unsupported/legacy by both the
/// queue and `SharedImportCoordinator` — see `SharedImportRequest.hasRequiredURL`.
/// True text-only AI import is Share Import Phase 2, not this phase.
public enum ShareImportSource: String, Codable, Sendable {
    case sharedURL
    case sharedText
    case sharedTextAndURL
}

/// Where a queued request currently sits in its lifecycle.
///
/// This is **persisted with the request**, not held in memory: the whole
/// point is that "the user already dealt with this" survives a relaunch.
/// Before this existed, a dismissed request stayed `pending` forever on
/// disk and was auto-presented (and auto-imported) on every single launch.
public enum SharedImportStatus: String, Codable, Sendable {
    /// Newly queued by the extension; eligible for automatic presentation
    /// and auto-start exactly once.
    case pending
    /// The user explicitly chose "稍后处理" (or just closed the sheet).
    /// Stays in the queue and remains reachable from an explicit entry
    /// point, but is never auto-presented or auto-started again.
    case deferred
    /// The import failed enough times that retrying automatically would
    /// just loop. Kept for an explicit user-driven retry / delete.
    case failed
}

/// A normalized request produced by the Share Extension and consumed by the
/// main app's existing Smart Import flow.
///
/// Deliberately Foundation-only: no SwiftUI, SwiftData, networking, or store
/// types, so it compiles unmodified into both the app and extension targets
/// and can be unit tested in isolation.
public struct SharedImportRequest: Codable, Sendable, Identifiable {
    /// Bumped whenever the on-disk shape of this type changes, so the queue
    /// can discard requests written by an older/newer version instead of
    /// crashing on decode.
    public static let currentSchemaVersion = 1

    public let id: UUID
    public let createdAt: Date
    public let source: ShareImportSource
    public let url: URL?
    public let text: String?
    public let originalHostBundleIdentifier: String?
    public let schemaVersion: Int
    /// Persisted lifecycle state. See `SharedImportStatus`.
    public let status: SharedImportStatus
    /// How many times the import pipeline has failed for this request.
    /// Persisted so a failing link can't silently auto-retry on every launch.
    public let failureCount: Int

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        source: ShareImportSource,
        url: URL?,
        text: String?,
        originalHostBundleIdentifier: String?,
        schemaVersion: Int = SharedImportRequest.currentSchemaVersion,
        status: SharedImportStatus = .pending,
        failureCount: Int = 0
    ) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.url = url
        self.text = text
        self.originalHostBundleIdentifier = originalHostBundleIdentifier
        self.schemaVersion = schemaVersion
        self.status = status
        self.failureCount = failureCount
    }

    /// Tolerant decode so a queue file written *before* `status`/
    /// `failureCount` existed still loads instead of being discarded.
    /// `schemaVersion` is deliberately **not** bumped for this addition:
    /// bumping it would make the queue silently drop every already-queued
    /// request, which is exactly the kind of blunt data loss this change is
    /// meant to avoid. Legacy entries decode as `.pending` / `0`, i.e. they
    /// behave exactly as before until the user acts on them once.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        source = try container.decode(ShareImportSource.self, forKey: .source)
        url = try container.decodeIfPresent(URL.self, forKey: .url)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        originalHostBundleIdentifier = try container.decodeIfPresent(
            String.self,
            forKey: .originalHostBundleIdentifier
        )
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        status = try container.decodeIfPresent(SharedImportStatus.self, forKey: .status) ?? .pending
        failureCount = try container.decodeIfPresent(Int.self, forKey: .failureCount) ?? 0
    }

    /// Returns a copy with updated lifecycle state; identity, content, and
    /// `createdAt` are never rewritten, so FIFO order and dedup stay stable.
    public func updating(
        status newStatus: SharedImportStatus? = nil,
        failureCount newFailureCount: Int? = nil
    ) -> SharedImportRequest {
        SharedImportRequest(
            id: id,
            createdAt: createdAt,
            source: source,
            url: url,
            text: text,
            originalHostBundleIdentifier: originalHostBundleIdentifier,
            schemaVersion: schemaVersion,
            status: newStatus ?? status,
            failureCount: newFailureCount ?? failureCount
        )
    }

    /// Phase 1 only supports content that resolves to a usable http/https
    /// URL. A request with no `url` can never be completed by the current
    /// import pipeline (`ImportRecipeView` only extracts a URL) — such a
    /// value should never be produced by `SharedImportRequestBuilder`, but
    /// this flags it explicitly for any code (the queue, the coordinator)
    /// that reads a request without necessarily having built it, e.g. a
    /// pre-existing value on disk from an older/different build.
    public var hasRequiredURL: Bool {
        url != nil
    }
}

extension SharedImportRequest: Equatable {
    // Explicit rather than synthesized: comparing `url` by `absoluteString`
    // sidesteps `URL`'s own `Equatable`, which has been observed to disagree
    // with itself for values that survive a JSON encode/decode round trip on
    // current toolchains, even when every visible component is identical.
    public static func == (lhs: SharedImportRequest, rhs: SharedImportRequest) -> Bool {
        lhs.id == rhs.id
            && lhs.createdAt.timeIntervalSince1970 == rhs.createdAt.timeIntervalSince1970
            && lhs.source == rhs.source
            && lhs.url?.absoluteString == rhs.url?.absoluteString
            && lhs.text == rhs.text
            && lhs.originalHostBundleIdentifier == rhs.originalHostBundleIdentifier
            && lhs.schemaVersion == rhs.schemaVersion
            && lhs.status == rhs.status
            && lhs.failureCount == rhs.failureCount
    }
}

/// Errors surfaced while building a `SharedImportRequest` from raw share-sheet
/// input. Kept internal-safe: descriptions never include file paths, tokens,
/// or other sensitive values.
public enum ShareImportBuildError: Error, Equatable, Sendable {
    case emptyContent
    case unsupportedContent

    public var localizedDescription: String {
        switch self {
        case .emptyContent:
            return "内容为空，无法导入。"
        case .unsupportedContent:
            return "暂时只支持包含网页链接的分享内容。"
        }
    }
}

/// Builds a normalized `SharedImportRequest` from raw text/URL fragments
/// pulled out of `NSItemProvider` attachments.
///
/// Phase 1 scope: a valid http/https URL attachment wins; otherwise a URL
/// embedded in plain text; anything else — including non-empty plain text
/// with **no** extractable URL — is rejected with `.unsupportedContent`.
/// A bare-text request is never queued in this phase (true text-only AI
/// import is Share Import Phase 2).
public enum SharedImportRequestBuilder {
    /// Reasonable upper bound so a share of an entire article/page doesn't
    /// balloon the on-disk queue or overwhelm the eventual AI-parse call.
    public static let maxTextLength = 20_000

    public static func build(
        attachmentURL: URL?,
        attachmentText: String?,
        originalHostBundleIdentifier: String?
    ) -> Result<SharedImportRequest, ShareImportBuildError> {
        let hadRawURLAttachment = attachmentURL != nil
        let normalizedURL = normalize(url: attachmentURL)
        let trimmedText = attachmentText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonEmptyText = (trimmedText?.isEmpty ?? true) ? nil : trimmedText

        if let normalizedURL {
            if let nonEmptyText, !nonEmptyText.isEmpty, nonEmptyText != normalizedURL.absoluteString {
                return .success(
                    SharedImportRequest(
                        source: .sharedTextAndURL,
                        url: normalizedURL,
                        text: truncate(nonEmptyText),
                        originalHostBundleIdentifier: originalHostBundleIdentifier
                    )
                )
            }
            return .success(
                SharedImportRequest(
                    source: .sharedURL,
                    url: normalizedURL,
                    text: nil,
                    originalHostBundleIdentifier: originalHostBundleIdentifier
                )
            )
        }

        // No directly-usable URL attachment. Phase 1 still accepts a URL
        // embedded inside plain text (e.g. a caption pasted alongside a
        // link) — but never bare text with no extractable URL at all.
        if let nonEmptyText, let embeddedURL = firstHTTPURL(in: nonEmptyText) {
            return .success(
                SharedImportRequest(
                    source: .sharedTextAndURL,
                    url: embeddedURL,
                    text: truncate(nonEmptyText),
                    originalHostBundleIdentifier: originalHostBundleIdentifier
                )
            )
        }

        guard nonEmptyText == nil, !hadRawURLAttachment else {
            // Something was shared — plain text with no link, and/or a URL
            // attachment we don't support (file://, a custom scheme) — but
            // Phase 1 only imports content that resolves to an http/https
            // URL, so this is a firm rejection, not queued.
            return .failure(.unsupportedContent)
        }

        return .failure(.emptyContent)
    }

    /// Only accepts http/https; rejects `file://` and custom schemes.
    public static func normalize(url: URL?) -> URL? {
        guard let url else { return nil }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        guard url.host?.isEmpty == false else { return nil }
        return url
    }

    /// Finds the first http/https URL embedded in free text, e.g. a
    /// share-sheet caption pasted alongside a link.
    public static func firstHTTPURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, options: [], range: range) {
            guard let matchURL = match.url else { continue }
            if let normalized = normalize(url: matchURL) {
                return normalized
            }
        }
        return nil
    }

    private static func truncate(_ text: String) -> String {
        guard text.count > maxTextLength else { return text }
        let endIndex = text.index(text.startIndex, offsetBy: maxTextLength)
        return String(text[text.startIndex..<endIndex])
    }
}

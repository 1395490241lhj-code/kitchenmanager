import Foundation
import UIKit

/// The only production abstraction around clipboard inspection. Its live
/// implementation asks UIKit for a pattern match and the pasteboard version;
/// it never requests the underlying value.
@MainActor
protocol ClipboardPatternDetecting {
    var changeCount: Int { get }
    func containsProbableWebURL() async throws -> Bool
}

@MainActor
struct SystemClipboardPatternDetector: ClipboardPatternDetecting {
    private let pasteboard: UIPasteboard

    init(pasteboard: UIPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    func containsProbableWebURL() async throws -> Bool {
        let matches = try await pasteboard.detectedPatterns(
            for: [\UIPasteboard.DetectedValues.probableWebURL]
        )
        return !matches.isEmpty
    }
}

/// Session-local, value-only policy for prompt visibility and change-count
/// deduplication. Keeping this independent of SwiftUI and UIKit makes every
/// lifecycle decision deterministic and unit testable.
struct ClipboardPromptSessionState: Equatable {
    private(set) var currentChangeCount: Int?
    private(set) var evaluatedChangeCount: Int?
    private(set) var probableURLChangeCount: Int?
    private(set) var ignoredChangeCount: Int?
    private(set) var handledChangeCount: Int?
    private(set) var inFlightChangeCount: Int?

    mutating func beginDetection(
        changeCount: Int,
        isAppActive: Bool,
        isPresentationBlocked: Bool
    ) -> Bool {
        guard isAppActive, !isPresentationBlocked else { return false }

        currentChangeCount = changeCount
        guard evaluatedChangeCount != changeCount,
              ignoredChangeCount != changeCount,
              handledChangeCount != changeCount
        else { return false }

        evaluatedChangeCount = changeCount
        probableURLChangeCount = nil
        inFlightChangeCount = changeCount
        return true
    }

    /// A nil result represents a detection error. Errors are intentionally
    /// silent and remain evaluated for this pasteboard version so foreground
    /// transitions cannot turn a transient failure into a prompt loop.
    mutating func finishDetection(
        changeCount: Int,
        latestChangeCount: Int,
        probableWebURL: Bool?,
        isAppActive: Bool,
        isPresentationBlocked: Bool
    ) {
        guard isAppActive,
              !isPresentationBlocked,
              changeCount == latestChangeCount,
              currentChangeCount == changeCount,
              evaluatedChangeCount == changeCount,
              inFlightChangeCount == changeCount
        else { return }

        probableURLChangeCount = probableWebURL == true ? changeCount : nil
        inFlightChangeCount = nil
    }

    func shouldShowPrompt(isAppActive: Bool, isPresentationBlocked: Bool) -> Bool {
        guard isAppActive,
              !isPresentationBlocked,
              let currentChangeCount,
              probableURLChangeCount == currentChangeCount
        else { return false }

        return ignoredChangeCount != currentChangeCount
            && handledChangeCount != currentChangeCount
    }

    mutating func ignore(changeCount: Int) {
        currentChangeCount = changeCount
        ignoredChangeCount = changeCount
        probableURLChangeCount = nil
    }

    mutating func markHandled(changeCount: Int) {
        currentChangeCount = changeCount
        handledChangeCount = changeCount
        probableURLChangeCount = nil
    }

    mutating func cancelDetection() {
        guard let inFlightChangeCount else { return }
        if evaluatedChangeCount == inFlightChangeCount {
            evaluatedChangeCount = nil
        }
        self.inFlightChangeCount = nil
    }
}

/// Clipboard input uses the same already-validated URL parser as the existing
/// Smart Import flow. This wrapper adds no regex or normalization rules.
enum ClipboardRecipeImportURL {
    struct Handoff: Equatable {
        let urlText: String
        let autoStart = true
    }

    static func makeHandoff(from pastedText: String) -> Handoff? {
        guard let url = try? LinkExtractService.firstHTTPURL(in: pastedText) else { return nil }
        return Handoff(urlText: url.absoluteString)
    }
}

enum ClipboardImportPresentationPolicy {
    static func isBlocked(hasPendingShare: Bool, hasActiveSheet: Bool) -> Bool {
        hasPendingShare || hasActiveSheet
    }
}

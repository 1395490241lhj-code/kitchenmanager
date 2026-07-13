import Foundation

/// Best-effort decode of whatever error JSON shape the backend returns.
/// Different existing endpoints use different field names for the same idea
/// (`code`, `error`, `message`, `detail`) — this tries all of them so no
/// endpoint's existing error-message parsing regresses when routed through
/// the shared client.
nonisolated struct APIErrorResponse: Decodable, Sendable {
    let code: String?
    let error: String?
    let message: String?
    let detail: String?

    /// First non-empty human-readable field, in the order services have
    /// historically preferred (`error` before `message` before `detail`).
    var displayMessage: String? {
        [error, message, detail]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

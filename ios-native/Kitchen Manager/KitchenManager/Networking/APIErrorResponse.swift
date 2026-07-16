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
    /// Only ever present on a 426 (`CLIENT_UPGRADE_REQUIRED`) response.
    let minimumVersion: String?
    let minimumBuild: Int?
    /// Only ever present on a 429 (`SYNC_RATE_LIMITED`) response.
    let retryAfterSeconds: Int?

    /// First non-empty human-readable field, in the order services have
    /// historically preferred (`error` before `message` before `detail`).
    var displayMessage: String? {
        [error, message, detail]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

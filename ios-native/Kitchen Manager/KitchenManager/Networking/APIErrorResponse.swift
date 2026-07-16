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

    private enum FlatCodingKeys: String, CodingKey {
        case code, error, message, detail, minimumVersion, minimumBuild, retryAfterSeconds
    }

    private struct NestedErrorBody: Decodable {
        let code: String?
        let message: String?
    }

    private enum NestedCodingKeys: String, CodingKey {
        case error
    }

    /// This codebase's Express routes (`/api/me`, `/api/sync/*`,
    /// `/api/account/*`) all nest their error body as `{ error: { code,
    /// message } }`, not the flat `{ code, error, message }` shape this
    /// type originally assumed (which no current caller actually decoded —
    /// every existing caller only ever branched on HTTP status, never
    /// `payload?.code`, so the mismatch was silent until account deletion
    /// needed to distinguish several errors sharing one status code). Tries
    /// the nested shape first since every current backend route uses it;
    /// falls back to the flat shape so a future flat-shaped endpoint still
    /// decodes.
    init(from decoder: Decoder) throws {
        if let nestedContainer = try? decoder.container(keyedBy: NestedCodingKeys.self),
           let nestedBody = try? nestedContainer.decode(NestedErrorBody.self, forKey: .error) {
            code = nestedBody.code
            error = nestedBody.message
            message = nestedBody.message
            detail = nil
            minimumVersion = nil
            minimumBuild = nil
            retryAfterSeconds = nil
            return
        }
        let flat = try decoder.container(keyedBy: FlatCodingKeys.self)
        code = try flat.decodeIfPresent(String.self, forKey: .code)
        error = try flat.decodeIfPresent(String.self, forKey: .error)
        message = try flat.decodeIfPresent(String.self, forKey: .message)
        detail = try flat.decodeIfPresent(String.self, forKey: .detail)
        minimumVersion = try flat.decodeIfPresent(String.self, forKey: .minimumVersion)
        minimumBuild = try flat.decodeIfPresent(Int.self, forKey: .minimumBuild)
        retryAfterSeconds = try flat.decodeIfPresent(Int.self, forKey: .retryAfterSeconds)
    }
}

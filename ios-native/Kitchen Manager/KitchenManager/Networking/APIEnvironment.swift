import Foundation

/// Centralizes the backend base URL so it stops being hardcoded across
/// individual service files.
///
/// There is currently only one real backend deployment (the Render
/// instance). `development` intentionally resolves to the exact same URL —
/// there is no separate staging/dev server today, so making the two cases
/// diverge would risk silently pointing debug builds at a dead address.
/// If a real staging backend is ever stood up, only this one place needs
/// to change.
nonisolated enum APIEnvironment: Sendable, Equatable {
    case production
    case development

    var baseURL: URL {
        switch self {
        case .production, .development:
            URL(string: "https://kitchenmanager-b8px.onrender.com")!
        }
    }

    static let current: APIEnvironment = {
        #if DEBUG
        .development
        #else
        .production
        #endif
    }()
}

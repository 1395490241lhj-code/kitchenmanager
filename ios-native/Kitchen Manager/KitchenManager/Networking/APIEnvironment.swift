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

    /// A safe, non-secret label for diagnostics/logging — never the URL
    /// itself, never a project ref.
    var label: String {
        switch self {
        case .production: "production"
        case .development: "development"
        }
    }

    /// Phase 2C-3 environment safety guard. There is only one real backend
    /// host today (see the type's own doc comment above), so this cannot yet
    /// distinguish "wrong project" — but it catches the one misconnection
    /// direction that would already be a real bug: a Release (App
    /// Store/TestFlight) build ever resolving to a loopback address, which
    /// could only happen via an accidental debug override leaking into a
    /// shipped build. When a genuinely separate production host exists
    /// (see docs/SUPABASE_ENVIRONMENT_TOPOLOGY.md), extend this to also
    /// reject a Release build whose host isn't the known production host.
    var isSafeForCurrentBuildConfiguration: Bool {
        let host = baseURL.host ?? ""
        let isLoopback = host == "127.0.0.1" || host == "localhost"
        #if DEBUG
        return true
        #else
        return !isLoopback
        #endif
    }
}

import Foundation

nonisolated struct SyncConfiguration: Equatable, Sendable {
    let isEnabled: Bool
    let maxMutationAttempts: Int
    let pullLimit: Int

    init(isEnabled: Bool = false, maxMutationAttempts: Int = 5, pullLimit: Int = 100) {
        self.isEnabled = isEnabled
        self.maxMutationAttempts = max(1, maxMutationAttempts)
        self.pullLimit = min(max(1, pullLimit), 100)
    }

    static func load(from bundle: Bundle = .main) -> SyncConfiguration {
        guard let rawValue = bundle.object(forInfoDictionaryKey: "KM_SYNC_ENABLED") else {
            return SyncConfiguration()
        }
        let normalized = String(describing: rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return SyncConfiguration(isEnabled: ["1", "true", "yes"].contains(normalized))
    }
}

nonisolated struct SyncAuthenticationContext: Equatable, Sendable {
    let userID: UUID
    let isAuthenticated: Bool
}

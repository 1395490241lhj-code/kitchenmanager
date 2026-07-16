import Foundation

/// Phase 2C-1 client-version transport headers. Built once per request by
/// `ExpressSyncTransport` only — never read by any View, never stored by
/// `AuthStore`, never written to SwiftData, never logged. Contains no device
/// identifier and no user information, only the app's own build metadata.
nonisolated struct SyncClientVersionHeaders: Sendable, Equatable {
    static let platformHeaderField = "X-Kitchen-App-Platform"
    static let versionHeaderField = "X-Kitchen-App-Version"
    static let buildHeaderField = "X-Kitchen-App-Build"
    static let schemaHeaderField = "X-Kitchen-Client-Schema"

    let platform: String
    let version: String
    let build: String
    let schema: Int

    /// The values a real running app sends — sourced from the bundle's own
    /// `CFBundleShortVersionString`/`CFBundleVersion`, never hardcoded and
    /// never derived from anything a View or user could influence.
    static var current: SyncClientVersionHeaders {
        SyncClientVersionHeaders(
            platform: "ios",
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            schema: InventorySyncEnrollment.currentSchemaVersion
        )
    }

    var headerFields: [String: String] {
        [
            Self.platformHeaderField: platform,
            Self.versionHeaderField: version,
            Self.buildHeaderField: build,
            Self.schemaHeaderField: String(schema)
        ]
    }
}

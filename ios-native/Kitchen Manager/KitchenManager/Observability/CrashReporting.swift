import Foundation

// Phase 2C-2 crash-reporting / nonfatal-error abstraction (see
// docs/CRASH_REPORTING.md). App/feature code never talks to a third-party
// SDK directly — only this protocol. Today the only concrete provider is
// `NoOpCrashReporter`; no SDK dependency has been added to the project. See
// `CrashReportingFactory` for the enabled/disabled/misconfigured decision.
//
// Safety model:
// - Only operational, non-business events are ever recorded — see
//   `CrashReportingEvent` for the fixed, exhaustive list. There is no way to
//   pass a free-text breadcrumb message; a caller can only pick one of these
//   cases.
// - Metadata is always funneled through `CrashReportingMetadata`, which
//   silently drops any key not on its allowlist — a caller cannot smuggle an
//   arbitrary Dictionary (inventory names, emails, tokens, full UUIDs)
//   through to a provider by construction.
// - A provider must never itself throw or crash the app; `NoOpCrashReporter`
//   (and any future real provider) is required to swallow its own internal
//   failures.
nonisolated protocol CrashReporting: Sendable {
    func configure(environment: String, release: String, build: String)
    /// Attaches safe, allowlisted context that *would* be included with a
    /// subsequent native crash report, were a real provider wired in. Never
    /// itself a crash trigger — for the no-op provider, and until a real SDK
    /// is integrated, this is inert.
    func captureFatalContext(_ metadata: CrashReportingMetadata)
    func captureNonFatal(_ error: Error, context: CrashReportingMetadata)
    func addBreadcrumb(_ event: CrashReportingEvent, metadata: CrashReportingMetadata)
    func setOperationalTag(key: String, value: String)
    func flushIfNeeded()
}

extension CrashReporting {
    /// Convenience overload so call sites can pass a plain `[String: String]`
    /// literal — it is still funneled through `CrashReportingMetadata`'s
    /// allowlist before reaching the provider.
    func addBreadcrumb(_ event: CrashReportingEvent, metadata raw: [String: String]) {
        addBreadcrumb(event, metadata: CrashReportingMetadata(raw))
    }
    func captureNonFatal(_ error: Error, context raw: [String: String]) {
        captureNonFatal(error, context: CrashReportingMetadata(raw))
    }
}

/// The exhaustive, fixed set of operational events this app ever reports —
/// section 六 of the Phase 2C-2 instructions. No other event name exists;
/// there is no free-text alternative.
enum CrashReportingEvent: String, Sendable, CaseIterable {
    case appStarted = "app_started"
    case syncStarted = "sync_started"
    case syncCompleted = "sync_completed"
    case syncFailed = "sync_failed"
    case syncRateLimited = "sync_rate_limited"
    case syncUpgradeRequired = "sync_upgrade_required"
    case mergePreviewStarted = "merge_preview_started"
    case mergePreviewFailed = "merge_preview_failed"
    case mergeConfirmStarted = "merge_confirm_started"
    case mergeConfirmCompleted = "merge_confirm_completed"
    case mergeConfirmFailed = "merge_confirm_failed"
    case rollbackStarted = "rollback_started"
    case rollbackCompleted = "rollback_completed"
    case rollbackFailed = "rollback_failed"
    case consistencyCheckFailed = "consistency_check_failed"

    var category: String {
        switch self {
        case .appStarted: "lifecycle"
        case .syncStarted, .syncCompleted, .syncFailed, .syncRateLimited, .syncUpgradeRequired: "sync"
        case .mergePreviewStarted, .mergePreviewFailed, .mergeConfirmStarted, .mergeConfirmCompleted, .mergeConfirmFailed: "merge"
        case .rollbackStarted, .rollbackCompleted, .rollbackFailed: "rollback"
        case .consistencyCheckFailed: "consistency"
        }
    }
}

/// Metadata funneled through a fixed allowlist — see section 六. Any key not
/// in `allowedKeys` is silently dropped at construction time, so no call
/// site anywhere in the app can accidentally leak an entity name, email,
/// token, household id, or full UUID through this type, regardless of what
/// it was given.
nonisolated struct CrashReportingMetadata: Sendable, Equatable, ExpressibleByDictionaryLiteral {
    static let allowedKeys: Set<String> = [
        "environment", "release", "build", "routeCategory", "errorCode",
        "httpStatus", "durationBucket", "mutationCountBucket", "conflictCountBucket",
        "retryCount", "featureFlagState"
    ]

    private(set) var fields: [String: String]

    init(_ raw: [String: String]) {
        fields = raw.filter { Self.allowedKeys.contains($0.key) }
    }

    init(dictionaryLiteral elements: (String, String)...) {
        self.init(Dictionary(uniqueKeysWithValues: elements))
    }

    /// Buckets a raw count into a small, stable, non-exact label — never the
    /// exact count of a business collection (inventory/receipt items).
    static func countBucket(_ count: Int) -> String {
        switch count {
        case ..<1: "0"
        case 1...5: "1-5"
        case 6...20: "6-20"
        case 21...100: "21-100"
        default: "100+"
        }
    }

    /// Buckets a duration into a small, stable label — never a raw millisecond
    /// value with unbounded cardinality.
    static func durationBucket(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<0.5: "lt500ms"
        case 0.5..<1: "lt1s"
        case 1..<3: "lt3s"
        case 3..<10: "lt10s"
        default: "gte10s"
        }
    }
}

/// Conformed by app error types (e.g. `SyncError`) to give crash reporting a
/// stable, non-localized code instead of ever needing `error.localizedDescription`
/// or `String(describing: error)` (which could, for a future error type,
/// embed unexpected content).
protocol CrashReportableError {
    var crashReportingCode: String { get }
}

/// Default, always-safe provider. Every method is a true no-op — it never
/// allocates, never performs I/O, never throws. This is both the default
/// (crash reporting disabled) provider and the fallback whenever
/// configuration is enabled but incomplete (see `CrashReportingFactory`).
final class NoOpCrashReporter: CrashReporting {
    static let shared = NoOpCrashReporter()
    private init() {}

    func configure(environment: String, release: String, build: String) {}
    func captureFatalContext(_ metadata: CrashReportingMetadata) {}
    func captureNonFatal(_ error: Error, context: CrashReportingMetadata) {}
    func addBreadcrumb(_ event: CrashReportingEvent, metadata: CrashReportingMetadata) {}
    func setOperationalTag(key: String, value: String) {}
    func flushIfNeeded() {}
}

/// Phase 2C-2 configuration — mirrors `SyncConfiguration.load(from:)`'s
/// pattern exactly (xcconfig -> Info.plist `KM_*` key -> this struct).
/// Default/missing/malformed configuration is always the safe "disabled"
/// state; enforcement never silently "fails open" into an enabled state.
nonisolated struct CrashReportingConfiguration: Equatable, Sendable {
    let isEnabled: Bool
    let environment: String
    let dsn: String
    let sampleRate: Double

    init(isEnabled: Bool = false, environment: String = "", dsn: String = "", sampleRate: Double = 0) {
        self.isEnabled = isEnabled
        self.environment = environment
        self.dsn = dsn
        // Clamp defensively — a malformed or out-of-range value (e.g. "150",
        // "-1") must never turn into 100% tracing by accident.
        self.sampleRate = min(max(sampleRate, 0), 1)
    }

    static func load(from bundle: Bundle = .main) -> CrashReportingConfiguration {
        func stringValue(_ key: String) -> String {
            guard let raw = bundle.object(forInfoDictionaryKey: key) else { return "" }
            return String(describing: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let enabledRaw = stringValue("KM_CRASH_REPORTING_ENABLED").lowercased()
        let isEnabled = ["1", "true", "yes"].contains(enabledRaw)
        let environment = stringValue("KM_CRASH_REPORTING_ENVIRONMENT")
        let dsn = stringValue("KM_CRASH_REPORTING_DSN")
        let sampleRate = Double(stringValue("KM_CRASH_REPORTING_SAMPLE_RATE")) ?? 0
        return CrashReportingConfiguration(isEnabled: isEnabled, environment: environment, dsn: dsn, sampleRate: sampleRate)
    }
}

/// Decides which concrete provider a call site gets. Phase 2C-2 only ever
/// returns `NoOpCrashReporter` — see docs/CRASH_REPORTING.md for why a real
/// SDK (Sentry, evaluated against Crashlytics/Bugsnag) is *selected* but not
/// yet *integrated* this phase. An enabled-but-incomplete configuration
/// (e.g. `CRASH_REPORTING_ENABLED=YES` with no DSN) must never crash or
/// silently pretend to report — it always falls back to the no-op provider.
enum CrashReportingFactory {
    static func makeProvider(configuration: CrashReportingConfiguration = .load()) -> any CrashReporting {
        guard configuration.isEnabled, !configuration.dsn.isEmpty else {
            return NoOpCrashReporter.shared
        }
        // No real provider is wired in yet this phase — see
        // docs/CRASH_REPORTING.md "Provider selected, not configured".
        return NoOpCrashReporter.shared
    }
}

import Foundation

/// Phase 2B-5: a dogfood-only configuration layer, entirely independent of
/// the network-capability (`INVENTORY_SYNC_ENABLED`) and UI-visibility
/// (`INVENTORY_MERGE_UI_ENABLED`) flags. Dogfood existing does **not** imply
/// automatic sync — it only ever unlocks two things: a read-only
/// diagnostics screen (`isDiagnosticsEnabled`), and safety limits that apply
/// to the existing, already-manual create/update/delete/syncNow paths.
/// Every field defaults to the safest value; a missing Info.plist key (the
/// normal state for every Release build) resolves to fully-off.
nonisolated struct InventorySyncDogfoodConfiguration: Equatable, Sendable {
    let isDogfoodEnabled: Bool
    /// Convenience read of the existing, independent `INVENTORY_MERGE_UI_ENABLED`
    /// flag — dogfood never overrides or duplicates its own source of truth.
    let isMergeUIEnabled: Bool
    /// Convenience read of the existing, independent `INVENTORY_SYNC_ENABLED`
    /// flag (the actual network-capability gate). Named to match the spec's
    /// vocabulary; dogfood itself never grants network capability on its own.
    let isManualSyncEnabled: Bool
    let maxPendingMutations: Int
    let maxBatchSize: Int
    let maxRetryAttempts: Int
    let diagnosticsEnabled: Bool
    /// Whether this dogfood configuration is even permitted to reach a real
    /// backend at all — mirrors the same one-off smoke-guard pattern as
    /// `GUEST_MERGE_SMOKE_ENABLED`; true only for an explicit,
    /// ignored-config-file, development-environment hosted dogfood run.
    let allowHostedWrites: Bool
    let environmentName: String

    static let defaultMaxPendingMutations = 200
    static let defaultMaxBatchSize = 100
    static let defaultMaxRetryAttempts = 5

    init(
        isDogfoodEnabled: Bool = false,
        isMergeUIEnabled: Bool = false,
        isManualSyncEnabled: Bool = false,
        maxPendingMutations: Int = InventorySyncDogfoodConfiguration.defaultMaxPendingMutations,
        maxBatchSize: Int = InventorySyncDogfoodConfiguration.defaultMaxBatchSize,
        maxRetryAttempts: Int = InventorySyncDogfoodConfiguration.defaultMaxRetryAttempts,
        diagnosticsEnabled: Bool = false,
        allowHostedWrites: Bool = false,
        environmentName: String = "unknown"
    ) {
        self.isDogfoodEnabled = isDogfoodEnabled
        self.isMergeUIEnabled = isMergeUIEnabled
        self.isManualSyncEnabled = isManualSyncEnabled
        self.maxPendingMutations = max(1, maxPendingMutations)
        self.maxBatchSize = max(1, min(maxBatchSize, 100))
        self.maxRetryAttempts = max(1, maxRetryAttempts)
        self.diagnosticsEnabled = diagnosticsEnabled
        self.allowHostedWrites = allowHostedWrites
        self.environmentName = environmentName
    }

    /// Whether the diagnostics screen should be reachable at all — requires
    /// *both* dogfood and diagnostics to be explicitly on; neither alone is
    /// sufficient. Never true in a Release build with default configuration.
    var showsDiagnosticsScreen: Bool { isDogfoodEnabled && diagnosticsEnabled }

    static func load(from bundle: Bundle = .main) -> InventorySyncDogfoodConfiguration {
        let dogfoodEnabled = flag(bundle, "KM_INVENTORY_SYNC_DOGFOOD_ENABLED")
        let diagnosticsEnabled = flag(bundle, "KM_INVENTORY_SYNC_DIAGNOSTICS_ENABLED")
        let mergeUIEnabled = InventoryMergeUIConfiguration.load(from: bundle).isEnabled
        let manualSyncEnabled = InventoryMergeConfiguration.load(from: bundle).isEnabled
        let environment = (bundle.object(forInfoDictionaryKey: "KM_SYNC_SMOKE_ENVIRONMENT") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return InventorySyncDogfoodConfiguration(
            isDogfoodEnabled: dogfoodEnabled,
            isMergeUIEnabled: mergeUIEnabled,
            isManualSyncEnabled: manualSyncEnabled,
            diagnosticsEnabled: diagnosticsEnabled,
            allowHostedWrites: environment == "development" && manualSyncEnabled,
            environmentName: environment ?? "unknown"
        )
    }

    private static func flag(_ bundle: Bundle, _ key: String) -> Bool {
        guard let rawValue = bundle.object(forInfoDictionaryKey: key) else { return false }
        let normalized = String(describing: rawValue).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["1", "true", "yes"].contains(normalized)
    }
}

import Foundation

/// Phase 2B-5: a read-only, fully redacted snapshot of Inventory Sync state
/// for the dogfood diagnostics screen and for `InventorySyncConsistencyChecker`.
/// Deliberately contains **no** entity identifier, name, token, or payload —
/// every field is either a count, a boolean, a duration, an enum's rawValue,
/// or a plain top-level cursor position (a monotonic sequence number, not a
/// secret). See `docs/INVENTORY_SYNC_DIAGNOSTICS.md` for the exhaustive
/// "never included" list and the test that enforces it.
nonisolated struct InventorySyncDiagnosticsSnapshot: Equatable, Sendable {
    let environment: String
    let isFeatureEnabled: Bool
    let isDogfoodEnabled: Bool
    let isEnrolled: Bool
    let currentUserPresent: Bool
    let householdPresent: Bool
    let pendingCount: Int
    let conflictCount: Int
    let failedCount: Int
    /// Seconds since the oldest still-pending mutation was first staged —
    /// `nil` when there is nothing pending.
    let oldestPendingAge: TimeInterval?
    let lastSyncStartedAt: Date?
    let lastSyncCompletedAt: Date?
    /// A short, non-identifying label derived from the last `SyncRunOutcome`
    /// (e.g. "completed", "failed", "paused", "disabled") — never the
    /// associated error's raw description.
    let lastSyncResult: String?
    /// The plain cursor position (a monotonic sequence number the server
    /// already exposes in every pull response) — not a secret, but still
    /// never combined here with any entity identifier.
    let lastSuccessfulCursor: String?
    let activeMergeSessionState: String?
    let enrollmentState: String
    let localSyncedItemCount: Int
    let localGuestOnlyItemCount: Int
    let localTombstoneCount: Int
    let appBuild: String
    let schemaVersion: Int

    /// Encodes to a redacted JSON export — the exact same fields as above,
    /// nothing more. Used by the diagnostics screen's "导出脱敏诊断摘要" action.
    func redactedJSON() -> Data {
        let payload: [String: Any] = [
            "environment": environment,
            "isFeatureEnabled": isFeatureEnabled,
            "isDogfoodEnabled": isDogfoodEnabled,
            "isEnrolled": isEnrolled,
            "currentUserPresent": currentUserPresent,
            "householdPresent": householdPresent,
            "pendingCount": pendingCount,
            "conflictCount": conflictCount,
            "failedCount": failedCount,
            "oldestPendingAgeSeconds": oldestPendingAge as Any,
            "lastSyncStartedAt": lastSyncStartedAt?.timeIntervalSince1970 as Any,
            "lastSyncCompletedAt": lastSyncCompletedAt?.timeIntervalSince1970 as Any,
            "lastSyncResult": lastSyncResult as Any,
            "lastSuccessfulCursor": lastSuccessfulCursor as Any,
            "activeMergeSessionState": activeMergeSessionState as Any,
            "enrollmentState": enrollmentState,
            "localSyncedItemCount": localSyncedItemCount,
            "localGuestOnlyItemCount": localGuestOnlyItemCount,
            "localTombstoneCount": localTombstoneCount,
            "appBuild": appBuild,
            "schemaVersion": schemaVersion
        ]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]))
            ?? Data("{}".utf8)
    }
}

/// A single, redacted consistency-issue code — never the entity's name,
/// household id, or full UUID. `shortId` (when present) is a short, unstable,
/// irreversible fragment (first 8 hex characters of the UUID's own bytes)
/// used only to distinguish "issue A vs issue B" in a list, never to look up
/// or display the real entity.
nonisolated struct InventorySyncConsistencyIssue: Equatable, Sendable {
    let code: Code
    let shortId: String?

    nonisolated enum Code: String, Sendable {
        case orphanMetadataNoInventoryRecord
        case metadataScopeEnrollmentMismatch
        case orphanPendingMutationNoMetadata
        case pendingMutationScopeMismatch
        case createPendingWithNonZeroBaseVersion
        case updateOrDeletePendingMissingRemoteVersion
        case conflictedMetadataMissingPendingMutation
        case tombstoneConflictsWithVisibleLocalRecord
        case multiplePendingMutationsForSameEntity
        case duplicateForkId
        case mergeSessionMissingPlan
        case enrollmentUserHouseholdMismatch
        case cursorRegressed
        case guestOnlyItemBoundToHousehold
    }

    static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }
}

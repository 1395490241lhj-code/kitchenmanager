import Foundation
import SwiftData

// MARK: - Guest dataset detection (read-only)

/// A read-only snapshot of how much Guest data exists locally. Built from
/// already-loaded in-memory store state (no SwiftData re-query, no network),
/// so computing it is effectively free and safe to call on demand (e.g. when
/// the signed-in user opens the account page).
nonisolated struct GuestDatasetSummary: Equatable, Sendable {
    let inventoryCount: Int
    let shoppingCount: Int
    let todayPlanCount: Int
    let weeklyPlanCount: Int
    let recipeCount: Int
    let detectedAt: Date

    var hasAnyGuestData: Bool {
        inventoryCount > 0 || shoppingCount > 0 || todayPlanCount > 0 || weeklyPlanCount > 0 || recipeCount > 0
    }

    /// Phase 2B-1 only offers a merge path for inventory; other counts are
    /// informational only (shown so the user knows what will NOT be touched).
    var hasMergeableInventory: Bool { inventoryCount > 0 }
}

// MARK: - INVENTORY_SYNC_ENABLED — a second, independent gate from SYNC_ENABLED

/// Phase 2B's own feature flag. `SYNC_ENABLED` continues to gate the general
/// Phase 2A-3 `SyncCoordinator.runOnce` boundary; this flag independently
/// gates whether the Guest inventory merge feature is offered to the user at
/// all. Both default `NO`; flipping one does not flip the other, and neither
/// is ever set from a remote response.
nonisolated struct InventoryMergeConfiguration: Equatable, Sendable {
    let isEnabled: Bool

    init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    static func load(from bundle: Bundle = .main) -> InventoryMergeConfiguration {
        guard let rawValue = bundle.object(forInfoDictionaryKey: "KM_INVENTORY_SYNC_ENABLED") else {
            return InventoryMergeConfiguration()
        }
        let normalized = String(describing: rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return InventoryMergeConfiguration(isEnabled: ["1", "true", "yes"].contains(normalized))
    }
}

// MARK: - Merge session state machine

nonisolated enum GuestMergeSessionStatus: String, Codable, Sendable {
    case detected
    case previewReady
    case awaitingConfirmation
    case preparing
    case uploading
    case conflict
    case completed
    case cancelled
    case rollbackPending
    case rolledBack
    case failed

    var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .rolledBack: true
        default: false
        }
    }

    /// A session in one of these states counts as "active" for the
    /// at-most-one-active-session-per-(user, household, entityType) rule.
    var isActive: Bool { !isTerminal }
}

/// One lightweight, bounded field set per Guest inventory item captured at
/// preview time — not the full `InventoryItem` (no staple/restock fields),
/// and never a token, password, or anything server-config related.
nonisolated struct GuestInventorySnapshotItem: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let unit: String
    let quantity: Double
    let expiryDate: Date?
}

nonisolated struct GuestMergeSession: Equatable, Sendable {
    let id: UUID
    let userId: UUID
    let householdId: UUID
    let entityType: SyncEntityType
    var status: GuestMergeSessionStatus
    let createdAt: Date
    var updatedAt: Date
    var confirmedAt: Date?
    var completedAt: Date?
    var cancelledAt: Date?
    var rollbackAvailableUntil: Date?
    /// Bounded snapshot of the local items this session planned to merge,
    /// captured at preview time so a later plan re-validation can detect
    /// local changes. Capped at `GuestMergeSession.maxSnapshotItems`.
    var localSnapshot: [GuestInventorySnapshotItem]
    /// The full plan, including any conflict choices already made — persisted
    /// so an App restart mid-review or mid-upload resumes without losing
    /// decisions or silently regenerating a different plan.
    var plan: InventoryMergePlan?
    var plannedItemCount: Int
    var uploadedItemCount: Int
    var conflictCount: Int
    var failedCount: Int
    var lastErrorCode: String?
    /// Entity ids this session itself created remotely (as opposed to
    /// updates to pre-existing remote records) — rollback only ever
    /// soft-deletes these, never a pre-existing or user-kept-remote record.
    var createdEntityIds: [UUID]
    let mergeVersion: Int

    static let maxSnapshotItems = 500

    var uniqueSessionKey: String { Self.uniqueKey(userId: userId, householdId: householdId, entityType: entityType) }

    static func uniqueKey(userId: UUID, householdId: UUID, entityType: SyncEntityType) -> String {
        "\(userId.uuidString.lowercased()):\(householdId.uuidString.lowercased()):\(entityType.rawValue)"
    }
}

@Model
final class GuestMergeSessionRecord {
    @Attribute(.unique) var id: UUID
    /// Not marked `.unique` — uniqueness of the *active* session per key is
    /// enforced at write time (see `SwiftDataSyncPersistence`), because a
    /// completed/cancelled/rolled-back session for the same key must remain
    /// queryable as history rather than being physically replaced.
    var sessionKey: String
    var userId: UUID
    var householdId: UUID
    var entityTypeRawValue: String
    var statusRawValue: String
    var createdAt: Date
    var updatedAt: Date
    var confirmedAt: Date?
    var completedAt: Date?
    var cancelledAt: Date?
    var rollbackAvailableUntil: Date?
    var localSnapshotData: Data?
    var planData: Data?
    var plannedItemCount: Int
    var uploadedItemCount: Int
    var conflictCount: Int
    var failedCount: Int
    var lastErrorCode: String?
    var createdEntityIdsData: Data
    var mergeVersion: Int

    init(session: GuestMergeSession) {
        id = session.id
        sessionKey = session.uniqueSessionKey
        userId = session.userId
        householdId = session.householdId
        entityTypeRawValue = session.entityType.rawValue
        statusRawValue = session.status.rawValue
        createdAt = session.createdAt
        updatedAt = session.updatedAt
        confirmedAt = session.confirmedAt
        completedAt = session.completedAt
        cancelledAt = session.cancelledAt
        rollbackAvailableUntil = session.rollbackAvailableUntil
        localSnapshotData = try? JSONEncoder().encode(session.localSnapshot)
        planData = session.plan.flatMap { try? JSONEncoder().encode($0) }
        plannedItemCount = session.plannedItemCount
        uploadedItemCount = session.uploadedItemCount
        conflictCount = session.conflictCount
        failedCount = session.failedCount
        lastErrorCode = session.lastErrorCode
        createdEntityIdsData = (try? JSONEncoder().encode(session.createdEntityIds)) ?? Data("[]".utf8)
        mergeVersion = session.mergeVersion
    }

    func update(from session: GuestMergeSession) {
        statusRawValue = session.status.rawValue
        updatedAt = session.updatedAt
        confirmedAt = session.confirmedAt
        completedAt = session.completedAt
        cancelledAt = session.cancelledAt
        rollbackAvailableUntil = session.rollbackAvailableUntil
        localSnapshotData = try? JSONEncoder().encode(session.localSnapshot)
        planData = session.plan.flatMap { try? JSONEncoder().encode($0) }
        plannedItemCount = session.plannedItemCount
        uploadedItemCount = session.uploadedItemCount
        conflictCount = session.conflictCount
        failedCount = session.failedCount
        lastErrorCode = session.lastErrorCode
        createdEntityIdsData = (try? JSONEncoder().encode(session.createdEntityIds)) ?? Data("[]".utf8)
    }

    var value: GuestMergeSession? {
        guard let entityType = SyncEntityType(rawValue: entityTypeRawValue),
              let status = GuestMergeSessionStatus(rawValue: statusRawValue) else { return nil }
        let snapshot = localSnapshotData.flatMap { try? JSONDecoder().decode([GuestInventorySnapshotItem].self, from: $0) } ?? []
        let plan = planData.flatMap { try? JSONDecoder().decode(InventoryMergePlan.self, from: $0) }
        let createdIds = (try? JSONDecoder().decode([UUID].self, from: createdEntityIdsData)) ?? []
        return GuestMergeSession(
            id: id,
            userId: userId,
            householdId: householdId,
            entityType: entityType,
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt,
            confirmedAt: confirmedAt,
            completedAt: completedAt,
            cancelledAt: cancelledAt,
            rollbackAvailableUntil: rollbackAvailableUntil,
            localSnapshot: snapshot,
            plan: plan,
            plannedItemCount: plannedItemCount,
            uploadedItemCount: uploadedItemCount,
            conflictCount: conflictCount,
            failedCount: failedCount,
            lastErrorCode: lastErrorCode,
            createdEntityIds: createdIds,
            mergeVersion: mergeVersion
        )
    }
}

// MARK: - Merge plan (pure, local-only, re-validatable)

nonisolated enum InventoryMergeAction: String, Codable, Sendable {
    case create
    case update
    case keepRemote
    case keepBoth
    case skip
}

nonisolated enum InventoryMergeConflictReason: String, Codable, Sendable {
    /// Identity matched (same stable id, or a single same-key candidate with
    /// a compatible expiry situation); only the mutable `quantity` differs.
    /// `quantity` is a business value compared *after* matching — it is
    /// never part of the identity/matching key itself, so a quantity
    /// difference alone must never cause a candidate to escape into
    /// `.create`.
    case quantityMismatch
    /// Same stable id, but `expiryDate` differs — a real conflict on the
    /// same tracked entity.
    case expiryMismatch
    /// Same stable id, quantity and expiry both match, but some other
    /// tracked field (`isStaple`, staple category/threshold/restock/tracking
    /// mode/availability) differs. Never silently overwritten by an upload.
    case metadataMismatch
    /// A different id shares the same business key (normalizedName + unit),
    /// and the expiry situation is not clearly compatible (one side has an
    /// expiry and the other doesn't, or the dates differ) — this looks like
    /// a different batch, not the same record; never auto-merged.
    case ambiguousDuplicate
    case multipleRemoteCandidates
}

nonisolated enum InventoryMergeConflictChoice: String, Codable, Sendable {
    case keepLocal
    case keepRemote
    case keepBoth
}

nonisolated struct InventoryMergeCandidate: Identifiable, Codable, Equatable, Sendable {
    var id: UUID { localItemId }
    let localItemId: UUID
    let name: String
    let unit: String
    let localQuantity: Double
    let localExpiryDate: Date?
    let remoteItemId: UUID?
    let remoteQuantity: Double?
    let remoteExpiryDate: Date?
    /// The remote record's version at the time the plan was generated — `nil`
    /// unless `remoteItemId` is a single, definite match (never set for
    /// `.multipleRemoteCandidates`, where no single remote id is known).
    /// Used by `GuestMergeController.confirmMerge` to seed the local
    /// `SyncMetadata` baseVersion before staging an `.update`, since a Guest
    /// device merging into an already-populated household has no local sync
    /// history for an entity it only just learned about via the pre-merge
    /// remote read.
    let remoteVersion: SyncCursorValue?
    var action: InventoryMergeAction
    var conflictReason: InventoryMergeConflictReason?
    var userChoice: InventoryMergeConflictChoice?

    /// A conflict that still needs an explicit user decision before it can
    /// be included in an upload batch.
    var needsDecision: Bool { conflictReason != nil && userChoice == nil }

    /// Explicit, user-driven resolution — never automatic. `keepRemote` never
    /// uploads local's conflicting value; `keepBoth` always creates a new
    /// remote record rather than overwriting the other match; `keepLocal`
    /// updates the same remote record only when the match was the same
    /// stable id (never takes over an ambiguous different-id match).
    func applyingChoice(_ choice: InventoryMergeConflictChoice) -> InventoryMergeCandidate {
        var copy = self
        copy.userChoice = choice
        switch choice {
        case .keepLocal:
            copy.action = (remoteItemId == localItemId) ? .update : .create
        case .keepRemote:
            copy.action = .keepRemote
        case .keepBoth:
            copy.action = .create
        }
        return copy
    }
}

nonisolated struct InventoryMergePlan: Codable, Equatable, Sendable {
    let sessionId: UUID
    let householdId: UUID
    let generatedAt: Date
    let sourceCount: Int
    var candidates: [InventoryMergeCandidate]
    let skippedItemIds: [UUID]
    let planHash: String

    var creates: [InventoryMergeCandidate] { candidates.filter { $0.action == .create && !$0.needsDecision } }
    var updates: [InventoryMergeCandidate] { candidates.filter { $0.action == .update && !$0.needsDecision } }
    var conflicts: [InventoryMergeCandidate] { candidates.filter { $0.needsDecision } }
    var readyToUpload: [InventoryMergeCandidate] {
        candidates.filter { ($0.action == .create || $0.action == .update || $0.action == .keepBoth) && !$0.needsDecision }
    }
}

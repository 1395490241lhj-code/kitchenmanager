import Foundation
import CryptoKit

/// What Phase 2B-1 already knows locally about the household's remote
/// inventory (from prior sync activity, if any — e.g. `SyncMetadata` records
/// already marked `.synced`). This phase never performs a network read to
/// populate this list; an empty list is a valid, honest starting state
/// ("nothing has ever synced yet"), and every local Guest item is then
/// planned as `create`. Wiring a real pre-merge bootstrap/pull to populate
/// this with genuinely-remote-but-locally-unknown items is Phase 2B-2 work.
nonisolated struct RemoteInventorySnapshotItem: Equatable, Sendable {
    let id: UUID
    let name: String
    let unit: String
    let quantity: Double
    let expiryDate: Date?
}

/// Pure, local-only, side-effect-free matching and plan generation. No
/// network access, no SwiftData writes — everything here is re-derivable
/// from its inputs, which is what makes plan re-validation possible.
nonisolated enum InventoryMergePlanner {
    static func normalizedKey(name: String, unit: String) -> String {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(normalizedName)|\(normalizedUnit)"
    }

    static func makePlan(
        sessionId: UUID,
        householdId: UUID,
        localItems: [InventoryItem],
        knownRemoteItems: [RemoteInventorySnapshotItem] = [],
        generatedAt: Date = Date()
    ) -> InventoryMergePlan {
        let remoteById = Dictionary(uniqueKeysWithValues: knownRemoteItems.map { ($0.id, $0) })
        var remoteByKey: [String: [RemoteInventorySnapshotItem]] = [:]
        for remote in knownRemoteItems {
            remoteByKey[normalizedKey(name: remote.name, unit: remote.unit), default: []].append(remote)
        }

        let candidates = localItems.map { local in
            candidate(for: local, remoteById: remoteById, remoteByKey: remoteByKey)
        }

        return InventoryMergePlan(
            sessionId: sessionId,
            householdId: householdId,
            generatedAt: generatedAt,
            sourceCount: localItems.count,
            candidates: candidates,
            skippedItemIds: candidates.filter { $0.action == .skip && $0.conflictReason == nil }.map(\.localItemId),
            planHash: planHash(sessionId: sessionId, householdId: householdId, localItems: localItems)
        )
    }

    /// Re-derives the plan's source fingerprint from the current local items
    /// and compares it against the stored hash. A mismatch means local data
    /// changed since the plan was generated, so callers must regenerate
    /// (never silently reuse) the plan before executing it.
    static func isPlanStillValid(_ plan: InventoryMergePlan, against currentLocalItems: [InventoryItem]) -> Bool {
        planHash(sessionId: plan.sessionId, householdId: plan.householdId, localItems: currentLocalItems) == plan.planHash
    }

    static func planHash(sessionId: UUID, householdId: UUID, localItems: [InventoryItem]) -> String {
        var components: [String] = [sessionId.uuidString.lowercased(), householdId.uuidString.lowercased()]
        for item in localItems.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let expiry = item.expiryDate.map { String($0.timeIntervalSince1970) } ?? "nil"
            components.append("\(item.id.uuidString.lowercased()):\(item.quantity):\(item.unit):\(expiry)")
        }
        let digest = SHA256.hash(data: Data(components.joined(separator: "|").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func candidate(
        for local: InventoryItem,
        remoteById: [UUID: RemoteInventorySnapshotItem],
        remoteByKey: [String: [RemoteInventorySnapshotItem]]
    ) -> InventoryMergeCandidate {
        // 1. Same stable id already known to exist remotely: compare directly,
        // never blindly overwrite.
        if let remote = remoteById[local.id] {
            return resolved(local: local, remote: remote, ambiguous: false)
        }

        let key = normalizedKey(name: local.name, unit: local.unit)
        let matches = remoteByKey[key] ?? []
        switch matches.count {
        case 0:
            return InventoryMergeCandidate(
                localItemId: local.id, name: local.name, unit: local.unit,
                localQuantity: local.quantity, localExpiryDate: local.expiryDate,
                remoteItemId: nil, remoteQuantity: nil, remoteExpiryDate: nil,
                action: .create, conflictReason: nil, userChoice: nil
            )
        case 1:
            return resolved(local: local, remote: matches[0], ambiguous: true)
        default:
            // Multiple remote candidates share the same business key: never
            // auto-select one. Requires an explicit user choice.
            return InventoryMergeCandidate(
                localItemId: local.id, name: local.name, unit: local.unit,
                localQuantity: local.quantity, localExpiryDate: local.expiryDate,
                remoteItemId: nil, remoteQuantity: nil, remoteExpiryDate: nil,
                action: .skip, conflictReason: .multipleRemoteCandidates, userChoice: nil
            )
        }
    }

    /// `ambiguous` distinguishes "same stable id, different values" (a real
    /// update candidate) from "different id, same business key" (a possible
    /// duplicate that must never be silently treated as the same record).
    private static func resolved(
        local: InventoryItem,
        remote: RemoteInventorySnapshotItem,
        ambiguous: Bool
    ) -> InventoryMergeCandidate {
        let sameValues = local.quantity == remote.quantity && local.expiryDate == remote.expiryDate
        if sameValues {
            return InventoryMergeCandidate(
                localItemId: local.id, name: local.name, unit: local.unit,
                localQuantity: local.quantity, localExpiryDate: local.expiryDate,
                remoteItemId: remote.id, remoteQuantity: remote.quantity, remoteExpiryDate: remote.expiryDate,
                action: .skip,
                conflictReason: ambiguous ? .ambiguousDuplicate : nil,
                userChoice: nil
            )
        }
        let reason: InventoryMergeConflictReason = ambiguous
            ? .ambiguousDuplicate
            : (local.quantity != remote.quantity ? .quantityMismatch : .expiryMismatch)
        return InventoryMergeCandidate(
            localItemId: local.id, name: local.name, unit: local.unit,
            localQuantity: local.quantity, localExpiryDate: local.expiryDate,
            remoteItemId: remote.id, remoteQuantity: remote.quantity, remoteExpiryDate: remote.expiryDate,
            action: .skip, conflictReason: reason, userChoice: nil
        )
    }
}

// MARK: - Guest dataset detection (read-only, in-memory)

nonisolated enum GuestDatasetDetector {
    /// Reads only already-loaded in-memory counts (no SwiftData query, no
    /// network). Safe to call whenever the account page appears; never
    /// scheduled from App startup.
    @MainActor
    static func summary(
        kitchenStore: KitchenStore,
        recipeStore: RecipeStore,
        at date: Date = Date()
    ) -> GuestDatasetSummary {
        GuestDatasetSummary(
            inventoryCount: kitchenStore.inventory.count,
            shoppingCount: kitchenStore.shoppingItems.count,
            todayPlanCount: kitchenStore.plans.count,
            weeklyPlanCount: kitchenStore.weeklyPlan == nil ? 0 : 1,
            recipeCount: recipeStore.userRecipes.count,
            detectedAt: date
        )
    }
}

import Foundation
import CryptoKit

/// What Phase 2B-1 already knows locally about the household's remote
/// inventory (from prior sync activity, if any — e.g. `SyncMetadata` records
/// already marked `.synced`). This phase never performs a network read to
/// populate this list; an empty list is a valid, honest starting state
/// ("nothing has ever synced yet"), and every local Guest item is then
/// planned as `create`. Wiring a real pre-merge bootstrap/pull to populate
/// this with genuinely-remote-but-locally-unknown items is Phase 2B-2 work.
///
/// `quantity` and `expiryDate` are compared *after* identity matching to
/// classify a conflict — neither is part of the matching key itself. The
/// remaining fields are "metadata": tracked so a same-id difference is
/// surfaced as an explicit `metadataMismatch` conflict rather than silently
/// overwritten by an upload, but never used to decide whether two items are
/// the same candidate.
nonisolated struct RemoteInventorySnapshotItem: Equatable, Sendable {
    let id: UUID
    let name: String
    let unit: String
    let quantity: Double
    let expiryDate: Date?
    let isStaple: Bool
    let stapleCategory: String?
    let lowStockThreshold: Double?
    let defaultRestockQuantity: Double?
    let autoSuggestRestock: Bool
    let stapleTrackingMode: StapleTrackingMode
    let stapleAvailabilityStatus: StapleAvailabilityStatus

    init(
        id: UUID,
        name: String,
        unit: String,
        quantity: Double,
        expiryDate: Date?,
        isStaple: Bool = false,
        stapleCategory: String? = nil,
        lowStockThreshold: Double? = nil,
        defaultRestockQuantity: Double? = nil,
        autoSuggestRestock: Bool = false,
        stapleTrackingMode: StapleTrackingMode = .quantity,
        stapleAvailabilityStatus: StapleAvailabilityStatus = .available
    ) {
        self.id = id
        self.name = name
        self.unit = unit
        self.quantity = quantity
        self.expiryDate = expiryDate
        self.isStaple = isStaple
        self.stapleCategory = stapleCategory
        self.lowStockThreshold = lowStockThreshold
        self.defaultRestockQuantity = defaultRestockQuantity
        self.autoSuggestRestock = autoSuggestRestock
        self.stapleTrackingMode = stapleTrackingMode
        self.stapleAvailabilityStatus = stapleAvailabilityStatus
    }
}

/// Whether two (possibly absent) expiry dates represent a compatible batch
/// for matching purposes. Two different-but-present dates, or one present
/// and one absent, are never treated as compatible — that looks like a
/// different physical batch, not the same record re-counted.
private enum ExpiryIdentity {
    case compatible
    case incompatible

    static func classify(_ lhs: Date?, _ rhs: Date?) -> ExpiryIdentity {
        switch (lhs, rhs) {
        case (nil, nil): return .compatible
        case (let l?, let r?): return l == r ? .compatible : .incompatible
        default: return .incompatible
        }
    }
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

    /// `ambiguous` distinguishes "same stable id" (a real, certain identity —
    /// only its mutable fields are in question) from "different id, same
    /// business key" (a possible duplicate whose *identity itself* is
    /// uncertain, so it must never be silently treated as the same record no
    /// matter how many fields happen to match).
    ///
    /// Classification order matters and is deliberate:
    /// 1. Same id + incompatible expiry -> `expiryMismatch` (certain identity,
    ///    real conflict on a mutable field).
    /// 2. Different id + incompatible expiry -> `ambiguousDuplicate` (looks
    ///    like a different batch under a different id; identity itself is in
    ///    question, so this is never narrowed down to "just an expiry issue").
    /// 3. Compatible expiry, but different id -> `ambiguousDuplicate`
    ///    (identity is still uncertain even though the values line up).
    /// 4. Compatible expiry, same id, quantity differs -> `quantityMismatch`.
    ///    `quantity` is never part of the matching key, so a quantity
    ///    difference alone must never let a candidate escape into `.create`.
    /// 5. Compatible expiry, same id, quantity/expiry both match, but a
    ///    metadata field differs -> `metadataMismatch` (never silently
    ///    overwritten by an upload).
    /// 6. Everything matches, same id -> `skip`, no conflict (true no-op).
    private static func resolved(
        local: InventoryItem,
        remote: RemoteInventorySnapshotItem,
        ambiguous: Bool
    ) -> InventoryMergeCandidate {
        func candidate(action: InventoryMergeAction, reason: InventoryMergeConflictReason?) -> InventoryMergeCandidate {
            InventoryMergeCandidate(
                localItemId: local.id, name: local.name, unit: local.unit,
                localQuantity: local.quantity, localExpiryDate: local.expiryDate,
                remoteItemId: remote.id, remoteQuantity: remote.quantity, remoteExpiryDate: remote.expiryDate,
                action: action, conflictReason: reason, userChoice: nil
            )
        }

        let expiryIdentity = ExpiryIdentity.classify(local.expiryDate, remote.expiryDate)
        guard expiryIdentity == .compatible else {
            // A different-id match with an incompatible expiry looks like a
            // different batch; a same-id match with an incompatible expiry
            // is a certain, real conflict on that one entity's mutable field.
            return candidate(action: .skip, reason: ambiguous ? .ambiguousDuplicate : .expiryMismatch)
        }
        if ambiguous {
            // Identity itself is uncertain (different id, same business
            // key) — never narrowed down to a specific field-level reason,
            // regardless of which fields happen to match or differ.
            return candidate(action: .skip, reason: .ambiguousDuplicate)
        }
        if local.quantity != remote.quantity {
            return candidate(action: .skip, reason: .quantityMismatch)
        }
        if hasMetadataMismatch(local: local, remote: remote) {
            return candidate(action: .skip, reason: .metadataMismatch)
        }
        return candidate(action: .skip, reason: nil)
    }

    private static func hasMetadataMismatch(local: InventoryItem, remote: RemoteInventorySnapshotItem) -> Bool {
        local.isStaple != remote.isStaple
            || local.stapleCategory != remote.stapleCategory
            || local.lowStockThreshold != remote.lowStockThreshold
            || local.defaultRestockQuantity != remote.defaultRestockQuantity
            || local.autoSuggestRestock != remote.autoSuggestRestock
            || local.stapleTrackingMode != remote.stapleTrackingMode
            || local.stapleAvailabilityStatus != remote.stapleAvailabilityStatus
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

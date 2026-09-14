import Foundation

/// The seven domains a backup covers, in the order a restore writes them.
///
/// Conforms to `Error` so a per-domain load or write failure can be reported as
/// the domain itself rather than through a parallel bookkeeping type.
enum KitchenBackupDomain: String, CaseIterable, Equatable, Error {
    case inventory
    case shoppingItems
    case plans
    case consumptionRecords
    case weeklyPlan
    case preparedComponents
    case specialPlans

    /// The established restore order. Unchanged by the outcome model: the
    /// sequence is a persistence contract, not a testing convenience.
    static let restoreOrder: [KitchenBackupDomain] = [
        .inventory, .shoppingItems, .plans, .consumptionRecords,
        .weeklyPlan, .preparedComponents, .specialPlans
    ]

    /// The error this domain has always surfaced, preserved so the thrown type
    /// does not change with this slice.
    var persistenceError: KitchenBackupError {
        switch self {
        case .inventory: .inventoryPersistenceFailed
        case .shoppingItems: .shoppingPersistenceFailed
        case .plans: .todayPlanPersistenceFailed
        case .consumptionRecords: .consumptionPersistenceFailed
        case .weeklyPlan: .weeklyPlanPersistenceFailed
        case .preparedComponents: .preparedComponentPersistenceFailed
        case .specialPlans: .specialPlanPersistenceFailed
        }
    }
}

/// Why a restore that had already begun writing could not be proven recovered.
///
/// Diagnostic, not presentational: it carries which domains were involved so a
/// log or a test can say what happened, and it deliberately carries no
/// member-facing wording.
enum KitchenRestoreUnsafeReason: Equatable {
    /// One or more compensating writes reported failure.
    case compensationFailed([KitchenBackupDomain])
    /// The backup scope could not be fully re-read from persistence, so there
    /// is no observable truth to compare against.
    case reconciliationFailed(KitchenBackupDomain)
    /// Everything was re-read, but what is stored is not the pre-restore state.
    case restoredStateDiffers
}

/// The result of one restore attempt.
///
/// The distinction that matters is between the two failures that never touched
/// anything, the failure that was put back and proven, and the failure that
/// could not be proven. Collapsing the last two would be the lie this whole
/// feature exists to stop telling.
enum KitchenRestoreOutcome: Equatable {
    /// Every backup-scoped domain was replaced.
    case success
    /// The candidate was refused before anything was written.
    case validationFailed
    /// The restore could not be set up — the durable recovery copy could not be
    /// prepared, or an inventory consistency window was holding the store.
    /// Nothing was written either way.
    case preparationFailed
    /// Writing began and failed, and the pre-restore state was re-read from
    /// persistence and proven to be back. Names the domain that failed.
    case failedAndRecovered(KitchenBackupDomain)
    /// Writing began and failed, and recovery could not be proven. What is
    /// stored may be a mixture.
    case failedUnsafe(KitchenRestoreUnsafeReason)

    /// True while the local kitchen may not hold what the member expects.
    /// The single programmatic signal Phase 6 will present.
    var isUnsafe: Bool {
        if case .failedUnsafe = self { return true }
        return false
    }

    /// True when the attempt never reached a destructive write.
    var mutatedNothing: Bool {
        switch self {
        case .validationFailed, .preparationFailed: true
        case .success, .failedAndRecovered, .failedUnsafe: false
        }
    }
}

extension KitchenBackupPayload {
    /// The proof behind `failedAndRecovered`.
    ///
    /// Compares every backup-scoped domain by identity and value. Ordering is
    /// deliberately not part of the proof: `loadInventory` re-sorts by creation
    /// date and name, so a faithful round trip can legitimately come back in a
    /// different array order than the in-memory array it was taken from.
    /// Within-domain ordering that the member can actually perceive is carried
    /// by persisted sort indexes, which are part of the compared values.
    func matchesBackupScope(of other: KitchenBackupPayload) -> Bool {
        keyed(inventory) == keyed(other.inventory)
            && keyed(shoppingItems) == keyed(other.shoppingItems)
            && keyed(plans) == keyed(other.plans)
            && keyed(consumptionRecords) == keyed(other.consumptionRecords)
            && keyed(preparedComponents) == keyed(other.preparedComponents)
            && keyed(specialPlans) == keyed(other.specialPlans)
            && weeklyPlan == other.weeklyPlan
    }

    private func keyed<T: Identifiable & Equatable>(_ items: [T]) -> [T.ID: T] {
        Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

extension KitchenBackupDomain {
    /// What a member calls this domain.
    var title: String {
        switch self {
        case .inventory: "库存与常备规则"
        case .shoppingItems: "买菜清单"
        case .plans: "用餐计划"
        case .consumptionRecords: "消耗记录"
        case .weeklyPlan: "每周菜单"
        case .preparedComponents: "备餐组件"
        case .specialPlans: "聚餐计划"
        }
    }

    /// How much of this domain a candidate carries.
    ///
    /// The weekly menu is a single optional value, not a collection, so it is
    /// reported as present or absent rather than given an invented item count.
    /// Every other domain counts its own top-level entries, never the objects
    /// nested inside them.
    func summary(in payload: KitchenBackupPayload) -> String {
        switch self {
        case .inventory: "\(payload.inventory.count) 项"
        case .shoppingItems: "\(payload.shoppingItems.count) 项"
        case .plans: "\(payload.plans.count) 项"
        case .consumptionRecords: "\(payload.consumptionRecords.count) 项"
        case .weeklyPlan: payload.weeklyPlan == nil ? "无" : "有"
        case .preparedComponents: "\(payload.preparedComponents.count) 项"
        case .specialPlans: "\(payload.specialPlans.count) 项"
        }
    }
}

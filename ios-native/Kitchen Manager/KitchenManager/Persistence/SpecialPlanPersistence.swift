import Foundation
import SwiftData

/// Persistence for special plans. Same shape as the other module persistences
/// (load / replace / upsert / delete / deleteAll) so `KitchenStore` owns the
/// in-memory array and every path — CRUD, backup restore, clear-all — routes
/// through the same protocol seam.
@MainActor
protocol SpecialPlanPersistenceProtocol: AnyObject {
    func loadPlans() throws -> [SpecialPlan]
    func replacePlans(with plans: [SpecialPlan]) throws
    func upsert(_ plan: SpecialPlan) throws
    func delete(id: UUID) throws
    func deleteAll() throws
}

@MainActor
final class SwiftDataSpecialPlanPersistence: SpecialPlanPersistenceProtocol {
    let container: ModelContainer
    private let context: ModelContext

    init(container: ModelContainer) {
        self.container = container
        context = ModelContext(container)
    }

    func loadPlans() throws -> [SpecialPlan] {
        let descriptor = FetchDescriptor<SpecialPlanRecord>(
            sortBy: [SortDescriptor(\.scheduledAt), SortDescriptor(\.title)]
        )
        return try context.fetch(descriptor).map { try $0.specialPlan() }
    }

    #if DEBUG
    /// One-shot deterministic save failure for the feature 005 context-hygiene
    /// tests. Full rationale on `SwiftDataShoppingListPersistence`.
    var failNextReplaceSaveForTesting: Error?
    #endif

    private func saveReplacement() throws {
        #if DEBUG
        if let injected = failNextReplaceSaveForTesting {
            failNextReplaceSaveForTesting = nil
            throw injected
        }
        #endif
        try context.save()
    }

    func replacePlans(with plans: [SpecialPlan]) throws {
        // Rolls back on any failure, the contract
        // `SwiftDataTodayPlanPersistence.replacePlans` and
        // `SwiftDataWeeklyPlanPersistence.replacePlan` already use. This type
        // owns its `ModelContext` outright, so a failed write would otherwise
        // leave that context holding this attempt's pending deletes and
        // inserts; the next call re-fetches, does not see a pending-deleted
        // row, and inserts a fresh record under the same
        // `@Attribute(.unique) id`, and the failed attempt stays readable
        // through this context as though it had been saved. The whole body is
        // covered rather than just the save
        // because `SpecialPlanRecord.update(from:)` and its initialiser can throw mid-loop while encoding, which leaves the same
        // debris without a save ever being attempted.
        do {
            let incomingByID = Dictionary(
                plans.enumerated().map { ($0.element.id, $0.element) },
                uniquingKeysWith: { _, latest in latest }
            )
            let existing = try context.fetch(FetchDescriptor<SpecialPlanRecord>())

            for record in existing {
                guard let plan = incomingByID[record.id] else {
                    context.delete(record)
                    continue
                }
                try record.update(from: plan)
            }

            let existingIDs = Set(existing.map(\.id))
            for plan in incomingByID.values where !existingIDs.contains(plan.id) {
                context.insert(try SpecialPlanRecord(plan: plan))
            }
            try saveReplacement()
        } catch {
            context.rollback()
            throw error
        }
    }

    func upsert(_ plan: SpecialPlan) throws {
        let id = plan.id
        var descriptor = FetchDescriptor<SpecialPlanRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let record = try context.fetch(descriptor).first {
            try record.update(from: plan)
        } else {
            context.insert(try SpecialPlanRecord(plan: plan))
        }
        try context.save()
    }

    func delete(id: UUID) throws {
        let targetID = id
        let descriptor = FetchDescriptor<SpecialPlanRecord>(predicate: #Predicate { $0.id == targetID })
        for record in try context.fetch(descriptor) {
            context.delete(record)
        }
        try context.save()
    }

    func deleteAll() throws {
        try context.delete(model: SpecialPlanRecord.self)
        try context.save()
    }
}

@MainActor
final class FailingSpecialPlanPersistence: SpecialPlanPersistenceProtocol {
    let underlyingError: Error

    init(underlyingError: Error) {
        self.underlyingError = underlyingError
    }

    func loadPlans() throws -> [SpecialPlan] { throw underlyingError }
    func replacePlans(with plans: [SpecialPlan]) throws { throw underlyingError }
    func upsert(_ plan: SpecialPlan) throws { throw underlyingError }
    func delete(id: UUID) throws { throw underlyingError }
    func deleteAll() throws { throw underlyingError }
}

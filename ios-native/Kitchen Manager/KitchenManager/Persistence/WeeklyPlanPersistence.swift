import Foundation
import SwiftData

@MainActor protocol WeeklyPlanPersistenceProtocol: AnyObject {
    func loadPlan() throws -> WeeklyMealPlan?
    func replacePlan(with plan: WeeklyMealPlan?) throws
    func deleteAll() throws
}

@MainActor final class SwiftDataWeeklyPlanPersistence: WeeklyPlanPersistenceProtocol {
    let container: ModelContainer; private let context: ModelContext
    init(container: ModelContainer) { self.container = container; context = ModelContext(container) }
    func loadPlan() throws -> WeeklyMealPlan? {
        let records = try context.fetch(FetchDescriptor<WeeklyPlanRecord>(sortBy: [SortDescriptor(\.startDate, order: .reverse)]))
        return try records.first?.weeklyPlan()
    }
    func replacePlan(with plan: WeeklyMealPlan?) throws {
        // Rolls back on any failure, the same contract
        // `SwiftDataTodayPlanPersistence.replacePlans` uses and for the same
        // reason. This type owns its `ModelContext` outright (created in `init`,
        // never shared), and `update(from:)` mutates a *live* record in it. A
        // failed `save()` would leave that object holding a payload the database
        // never took, and the next `loadPlan()` on this context would hand the
        // unsaved payload back as if it were stored. `update(from:)` and
        // `WeeklyPlanRecord(plan:)` can also throw mid-way while encoding, which
        // leaves the same debris. A materialization receipt depends on a failed
        // write staging nothing at all.
        do {
            let records = try context.fetch(FetchDescriptor<WeeklyPlanRecord>())
            guard let plan else { records.forEach(context.delete); try context.save(); return }
            if let first = records.first { try first.update(from: plan); records.dropFirst().forEach(context.delete) }
            else { context.insert(try WeeklyPlanRecord(plan: plan)) }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
    func deleteAll() throws { try context.delete(model: WeeklyPlanRecord.self); try context.save() }
}

@MainActor final class FailingWeeklyPlanPersistence: WeeklyPlanPersistenceProtocol {
    let error: Error; init(_ error: Error) { self.error = error }
    func loadPlan() throws -> WeeklyMealPlan? { throw error }
    func replacePlan(with plan: WeeklyMealPlan?) throws { throw error }
    func deleteAll() throws { throw error }
}

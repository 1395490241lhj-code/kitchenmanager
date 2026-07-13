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
        let records = try context.fetch(FetchDescriptor<WeeklyPlanRecord>())
        guard let plan else { records.forEach(context.delete); try context.save(); return }
        if let first = records.first { try first.update(from: plan); records.dropFirst().forEach(context.delete) }
        else { context.insert(try WeeklyPlanRecord(plan: plan)) }
        try context.save()
    }
    func deleteAll() throws { try context.delete(model: WeeklyPlanRecord.self); try context.save() }
}

@MainActor final class FailingWeeklyPlanPersistence: WeeklyPlanPersistenceProtocol {
    let error: Error; init(_ error: Error) { self.error = error }
    func loadPlan() throws -> WeeklyMealPlan? { throw error }
    func replacePlan(with plan: WeeklyMealPlan?) throws { throw error }
    func deleteAll() throws { throw error }
}

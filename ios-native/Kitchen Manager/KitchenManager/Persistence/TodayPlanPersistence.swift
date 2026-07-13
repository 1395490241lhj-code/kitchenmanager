import Foundation
import SwiftData

@MainActor
protocol TodayPlanPersistenceProtocol: AnyObject {
    func loadPlans() throws -> [MealPlanItem]
    func replacePlans(with items: [MealPlanItem]) throws
    func upsert(_ item: MealPlanItem) throws
    func delete(id: UUID) throws
    func deleteAll() throws
}

@MainActor
final class SwiftDataTodayPlanPersistence: TodayPlanPersistenceProtocol {
    let container: ModelContainer
    private let context: ModelContext

    init(container: ModelContainer) {
        self.container = container
        context = ModelContext(container)
    }

    convenience init(isStoredInMemoryOnly: Bool = false) throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: isStoredInMemoryOnly)
        let container = try ModelContainer(
            for: InventoryRecord.self,
            ShoppingItemRecord.self,
            TodayPlanRecord.self,
            ConsumptionRecordEntity.self,
            WeeklyPlanRecord.self,
            configurations: configuration
        )
        self.init(container: container)
    }

    func loadPlans() throws -> [MealPlanItem] {
        let descriptor = FetchDescriptor<TodayPlanRecord>(
            sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.date), SortDescriptor(\.recipeName)]
        )
        return try context.fetch(descriptor).map(\.mealPlanItem)
    }

    func replacePlans(with items: [MealPlanItem]) throws {
        let indexedItems = items.enumerated().map { ($0.element.id, ($0.element, $0.offset)) }
        let incomingByID = Dictionary(indexedItems, uniquingKeysWith: { _, latest in latest })
        let existing = try context.fetch(FetchDescriptor<TodayPlanRecord>())

        for record in existing {
            guard let (item, index) = incomingByID[record.id] else {
                context.delete(record)
                continue
            }
            record.update(from: item, sortIndex: index)
        }

        let existingIDs = Set(existing.map(\.id))
        for (item, index) in incomingByID.values where !existingIDs.contains(item.id) {
            context.insert(TodayPlanRecord(item: item, sortIndex: index))
        }
        try context.save()
    }

    func upsert(_ item: MealPlanItem) throws {
        let id = item.id
        var descriptor = FetchDescriptor<TodayPlanRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let record = try context.fetch(descriptor).first {
            record.update(from: item, sortIndex: record.sortIndex)
        } else {
            let lastIndex = try context.fetchCount(FetchDescriptor<TodayPlanRecord>())
            context.insert(TodayPlanRecord(item: item, sortIndex: lastIndex))
        }
        try context.save()
    }

    func delete(id: UUID) throws {
        let targetID = id
        let descriptor = FetchDescriptor<TodayPlanRecord>(predicate: #Predicate { $0.id == targetID })
        for record in try context.fetch(descriptor) {
            context.delete(record)
        }
        try context.save()
    }

    func deleteAll() throws {
        try context.delete(model: TodayPlanRecord.self)
        try context.save()
    }
}

@MainActor
final class FailingTodayPlanPersistence: TodayPlanPersistenceProtocol {
    let underlyingError: Error

    init(underlyingError: Error) {
        self.underlyingError = underlyingError
    }

    func loadPlans() throws -> [MealPlanItem] { throw underlyingError }
    func replacePlans(with items: [MealPlanItem]) throws { throw underlyingError }
    func upsert(_ item: MealPlanItem) throws { throw underlyingError }
    func delete(id: UUID) throws { throw underlyingError }
    func deleteAll() throws { throw underlyingError }
}

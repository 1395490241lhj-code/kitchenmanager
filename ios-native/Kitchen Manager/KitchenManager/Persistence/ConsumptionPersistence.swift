import Foundation
import SwiftData

@MainActor
protocol ConsumptionPersistenceProtocol: AnyObject {
    func loadRecords() throws -> [InventoryConsumptionRecord]
    func replaceRecords(with records: [InventoryConsumptionRecord]) throws
    func upsert(_ record: InventoryConsumptionRecord) throws
    func delete(id: UUID) throws
    func deleteAll() throws
}

@MainActor
final class SwiftDataConsumptionPersistence: ConsumptionPersistenceProtocol {
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

    func loadRecords() throws -> [InventoryConsumptionRecord] {
        let descriptor = FetchDescriptor<ConsumptionRecordEntity>(
            sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.date, order: .reverse), SortDescriptor(\.recipeName)]
        )
        do {
            return try context.fetch(descriptor).map { try $0.consumptionRecord() }
        } catch {
            throw ConsumptionPersistenceError.invalidStoredRecord(error)
        }
    }

    func replaceRecords(with records: [InventoryConsumptionRecord]) throws {
        let indexedRecords = records.enumerated().map { ($0.element.id, ($0.element, $0.offset)) }
        let incomingByID = Dictionary(indexedRecords, uniquingKeysWith: { _, latest in latest })
        let existing = try context.fetch(FetchDescriptor<ConsumptionRecordEntity>())

        for entity in existing {
            guard let (record, index) = incomingByID[entity.id] else {
                context.delete(entity)
                continue
            }
            try entity.update(from: record, sortIndex: index)
        }

        let existingIDs = Set(existing.map(\.id))
        for (record, index) in incomingByID.values where !existingIDs.contains(record.id) {
            context.insert(try ConsumptionRecordEntity(record: record, sortIndex: index))
        }
        try context.save()
    }

    func upsert(_ record: InventoryConsumptionRecord) throws {
        let id = record.id
        var descriptor = FetchDescriptor<ConsumptionRecordEntity>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let entity = try context.fetch(descriptor).first {
            try entity.update(from: record, sortIndex: entity.sortIndex)
        } else {
            let lastIndex = try context.fetchCount(FetchDescriptor<ConsumptionRecordEntity>())
            context.insert(try ConsumptionRecordEntity(record: record, sortIndex: lastIndex))
        }
        try context.save()
    }

    func delete(id: UUID) throws {
        let targetID = id
        let descriptor = FetchDescriptor<ConsumptionRecordEntity>(predicate: #Predicate { $0.id == targetID })
        for entity in try context.fetch(descriptor) {
            context.delete(entity)
        }
        try context.save()
    }

    func deleteAll() throws {
        try context.delete(model: ConsumptionRecordEntity.self)
        try context.save()
    }
}

@MainActor
final class FailingConsumptionPersistence: ConsumptionPersistenceProtocol {
    let underlyingError: Error

    init(underlyingError: Error) {
        self.underlyingError = underlyingError
    }

    func loadRecords() throws -> [InventoryConsumptionRecord] { throw underlyingError }
    func replaceRecords(with records: [InventoryConsumptionRecord]) throws { throw underlyingError }
    func upsert(_ record: InventoryConsumptionRecord) throws { throw underlyingError }
    func delete(id: UUID) throws { throw underlyingError }
    func deleteAll() throws { throw underlyingError }
}

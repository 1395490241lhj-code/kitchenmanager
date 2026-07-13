import Foundation
import SwiftData

@MainActor
protocol InventoryPersistenceProtocol: AnyObject {
    func loadInventory() throws -> [InventoryItem]
    func replaceInventory(with items: [InventoryItem]) throws
    func upsert(_ item: InventoryItem) throws
    func delete(id: UUID) throws
    func deleteAll() throws
}

@MainActor
final class SwiftDataInventoryPersistence: InventoryPersistenceProtocol {
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

    func loadInventory() throws -> [InventoryItem] {
        let descriptor = FetchDescriptor<InventoryRecord>(
            sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.name)]
        )
        return try context.fetch(descriptor).map(\.inventoryItem)
    }

    func replaceInventory(with items: [InventoryItem]) throws {
        let incomingByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let existing = try context.fetch(FetchDescriptor<InventoryRecord>())

        for record in existing {
            guard let item = incomingByID[record.id] else {
                context.delete(record)
                continue
            }
            record.update(from: item)
        }

        let existingIDs = Set(existing.map(\.id))
        for item in incomingByID.values where !existingIDs.contains(item.id) {
            context.insert(InventoryRecord(item: item))
        }
        try context.save()
    }

    func upsert(_ item: InventoryItem) throws {
        let id = item.id
        var descriptor = FetchDescriptor<InventoryRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let record = try context.fetch(descriptor).first {
            record.update(from: item)
        } else {
            context.insert(InventoryRecord(item: item))
        }
        try context.save()
    }

    func delete(id: UUID) throws {
        let targetID = id
        let descriptor = FetchDescriptor<InventoryRecord>(predicate: #Predicate { $0.id == targetID })
        for record in try context.fetch(descriptor) {
            context.delete(record)
        }
        try context.save()
    }

    func deleteAll() throws {
        try context.delete(model: InventoryRecord.self)
        try context.save()
    }
}

@MainActor
enum InventoryPersistenceFactory {
    static func application() -> InventoryPersistenceProtocol {
        do {
            return try SwiftDataInventoryPersistence()
        } catch {
            #if DEBUG
            print("[InventoryPersistence] unable to initialize application store: \(error)")
            #endif
            return FailingInventoryPersistence(underlyingError: error)
        }
    }

    static func isolatedInMemory() -> InventoryPersistenceProtocol {
        do {
            return try SwiftDataInventoryPersistence(isStoredInMemoryOnly: true)
        } catch {
            #if DEBUG
            print("[InventoryPersistence] unable to initialize in-memory store: \(error)")
            #endif
            return FailingInventoryPersistence(underlyingError: error)
        }
    }
}

@MainActor
final class FailingInventoryPersistence: InventoryPersistenceProtocol {
    let underlyingError: Error

    init(underlyingError: Error) {
        self.underlyingError = underlyingError
    }

    func loadInventory() throws -> [InventoryItem] { throw underlyingError }
    func replaceInventory(with items: [InventoryItem]) throws { throw underlyingError }
    func upsert(_ item: InventoryItem) throws { throw underlyingError }
    func delete(id: UUID) throws { throw underlyingError }
    func deleteAll() throws { throw underlyingError }
}

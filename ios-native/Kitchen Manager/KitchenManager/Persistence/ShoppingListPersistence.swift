import Foundation
import SwiftData

@MainActor
protocol ShoppingListPersistenceProtocol: AnyObject {
    func loadShoppingItems() throws -> [KitchenShoppingItem]
    func replaceShoppingItems(with items: [KitchenShoppingItem]) throws
    func upsert(_ item: KitchenShoppingItem) throws
    func delete(id: UUID) throws
    func deleteAll() throws
}

@MainActor
final class SwiftDataShoppingListPersistence: ShoppingListPersistenceProtocol {
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

    func loadShoppingItems() throws -> [KitchenShoppingItem] {
        let descriptor = FetchDescriptor<ShoppingItemRecord>(
            sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.name)]
        )
        return try context.fetch(descriptor).map(\.shoppingItem)
    }

    #if DEBUG
    /// One-shot deterministic save failure, used only by the feature 005
    /// context-hygiene tests. Throwing *instead of* calling through to
    /// SwiftData leaves this context holding exactly the pending deletes,
    /// inserts and updates a real failed `save()` leaves behind, which is the
    /// state the rollback below has to clean up. There is no other way to
    /// produce that state on a real context on demand: the ordinary
    /// `Failing*Persistence` stubs replace the type outright, so they never
    /// touch a context at all. Consumed on use; production never sets it, and
    /// the whole seam is compiled out of Release.
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

    func replaceShoppingItems(with items: [KitchenShoppingItem]) throws {
        // Rolls back on any failure, the contract
        // `SwiftDataTodayPlanPersistence.replacePlans` and
        // `SwiftDataWeeklyPlanPersistence.replacePlan` already use, and for the
        // same reason. This type owns its `ModelContext` outright, so a failed
        // write would otherwise leave that context holding this attempt's
        // pending deletes and inserts. The very next call re-fetches, does not
        // see a pending-deleted row, and the failed attempt stays readable
        // through this context as though it had been saved. Rolling back is
        // what makes the state a reader observes match what is stored.
        do {
            let indexedItems = items.enumerated().map { ($0.element.id, ($0.element, $0.offset)) }
            let incomingByID = Dictionary(indexedItems, uniquingKeysWith: { _, latest in latest })
            let existing = try context.fetch(FetchDescriptor<ShoppingItemRecord>())

            for record in existing {
                guard let (item, index) = incomingByID[record.id] else {
                    context.delete(record)
                    continue
                }
                record.update(from: item, sortIndex: index)
            }

            let existingIDs = Set(existing.map(\.id))
            for (item, index) in incomingByID.values where !existingIDs.contains(item.id) {
                context.insert(ShoppingItemRecord(item: item, sortIndex: index))
            }
            try saveReplacement()
        } catch {
            context.rollback()
            throw error
        }
    }

    func upsert(_ item: KitchenShoppingItem) throws {
        let id = item.id
        var descriptor = FetchDescriptor<ShoppingItemRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let record = try context.fetch(descriptor).first {
            record.update(from: item, sortIndex: record.sortIndex)
        } else {
            let lastIndex = try context.fetchCount(FetchDescriptor<ShoppingItemRecord>())
            context.insert(ShoppingItemRecord(item: item, sortIndex: lastIndex))
        }
        try context.save()
    }

    func delete(id: UUID) throws {
        let targetID = id
        let descriptor = FetchDescriptor<ShoppingItemRecord>(predicate: #Predicate { $0.id == targetID })
        for record in try context.fetch(descriptor) {
            context.delete(record)
        }
        try context.save()
    }

    func deleteAll() throws {
        try context.delete(model: ShoppingItemRecord.self)
        try context.save()
    }
}

@MainActor
final class FailingShoppingListPersistence: ShoppingListPersistenceProtocol {
    let underlyingError: Error

    init(underlyingError: Error) {
        self.underlyingError = underlyingError
    }

    func loadShoppingItems() throws -> [KitchenShoppingItem] { throw underlyingError }
    func replaceShoppingItems(with items: [KitchenShoppingItem]) throws { throw underlyingError }
    func upsert(_ item: KitchenShoppingItem) throws { throw underlyingError }
    func delete(id: UUID) throws { throw underlyingError }
    func deleteAll() throws { throw underlyingError }
}

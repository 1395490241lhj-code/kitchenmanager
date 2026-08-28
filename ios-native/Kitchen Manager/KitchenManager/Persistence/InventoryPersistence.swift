import Foundation
import SwiftData

@MainActor
protocol InventoryPersistenceProtocol: AnyObject {
    func loadInventory() throws -> [InventoryItem]
    func replaceInventory(with items: [InventoryItem]) throws
    func upsert(_ item: InventoryItem) throws
    func delete(id: UUID) throws
    func deleteAll() throws
    /// R1: applies a row-scoped diff in ONE transaction.
    ///
    /// The ordinary edit path needs row scoping (so a stale snapshot cannot
    /// delete or resurrect rows it never touched) *and* the all-or-nothing
    /// write the previous whole-table `replaceInventory` gave it. Looping over
    /// `upsert`/`delete` would give up the second: a failure partway through a
    /// batch would leave a committed prefix on disk, an uncommitted remainder
    /// in memory, and no retry — the two would never converge again.
    func applyChanges(upserting items: [InventoryItem], deleting ids: [UUID]) throws
}

@MainActor
final class SwiftDataInventoryPersistence: InventoryPersistenceProtocol {
    let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
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

    /// R1: every public operation runs on its own short-lived `ModelContext`.
    ///
    /// This type used to keep one context for the whole app lifetime. That
    /// made a load-bearing question — "does the UI side observe what the
    /// sync `@ModelActor` (`SwiftDataSyncPersistence`, its own context over
    /// the *same* `ModelContainer`) just committed?" — depend on the SDK's
    /// undocumented sibling-context merge behaviour and on which objects that
    /// long-lived context had already materialised. A fresh context per
    /// operation removes the question by construction: there is no
    /// cross-operation identity map or row cache to go stale.
    ///
    /// Each method here is already a self-contained fetch → mutate → save, so
    /// nothing was carried across calls for a shared context to be worth
    /// keeping. `SwiftDataMultiContextFreshnessTests` (T10a-d) is the
    /// behavioural guard; it passes on both shapes today, which is exactly
    /// why the guarantee must come from the code rather than from the SDK.
    private func makeContext() -> ModelContext { ModelContext(container) }

    func loadInventory() throws -> [InventoryItem] {
        let context = makeContext()
        let descriptor = FetchDescriptor<InventoryRecord>(
            sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.name)]
        )
        return try context.fetch(descriptor).map(\.inventoryItem)
    }

    func replaceInventory(with items: [InventoryItem]) throws {
        let context = makeContext()
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
        let context = makeContext()
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
        let context = makeContext()
        let targetID = id
        let descriptor = FetchDescriptor<InventoryRecord>(predicate: #Predicate { $0.id == targetID })
        for record in try context.fetch(descriptor) {
            context.delete(record)
        }
        try context.save()
    }

    func deleteAll() throws {
        let context = makeContext()
        try context.delete(model: InventoryRecord.self)
        try context.save()
    }

    func applyChanges(upserting items: [InventoryItem], deleting ids: [UUID]) throws {
        guard !items.isEmpty || !ids.isEmpty else { return }
        let context = makeContext()
        let targetIDs = Set(items.map(\.id)).union(ids)
        let existing = try context.fetch(FetchDescriptor<InventoryRecord>())
            .filter { targetIDs.contains($0.id) }
        var existingByID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for id in ids {
            guard let record = existingByID.removeValue(forKey: id) else { continue }
            context.delete(record)
        }
        for item in items {
            if let record = existingByID[item.id] {
                record.update(from: item)
            } else {
                context.insert(InventoryRecord(item: item))
            }
        }
        // One save for the whole diff — every row lands or none does.
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
    func applyChanges(upserting items: [InventoryItem], deleting ids: [UUID]) throws { throw underlyingError }
}

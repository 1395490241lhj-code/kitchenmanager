import Foundation
import SwiftData

@MainActor
protocol PreparedComponentPersistenceProtocol: AnyObject {
    func loadComponents() throws -> [PreparedComponent]
    func replaceComponents(with components: [PreparedComponent]) throws
    func upsert(_ component: PreparedComponent) throws
    func delete(id: UUID) throws
    func deleteAll() throws
}

@MainActor
final class SwiftDataPreparedComponentPersistence: PreparedComponentPersistenceProtocol {
    let container: ModelContainer
    private let context: ModelContext

    init(container: ModelContainer) {
        self.container = container
        context = ModelContext(container)
    }

    func loadComponents() throws -> [PreparedComponent] {
        let descriptor = FetchDescriptor<PreparedComponentRecord>(
            sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.expiryDate), SortDescriptor(\.name)]
        )
        return try context.fetch(descriptor).map(\.preparedComponent)
    }

    func replaceComponents(with components: [PreparedComponent]) throws {
        let indexed = components.enumerated().map { ($0.element.id, ($0.element, $0.offset)) }
        let incomingByID = Dictionary(indexed, uniquingKeysWith: { _, latest in latest })
        let existing = try context.fetch(FetchDescriptor<PreparedComponentRecord>())

        for record in existing {
            guard let (component, index) = incomingByID[record.id] else {
                context.delete(record)
                continue
            }
            record.update(from: component, sortIndex: index)
        }

        let existingIDs = Set(existing.map(\.id))
        for (component, index) in incomingByID.values where !existingIDs.contains(component.id) {
            context.insert(PreparedComponentRecord(component: component, sortIndex: index))
        }
        try context.save()
    }

    func upsert(_ component: PreparedComponent) throws {
        let id = component.id
        var descriptor = FetchDescriptor<PreparedComponentRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let record = try context.fetch(descriptor).first {
            record.update(from: component, sortIndex: record.sortIndex)
        } else {
            let lastIndex = try context.fetchCount(FetchDescriptor<PreparedComponentRecord>())
            context.insert(PreparedComponentRecord(component: component, sortIndex: lastIndex))
        }
        try context.save()
    }

    func delete(id: UUID) throws {
        let targetID = id
        let descriptor = FetchDescriptor<PreparedComponentRecord>(predicate: #Predicate { $0.id == targetID })
        for record in try context.fetch(descriptor) {
            context.delete(record)
        }
        try context.save()
    }

    func deleteAll() throws {
        try context.delete(model: PreparedComponentRecord.self)
        try context.save()
    }
}

@MainActor
final class FailingPreparedComponentPersistence: PreparedComponentPersistenceProtocol {
    let underlyingError: Error

    init(underlyingError: Error) {
        self.underlyingError = underlyingError
    }

    func loadComponents() throws -> [PreparedComponent] { throw underlyingError }
    func replaceComponents(with components: [PreparedComponent]) throws { throw underlyingError }
    func upsert(_ component: PreparedComponent) throws { throw underlyingError }
    func delete(id: UUID) throws { throw underlyingError }
    func deleteAll() throws { throw underlyingError }
}

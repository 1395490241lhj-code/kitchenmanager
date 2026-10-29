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
    /// Last observed durable values, never updated by a failed write/read.
    private var lastSnapshot: [PreparedComponent]?

    init(container: ModelContainer) { self.container = container }

    private func rows(in context: ModelContext) throws -> [PreparedComponentRecord] {
        try context.fetch(FetchDescriptor<PreparedComponentRecord>(
            sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.expiryDate), SortDescriptor(\.name)]
        ))
    }
    private func decode(_ rows: [PreparedComponentRecord]) throws -> [PreparedComponent] {
        let components = try rows.map { try $0.decodePreparedComponent() }
        try PreparedComponentCollectionValidator.validate(components)
        return components
    }
    func loadComponents() throws -> [PreparedComponent] {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let components = try decode(rows(in: context))
        lastSnapshot = components
        return components
    }

    #if DEBUG
    var failNextReplaceSaveForTesting: Error?
    var beforeReplaceSaveForTesting: (() -> Void)?
    var afterReplaceSaveForTesting: (() -> Void)?
    #endif

    private func mutate(_ proposal: ([PreparedComponent]) throws -> [PreparedComponent]) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            let existing = try rows(in: context)
            let current = try decode(existing)
            guard lastSnapshot == nil || lastSnapshot == current else {
                throw PreparedGroupingValidationError.staleSnapshot
            }
            let proposed = try proposal(current)
            try PreparedComponentCollectionValidator.validate(proposed)
            // Duplicate IDs were rejected before building this lookup.
            let incoming = Dictionary(uniqueKeysWithValues: proposed.enumerated().map { ($0.element.id, ($0.element, $0.offset)) })
            for record in existing {
                if let (component, index) = incoming[record.id] {
                    try record.update(from: component, sortIndex: index)
                } else {
                    context.delete(record)
                }
            }
            let existingIDs = Set(existing.map(\.id))
            for (index, component) in proposed.enumerated() where !existingIDs.contains(component.id) {
                context.insert(try PreparedComponentRecord(component: component, sortIndex: index))
            }
            #if DEBUG
            if let error = failNextReplaceSaveForTesting {
                failNextReplaceSaveForTesting = nil
                throw error
            }
            beforeReplaceSaveForTesting?()
            #endif
            try context.save()
            #if DEBUG
            afterReplaceSaveForTesting?()
            #endif
            lastSnapshot = proposed
        } catch {
            context.rollback()
            throw error
        }
    }
    func replaceComponents(with components: [PreparedComponent]) throws { try mutate { _ in components } }
    func upsert(_ component: PreparedComponent) throws {
        try mutate { current in
            var result = current
            if let index = result.firstIndex(where: { $0.id == component.id }) {
                result[index] = component
            } else {
                result.append(component)
            }
            return result
        }
    }
    func delete(id: UUID) throws { try mutate { $0.filter { $0.id != id } } }
    func deleteAll() throws { try mutate { _ in [] } }
}

@MainActor
final class FailingPreparedComponentPersistence: PreparedComponentPersistenceProtocol {
    let underlyingError: Error
    init(underlyingError: Error) { self.underlyingError = underlyingError }
    func loadComponents() throws -> [PreparedComponent] { throw underlyingError }
    func replaceComponents(with components: [PreparedComponent]) throws { throw underlyingError }
    func upsert(_ component: PreparedComponent) throws { throw underlyingError }
    func delete(id: UUID) throws { throw underlyingError }
    func deleteAll() throws { throw underlyingError }
}

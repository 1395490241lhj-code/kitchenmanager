import Foundation
import SwiftData

/// SwiftData row for a prepared batch. Enums are stored as their raw strings,
/// the same way `InventoryRecord` stores the staple enums, so an unknown value
/// written by a future build degrades to a sensible default rather than
/// failing the whole load.
@Model
final class PreparedComponentRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var portionsRemaining: Int
    var stateRawValue: String
    var storageRawValue: String
    var preparedAt: Date
    var expiryDate: Date
    /// Persistence-only ordering metadata, matching `TodayPlanRecord`. The
    /// business model and the backup format stay unchanged by it.
    var sortIndex: Int
    var portionGroupingData: Data? = nil

    init(component: PreparedComponent, sortIndex: Int) throws {
        id = component.id
        name = component.name
        portionsRemaining = component.portionsRemaining
        stateRawValue = component.state.rawValue
        storageRawValue = component.storage.rawValue
        preparedAt = component.preparedAt
        expiryDate = component.expiryDate
        self.sortIndex = sortIndex
        portionGroupingData = try component.grouping.map { try JSONEncoder().encode($0) }
    }

    func decodePreparedComponent() throws -> PreparedComponent {
        guard PreparedComponent.portionRange.contains(portionsRemaining) else {
            throw PreparedGroupingValidationError.invalidComponent
        }
        let grouping = try portionGroupingData.map { try JSONDecoder().decode(PreparedPortionGrouping.self, from: $0) }
        var component = PreparedComponent(
            id: id,
            name: name,
            portionsRemaining: portionsRemaining,
            state: PreparedComponentState(rawValue: stateRawValue) ?? .cooked,
            storage: PreparedStorage(rawValue: storageRawValue) ?? .refrigerated,
            preparedAt: preparedAt,
            expiryDate: expiryDate,
            grouping: grouping
        )
        // Preserve the saved value exactly. Entry-time normalization must not
        // make a successful write differ from its subsequent stale-check read.
        component.name = name
        try PreparedComponentCollectionValidator.validate([component])
        return component
    }

    func update(from component: PreparedComponent, sortIndex: Int) throws {
        let groupingData = try component.grouping.map { try JSONEncoder().encode($0) }
        name = component.name
        portionsRemaining = component.portionsRemaining
        stateRawValue = component.state.rawValue
        storageRawValue = component.storage.rawValue
        preparedAt = component.preparedAt
        expiryDate = component.expiryDate
        self.sortIndex = sortIndex
        portionGroupingData = groupingData
    }
}

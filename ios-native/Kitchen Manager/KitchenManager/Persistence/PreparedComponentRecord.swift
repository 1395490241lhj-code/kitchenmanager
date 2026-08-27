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

    init(component: PreparedComponent, sortIndex: Int) {
        id = component.id
        name = component.name
        portionsRemaining = component.portionsRemaining
        stateRawValue = component.state.rawValue
        storageRawValue = component.storage.rawValue
        preparedAt = component.preparedAt
        expiryDate = component.expiryDate
        self.sortIndex = sortIndex
    }

    var preparedComponent: PreparedComponent {
        PreparedComponent(
            id: id,
            name: name,
            portionsRemaining: portionsRemaining,
            state: PreparedComponentState(rawValue: stateRawValue) ?? .cooked,
            storage: PreparedStorage(rawValue: storageRawValue) ?? .refrigerated,
            preparedAt: preparedAt,
            expiryDate: expiryDate
        )
    }

    func update(from component: PreparedComponent, sortIndex: Int) {
        name = component.name
        portionsRemaining = component.portionsRemaining
        stateRawValue = component.state.rawValue
        storageRawValue = component.storage.rawValue
        preparedAt = component.preparedAt
        expiryDate = component.expiryDate
        self.sortIndex = sortIndex
    }
}

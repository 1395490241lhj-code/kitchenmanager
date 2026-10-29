import Foundation
import SwiftData

/// SwiftData row for a prepared batch. Enums are stored as their raw strings,
/// the same way `InventoryRecord` stores the staple enums. Legacy rows retain
/// their enum fallbacks; lifecycle-bearing rows require known context.
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
    var lifecycleData: Data? = nil

    func decodeLifecycle() throws -> PreparedLifecycle? {
        guard let lifecycleData else { return nil }
        guard let state = PreparedComponentState(rawValue: stateRawValue),
              let storage = PreparedStorage(rawValue: storageRawValue) else {
            throw PreparedLifecycleError.invalidMetadata
        }
        let lifecycle = try JSONDecoder().decode(PreparedLifecycle.self, from: lifecycleData)
        try lifecycle.validate(state: state, storage: storage)
        return lifecycle
    }

    init(component: PreparedComponent, sortIndex: Int) throws {
        id = component.id
        name = component.name
        portionsRemaining = component.portionsRemaining
        stateRawValue = component.state.rawValue
        storageRawValue = component.storage.rawValue
        preparedAt = component.preparedAt
        expiryDate = component.expiryDate
        self.sortIndex = sortIndex
        try PreparedComponentCollectionValidator.validate([component])
        portionGroupingData = try component.grouping.map { try JSONEncoder().encode($0) }
        lifecycleData = try component.lifecycle.map { try JSONEncoder().encode($0) }
    }

    func decodePreparedComponent() throws -> PreparedComponent {
        let lifecycle = try decodeLifecycle()
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
            grouping: grouping,
            lifecycle: lifecycle
        )
        // Preserve the saved value exactly. Entry-time normalization must not
        // make a successful write differ from its subsequent stale-check read.
        component.name = name
        try PreparedComponentCollectionValidator.validate([component])
        return component
    }

    func update(from component: PreparedComponent, sortIndex: Int) throws {
        try PreparedComponentCollectionValidator.validate([component])
        let existingGrouping = try portionGroupingData.map { try JSONDecoder().decode(PreparedPortionGrouping.self, from: $0) }
        let existingLifecycle = try decodeLifecycle()
        // Preserve unchanged recorded blobs, including original JSON key ordering.
        let groupingData = try existingGrouping == component.grouping ? portionGroupingData
            : component.grouping.map { try JSONEncoder().encode($0) }
        let lifecycleData = try existingLifecycle == component.lifecycle ? self.lifecycleData
            : component.lifecycle.map { try JSONEncoder().encode($0) }
        name = component.name
        portionsRemaining = component.portionsRemaining
        stateRawValue = component.state.rawValue
        storageRawValue = component.storage.rawValue
        preparedAt = component.preparedAt
        expiryDate = component.expiryDate
        self.sortIndex = sortIndex
        portionGroupingData = groupingData
        self.lifecycleData = lifecycleData
    }
}

import Foundation
import SwiftData

@Model
final class InventoryRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var quantity: Double
    var unit: String
    var expiryDate: Date?
    var isStaple: Bool
    var createdAt: Date?
    var updatedAt: Date?
    var lowStockThreshold: Double?
    var defaultRestockQuantity: Double?
    var autoSuggestRestock: Bool
    var stapleNote: String?
    var stapleCategory: String?
    var stapleTrackingModeRawValue: String
    var stapleAvailabilityStatusRawValue: String

    init(item: InventoryItem) {
        id = item.id
        name = item.name
        quantity = item.quantity
        unit = item.unit
        expiryDate = item.expiryDate
        isStaple = item.isStaple
        createdAt = item.createdAt
        updatedAt = item.updatedAt
        lowStockThreshold = item.lowStockThreshold
        defaultRestockQuantity = item.defaultRestockQuantity
        autoSuggestRestock = item.autoSuggestRestock
        stapleNote = item.stapleNote
        stapleCategory = item.stapleCategory
        stapleTrackingModeRawValue = item.stapleTrackingMode.rawValue
        stapleAvailabilityStatusRawValue = item.stapleAvailabilityStatus.rawValue
    }

    var inventoryItem: InventoryItem {
        InventoryItem(
            id: id,
            name: name,
            quantity: quantity,
            unit: unit,
            expiryDate: expiryDate,
            isStaple: isStaple,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lowStockThreshold: lowStockThreshold,
            defaultRestockQuantity: defaultRestockQuantity,
            autoSuggestRestock: autoSuggestRestock,
            stapleNote: stapleNote,
            stapleCategory: stapleCategory,
            stapleTrackingMode: StapleTrackingMode(rawValue: stapleTrackingModeRawValue) ?? .quantity,
            stapleAvailabilityStatus: StapleAvailabilityStatus(rawValue: stapleAvailabilityStatusRawValue)
                ?? (quantity <= 0 ? .missing : .available)
        )
    }

    func update(from item: InventoryItem) {
        name = item.name
        quantity = item.quantity
        unit = item.unit
        expiryDate = item.expiryDate
        isStaple = item.isStaple
        createdAt = item.createdAt
        updatedAt = item.updatedAt
        lowStockThreshold = item.lowStockThreshold
        defaultRestockQuantity = item.defaultRestockQuantity
        autoSuggestRestock = item.autoSuggestRestock
        stapleNote = item.stapleNote
        stapleCategory = item.stapleCategory
        stapleTrackingModeRawValue = item.stapleTrackingMode.rawValue
        stapleAvailabilityStatusRawValue = item.stapleAvailabilityStatus.rawValue
    }
}

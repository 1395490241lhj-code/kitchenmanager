import Foundation
import SwiftData

@Model
final class ShoppingItemRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var quantity: Double
    var unit: String
    var source: String
    var isDone: Bool
    var remark: String?
    /// Persistence-only ordering metadata. The business and backup model stays unchanged.
    var sortIndex: Int

    init(item: KitchenShoppingItem, sortIndex: Int) {
        id = item.id
        name = item.name
        quantity = item.quantity
        unit = item.unit
        source = item.source
        isDone = item.isDone
        remark = item.remark
        self.sortIndex = sortIndex
    }

    var shoppingItem: KitchenShoppingItem {
        KitchenShoppingItem(
            id: id,
            name: name,
            quantity: quantity,
            unit: unit,
            source: source,
            isDone: isDone,
            remark: remark
        )
    }

    func update(from item: KitchenShoppingItem, sortIndex: Int) {
        name = item.name
        quantity = item.quantity
        unit = item.unit
        source = item.source
        isDone = item.isDone
        remark = item.remark
        self.sortIndex = sortIndex
    }
}

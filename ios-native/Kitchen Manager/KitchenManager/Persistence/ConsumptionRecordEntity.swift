import Foundation
import SwiftData

@Model
final class ConsumptionRecordEntity {
    @Attribute(.unique) var id: UUID
    var date: Date
    var recipeID: String?
    var recipeName: String
    var planIDsData: Data
    var itemsData: Data
    var isUndone: Bool
    /// Persistence-only metadata. The existing business model and backup remain unchanged.
    var sortIndex: Int

    init(record: InventoryConsumptionRecord, sortIndex: Int) throws {
        id = record.id
        date = record.date
        recipeID = record.recipeID
        recipeName = record.recipeName
        planIDsData = try JSONEncoder().encode(record.planIDs)
        itemsData = try JSONEncoder().encode(record.items)
        isUndone = record.isUndone
        self.sortIndex = sortIndex
    }

    func consumptionRecord() throws -> InventoryConsumptionRecord {
        InventoryConsumptionRecord(
            id: id,
            date: date,
            recipeID: recipeID,
            recipeName: recipeName,
            planIDs: try JSONDecoder().decode([UUID].self, from: planIDsData),
            items: try JSONDecoder().decode([InventoryConsumptionRecordItem].self, from: itemsData),
            isUndone: isUndone
        )
    }

    func update(from record: InventoryConsumptionRecord, sortIndex: Int) throws {
        date = record.date
        recipeID = record.recipeID
        recipeName = record.recipeName
        planIDsData = try JSONEncoder().encode(record.planIDs)
        itemsData = try JSONEncoder().encode(record.items)
        isUndone = record.isUndone
        self.sortIndex = sortIndex
    }
}

enum ConsumptionPersistenceError: LocalizedError {
    case invalidStoredRecord(Error)

    var errorDescription: String? {
        switch self {
        case .invalidStoredRecord:
            return "消耗记录数据无法读取。"
        }
    }
}

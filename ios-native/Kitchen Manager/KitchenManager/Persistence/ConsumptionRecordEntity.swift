import Foundation
import SwiftData

@Model
final class ConsumptionRecordEntity {
    @Attribute(.unique) var id: UUID
    var date: Date
    var recipeID: String?
    var recipeName: String
    /// Legacy property name intentionally preserved to avoid SwiftData schema migrations.
    /// Evolved to encode `ConsumptionTargetPayload` (carrying either planIDs or Special Plan fields),
    /// with fallback decoding for legacy raw `[UUID]` data.
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
        let payload = ConsumptionTargetPayload(
            planIDs: record.planIDs,
            specialPlanID: record.specialPlanID,
            specialPlanDishID: record.specialPlanDishID,
            specialPlanTitleSnapshot: record.specialPlanTitleSnapshot
        )
        planIDsData = try JSONEncoder().encode(payload)
        itemsData = try JSONEncoder().encode(record.items)
        isUndone = record.isUndone
        self.sortIndex = sortIndex
    }

    func consumptionRecord() throws -> InventoryConsumptionRecord {
        let payload: ConsumptionTargetPayload
        if let decoded = try? JSONDecoder().decode(ConsumptionTargetPayload.self, from: planIDsData) {
            payload = decoded
        } else if let legacyIDs = try? JSONDecoder().decode([UUID].self, from: planIDsData) {
            payload = ConsumptionTargetPayload(
                planIDs: legacyIDs,
                specialPlanID: nil,
                specialPlanDishID: nil,
                specialPlanTitleSnapshot: nil
            )
        } else {
            // Both new payload and legacy raw [UUID] failed to decode; propagate honest decoding failure.
            payload = try JSONDecoder().decode(ConsumptionTargetPayload.self, from: planIDsData)
        }

        return InventoryConsumptionRecord(
            id: id,
            date: date,
            recipeID: recipeID,
            recipeName: recipeName,
            planIDs: payload.planIDs,
            specialPlanID: payload.specialPlanID,
            specialPlanDishID: payload.specialPlanDishID,
            specialPlanTitleSnapshot: payload.specialPlanTitleSnapshot,
            items: try JSONDecoder().decode([InventoryConsumptionRecordItem].self, from: itemsData),
            isUndone: isUndone
        )
    }

    func update(from record: InventoryConsumptionRecord, sortIndex: Int) throws {
        date = record.date
        recipeID = record.recipeID
        recipeName = record.recipeName
        let payload = ConsumptionTargetPayload(
            planIDs: record.planIDs,
            specialPlanID: record.specialPlanID,
            specialPlanDishID: record.specialPlanDishID,
            specialPlanTitleSnapshot: record.specialPlanTitleSnapshot
        )
        planIDsData = try JSONEncoder().encode(payload)
        itemsData = try JSONEncoder().encode(record.items)
        isUndone = record.isUndone
        self.sortIndex = sortIndex
    }
}

nonisolated private struct ConsumptionTargetPayload: Codable {
    var planIDs: [UUID]
    var specialPlanID: UUID?
    var specialPlanDishID: UUID?
    var specialPlanTitleSnapshot: String?
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

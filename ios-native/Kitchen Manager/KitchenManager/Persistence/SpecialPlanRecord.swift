import Foundation
import SwiftData

/// SwiftData row for a `SpecialPlan`. Follows the existing repo convention for
/// an aggregate with a nested collection: scalar columns for the fields that
/// queries, sorting and grouping actually touch, plus one JSON blob
/// (`payloadData`) for the embedded `constraintNotes` and `dishes` — exactly
/// the shape `WeeklyPlanRecord` already uses. No relationship graph: dishes
/// stay embedded Codable so there is no second planning source of truth.
@Model
final class SpecialPlanRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var scheduledAt: Date
    var peopleCount: Int
    var payloadData: Data
    var createdAt: Date
    var updatedAt: Date

    @MainActor init(plan: SpecialPlan) throws {
        id = plan.id
        title = plan.title
        scheduledAt = plan.scheduledAt
        peopleCount = plan.peopleCount
        payloadData = try JSONEncoder().encode(PlanPayload(plan: plan))
        createdAt = plan.createdAt
        updatedAt = plan.updatedAt
    }

    @MainActor func specialPlan() throws -> SpecialPlan {
        let payload = try JSONDecoder().decode(PlanPayload.self, from: payloadData)
        return SpecialPlan(
            id: id,
            title: title,
            scheduledAt: scheduledAt,
            peopleCount: peopleCount,
            constraintNotes: payload.constraintNotes,
            notes: payload.notes,
            requestText: payload.requestText,
            usesHomeInventory: payload.usesHomeInventory,
            dishes: payload.dishes,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    @MainActor func update(from plan: SpecialPlan) throws {
        title = plan.title
        scheduledAt = plan.scheduledAt
        peopleCount = plan.peopleCount
        payloadData = try JSONEncoder().encode(PlanPayload(plan: plan))
        createdAt = plan.createdAt
        updatedAt = plan.updatedAt
    }
}

/// Embedded fields that live in the JSON blob. Kept tolerant-toward-the-future:
/// a future build adding a field here decodes old blobs through defaults.
private struct PlanPayload: Codable {
    var constraintNotes: [String]
    var notes: String
    /// Added with the AI composer. Absent in rows written before it.
    var requestText: String
    /// Added with the AI composer. A row written before it has no value and
    /// keeps the behaviour it always had: reconcile against home inventory
    /// (`SpecialPlan.legacyUsesHomeInventory`). Only a plan the composer
    /// created can say `false`.
    var usesHomeInventory: Bool
    var dishes: [SpecialPlanDish]

    init(plan: SpecialPlan) {
        constraintNotes = plan.constraintNotes
        notes = plan.notes
        requestText = plan.requestText
        usesHomeInventory = plan.usesHomeInventory
        dishes = plan.dishes
    }

    enum CodingKeys: String, CodingKey {
        case constraintNotes, notes, requestText, usesHomeInventory, dishes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        constraintNotes = try container.decodeIfPresent([String].self, forKey: .constraintNotes) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        requestText = try container.decodeIfPresent(String.self, forKey: .requestText) ?? ""
        usesHomeInventory = try container.decodeIfPresent(Bool.self, forKey: .usesHomeInventory)
            ?? SpecialPlan.legacyUsesHomeInventory
        dishes = try container.decodeIfPresent([SpecialPlanDish].self, forKey: .dishes) ?? []
    }
}

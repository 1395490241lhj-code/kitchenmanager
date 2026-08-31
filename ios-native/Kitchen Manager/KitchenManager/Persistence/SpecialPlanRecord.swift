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
    var dishes: [SpecialPlanDish]

    init(plan: SpecialPlan) {
        constraintNotes = plan.constraintNotes
        notes = plan.notes
        dishes = plan.dishes
    }
}

import Foundation
import SwiftData

@Model
final class WeeklyPlanRecord {
    @Attribute(.unique) var id: UUID
    var startDate: Date
    var planData: Data

    @MainActor init(plan: WeeklyMealPlan) throws {
        id = UUID()
        startDate = plan.startDate
        planData = try JSONEncoder().encode(plan)
    }

    @MainActor func weeklyPlan() throws -> WeeklyMealPlan {
        try JSONDecoder().decode(WeeklyMealPlan.self, from: planData)
    }

    @MainActor func update(from plan: WeeklyMealPlan) throws {
        startDate = plan.startDate
        planData = try JSONEncoder().encode(plan)
    }
}

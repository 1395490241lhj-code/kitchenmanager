import Foundation

// MARK: - Special plan (event-level aggregate)
//
// A narrow aggregate for multi-dish events (周六 7 人聚餐, 火锅局) that a single
// `MealPlanItem` cannot express: one date+time, one headcount, shared notes and
// constraints, and a menu of existing `Recipe` references.
//
// It deliberately *does not* copy recipe data. Each dish keeps a stable id plus
// the `recipeID` into `RecipeStore` and a `recipeName` display snapshot; the
// recipe remains the single source of truth. Deliberately thin: no servings per
// dish (there is no canonical recipe yield to scale against — see
// `ShoppingListGeneratorTests` servings warnings), no inventory reservation, no
// budget, no prep timeline in this foundation slice.

/// One planned dish inside a `SpecialPlan`. References, never owns, a `Recipe`.
struct SpecialPlanDish: Identifiable, Codable, Hashable {
    var id = UUID()
    /// The recipe's canonical id in `RecipeStore.recipe(id:)`.
    var recipeID: String
    /// Display snapshot for rows whose recipe can no longer be resolved.
    var recipeName: String
    /// Execution state kept on the plan itself; does not touch the recipe.
    var isCooked = false

    init(
        id: UUID = UUID(),
        recipeID: String,
        recipeName: String,
        isCooked: Bool = false
    ) {
        self.id = id
        self.recipeID = recipeID
        self.recipeName = recipeName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isCooked = isCooked
    }
}

/// A special plan event. `scheduledAt` carries the full date+time; Planner groups
/// it by local calendar day.
struct SpecialPlan: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var scheduledAt: Date
    var peopleCount: Int
    /// Free-text constraint lines (忌口/偏好/要求). Structured dietary model is
    /// explicitly out of scope — these are user-confirmed notes, not guarantees.
    var constraintNotes: [String]
    var notes: String
    var dishes: [SpecialPlanDish]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        scheduledAt: Date,
        peopleCount: Int = 2,
        constraintNotes: [String] = [],
        notes: String = "",
        dishes: [SpecialPlanDish] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.scheduledAt = scheduledAt
        self.peopleCount = min(max(peopleCount, 1), 99)
        self.constraintNotes = constraintNotes.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }.reduce(into: []) { result, line in
            if !result.contains(line) { result.append(line) }
        }
        self.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        self.dishes = dishes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Aggregate display summary, e.g. "朋友聚餐 · 7 人 · 18:30".
    var summaryText: String {
        let time = Self.timeText(scheduledAt)
        return [title, "\(peopleCount) 人", time].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Time-of-day text pinned to zh_Hans_CN so rows never render an English
    /// simulator date; same convention as `HomeDatePresentation` / `MealPrepBoard`.
    static func timeText(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

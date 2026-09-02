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
// dish (a Special Plan cooks its recipes as written — see the P4-A base-yield
// contract), no inventory reservation, no budget, no prep timeline.
//
// The user describes the event in one natural-language request (`requestText`).
// `title`, `scheduledAt`, `peopleCount` and `constraintNotes` are *derived*
// from that request by the menu generation call and are kept as display and
// validation state; the request itself remains the canonical statement of
// intent that regeneration and replacement start from.

/// One planned dish inside a `SpecialPlan`. References, never owns, a `Recipe`.
nonisolated struct SpecialPlanDish: Identifiable, Codable, Hashable {
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
nonisolated struct SpecialPlan: Identifiable, Codable, Hashable {
    /// What a plan written before `usesHomeInventory` existed means. Those plans
    /// were always reconciled against the home refrigerator, so a missing value
    /// decodes as `true`; only a plan created through the composer says `false`.
    static let legacyUsesHomeInventory = true

    var id = UUID()
    var title: String
    var scheduledAt: Date
    var peopleCount: Int
    /// Free-text constraint lines (忌口/偏好/要求). Structured dietary model is
    /// explicitly out of scope — these are user-confirmed notes, not guarantees.
    var constraintNotes: [String]
    var notes: String
    /// The user's original natural-language request, verbatim. Empty for plans
    /// created before the composer existed. Never rewritten by the app.
    var requestText: String
    /// Whether this meal is cooked from the home kitchen. `false` means the
    /// home refrigerator is neither shown to the AI nor subtracted from the
    /// shopping list, because food on this phone is not food at the venue.
    var usesHomeInventory: Bool
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
        requestText: String = "",
        usesHomeInventory: Bool = false,
        dishes: [SpecialPlanDish] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.scheduledAt = scheduledAt
        self.peopleCount = min(max(peopleCount, 1), 99)
        self.constraintNotes = Self.normalizedConstraintNotes(constraintNotes)
        self.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        self.requestText = requestText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.usesHomeInventory = usesHomeInventory
        self.dishes = dishes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func normalizedConstraintNotes(_ notes: [String]) -> [String] {
        notes.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }.reduce(into: []) { result, line in
            if !result.contains(line) { result.append(line) }
        }
    }

    // MARK: Codable
    //
    // Backups encode this type directly, so a backup written before the
    // composer existed lacks `requestText` and `usesHomeInventory`. Decoding
    // fills them with the legacy meaning rather than failing or silently
    // switching an old plan's shopping behaviour.

    enum CodingKeys: String, CodingKey {
        case id, title, scheduledAt, peopleCount, constraintNotes, notes
        case requestText, usesHomeInventory, dishes, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            title: try container.decode(String.self, forKey: .title),
            scheduledAt: try container.decode(Date.self, forKey: .scheduledAt),
            peopleCount: try container.decodeIfPresent(Int.self, forKey: .peopleCount) ?? 2,
            constraintNotes: try container.decodeIfPresent([String].self, forKey: .constraintNotes) ?? [],
            notes: try container.decodeIfPresent(String.self, forKey: .notes) ?? "",
            requestText: try container.decodeIfPresent(String.self, forKey: .requestText) ?? "",
            usesHomeInventory: try container.decodeIfPresent(Bool.self, forKey: .usesHomeInventory)
                ?? Self.legacyUsesHomeInventory,
            dishes: try container.decodeIfPresent([SpecialPlanDish].self, forKey: .dishes) ?? [],
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(),
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        )
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

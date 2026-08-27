import Foundation

// MARK: - When a prepared batch is urgent enough for ordinary Home
//
// One place decides how many days are left on a batch, and one place decides
// how few of them counts as urgent. Before this existed the same
// `dateComponents([.day], from: startOfDay(now), to: startOfDay(expiry))` was
// written out in two files, and the horizon itself was a bare `days <= 1` deep
// inside a private helper — a magic day offset nobody could find or change on
// purpose.

/// How Home reads a prepared batch's 建议吃完 date.
///
/// > **This is a presentation policy about urgency on Home. It is not a
/// > food-safety guarantee, and no wording derived from it may read like one.**
/// > The date it works from is `PreparedComponent.expiryDate`, which is the
/// > user's own editable note about when they mean to finish a batch, seeded
/// > from a conservative starting point by `PreparedComponentExpirySuggestion`.
/// > Nothing here claims a batch is safe to eat, or unsafe after.
enum PreparedComponentExpiryPolicy {
    /// How far ahead ordinary Home still calls a batch urgent, counted in whole
    /// days from the start of today.
    ///
    /// `1` means "through tomorrow": already past, today, and tomorrow are
    /// urgent; the day after tomorrow is not. That boundary is a product
    /// decision about what belongs in a short list of things to handle *now* —
    /// a batch four days out is real information, but acting on it today is
    /// not a task, and putting it in 需要处理 would crowd out what is.
    static let homeAttentionHorizonDays = 1

    /// Whole days from the start of today to the start of the batch's date.
    /// Negative when the date has passed, `0` on the day itself.
    ///
    /// The single implementation of that calculation. `MealPrepBoard` phrases it
    /// and this type thresholds it; neither re-derives it.
    static func daysRemaining(
        until expiryDate: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: expiryDate)
        ).day ?? 0
    }

    /// Whether this batch belongs in ordinary Home's 需要处理 list.
    ///
    /// Deliberately **not** consulted by `MealPrepBoard`: a 备餐日 shows every
    /// batch the household has, ordered soonest-first, because that page is
    /// about the whole stock rather than about today's urgency. This only
    /// governs the short attention list on every *other* kind of day.
    static func isUrgentForHomeAttention(
        expiryDate: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        daysRemaining(until: expiryDate, now: now, calendar: calendar) <= homeAttentionHorizonDays
    }
}

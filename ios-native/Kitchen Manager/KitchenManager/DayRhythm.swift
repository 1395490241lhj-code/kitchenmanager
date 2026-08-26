import Foundation

// MARK: - Weekly Rhythm + Meal Intent business models (P0-1B1)
//
// These are pure value types with no persistence of their own.
// `DayRhythmStore` owns the UserDefaults representation and maps unknown
// raw values back to safe defaults, so none of these enums need custom
// tolerant `Codable` conformances.

/// The overall rhythm of a day — how much cooking the household plans to do.
/// Deliberately *not* the same axis as eating out: 外食 belongs to a specific
/// meal's `MealIntent`, never to the day as a whole.
enum DayType: String, Codable, CaseIterable {
    case cooking
    case quick
    case mealPrep
    case flexible
}

/// Canonical Gregorian weekday numbering (1 = Sunday … 7 = Saturday), matching
/// `Calendar.component(.weekday, from:)`. This numbering is independent of the
/// locale's `firstWeekday`, so weekly defaults never shift when the user's
/// region changes which day a week starts on.
enum Weekday: Int, Codable, CaseIterable {
    case sunday = 1
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday

    static func from(_ date: Date, calendar: Calendar) -> Weekday {
        Weekday(rawValue: calendar.component(.weekday, from: date)) ?? .sunday
    }
}

/// A meal slot within a day. First version only models lunch and dinner;
/// future slots are new cases, not a new structure. Future per-meal data
/// (servings, leftovers, packed lunches, meal-prep components) keys off
/// `(date, MealSlot)` — keep this the stable identity.
enum MealSlot: String, Codable, CaseIterable {
    case lunch
    case dinner
}

/// Where a meal's food comes from — the household's own food system, or outside it.
///
/// `household` is the implicit default everywhere and deliberately describes the
/// *source*, not the location: cooking at home, a quick meal, leftovers, a packed
/// lunch eaten at the office and meal-prep portions are all `household`, because
/// binding this axis to physical location would misclassify food brought from home.
/// `eatOut` is per-meal state, not a `DayType`.
enum MealIntent: String, Codable {
    case household
    case eatOut
}

// MARK: - Display copy
//
// Every user-facing string for these types lives here, so Home and Settings
// never grow their own `switch` over the same enum. Same pattern as
// `AppAppearance.title`. Note that `household` deliberately surfaces as 照常 —
// the internal term is never shown to the user.

extension DayType {
    /// Picker/settings form: the rhythm as a plain noun.
    var title: String {
        switch self {
        case .cooking: return "做饭"
        case .quick: return "快手"
        case .mealPrep: return "备餐"
        case .flexible: return "自由"
        }
    }

    /// Home's summary line, where the word stands alone and reads as a day.
    var homeSummaryTitle: String {
        switch self {
        case .cooking: return "做饭日"
        case .quick: return "快手日"
        case .mealPrep: return "备餐日"
        case .flexible: return "自由日"
        }
    }
}

extension MealSlot {
    var title: String {
        switch self {
        case .lunch: return "午餐"
        case .dinner: return "晚餐"
        }
    }

    /// Home only ever names the exception, never the default.
    var eatOutSummary: String { "\(title)外食" }
}

extension MealIntent {
    var title: String {
        switch self {
        case .household: return "照常"
        case .eatOut: return "外食"
        }
    }
}

extension Weekday {
    var title: String {
        switch self {
        case .sunday: return "周日"
        case .monday: return "周一"
        case .tuesday: return "周二"
        case .wednesday: return "周三"
        case .thursday: return "周四"
        case .friday: return "周五"
        case .saturday: return "周六"
        }
    }

    /// Display order for the weekly settings page. Fixed Monday-first because
    /// the product specifies 周一到周日; the stored keys stay locale-independent
    /// Gregorian numbers either way.
    static let displayOrder: [Weekday] = [
        .monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday
    ]
}

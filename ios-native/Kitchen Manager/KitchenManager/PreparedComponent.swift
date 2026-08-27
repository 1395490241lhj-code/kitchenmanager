import Foundation

// MARK: - Prepared components (P1-B)
//
// A batch of portions made ahead: 周末卤好的鸡腿, 提前腌好的鸡肉. Deliberately a
// separate type from `InventoryItem` rather than a mode of it — the audit found
// that four shared behaviours (restock suggestions, the expiry keyword table,
// recipe recommendation scoring, and the pantry shelf) all assume every
// `InventoryItem` is a purchasable raw ingredient, which prepared food is not.
//
// This type owns its own domain vocabulary. It deliberately does not reuse
// `PreparationState` from Quick Meal assembly: that enum also carries `.raw`,
// `.convenience` and `.unknown`, none of which a prepared batch can be, and a
// classifier built for name inference should not define what gets persisted.
// P1-C will map between the two explicitly.

/// How far along a batch is. Only two states exist: something made ahead has
/// either been cooked or only prepped.
enum PreparedComponentState: String, Codable, CaseIterable {
    /// Marinated, portioned, part-processed — still needs a pan. 腌鸡肉.
    case prepped
    /// Cooked through. Eat as is, or just reheat. 卤鸡腿.
    case cooked

    var title: String {
        switch self {
        case .prepped: return "已备好"
        case .cooked: return "已做熟"
        }
    }
}

/// Where the batch is kept. This is not decoration: the same cooked chicken
/// keeps for days refrigerated and weeks frozen, so `preparedAt` and the state
/// alone cannot produce a usable expiry date.
enum PreparedStorage: String, Codable, CaseIterable {
    case refrigerated
    case frozen

    var title: String {
        switch self {
        case .refrigerated: return "冷藏"
        case .frozen: return "冷冻"
        }
    }
}

/// One batch of made-ahead portions.
///
/// `portionsRemaining` counts physical portions that exist, and is never zero:
/// eating the last one removes the batch instead of leaving an empty row. That
/// is why the range starts at 1 — see `KitchenStore.consumePreparedPortion`.
struct PreparedComponent: Identifiable, Codable, Hashable {
    /// A batch of fewer than one portion is not a batch. The upper bound is a
    /// sanity guard, not a product rule.
    static let portionRange = 1...50

    var id = UUID()
    var name: String
    var portionsRemaining: Int
    var state: PreparedComponentState
    var storage: PreparedStorage
    var preparedAt: Date
    /// Always present and always editable. Prepared food always spoils, so
    /// unlike a bag of rice there is no honest "no expiry" case; the value is
    /// seeded from `PreparedComponentExpirySuggestion` and the user can change
    /// it whenever their own judgement differs.
    var expiryDate: Date

    init(
        id: UUID = UUID(),
        name: String,
        portionsRemaining: Int,
        state: PreparedComponentState,
        storage: PreparedStorage,
        preparedAt: Date,
        expiryDate: Date
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.portionsRemaining = Self.clampedPortions(portionsRemaining)
        self.state = state
        self.storage = storage
        self.preparedAt = preparedAt
        self.expiryDate = expiryDate
    }

    static func clampedPortions(_ portions: Int) -> Int {
        min(max(portions, portionRange.lowerBound), portionRange.upperBound)
    }

    var portionsText: String { "剩 \(portionsRemaining) 份" }
}

// MARK: - Expiry suggestion
//
// Deliberately not `InventoryExpirySuggestion`: that table is a keyword lookup
// built for raw groceries, and its answers for prepared food are accidental
// (卤鸡腿 matches nothing and falls to its 7-day default, while 卤牛肉 happens to
// match 牛肉 and gets 3). This one is driven by the two facts that actually
// determine the answer.
//
// These are conservative starting points for a date the user can edit, not a
// food-safety guarantee — the wording around them must not claim otherwise.

enum PreparedComponentExpirySuggestion {
    static func suggestedExpiryDate(
        state: PreparedComponentState,
        storage: PreparedStorage,
        preparedAt: Date = Date(),
        calendar: Calendar = .current
    ) -> Date {
        let days = suggestedDays(state: state, storage: storage)
        return calendar.date(byAdding: .day, value: days, to: preparedAt) ?? preparedAt
    }

    static func suggestedDays(state: PreparedComponentState, storage: PreparedStorage) -> Int {
        switch (storage, state) {
        case (.refrigerated, .cooked): return 3
        case (.refrigerated, .prepped): return 2
        case (.frozen, .cooked), (.frozen, .prepped): return 30
        }
    }
}

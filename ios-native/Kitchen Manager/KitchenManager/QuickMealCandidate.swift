import Foundation

// MARK: - Quick meal candidates (P1-C)
//
// The engine used to take `[InventoryItem]` directly, which meant its rules
// were written against a persistence domain model. Prepared components are a
// second, genuinely different domain — turning them into fake `InventoryItem`s
// would undo exactly the separation P1-B established.
//
// So the rules now face a candidate: a name, a profile, an expiry, and where it
// came from. Both domains adapt *into* this; nothing adapts the other way, and
// the engine can neither see nor write either store.

/// Which record a candidate came from. Carried through to every component of
/// every suggestion, so a later phase can act on the actual record without the
/// engine ever having known its type.
enum QuickMealCandidateSource: Hashable {
    case inventory(UUID)
    case preparedComponent(UUID)

    var id: UUID {
        switch self {
        case .inventory(let id), .preparedComponent(let id): return id
        }
    }
}

/// One thing in the kitchen that could take part in a quick meal.
struct QuickMealCandidate: Equatable {
    let source: QuickMealCandidateSource
    let name: String
    let profile: QuickFoodProfile
    let expiryDate: Date?

    /// Mirrors `InventoryItem.expiryStatus`'s window — expired, today, or
    /// within three days. Defined once here so both domains are ranked by the
    /// same rule; `QuickMealCandidateTests` pins it against the inventory
    /// property so the two cannot drift apart.
    var isExpiringSoon: Bool {
        Self.isExpiringSoon(expiryDate)
    }

    static func isExpiringSoon(_ expiryDate: Date?, now: Date = Date()) -> Bool {
        guard let expiryDate else { return false }
        let calendar = Calendar.current
        guard let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: expiryDate)
        ).day else { return false }
        return days <= 3
    }
}

// MARK: - Adapters
//
// Two paths in, one shape out. Each knows its own domain's availability rule
// and nothing about the other's.

extension QuickMealCandidate {
    /// Inventory: the name is all there is to go on, so the profile is inferred
    /// exactly as it was before this change.
    init(inventoryItem item: InventoryItem) {
        self.init(
            source: .inventory(item.id),
            name: item.name,
            profile: QuickFoodProfileClassifier.profile(for: item.name),
            expiryDate: item.expiryDate
        )
    }

    /// A prepared batch knows its own preparation state as a stored fact, so
    /// that axis is passed in rather than guessed from 卤 / 腌 in the name.
    /// Roles and form still come from the name — a batch called 卤鸡腿 is protein
    /// because of what it is, and no structured field records that yet.
    init(preparedComponent component: PreparedComponent) {
        self.init(
            source: .preparedComponent(component.id),
            name: component.name,
            profile: QuickFoodProfileClassifier.profile(
                for: component.name,
                preparationState: component.state.quickMealPreparationState
            ),
            expiryDate: component.expiryDate
        )
    }
}

extension PreparedComponentState {
    /// The one explicit mapping between the prepared-component domain and Quick
    /// Meal's wider vocabulary. Total by construction: a batch can only ever be
    /// one of these two, so there is no default case to get wrong.
    var quickMealPreparationState: PreparationState {
        switch self {
        case .prepped: return .prepped
        case .cooked: return .cooked
        }
    }
}

// MARK: - Building the pool

extension QuickMealCandidate {
    /// Everything that can take part, from both domains.
    ///
    /// Inventory keeps its own availability rule (`quantity > 0`). A prepared
    /// batch needs none: P1-B guarantees a stored batch always has at least one
    /// portion, because eating the last one deletes the record.
    static func pool(
        inventory: [InventoryItem],
        preparedComponents: [PreparedComponent]
    ) -> [QuickMealCandidate] {
        let fromInventory = inventory
            .filter(\.isAvailable)
            .map(QuickMealCandidate.init(inventoryItem:))
        let fromPrepared = preparedComponents.map(QuickMealCandidate.init(preparedComponent:))
        // Inventory first so that, all else equal, the deterministic ordering
        // this pool feeds is unchanged from before prepared components existed.
        return (fromInventory + fromPrepared)
            .filter { !$0.profile.isUnclassified && !$0.profile.isSeasoningOnly }
    }
}

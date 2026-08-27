import Foundation

// MARK: - Component meal policy (P1-F)
//
// A weekday plate: 主食 + 蛋白 + 蔬菜, for example 红薯 + 卤鸡腿 + 西兰花.
//
// Deliberately NOT part of `QuickMealAssemblyEngine`, and not because two
// engines look tidier. The two answer different questions, and four of Quick
// Meal's rules are actively wrong here:
//
//   1. its staple pool requires `preparationState == .cooked`, so a raw sweet
//      potato — the staple of the very example above — can never be picked;
//   2. it ranks by effort first, which would always demote a complete plate
//      below a lazier incomplete one;
//   3. its dedupe drops a fuller combination whenever a subset is less work,
//      which is precisely the three-part structure this policy exists to find;
//   4. its `best` deliberately ignores provenance, while this policy needs to
//      prefer a prepared batch — and teaching provenance to Quick Meal's
//      selection would change Quick Meal's results.
//
// What *is* shared is the candidate layer: `QuickMealCandidate`, its pool, and
// `QuickFoodProfile`. Those names are historical — they were extracted while
// Quick Meal was the only consumer — but the values themselves carry nothing
// Quick-Meal-specific: a source, a name, a profile and an expiry. They are
// reused as-is rather than renamed, because a rename would touch several
// hundred stable lines for no behavioural gain.
//
// This layer produces no effort tier and no time estimate. It says what stands
// up structurally, nothing more — in particular it makes no claim about
// nutrition, calories or macros, and none of its wording may imply one.

/// One candidate filling one slot of the plate.
struct ComponentMealComponent: Equatable {
    enum Slot: String, CaseIterable {
        case carb
        case protein
        case vegetable
    }

    let slot: Slot
    let candidate: QuickMealCandidate

    var name: String { candidate.name }
    var profile: QuickFoodProfile { candidate.profile }
    var source: QuickMealCandidateSource { candidate.source }
}

/// A complete plate. There is no partial suggestion: the whole point is that
/// all three parts are present.
struct ComponentMealSuggestion: Equatable {
    let carb: ComponentMealComponent
    let protein: ComponentMealComponent
    let vegetable: ComponentMealComponent

    /// Staple first, then the two things that go on it — the order a person
    /// would say them in.
    var components: [ComponentMealComponent] { [carb, protein, vegetable] }

    var componentSources: [QuickMealCandidateSource] { components.map(\.source) }

    /// "红薯 · 卤鸡腿 · 西兰花"
    var componentsText: String { components.map(\.name).joined(separator: " · ") }
}

/// Why no plate stands up. Its own vocabulary: Quick Meal's
/// `.nothingQuickEnough` has no meaning here, because this policy never judged
/// how much work anything is.
enum ComponentMealGap: Equatable {
    /// Nothing in the kitchen can take part — empty, seasonings only, or names
    /// that could not be placed.
    case nothingUsable
    case missingCarb
    case missingProtein
    case missingVegetable
}

struct ComponentMealResult: Equatable {
    /// First version returns at most one. No rotation, so no new stored state.
    let suggestion: ComponentMealSuggestion?
    /// Populated only when `suggestion` is nil.
    let gaps: [ComponentMealGap]

    static let nothingUsable = ComponentMealResult(suggestion: nil, gaps: [.nothingUsable])
}

enum ComponentMealPolicy {
    /// Strictly 1 carb + 1 protein + 1 vegetable, each a *different* record.
    ///
    /// The one-record-one-slot rule is not bookkeeping: 红薯 and 玉米 both carry
    /// a staple role and a vegetable role, so without it a single sweet potato
    /// beside a chicken thigh would report itself as a complete three-part
    /// plate. Slots are filled staple first, and each one excludes what the
    /// earlier ones took.
    static func assemble(
        inventory: [InventoryItem],
        preparedComponents: [PreparedComponent] = []
    ) -> ComponentMealResult {
        let usable = QuickMealCandidate.pool(
            inventory: inventory,
            preparedComponents: preparedComponents
        )
        guard !usable.isEmpty else { return .nothingUsable }

        var taken: Set<QuickMealCandidateSource> = []

        let carb = bestCarb(in: usable, excluding: taken)
        if let carb { taken.insert(carb.source) }

        let protein = bestProtein(in: usable, excluding: taken)
        if let protein { taken.insert(protein.source) }

        let vegetable = bestVegetable(in: usable, excluding: taken)

        guard let carb, let protein, let vegetable else {
            var gaps: [ComponentMealGap] = []
            if carb == nil { gaps.append(.missingCarb) }
            if protein == nil { gaps.append(.missingProtein) }
            if vegetable == nil { gaps.append(.missingVegetable) }
            return ComponentMealResult(
                suggestion: nil,
                gaps: gaps.isEmpty ? [.nothingUsable] : gaps
            )
        }

        return ComponentMealResult(
            suggestion: ComponentMealSuggestion(
                carb: ComponentMealComponent(slot: .carb, candidate: carb),
                protein: ComponentMealComponent(slot: .protein, candidate: protein),
                vegetable: ComponentMealComponent(slot: .vegetable, candidate: vegetable)
            ),
            gaps: []
        )
    }

    // MARK: - Slots

    /// Staples that make sense as the base of a plate you eat with a fork.
    ///
    /// An allowlist rather than "anything with a carb role", so what is in and
    /// what is out is visible in one place. Noodles and rice noodles are out on
    /// purpose: a bowl of noodles is a whole meal in its own right, Quick Meal's
    /// `noodleBowl` already describes it, and admitting them here would produce
    /// a near-duplicate of that card. Dumplings and wontons are out for the same
    /// reason, and flour — which has a carb role but no form — never qualifies.
    ///
    /// Unlike Quick Meal's staple pool this does *not* require the staple to be
    /// cooked already. A raw sweet potato is a perfectly ordinary weekday base;
    /// how long it takes is not something this layer claims to know.
    static let carbForms: [QuickFoodForm] = [.rice, .tuber, .corn, .bread]

    private static func bestCarb(
        in usable: [QuickMealCandidate],
        excluding taken: Set<QuickMealCandidateSource>
    ) -> QuickMealCandidate? {
        let pool = usable.filter { candidate in
            !taken.contains(candidate.source)
                && candidate.profile.has(.carb)
                && isPlateBase(candidate)
        }
        return pool.min { lhs, rhs in
            if lhs.isExpiringSoon != rhs.isExpiringSoon { return lhs.isExpiringSoon }
            let lhsRank = carbRank(lhs), rhsRank = carbRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }

    /// A fixed preference among staples, used only for a stable order. Not a
    /// quality ranking and not a time estimate — rice simply reads as the
    /// default base, and the list has to break ties the same way every run.
    private static func carbRank(_ candidate: QuickMealCandidate) -> Int {
        guard let form = candidate.profile.form,
              let index = carbForms.firstIndex(of: form) else { return carbForms.count }
        return index
    }

    private static func bestProtein(
        in usable: [QuickMealCandidate],
        excluding taken: Set<QuickMealCandidateSource>
    ) -> QuickMealCandidate? {
        let pool = usable.filter { candidate in
            !taken.contains(candidate.source)
                && candidate.profile.has(.protein)
                && !isStandaloneMeal(candidate)
        }
        return pool.min { lhs, rhs in
            // Using something up beats every other consideration: a raw thigh
            // that turns tomorrow is more urgent than a batch that keeps.
            if lhs.isExpiringSoon != rhs.isExpiringSoon { return lhs.isExpiringSoon }
            // Then a prepared batch. Not because it is less work — this layer
            // has no opinion on work — but because it is labour already spent,
            // and it is the only thing in the kitchen whose portions the app can
            // honestly count down.
            let lhsPrepared = isPrepared(lhs), rhsPrepared = isPrepared(rhs)
            if lhsPrepared != rhsPrepared { return lhsPrepared }
            // cooked > prepped > raw, via the shared readiness ordering.
            if lhs.profile.readinessScore != rhs.profile.readinessScore {
                return lhs.profile.readinessScore > rhs.profile.readinessScore
            }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }

    private static func bestVegetable(
        in usable: [QuickMealCandidate],
        excluding taken: Set<QuickMealCandidateSource>
    ) -> QuickMealCandidate? {
        let pool = usable.filter { candidate in
            !taken.contains(candidate.source)
                && candidate.profile.has(.vegetable)
                && !isStandaloneMeal(candidate)
        }
        return pool.min { lhs, rhs in
            if lhs.isExpiringSoon != rhs.isExpiringSoon { return lhs.isExpiringSoon }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }

    /// Whether this candidate's form is one the plate can be built on.
    static func isPlateBase(_ candidate: QuickMealCandidate) -> Bool {
        guard let form = candidate.profile.form else { return false }
        return carbForms.contains(form)
    }

    private static func isPrepared(_ candidate: QuickMealCandidate) -> Bool {
        if case .preparedComponent = candidate.source { return true }
        return false
    }

    /// A packet of dumplings is a whole dinner, not a part of a plate. Same rule
    /// Quick Meal applies, stated here rather than imported so this policy owns
    /// every condition it depends on.
    private static func isStandaloneMeal(_ candidate: QuickMealCandidate) -> Bool {
        candidate.profile.form == .dumpling || candidate.profile.form == .wonton
    }
}

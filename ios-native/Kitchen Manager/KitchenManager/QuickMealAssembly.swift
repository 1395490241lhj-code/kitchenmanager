import Foundation

// MARK: - Quick meal assembly (P0-3C)
//
// A pure function over inventory: given what is in the kitchen right now, which
// fast combinations actually stand up. This is deliberately NOT part of recipe
// recommendation — that layer answers "which dish should I cook", starting from
// the recipe library. This one answers "what can I put together from what I
// have", starting from inventory, and it is allowed to return nothing.
//
// Out of scope on purpose: cooking-time estimates (the app has no per-dish time
// data and will not invent minutes), portions and ingredient scaling, AI, and
// any write to inventory, plans or recipes.

/// One candidate filling one slot of a template.
struct QuickMealComponent: Equatable {
    enum Slot: String {
        case carb
        case protein
        case vegetable
        /// An already-finished dish: 卤牛肉, 剩菜, 熟食.
        case readyMade
        /// The item that is the whole meal by itself — a plate of dumplings is
        /// wrapper and filling at once, so calling it the "carb" would understate it.
        case main
    }

    let slot: Slot
    /// The whole candidate, provenance included — a suggestion can always say
    /// which record each part came from, even though the rules never look.
    let candidate: QuickMealCandidate

    var name: String { candidate.name }
    var profile: QuickFoodProfile { candidate.profile }
    var source: QuickMealCandidateSource { candidate.source }
}

/// The shapes of meal this version can assemble. Each one is a real habit, not
/// a generic "staple + protein + vegetable" rule — a plate of dumplings is a
/// complete dinner and must not be rejected for lacking a vegetable.
enum QuickMealTemplate: String, CaseIterable {
    /// 饺子 / 馄饨，蔬菜可选。
    case dumplingBowl
    /// 现成的熟食 / 卤味 / 剩菜，配一份能马上吃的主食。
    case preparedWithCarb
    /// 已经煮好的米饭 + 蛋白或现成菜。
    case riceBowl
    /// 面 / 粉 + 蛋白和/或蔬菜。
    case noodleBowl
    /// 腌好的蛋白下锅 + 简单主食，蔬菜可选。
    case preppedProteinWithCarb

    var title: String {
        switch self {
        case .dumplingBowl: return "煮饺子 / 馄饨"
        case .preparedWithCarb: return "现成菜配主食"
        case .riceBowl: return "盖饭"
        case .noodleBowl: return "煮面 / 煮粉"
        case .preppedProteinWithCarb: return "腌好的下锅 + 主食"
        }
    }

    /// A fixed order used only to break ties after effort and expiry urgency,
    /// and to pick the plainer name when two templates describe one plate of
    /// food. Never a stand-in for a time estimate.
    var simplicityRank: Int {
        switch self {
        case .dumplingBowl: return 0
        case .preparedWithCarb: return 1
        case .riceBowl: return 2
        case .noodleBowl: return 3
        case .preppedProteinWithCarb: return 4
        }
    }
}

struct QuickMealSuggestion: Equatable {
    let template: QuickMealTemplate
    let components: [QuickMealComponent]

    /// Identity for de-duplication. Keyed by the source rather than a bare UUID
    /// so an inventory item and a prepared batch can never collide.
    var componentSources: Set<QuickMealCandidateSource> { Set(components.map(\.source)) }

    /// Derived from the components that were actually chosen, never from the
    /// template. A template only describes the shape of a meal; whether it is
    /// "just plate it up" depends on what ended up in it — adding a raw leafy
    /// vegetable to cooked rice and cooked beef means there is still a pan or a
    /// pot to deal with, and the tier has to say so.
    var effort: QuickMealEffort {
        let staple = components.first { $0.slot == .carb || $0.slot == .main }
        // A cooked staple is done; dried noodles and a frozen dumpling both mean
        // a pot of water, which is the lightest kind of work there is.
        let potWork = staple.map { $0.profile.preparationState != .cooked } ?? false

        let proteinWork = components.contains { component in
            component.slot == .protein
                && (component.profile.preparationState == .raw || component.profile.preparationState == .prepped)
        }
        let unfinishedVegetable = components.first {
            $0.slot == .vegetable && $0.profile.preparationState != .cooked
        }
        // Template rule, not an accident: greens can go into the pot that is
        // already boiling, or the pan that is already hot. A tuber cannot — it
        // needs its own real cooking.
        let vegetableNeedsItsOwnPan = unfinishedVegetable?.profile.form == .tuber
        let panWork = proteinWork || vegetableNeedsItsOwnPan
        // Greens ride along whenever something is already on the heat, so they
        // only count as work of their own when nothing else is.
        let blanchWork = !panWork && unfinishedVegetable != nil

        if panWork { return potWork ? .standardQuick : .simpleCook }
        if potWork || blanchWork { return .minimalCook }
        return .readyToAssemble
    }
    /// How many components need using up. Both domains answer this through the
    /// same candidate rule, so a prepared batch about to turn is ranked exactly
    /// like a vegetable about to turn.
    var urgencyScore: Int { components.filter(\.candidate.isExpiringSoon).count }

    /// A short, user-facing name. Composed deterministically from the components,
    /// never generated.
    var displayTitle: String { QuickMealTitleBuilder.title(for: self) }
}

/// How much handling a meal takes, as a small ordered ladder rather than a score.
///
/// Deliberately not a sum over components: a three-item plate is not more work
/// than a two-item one just because it has more parts. Deliberately not minutes
/// either — the app has no per-dish time data and will not invent any.
enum QuickMealEffort: Int, Comparable {
    /// Nothing left to cook. 米饭 + 卤牛肉.
    case readyToAssemble = 0
    /// One pot of boiling water and nothing else: 冷冻饺子, or greens blanched
    /// alongside an otherwise finished plate.
    case minimalCook = 1
    /// Something genuinely goes in a pan, but the staple is already done.
    /// 米饭 + 腌鸡肉.
    case simpleCook = 2
    /// The ordinary quick-day bowl: boil the staple *and* cook a topping.
    case standardQuick = 3

    static func < (lhs: QuickMealEffort, rhs: QuickMealEffort) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Why nothing could be assembled. Returned instead of falling back to ordinary
/// recipe recommendation, so a quick day that genuinely has nothing fast in the
/// kitchen says so rather than quietly behaving like any other day.
enum QuickMealGap: Equatable {
    /// Nothing in the kitchen can take part — empty, seasonings only, or names
    /// the classifier could not place.
    case nothingUsable
    /// There is something to eat, but no staple that is quick to put with it.
    case missingCarb
    /// There is a staple, but nothing to go with it.
    case missingProteinOrVegetable
    /// Both sides are present but everything still needs cooking from scratch —
    /// 大米 plus raw 牛肉 is a dinner, just not a quick one.
    case nothingQuickEnough
}

struct QuickMealAssemblyResult: Equatable {
    let suggestions: [QuickMealSuggestion]
    /// Populated only when `suggestions` is empty.
    let gaps: [QuickMealGap]

    static let empty = QuickMealAssemblyResult(suggestions: [], gaps: [.nothingUsable])
}

enum QuickMealAssemblyEngine {
    /// Both domains feed the same pool. Each keeps its own availability rule —
    /// see `QuickMealCandidate.pool` — and neither is ever written to.
    static func assemble(
        inventory: [InventoryItem],
        preparedComponents: [PreparedComponent] = [],
        limit: Int = 3
    ) -> QuickMealAssemblyResult {
        let usable = QuickMealCandidate.pool(
            inventory: inventory,
            preparedComponents: preparedComponents
        )

        guard !usable.isEmpty else {
            return QuickMealAssemblyResult(suggestions: [], gaps: [.nothingUsable])
        }

        let built = QuickMealTemplate.allCases.compactMap { build($0, from: usable) }
        let deduplicated = dedupe(built)
        guard !deduplicated.isEmpty else {
            return QuickMealAssemblyResult(suggestions: [], gaps: [gap(for: usable)])
        }
        return QuickMealAssemblyResult(
            suggestions: Array(ranked(deduplicated).prefix(limit)),
            gaps: []
        )
    }

    // MARK: - Templates

    private typealias Candidate = QuickMealCandidate

    private static func build(_ template: QuickMealTemplate, from usable: [Candidate]) -> QuickMealSuggestion? {
        switch template {
        case .dumplingBowl:
            guard let main = best(usable.filter { $0.profile.form == .dumpling || $0.profile.form == .wonton })
            else { return nil }
            var components = [component(.main, main)]
            if let vegetable = best(vegetables(in: usable, excluding: [main.source])) {
                components.append(component(.vegetable, vegetable))
            }
            return QuickMealSuggestion(template: template, components: components)

        case .preparedWithCarb:
            guard let readyMade = best(readyMadeDishes(in: usable)) else { return nil }
            // Meal-base carbs only. A packet of dried noodles is not "现成主食" —
            // pairing it with a cooked dish is a noodle bowl, and `noodleBowl`
            // owns that case, so allowing it here only produced a near-duplicate
            // of the very same plate of food.
            guard let carb = best(mealBaseCarbs(in: usable, excluding: [readyMade.source])) else { return nil }
            return QuickMealSuggestion(
                template: template,
                components: [component(.readyMade, readyMade), component(.carb, carb)]
            )

        case .riceBowl:
            guard let rice = best(usable.filter {
                $0.profile.form == .rice && $0.profile.preparationState == .cooked
            }) else { return nil }
            let excluded: Set<QuickMealCandidateSource> = [rice.source]
            let topping = best(usable.filter {
                !excluded.contains($0.source)
                    && !isStandaloneMeal($0)
                    && ($0.profile.has(.protein) || $0.profile.form == .preparedDish)
            })
            guard let topping else { return nil }
            var components = [component(.carb, rice)]
            components.append(component(topping.profile.has(.protein) ? .protein : .readyMade, topping))
            if let vegetable = best(vegetables(in: usable, excluding: [rice.source, topping.source])) {
                components.append(component(.vegetable, vegetable))
            }
            return QuickMealSuggestion(template: template, components: components)

        case .noodleBowl:
            guard let carb = best(usable.filter {
                $0.profile.form == .noodle || $0.profile.form == .riceNoodle
            }) else { return nil }
            let excluded: Set<QuickMealCandidateSource> = [carb.source]
            // The noodle itself must not satisfy the protein slot — 鸡蛋面 carries
            // a protein role, but a bowl of it is still just noodles.
            let protein = best(proteins(in: usable, excluding: excluded))
            let vegetable = best(vegetables(in: usable, excluding: excluded.union(protein.map { [$0.source] } ?? [])))
            // A finished dish spooned over freshly boiled noodles is still a
            // noodle bowl; this is the case `preparedWithCarb` no longer takes.
            let readyMade = protein == nil
                ? best(readyMadeDishes(in: usable).filter { !excluded.contains($0.source) })
                : nil
            guard protein != nil || vegetable != nil || readyMade != nil else { return nil }
            var components = [component(.carb, carb)]
            if let protein { components.append(component(.protein, protein)) }
            if let readyMade { components.append(component(.readyMade, readyMade)) }
            if let vegetable { components.append(component(.vegetable, vegetable)) }
            return QuickMealSuggestion(template: template, components: components)

        case .preppedProteinWithCarb:
            guard let protein = best(usable.filter {
                $0.profile.has(.protein) && $0.profile.preparationState == .prepped
            }) else { return nil }
            guard let carb = best(mealBaseCarbs(in: usable, excluding: [protein.source])) else { return nil }
            var components = [component(.protein, protein), component(.carb, carb)]
            if let vegetable = best(vegetables(in: usable, excluding: [protein.source, carb.source])) {
                components.append(component(.vegetable, vegetable))
            }
            return QuickMealSuggestion(template: template, components: components)
        }
    }

    // MARK: - Candidate pools

    /// A staple that is *already* a meal base: cooked rice, bread, 馒头, and any
    /// cooked tuber the classifier learns to recognise later. Something that
    /// still has to be boiled is not a base — 大米 and 挂面 are both excluded,
    /// for different reasons that only the preparation axis can tell apart.
    private static func mealBaseCarbs(in usable: [Candidate], excluding excluded: Set<QuickMealCandidateSource>) -> [Candidate] {
        usable.filter { candidate in
            !excluded.contains(candidate.source)
                && candidate.profile.has(.carb)
                && candidate.profile.preparationState == .cooked
                && !isStandaloneMeal(candidate)
        }
    }

    /// A packet of dumplings is a whole dinner, not an ingredient. It fills the
    /// `main` slot of its own template and must never turn up as the topping on
    /// someone else's noodles.
    private static func isStandaloneMeal(_ candidate: Candidate) -> Bool {
        candidate.profile.form == .dumpling || candidate.profile.form == .wonton
    }

    private static func readyMadeDishes(in usable: [Candidate]) -> [Candidate] {
        usable.filter { candidate in
            guard !isStandaloneMeal(candidate) else { return false }
            guard candidate.profile.preparationState == .cooked else { return false }
            // A cooked staple is the carb, not the dish that goes with it.
            return !candidate.profile.has(.carb) || candidate.profile.form == .preparedDish
        }
    }

    private static func proteins(in usable: [Candidate], excluding excluded: Set<QuickMealCandidateSource>) -> [Candidate] {
        usable.filter {
            !excluded.contains($0.source) && $0.profile.has(.protein) && !isStandaloneMeal($0)
        }
    }

    private static func vegetables(in usable: [Candidate], excluding excluded: Set<QuickMealCandidateSource>) -> [Candidate] {
        usable.filter {
            !excluded.contains($0.source) && $0.profile.has(.vegetable) && !isStandaloneMeal($0)
        }
    }

    private static func component(_ slot: QuickMealComponent.Slot, _ candidate: Candidate) -> QuickMealComponent {
        QuickMealComponent(slot: slot, candidate: candidate)
    }

    /// Within one slot: use up what is about to expire first, then whatever is
    /// closest to edible, then name order so the result never depends on the
    /// order inventory happened to arrive in.
    private static func best(_ candidates: [Candidate]) -> Candidate? {
        candidates.min { lhs, rhs in
            if lhs.isExpiringSoon != rhs.isExpiringSoon { return lhs.isExpiringSoon }
            if lhs.profile.readinessScore != rhs.profile.readinessScore {
                return lhs.profile.readinessScore > rhs.profile.readinessScore
            }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - Ranking

    /// Collapses descriptions of the same food. Two passes:
    ///
    /// 1. identical component sets — keep the simpler-named template;
    /// 2. one suggestion's components being a strict subset of another's, with no
    ///    effort advantage — keep the fuller one. This is what stops "卤牛肉 +
    ///    米饭" from riding alongside "米饭 + 卤牛肉 + 青菜"; a leaner option
    ///    survives only when it is genuinely less work.
    private static func dedupe(_ suggestions: [QuickMealSuggestion]) -> [QuickMealSuggestion] {
        var byItems: [Set<QuickMealCandidateSource>: QuickMealSuggestion] = [:]
        for suggestion in suggestions {
            if let existing = byItems[suggestion.componentSources],
               existing.template.simplicityRank <= suggestion.template.simplicityRank {
                continue
            }
            byItems[suggestion.componentSources] = suggestion
        }
        let candidates = Array(byItems.values)
        return candidates.filter { candidate in
            !candidates.contains { other in
                other.componentSources != candidate.componentSources
                    && candidate.componentSources.isSubset(of: other.componentSources)
                    && candidate.effort >= other.effort
            }
        }
    }

    /// Effort first, then what needs using up, then a fixed template order so the
    /// same kitchen always produces the same list.
    private static func ranked(_ suggestions: [QuickMealSuggestion]) -> [QuickMealSuggestion] {
        suggestions.sorted { lhs, rhs in
            if lhs.effort != rhs.effort { return lhs.effort < rhs.effort }
            if lhs.urgencyScore != rhs.urgencyScore { return lhs.urgencyScore > rhs.urgencyScore }
            if lhs.template.simplicityRank != rhs.template.simplicityRank {
                return lhs.template.simplicityRank < rhs.template.simplicityRank
            }
            return lhs.template.rawValue < rhs.template.rawValue
        }
    }

    // MARK: - Gaps

    private static func gap(for usable: [Candidate]) -> QuickMealGap {
        let hasCarb = usable.contains { $0.profile.has(.carb) }
        let hasCompanion = usable.contains {
            $0.profile.has(.protein) || $0.profile.has(.vegetable) || $0.profile.form == .preparedDish
        }
        switch (hasCarb, hasCompanion) {
        case (false, true): return .missingCarb
        case (true, false): return .missingProteinOrVegetable
        case (true, true): return .nothingQuickEnough
        case (false, false): return .nothingUsable
        }
    }
}

// MARK: - Display titles
//
// Composed from the components by fixed rules — no AI, no generation. The point
// is a name a person would actually say out loud ("牛肉青菜面"), not the internal
// template name. When the parts do not compose into something natural, the
// template's own plain title is used rather than forcing an awkward string.

enum QuickMealTitleBuilder {
    /// Longest first, so 已熟 is stripped before 熟. Deliberately no "生": 生菜
    /// and 生姜 are names, not raw versions of 菜 and 姜.
    private static let stateMarkers = ["已熟", "冷冻", "速冻", "新鲜", "熟", "卤", "腌", "剩"]

    /// Only where the stock name and the spoken name genuinely differ.
    private static let spokenNames = [
        "上海青": "青菜",
        "小白菜": "青菜",
        "油麦菜": "青菜",
        "鸡胸肉": "鸡肉",
        "鸡腿肉": "鸡肉"
    ]

    /// Titles longer than this read as a list of stock items rather than a dish.
    private static let maximumComposedLength = 10

    static func title(for suggestion: QuickMealSuggestion) -> String {
        let composed: String?
        switch suggestion.template {
        case .dumplingBowl:
            composed = main(suggestion).map { $0.profile.form == .wonton ? "煮馄饨" : "煮饺子" }

        case .preparedWithCarb:
            composed = pair(suggestion, .readyMade, .carb) { dish, carb in
                "\(spoken(dish))配\(carbNoun(carb))"
            }

        case .riceBowl:
            if let dish = component(suggestion, .readyMade) {
                // A finished dish over rice is 盖饭; naming the vegetable too
                // would turn it into an inventory list.
                composed = "\(spoken(dish))盖饭"
            } else {
                composed = component(suggestion, .carb).map { rice in
                    joined(suggestion, tail: carbNoun(rice))
                }
            }

        case .noodleBowl:
            composed = component(suggestion, .carb).map { carb in
                joined(suggestion, tail: carbNoun(carb))
            }

        case .preppedProteinWithCarb:
            // With a vegetable in the bowl, name all of it — "鸡肉配饭" would hide
            // the greens that are actually part of the meal.
            if component(suggestion, .vegetable) != nil {
                composed = component(suggestion, .carb).map { carb in
                    joined(suggestion, tail: carbNoun(carb))
                }
            } else {
                composed = pair(suggestion, .protein, .carb) { protein, carb in
                    "\(spoken(protein))配\(carbNoun(carb))"
                }
            }
        }

        guard let composed, !composed.isEmpty, composed.count <= maximumComposedLength else {
            return suggestion.template.title
        }
        return composed
    }

    /// protein + vegetable + the staple's noun: 牛肉 + 青菜 + 面.
    private static func joined(_ suggestion: QuickMealSuggestion, tail: String) -> String {
        let toppings = [QuickMealComponent.Slot.protein, .readyMade, .vegetable]
            .compactMap { component(suggestion, $0) }
            .map(spoken)
        return toppings.joined() + tail
    }

    private static func pair(
        _ suggestion: QuickMealSuggestion,
        _ first: QuickMealComponent.Slot,
        _ second: QuickMealComponent.Slot,
        _ build: (QuickMealComponent, QuickMealComponent) -> String
    ) -> String? {
        guard let a = component(suggestion, first), let b = component(suggestion, second) else { return nil }
        return build(a, b)
    }

    private static func component(
        _ suggestion: QuickMealSuggestion,
        _ slot: QuickMealComponent.Slot
    ) -> QuickMealComponent? {
        suggestion.components.first { $0.slot == slot }
    }

    private static func main(_ suggestion: QuickMealSuggestion) -> QuickMealComponent? {
        component(suggestion, .main)
    }

    /// What the staple is called on a menu: 米饭 → 饭, 挂面 → 面, 米粉 stays 米粉.
    private static func carbNoun(_ component: QuickMealComponent) -> String {
        switch component.profile.form {
        case .rice: return "饭"
        case .noodle: return "面"
        case .dumpling: return "饺子"
        case .wonton: return "馄饨"
        case .riceNoodle, .bread, .tuber, .preparedDish, .none: return spoken(component)
        }
    }

    /// The item name as a person would say it: no storage or preparation prefix,
    /// and the common spoken form where it differs. A prepared dish keeps its
    /// name whole — stripping 剩 from 剩菜 would leave "菜".
    private static func spoken(_ component: QuickMealComponent) -> String {
        var name = component.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if component.profile.form != .preparedDish {
            // Never strip down to a single character — 腌菜 must not become 菜.
            for marker in stateMarkers where name.hasPrefix(marker) && name.count > marker.count + 1 {
                name.removeFirst(marker.count)
                break
            }
        }
        return spokenNames[name] ?? name
    }
}

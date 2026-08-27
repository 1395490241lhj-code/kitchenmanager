import SwiftUI

// MARK: - Quick meal on Home (P0-3D)
//
// Presentation only. Everything here reads values the engine already produced;
// no classification, effort or ordering decision is made or overridden at this
// layer, and the engine has no idea Home exists.
//
// Deliberately withheld from the first version: the internal effort tier, any
// minutes, nutrition, AI, cooking mode, adding to today's plan, saving as a
// recipe, and the role/form/preparation vocabulary. What a person needs here is
// "what am I eating tonight", not a model dump.

/// Plain-language copy for the engine's structured gaps. Lives in the view layer
/// so the engine stays free of Home's wording, and never blames the user for
/// what is in their fridge.
extension QuickMealGap {
    var homeMessage: String {
        switch self {
        case .nothingUsable: return "库存里暂时没有适合快手组合的食材"
        case .nothingQuickEnough: return "现有食材更适合正常做饭"
        case .missingCarb: return "有现成的菜，还差一样主食"
        case .missingProteinOrVegetable: return "有主食，还差一样配菜"
        }
    }
}

/// What occupies Home's single recommendation slot today.
///
/// `.cooking` and `.flexible` keep ordinary recipe recommendation, which nothing
/// here touches. `.quick` and `.mealPrep` each swap the slot for the thing that
/// day is actually about — Home never shows two of these at once, and no day
/// gains a second permanent section.
///
/// Component Meal is deliberately absent: it is a meal *structure*, not a day
/// rhythm, so it lives behind an entry point on the prepared-components page
/// rather than on any DayType.
enum HomeRecommendationSlot: Equatable {
    case recipeRecommendation
    case quickMeal
    case mealPrepBoard

    static func slot(for dayType: DayType) -> HomeRecommendationSlot {
        switch dayType {
        case .quick: return .quickMeal
        case .mealPrep: return .mealPrepBoard
        case .cooking, .flexible: return .recipeRecommendation
        }
    }
}

/// Everything Home needs to draw the quick slot, decided in one pure place so
/// the rules are testable without a running view.
enum QuickMealHomeContent: Equatable {
    case suggestion(QuickMealSuggestion, canRotate: Bool, preparedUsages: [PreparedPortionUsage])
    /// Dinner is being eaten out. The suggestion is hidden, never deleted.
    case eatingOut
    /// Nothing stands up; the text is the engine's gap in plain language. Home
    /// never quietly falls back to recipe recommendation here.
    case unavailable(String)

    static func resolve(
        result: QuickMealAssemblyResult,
        isEatingOutTonight: Bool,
        storedIndex: Int,
        preparedComponents: [PreparedComponent] = []
    ) -> QuickMealHomeContent {
        // Checked before the suggestions: an evening that is already settled does
        // not need a proposal, and the assembly data stays untouched underneath.
        if isEatingOutTonight { return .eatingOut }
        let index = QuickMealRotation.visibleIndex(stored: storedIndex, count: result.suggestions.count)
        guard result.suggestions.indices.contains(index) else {
            return .unavailable(result.gaps.first?.homeMessage ?? QuickMealGap.nothingUsable.homeMessage)
        }
        let suggestion = result.suggestions[index]
        return .suggestion(
            suggestion,
            canRotate: result.suggestions.count > 1,
            preparedUsages: preparedUsages(in: suggestion, among: preparedComponents)
        )
    }

    /// One entry per prepared batch the suggestion uses, in the order its
    /// components appear. The matching rule itself is shared with Component
    /// Meal — see `PreparedPortionUsage.resolve`.
    static func preparedUsages(
        in suggestion: QuickMealSuggestion,
        among preparedComponents: [PreparedComponent]
    ) -> [PreparedPortionUsage] {
        PreparedPortionUsage.resolve(
            sources: suggestion.components.map(\.source),
            among: preparedComponents
        )
    }
}

/// Which suggestion Home is currently showing.
///
/// Home keeps the raw index in ordinary view state, so it survives a body
/// refresh and a sheet, and is gone after a relaunch — a quick day starting back
/// at the easiest option is the right default anyway. Clamping happens on read
/// rather than by writing back, so nothing is published from inside `body` when
/// the inventory changes underneath a stale index.
enum QuickMealRotation {
    /// The index actually safe to show for `count` suggestions.
    static func visibleIndex(stored: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        guard stored >= 0 else { return 0 }
        return min(stored, count - 1)
    }

    /// The next index, wrapping around. Rotating past the end returns to the
    /// easiest suggestion rather than dead-ending.
    static func nextIndex(stored: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (visibleIndex(stored: stored, count: count) + 1) % count
    }
}

/// Home's quick-day content.
///
/// Home V2: the title moved out. `HomePrimaryHeader` says 今天怎么吃, and this
/// renders only when the quick meal *is* the primary task, so the section no
/// longer carries a `.title3` heading competing with the plan and the inventory
/// summary. Nothing about assembly, ranking, rotation, the three-suggestion
/// limit or prepared-portion usage changed.
///
/// Takes plain values rather than reading stores, so previews render it without
/// an environment object.
struct HomeQuickMealSection: View {
    let content: QuickMealHomeContent
    let onRotate: () -> Void
    /// Called with the batch's own id, so the store decrements exactly the
    /// record the user tapped — never one that merely shares a name.
    var onUsePreparedPortion: (UUID) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch content {
            case .eatingOut:
                // Unreachable from Home V2 — `HomePrimaryTask` resolves an
                // eat-out dinner before the quick slot is ever built. Kept
                // because the content type is shared and must stay total.
                statusRow("今晚已安排外食", identifier: "home.quickMeal.eatOut")
            case .suggestion(let suggestion, let canRotate, let preparedUsages):
                suggestionCard(suggestion, canRotate: canRotate, preparedUsages: preparedUsages)
            case .unavailable(let message):
                statusRow(message, identifier: "home.quickMeal.empty")
            }
        }
    }

    /// Lighter than the recipe card on purpose: a title, one line of components,
    /// and one secondary action. No image, no primary button, no metadata row.
    private func suggestionCard(
        _ suggestion: QuickMealSuggestion,
        canRotate: Bool,
        preparedUsages: [PreparedPortionUsage]
    ) -> some View {
        let components = suggestion.components.map(\.name).joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 8) {
            Text(suggestion.displayTitle)
                .font(.headline)
                .accessibilityIdentifier("home.quickMeal.title")
            // One plain line rather than a chip per item: these are things the
            // reader already owns, not filters to tap.
            Text(components)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("home.quickMeal.components")

            // One row per batch, each with its own button. Deliberately not a
            // single "finish this meal" action: using a portion changes only
            // that batch, and says nothing about the rice or the greens.
            ForEach(preparedUsages) { usage in
                PreparedPortionUsageRow(
                    usage: usage,
                    identifierPrefix: "home.quickMeal",
                    onUse: onUsePreparedPortion
                )
            }

            if canRotate {
                Button(action: onRotate) {
                    Text("换一个")
                        .font(.subheadline.weight(.medium))
                        .frame(minHeight: AppTheme.minimumHitTarget)
                        .contentShape(Rectangle())
                }
                    .foregroundStyle(AppTheme.brand)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.quickMeal.rotate")
                    .accessibilityHint("换一个今晚的快手组合")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous)
        )
        // Read as one thing — "牛肉青菜面，挂面 · 卤牛肉 · 上海青" — with the
        // rotate button still reachable as its own element.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(suggestion.displayTitle)，\(components)")
    }

    private func statusRow(_ message: String, identifier: String) -> some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: AppTheme.minimumHitTarget, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous)
            )
            .accessibilityIdentifier(identifier)
    }
}

// MARK: - Previews

private func previewItem(_ name: String) -> InventoryItem {
    InventoryItem(name: name, quantity: 1, unit: "份", expiryDate: nil, createdAt: Date())
}

@MainActor
private func previewContent(
    _ names: [String],
    prepared: [PreparedComponent] = [],
    index: Int = 0
) -> QuickMealHomeContent {
    QuickMealHomeContent.resolve(
        result: QuickMealAssemblyEngine.assemble(
            inventory: names.map(previewItem),
            preparedComponents: prepared
        ),
        isEatingOutTonight: false,
        storedIndex: index,
        preparedComponents: prepared
    )
}

@MainActor
private func previewBatch(_ name: String, _ portions: Int) -> PreparedComponent {
    PreparedComponent(
        name: name, portionsRemaining: portions, state: .cooked, storage: .refrigerated,
        preparedAt: Date(), expiryDate: Calendar.current.date(byAdding: .day, value: 3, to: Date())!
    )
}

#Preview("快手 — 一条建议") {
    HomeQuickMealSection(content: previewContent(["挂面", "卤牛肉", "上海青"]), onRotate: {})
        .padding()
        .background(Color(.systemGroupedBackground))
}

#Preview("快手 — 可换一个") {
    HomeQuickMealSection(content: previewContent(["米饭", "卤牛肉", "上海青"]), onRotate: {})
        .padding()
        .background(Color(.systemGroupedBackground))
}

#Preview("快手 — 用到备餐") {
    HomeQuickMealSection(
        content: previewContent(["米饭", "上海青"], prepared: [previewBatch("卤牛肉", 3)]),
        onRotate: {},
        onUsePreparedPortion: { _ in }
    )
    .padding()
    .background(Color(.systemGroupedBackground))
}

#Preview("快手 — 两个备餐") {
    HomeQuickMealSection(
        content: previewContent(
            ["米饭"],
            prepared: [previewBatch("卤牛肉", 3), previewBatch("卤鸡腿", 1)]
        ),
        onRotate: {},
        onUsePreparedPortion: { _ in }
    )
    .padding()
    .background(Color(.systemGroupedBackground))
}

#Preview("快手 — 今晚外食") {
    HomeQuickMealSection(content: .eatingOut, onRotate: {})
        .padding()
        .background(Color(.systemGroupedBackground))
}

#Preview("快手 — 没有合适组合") {
    HomeQuickMealSection(content: .unavailable(QuickMealGap.nothingQuickEnough.homeMessage), onRotate: {})
        .padding()
        .background(Color(.systemGroupedBackground))
}

#Preview("快手 — 深色") {
    HomeQuickMealSection(content: previewContent(["米粉", "鸡蛋", "生菜"]), onRotate: {})
        .padding()
        .background(Color(.systemGroupedBackground))
        .preferredColorScheme(.dark)
}

#Preview("快手 — 大字号") {
    HomeQuickMealSection(content: previewContent(["米饭", "卤牛肉", "上海青"]), onRotate: {})
        .padding()
        .background(Color(.systemGroupedBackground))
        .dynamicTypeSize(.accessibility3)
}

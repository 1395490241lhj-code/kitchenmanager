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
/// Only `.quick` swaps it. `.cooking`, `.flexible` and — for this version —
/// `.mealPrep` all keep ordinary recipe recommendation, which nothing here
/// touches. Home never shows both at once.
enum HomeRecommendationSlot: Equatable {
    case recipeRecommendation
    case quickMeal

    static func slot(for dayType: DayType) -> HomeRecommendationSlot {
        switch dayType {
        case .quick: return .quickMeal
        case .cooking, .flexible, .mealPrep: return .recipeRecommendation
        }
    }
}

/// A prepared batch this suggestion is using, and how much of it is left.
///
/// Resolved by looking the provenance id up in the live batches rather than by
/// carrying portion counts through the engine — that is exactly what keeping
/// `QuickMealCandidateSource` on every component was for, and it keeps the
/// candidate free of one domain's fields.
struct QuickMealPreparedUsage: Equatable, Identifiable {
    let id: UUID
    let name: String
    let portionsRemaining: Int

    var remainingText: String { "备餐剩 \(portionsRemaining) 份" }
}

/// Everything Home needs to draw the quick slot, decided in one pure place so
/// the rules are testable without a running view.
enum QuickMealHomeContent: Equatable {
    case suggestion(QuickMealSuggestion, canRotate: Bool, preparedUsages: [QuickMealPreparedUsage])
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
    /// components appear. Inventory components get none — a bag of rice has no
    /// provenance worth naming.
    static func preparedUsages(
        in suggestion: QuickMealSuggestion,
        among preparedComponents: [PreparedComponent]
    ) -> [QuickMealPreparedUsage] {
        var seen = Set<UUID>()
        return suggestion.components.compactMap { component in
            guard case .preparedComponent(let id) = component.source,
                  seen.insert(id).inserted,
                  // Matched by id, never by name: two batches can share a name.
                  let batch = preparedComponents.first(where: { $0.id == id })
            else { return nil }
            return QuickMealPreparedUsage(
                id: batch.id,
                name: batch.name,
                portionsRemaining: batch.portionsRemaining
            )
        }
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

/// Home's quick-day surface. It stands in the recommendation slot rather than
/// adding a section, so the page keeps its 今日计划 → 推荐位 → 库存待处理 shape.
///
/// Takes plain values rather than reading stores, so previews render it without
/// an environment object — the same arrangement `HomeDayRhythmRow` uses.
struct HomeQuickMealSection: View {
    let content: QuickMealHomeContent
    let onRotate: () -> Void
    /// Called with the batch's own id, so the store decrements exactly the
    /// record the user tapped — never one that merely shares a name.
    var onUsePreparedPortion: (UUID) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("今晚快手吃")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("home.quickMeal.section")

            switch content {
            case .eatingOut:
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
        preparedUsages: [QuickMealPreparedUsage]
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
                preparedUsageRow(usage)
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

    private func preparedUsageRow(_ usage: QuickMealPreparedUsage) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                preparedUsageLabel(usage)
                Spacer(minLength: 8)
                preparedUsageButton(usage)
            }
            VStack(alignment: .leading, spacing: 4) {
                preparedUsageLabel(usage)
                preparedUsageButton(usage)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func preparedUsageLabel(_ usage: QuickMealPreparedUsage) -> some View {
        Text("\(usage.name) · \(usage.remainingText)")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("home.quickMeal.prepared.\(usage.id.uuidString)")
    }

    private func preparedUsageButton(_ usage: QuickMealPreparedUsage) -> some View {
        // The height has to be inside the label: a `.frame` applied to the
        // Button itself leaves the hit target — and the accessibility frame —
        // the size of the text, which measured 18pt. Same shape as
        // `HomeDayRhythmRow`.
        Button {
            onUsePreparedPortion(usage.id)
        } label: {
            Text("使用 1 份")
                .font(.subheadline.weight(.medium))
                .frame(minHeight: AppTheme.minimumHitTarget)
                .contentShape(Rectangle())
        }
            .foregroundStyle(AppTheme.brand)
            .buttonStyle(.plain)
            // Names the batch so it is unambiguous when a meal uses two.
            .accessibilityLabel("使用 1 份\(usage.name)")
            .accessibilityHint("\(usage.remainingText)")
            .accessibilityIdentifier("home.quickMeal.usePrepared.\(usage.id.uuidString)")
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

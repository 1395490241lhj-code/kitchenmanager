import SwiftUI

// MARK: - Component meal sheet (P1-F)
//
// Reached from the prepared-components page, never from Home: a component meal
// is a meal structure, not a day rhythm, so it does not take a slot from any
// DayType and does not add a permanent Home section.
//
// Presentation only. Every decision was made by `ComponentMealPolicy`; nothing
// is re-ranked or re-worded here, and no claim is made about nutrition.

extension ComponentMealGap {
    /// Plain, short, and never blaming the fridge's owner.
    var sheetMessage: String {
        switch self {
        case .nothingUsable: return "库存里暂时没有可以搭配的食材"
        case .missingCarb: return "差一样主食"
        case .missingProtein: return "差一样蛋白"
        case .missingVegetable: return "差一样蔬菜"
        }
    }
}

struct ComponentMealView: View {
    @EnvironmentObject private var store: KitchenStore
    @Environment(\.dismiss) private var dismiss
    @State private var toastMessage: String?

    private var result: ComponentMealResult {
        ComponentMealPolicy.assemble(
            inventory: store.inventory,
            preparedComponents: store.preparedComponents
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let suggestion = result.suggestion {
                        card(suggestion)
                    } else {
                        gapCard(result.gaps)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("搭配一顿")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("componentMeal.done")
                }
            }
            .overlay(alignment: .bottom) {
                if let toastMessage {
                    FeedbackToast(message: toastMessage, style: .success)
                }
            }
        }
    }

    private func card(_ suggestion: ComponentMealSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("今天可以这样配")
                .font(.headline)
                .accessibilityIdentifier("componentMeal.title")

            // One plain line, in slot order. No slot labels: "主食/蛋白/蔬菜"
            // is the model's vocabulary, and the plate reads fine without it.
            Text(suggestion.componentsText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("componentMeal.components")

            // Only prepared batches get a row. An inventory staple or vegetable
            // has no portion model behind it, so this sheet never offers to
            // "use" one and never touches inventory quantities.
            ForEach(preparedUsages(for: suggestion)) { usage in
                PreparedPortionUsageRow(
                    usage: usage,
                    identifierPrefix: "componentMeal",
                    onUse: usePreparedPortion
                )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("今天可以这样配，\(suggestion.componentsText)")
    }

    private func gapCard(_ gaps: [ComponentMealGap]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(gaps.enumerated()), id: \.offset) { _, gap in
                Text(gap.sheetMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: AppTheme.minimumHitTarget, alignment: .leading)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous)
        )
        .accessibilityIdentifier("componentMeal.empty")
    }

    private func preparedUsages(for suggestion: ComponentMealSuggestion) -> [PreparedPortionUsage] {
        PreparedPortionUsage.resolve(
            sources: suggestion.componentSources,
            among: store.preparedComponents
        )
    }

    /// The same single store API Home uses. `preparedComponents` is published,
    /// so `result` recomputes on its own — the plate is never patched by hand,
    /// and if the batch is gone the sheet falls to the gap wording.
    private func usePreparedPortion(_ id: UUID) {
        guard let previous = store.consumePreparedPortion(id: id) else { return }
        showToast(
            previous.portionsRemaining > 1
                ? "已使用 1 份\(previous.name)，还剩 \(previous.portionsRemaining - 1) 份"
                : "\(previous.name)已用完"
        )
    }

    private func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if toastMessage == message { toastMessage = nil }
        }
    }
}

#Preview("搭配一顿") {
    ComponentMealView()
        .environmentObject(KitchenStore())
}

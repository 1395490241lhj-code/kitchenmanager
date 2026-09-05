import SwiftUI

/// Home's meal hero: the dish, when it is eaten, and whether its ingredients
/// are ready — read as one composition rather than as stacked components.
///
/// There is no photo here. `Recipe` has no persistent media of any kind today,
/// so a photographic hero has nothing to draw; the typography-led treatment is
/// the canonical production hero, not a fallback for a missing asset. When a
/// recipe media model genuinely exists, an image layer can be added behind
/// this same status line without changing its grammar.
struct HomeMealHero: View {
    /// The dish this evening is built around.
    let title: String
    /// Everything else on the menu, already excluding `title`.
    let sideDishes: [String]
    /// `18:30 开饭` / `18:30 以后` — supplied, never invented here.
    let timing: String?
    /// Total cooking time, when the recipes state one.
    let duration: String?
    /// Dishes actually on the menu. Counted by the caller from real contents.
    let dishCount: Int
    /// Ingredient readiness, when the caller can state it honestly.
    let readiness: HomeMealReadiness?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var isAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {


            // Semantic title sizing preserves Dynamic Type reflow.
            Text(title)
                .font(.system(
                    isAccessibilitySize ? .title : .largeTitle,
                    design: KitchenTheme.heroFontDesign,
                    weight: .semibold
                ))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("home.hero.title")

            if let composition {
                Text(composition)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                    .accessibilityIdentifier("home.hero.composition")
            }

            if metaLine != nil || readiness != nil {
                Rectangle()
                    .fill(.quaternary)
                    .frame(height: 1)
                    .padding(.top, 12)
                    .padding(.bottom, 10)

                statusLine
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composition: String? {
        guard !sideDishes.isEmpty else { return nil }
        return "配" + sideDishes.joined(separator: "、")
    }

    /// `18:30 开饭 · 45 分钟 · 2 道菜`, with every absent part simply omitted
    /// rather than filled with a placeholder.
    private var metaLine: String? {
        var parts: [String] = []
        if let timing { parts.append(timing) }
        if let duration { parts.append(duration) }
        if dishCount > 0 { parts.append("\(dishCount) 道菜") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var statusLine: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let metaLine {
                KitchenMetadataText(text: metaLine)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dynamicTypeSize(...ChromeMetrics.summaryTypeLimit)
            }
            if let readiness, readiness.total > 0 {
                KitchenReadinessChip(readiness: readiness)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(statusAccessibilityLabel)
        .accessibilityIdentifier("home.hero.status")
    }

    private var statusAccessibilityLabel: String {
        [metaLine, readiness?.summary].compactMap { $0 }.joined(separator: "，")
    }
}

/// How much of tonight's shopping is already in the kitchen.
///
/// `nonisolated` for the same reason the other Home value types are: it carries
/// no reference state and has to be constructible from nonisolated test code.
nonisolated struct HomeMealReadiness: Equatable {
    let ready: Int
    let total: Int

    var fraction: CGFloat {
        guard total > 0 else { return 0 }
        return CGFloat(ready) / CGFloat(total)
    }

    var summary: String {
        guard total > 0 else { return "无需备料" }
        if ready >= total { return "食材齐全" }
        return "\(ready)/\(total) 食材就绪"
    }
}

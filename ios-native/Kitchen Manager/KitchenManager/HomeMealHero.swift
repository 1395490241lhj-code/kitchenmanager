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
            // Semantic style, not a fixed point size: the exploration's 44pt was
            // evidence about proportion on one device, never an API.
            Text(title)
                .font(.system(isAccessibilitySize ? .title : .largeTitle, design: .serif, weight: .semibold))
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
                    .padding(.top, 16)
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

    @ViewBuilder
    private var statusLine: some View {
        VStack(alignment: .leading, spacing: 7) {
            Group {
                if isAccessibilitySize {
                    // Deliberately two lines: one wrapping line collides the
                    // timing with the readiness count and reads as a mistake.
                    VStack(alignment: .leading, spacing: 4) {
                        metaText
                        readinessText
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        metaText
                        Spacer(minLength: 8)
                        readinessText
                    }
                }
            }
            .font(.footnote.weight(.medium))
            .frame(maxWidth: .infinity, alignment: .leading)
            .dynamicTypeSize(...ChromeMetrics.summaryTypeLimit)

            readinessRule
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(statusAccessibilityLabel)
        .accessibilityIdentifier("home.hero.status")
    }

    @ViewBuilder
    private var metaText: some View {
        if let metaLine {
            Text(metaLine).monospacedDigit()
        }
    }

    @ViewBuilder
    private var readinessText: some View {
        if let readiness {
            Text(readiness.summary)
                .monospacedDigit()
                .foregroundStyle(AppTheme.cookingAccentForeground)
        }
    }

    /// A hairline, not a progress bar. Signature width so it reads as a mark on
    /// the page rather than as a meter to be filled.
    @ViewBuilder
    private var readinessRule: some View {
        if let readiness, readiness.total > 0 {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(AppTheme.cookingAccentForeground)
                        .opacity(0.75)
                        .frame(width: max(proxy.size.width * readiness.fraction, readiness.ready > 0 ? 6 : 0))
                }
            }
            .frame(height: 2)
            .frame(maxWidth: 190, alignment: .leading)
            .accessibilityHidden(true)
        }
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

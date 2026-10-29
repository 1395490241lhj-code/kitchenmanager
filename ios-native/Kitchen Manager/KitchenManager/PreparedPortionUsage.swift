import SwiftUI

extension View {
    /// Each entry point owns its error, including a sheet above another sheet.
    /// A shared native alert keeps failure feedback consistent without turning
    /// the store's persistent notice into a global success/error event stream.
    func preparedFailureAlert(_ error: Binding<PreparedComponentMutationError?>) -> some View {
        alert("备餐操作未完成", isPresented: Binding(
            get: { error.wrappedValue != nil },
            set: { if !$0 { error.wrappedValue = nil } }
        )) {
            Button("好", role: .cancel) { error.wrappedValue = nil }
        } message: {
            Text(error.wrappedValue?.localizedDescription ?? "请稍后重试。")
        }
    }
}

// MARK: - Taking one portion off a prepared batch (P1-F)
//
// P1-D built this on Home's quick card. Component Meal needs exactly the same
// affordance, so it moved here rather than being written a second time — the
// row carries a hit-target rule that is easy to get wrong (see the button
// below), and a copy would have re-derived that mistake.
//
// Presentation and a value type only. The single decrement lives in
// `KitchenStore.consumePreparedPortion(id:)` and nothing here duplicates it.

/// A prepared batch a suggestion is using, and how much of it is left.
///
/// Resolved by looking the provenance id up in the live batches rather than by
/// carrying portion counts through an assembling layer — that is exactly what
/// keeping `QuickMealCandidateSource` on every component was for, and it keeps
/// the candidate free of one domain's fields.
struct PreparedPortionUsage: Equatable, Identifiable {
    let expected: PreparedComponent
    var id: UUID { expected.id }
    var name: String { expected.name }
    var portionsRemaining: Int { expected.portionsRemaining }

    var detailText: String? = nil
    var spokenDetail: String? = nil
    var remainingText: String { "备餐剩 \(portionsRemaining) 份" }
    var buttonLabel: String {
        "使用 1 份\(name)" + (spokenDetail.map { "，" + $0 } ?? "")
    }
}

extension PreparedPortionUsage {
    /// One entry per prepared batch among these component sources, in order.
    /// Inventory sources get none — a bag of rice has no provenance worth
    /// naming, and nothing in the app can honestly decrement it.
    ///
    /// A source whose batch is no longer around is dropped rather than shown:
    /// resolving against a stale suggestion must never produce a button that
    /// points at a record that does not exist.
    static func resolve(
        sources: [QuickMealCandidateSource],
        among preparedComponents: [PreparedComponent]
    ) -> [PreparedPortionUsage] {
        // A corrupt collection must not manufacture consumable usage actions.
        guard let sections = try? PreparedSourceSection.make(preparedComponents) else { return [] }
        let sectionsByGroup = Dictionary(uniqueKeysWithValues: sections.flatMap { section in
            section.components.map { ($0.id, section) }
        })
        var seen = Set<UUID>()
        return sources.compactMap { source in
            guard case .preparedComponent(let id) = source,
                  seen.insert(id).inserted,
                  // Matched by id, never by name: two batches can share a name.
                  let batch = preparedComponents.first(where: { $0.id == id }),
                  PreparedMealAvailability.isEligible(batch)
            else { return nil }
            var usage = PreparedPortionUsage(expected: batch)
            if let grouping = batch.grouping, let section = sectionsByGroup[batch.id] {
                let group = section.groupLabel(for: batch)
                usage.detailText = "\(group) · 每份\(PreparedMassInput.grams(grouping.massPerPortionDecigrams)) · \(batch.state.title) · \(batch.storage.title)"
                usage.spokenDetail = "\(group.replacingOccurrences(of: " · ", with: "，"))，每份\(PreparedMassInput.spoken(grouping.massPerPortionDecigrams))，\(batch.state.title)，\(batch.storage.title)"
            }
            return usage
        }
    }
}

/// The one row that offers a portion of a batch. Quick Meal and Component Meal
/// both use it; neither owns it.
///
/// `identifierPrefix` namespaces the accessibility identifiers so the two
/// surfaces stay separately addressable in UI tests — Home's quick card keeps
/// the identifiers it has had since P1-D.
struct PreparedPortionUsageRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let usage: PreparedPortionUsage
    let identifierPrefix: String
    let onUse: (PreparedComponent) -> Void

    var body: some View {
        Group {
            if usage.detailText != nil && dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { label; button }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { label; Spacer(minLength: 8); button }
                    VStack(alignment: .leading, spacing: 8) { label; button }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
    @ViewBuilder private var label: some View {
        if let detail = usage.detailText {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(usage.name) · \(usage.remainingText)").font(.footnote)
                Text(detail).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(usage.name)，\(usage.remainingText)，\(usage.spokenDetail ?? detail)")
            .accessibilityIdentifier("\(identifierPrefix).prepared.\(usage.id.uuidString)")
        } else {
            Text("\(usage.name) · \(usage.remainingText)")
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("\(identifierPrefix).prepared.\(usage.id.uuidString)")
        }
    }

    private var button: some View {
        // The height has to be inside the label: a `.frame` applied to the
        // Button itself leaves the hit target — and the accessibility frame —
        // the size of the text, which measured 18pt. Same shape as
        // `HomeDayRhythmRow`.
        Button {
            onUse(usage.expected)
        } label: {
            Text("使用 1 份")
                .font(.subheadline.weight(.medium))
                .frame(minHeight: AppTheme.minimumHitTarget)
                .contentShape(Rectangle())
        }
            .foregroundStyle(AppTheme.brand)
            .buttonStyle(.plain)
            // Names the batch so it is unambiguous when a meal uses two.
            .accessibilityLabel(usage.buttonLabel)
            .accessibilityHint("\(usage.remainingText)")
            .accessibilityIdentifier("\(identifierPrefix).usePrepared.\(usage.id.uuidString)")
    }
}

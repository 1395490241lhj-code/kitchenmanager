import SwiftUI

/// Inventory's control layer: what is in the kitchen, and the filters that
/// narrow it. One interactive surface above the list.
///
/// The counts were previously a read-only summary line — the same facts, but
/// nothing you could do with them. A number that names a problem should be the
/// way you go and look at it, so each count sets `InventoryFocus`. No new
/// filtering rule is introduced here: `InventoryFocus` already drives the
/// list's own filtering, and these controls only select it.
///
/// Quiet Kitchen R3.1 (research branch): the counts and the segmented filter
/// now share one compact surface instead of a summary card above a picker.
/// Counts render as small inline text (label first, count after) so the zone
/// reads as one filter control, not a dashboard. Behaviour, identifiers and
/// accessibility labels are unchanged.
struct InventoryControlStrip: View {
    let totalCount: Int
    let expiringCount: Int
    let lowStockCount: Int
    @Binding var focus: InventoryFocus

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ViewBuilder var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    accessibilityCounts
                } else {
                    counts
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            filterControl
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            KitchenTheme.filterSurface,
            in: .rect(cornerRadius: 14, style: .continuous)
        )
    }

    private var counts: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            ForEach(countItems, id: \.focus) { item in
                inlineCountButton(item)
            }
            Spacer(minLength: 0)
        }
    }

    private var accessibilityCounts: some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(countItems, id: \.focus) { item in
                inlineCountButton(item)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private struct CountItem {
        let focus: InventoryFocus
        let value: Int
        let label: String
        let tint: Color

        var identifier: String {
            switch focus {
            case .all: "inventory.summary.all"
            case .expiringSoon: "inventory.summary.expiringSoon"
            case .lowStock: "inventory.summary.lowStock"
            case .expired: "inventory.summary.expired"
            }
        }

        var accessibilityLabel: String {
            "\(value) 项\(label)"
        }

        var compactLabel: String {
            switch focus {
            case .all: "在库"
            case .expiringSoon: "临期"
            case .lowStock: "补货"
            case .expired: "过期"
            }
        }
    }

    /// Only counts that describe something real. A zero 需要补货 is not a
    /// filter worth offering, and a strip of zeroes reads as a dashboard.
    private var countItems: [CountItem] {
        var items = [CountItem(
            focus: .all,
            value: totalCount,
            label: "在库",
            tint: KitchenTheme.statusNeutral
        )]
        if expiringCount > 0 {
            items.append(.init(
                focus: .expiringSoon,
                value: expiringCount,
                label: "即将到期",
                tint: KitchenTheme.statusTerracotta
            ))
        }
        if lowStockCount > 0 {
            items.append(.init(
                focus: .lowStock,
                value: lowStockCount,
                label: "需要补货",
                tint: KitchenTheme.statusOchre
            ))
        }
        return items
    }

    private func inlineCountButton(_ item: CountItem) -> some View {
        Button {
            focus = item.focus
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                labelText(item)
                countText(item)
            }
            .frame(minHeight: KitchenTheme.controlHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(KitchenPressFeedbackStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityHint("筛选食材")
        .accessibilityAddTraits(focus == item.focus ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(item.identifier)
    }

    private func countText(_ item: CountItem) -> some View {
        Text("\(item.value)")
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(item.tint)
    }

    private func labelText(_ item: CountItem) -> some View {
        Text(item.compactLabel)
            .font(.footnote)
            .foregroundStyle(Color.secondary)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var filterControl: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Menu {
                ForEach(InventoryFocus.filterOrder, id: \.self) { option in
                    Button {
                        focus = option
                    } label: {
                        if focus == option {
                            Label(option.shortTitle, systemImage: "checkmark")
                        } else {
                            Text(option.shortTitle)
                        }
                    }
                }
            } label: {
                Text("筛选：\(focus.shortTitle)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(KitchenTheme.managementBlue)
                    .frame(maxWidth: .infinity, minHeight: AppTheme.minimumHitTarget, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("筛选")
            .accessibilityValue(focus.shortTitle)
            .accessibilityIdentifier("inventory.filter.menu")
        } else {
            Picker("筛选食材", selection: $focus) {
                ForEach(InventoryFocus.filterOrder, id: \.self) { option in
                    Text(option.shortTitle).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("inventory.filter.picker")
        }
    }
}

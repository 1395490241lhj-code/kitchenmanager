import SwiftUI

/// Inventory's control layer: one surface that says what the list is currently
/// showing and lets the user change or clear it.
///
/// P-3 of the behavior-contract prototype collapses what used to be two rows —
/// a read-only count line above a segmented picker — into a single filter
/// control. The counts were never a separate fact; they describe the choices,
/// so they now live on the choices. Two rows of the same information read as a
/// dashboard, and Inventory is a list.
///
/// The native segmented control is itself the filter surface: the padded grey
/// container that used to wrap it added a second, purely visual layer.
///
/// The other half of the change is that this surface no longer disappears while
/// the user is searching. `InventoryFocus` kept filtering during search but
/// stopped being visible, so a query that returned nothing blamed itself for a
/// filter the user could not see.
struct InventoryControlStrip: View {
    /// How many rows each filter would produce, supplied by the list itself so
    /// a segment's number and the rows beneath it can never disagree.
    let counts: [InventoryFocus: Int]
    @Binding var focus: InventoryFocus
    /// True while a search query narrows the list further. The filter is shown
    /// either way; this only adds the second, independent exit.
    var isSearching = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isConstrained: Bool { focus != .all }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if dynamicTypeSize.isAccessibilitySize {
                compactDisclosure
            } else {
                segmentedFilter
            }
            if isSearching && isConstrained {
                clearFilterButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func count(_ option: InventoryFocus) -> Int { counts[option] ?? 0 }

    /// `全部 24`, `临期 2`, and a bare `已过期` when nothing is expired. A zero is
    /// not a useful number to carry, but the choice still has to be offerable —
    /// dropping the segment entirely would move the control under the user's
    /// finger every time the kitchen changed.
    private func label(_ option: InventoryFocus) -> String {
        let value = count(option)
        guard option == .all || value > 0 else { return option.shortTitle }
        return "\(option.shortTitle) \(value)"
    }

    private func accessibilityLabel(_ option: InventoryFocus) -> String {
        // Mirrors the visible label rather than adding to it. A segment that
        // shows no number must not announce "0 项": the count is suppressed
        // because zero is not useful, and VoiceOver hearing it anyway would be
        // the visible and spoken layers disagreeing about the same control.
        let value = count(option)
        guard option == .all || value > 0 else { return option.shortTitle }
        return "\(option.shortTitle)，\(value) 项"
    }

    private var segmentedFilter: some View {
        Picker("筛选食材", selection: $focus) {
            ForEach(InventoryFocus.filterOrder, id: \.self) { option in
                Text(label(option))
                    .accessibilityLabel(accessibilityLabel(option))
                    .accessibilityIdentifier(option.segmentIdentifier)
                    .tag(option)
            }
        }
        .pickerStyle(.segmented)
        // Bounded exception to Kitchen Manager's 44pt target: this stock
        // four-choice Picker exposes 32pt segments. A 44pt wrapper did not
        // receive taps 3pt above/below them (iPhone 17 Pro runtime probe).
        // Keep the familiar native selection control; AX sizes use Menu.
        // This is not a blanket HIG-compliance claim or a custom-control waiver.
        // InventoryNavigationUITests documents and checks this exception.
        // Chrome, not content: four Chinese labels carrying digits cannot also
        // scale. The Accessibility fork below is where the full range is served.
        .dynamicTypeSize(...ChromeMetrics.headerTypeLimit)
        .accessibilityIdentifier("inventory.filter.picker")
    }

    /// Accessibility sizes get the constraint as one sentence plus a menu,
    /// rather than four segments compressed past legibility.
    private var compactDisclosure: some View {
        Menu {
            ForEach(InventoryFocus.filterOrder, id: \.self) { option in
                Button {
                    focus = option
                } label: {
                    if focus == option {
                        Label(label(option), systemImage: "checkmark")
                    } else {
                        Text(label(option))
                    }
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(focus.shortTitle) · \(count(focus)) 项")
                    .contentTransition(.opacity)
                    .animation(reduceMotion ? nil : KitchenMotion.quick, value: focus)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(KitchenTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text("更改筛选")
                    .font(.subheadline)
                    .foregroundStyle(KitchenTheme.managementBlue)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: AppTheme.minimumHitTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("筛选")
        .accessibilityValue("\(focus.shortTitle)，\(count(focus)) 项")
        .accessibilityIdentifier("inventory.filter.menu")
    }

    /// Independent of the search field's own clear button. Clearing one
    /// constraint must never clear the other.
    ///
    /// A lightweight text action belonging to the filter above it. It used to
    /// grow a padded container into a card-sized grey block, which made the
    /// control layer compete with the list it describes.
    private var clearFilterButton: some View {
        Button("清除筛选") { focus = .all }
            .font(.subheadline)
            .foregroundStyle(KitchenTheme.managementBlue)
            .frame(minHeight: AppTheme.minimumHitTarget, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityIdentifier("inventory.filter.clear")
    }
}

extension InventoryFocus {
    /// A stable per-segment identifier, so a test can address 临期 without
    /// depending on the count now baked into its visible label.
    var segmentIdentifier: String {
        switch self {
        case .all: "inventory.filter.option.all"
        case .expiringSoon: "inventory.filter.option.expiringSoon"
        case .expired: "inventory.filter.option.expired"
        case .lowStock: "inventory.filter.option.lowStock"
        }
    }
}

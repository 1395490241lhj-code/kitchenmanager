import SwiftUI

/// Shared presentation for the Planner's native lists and supporting copy.
extension View {
    func plannerFootnote() -> some View {
        self.font(.caption).foregroundStyle(KitchenTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8).background(KitchenTheme.canvas)
    }

    func plannerList() -> some View {
        self.listStyle(.plain)
            .listSectionSpacing(0)
            .environment(\.defaultMinListHeaderHeight, 0)
            .scrollContentBackground(.hidden)
            .background(KitchenTheme.canvas)
            .toolbarBackground(KitchenTheme.canvas, for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            .tint(KitchenTheme.cookingGreen)
    }

    func plannerRow() -> some View {
        self.listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: KitchenTheme.rowVerticalInset, leading: KitchenTheme.pageGutter,
                                     bottom: KitchenTheme.rowVerticalInset, trailing: KitchenTheme.pageGutter))
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
    }

    /// Plain-list section headers pin while scrolling, so they sit on an opaque
    /// canvas slab that fully covers the rows passing beneath them.
    func plannerSectionHeader() -> some View {
        self.textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, KitchenTheme.sectionSpacing).padding(.bottom, 8)
            .listRowInsets(EdgeInsets(top: 0, leading: KitchenTheme.pageGutter, bottom: 0, trailing: KitchenTheme.pageGutter))
            .background(KitchenTheme.canvas)
    }

    func plannerSectionTitle() -> some View {
        self.font(.subheadline.weight(.semibold))
            .foregroundStyle(KitchenTheme.textSecondary)
            .plannerSectionHeader()
    }
}

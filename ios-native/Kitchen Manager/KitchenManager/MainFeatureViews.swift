import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Unified presentation limits for shared screen chrome — navigation titles,
/// summaries, section headers, filter bars, toolbar/tab glyphs, and the
/// floating (iOS 26) tab-bar clearance. Content text (food names, quantities,
/// status labels) keeps unrestricted Dynamic Type.
enum ChromeMetrics {
    static let summaryTypeLimit = DynamicTypeSize.accessibility1
    static let headerTypeLimit = DynamicTypeSize.accessibility1
    static let symbolTypeLimit = DynamicTypeSize.xxLarge
    /// Bottom clearance for the expanded floating (iOS 26) tab bar.
    static let bottomClearance: CGFloat = 72
    /// Minimum row height for Settings rows. Matches `AppTheme.minimumHitTarget`.
    static let minimumRowHeight: CGFloat = 44
}

struct InventoryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var store: KitchenStore
    @EnvironmentObject private var recipeStore: RecipeStore
    @EnvironmentObject private var navigationStore: AppNavigationStore
    /// Pushes onto the tab-root NavigationPath directly, rather than relying on
    /// NavigationLink(value:)'s own resolution — a LazyVGrid of many value-linked
    /// cards inside a List Section was reproducibly (via a real XCUITest tap, not
    /// just code review) pushing the wrong/stale item onto the stack. A plain
    /// Button that calls this closure sidesteps that resolution path entirely.
    var onSelectItem: (UUID) -> Void
    @State private var recordMode: FoodInputMode?
    @State private var isShowingAddStaple = false
    @State private var isShowingPreparedComponents = false
    @State private var stapleFilter: PantryStapleFilter = .all
    @State private var itemPendingDeletion: InventoryItem?
    @State private var searchText = ""

    private var restockSuggestions: [RestockSuggestion] {
        RestockSuggestionEngine().generate(kitchenStore: store, recipeStore: recipeStore)
    }

    /// Which of tonight's dishes each stocked food is already spoken for by.
    /// Built once per render rather than per row: every row would otherwise
    /// re-parse every recipe line in today's plan.
    private var tonightSummaries: [String: String] {
        InventoryTonightLinkage.summaries(
            plans: store.todayPlans,
            recipes: { recipeStore.recipe(id: $0) }
        )
    }

    private var focusedFreshInventory: [InventoryItem] {
        switch navigationStore.inventoryFocus {
        case .all:
            store.sortedFreshInventory
        case .expired:
            store.sortedFreshInventory.filter { $0.expiryStatus == .expired }
        case .expiringSoon:
            store.sortedFreshInventory.filter {
                $0.expiryStatus == .today || $0.expiryStatus == .soon
            }
        case .lowStock:
            store.sortedFreshInventory.filter {
                $0.stapleStatus == .low || $0.stapleStatus == .outOfStock
            }
        }
    }

    private var focusedStaples: [InventoryItem] {
        let staples = store.pantryStaples.filter(stapleFilter.includes)
        guard navigationStore.inventoryFocus == .lowStock else { return staples }
        return staples.filter { $0.stapleStatus == .low || $0.stapleStatus == .outOfStock }
    }

    private var displayedFreshInventory: [InventoryItem] {
        focusedFreshInventory.filter(matchesSearch)
    }

    private var displayedStaples: [InventoryItem] {
        focusedStaples.filter(matchesSearch)
    }

    private var hasSearchQuery: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasSearchResults: Bool {
        !displayedFreshInventory.isEmpty || !displayedStaples.isEmpty
    }

    private var showsEmptyInventory: Bool {
        !hasSearchQuery && navigationStore.inventoryFocus == .all && store.inventory.isEmpty
    }

    private func matchesSearch(_ item: InventoryItem) -> Bool {
        guard hasSearchQuery else { return true }
        return item.name.localizedCaseInsensitiveContains(searchText)
    }

    var body: some View {
        List {
            let tonight = tonightSummaries
            // The control layer: the counts *are* the filters, and the picker
            // names the same `InventoryFocus` the list already filters by. The
            // read-only summary row and the separate "正在查看 … 清除" banner
            // both collapse into this one surface.
            //
            // It stays on screen whenever the kitchen has anything in it, even
            // when the current filter matches nothing: the control that got you
            // into an empty result is the one that has to get you out of it.
            if !hasSearchQuery && !store.inventory.isEmpty {
                Section {
                    InventoryControlStrip(
                        totalCount: store.inventory.count,
                        expiringCount: store.expiringItems.count,
                        lowStockCount: store.inventory.filter {
                            $0.stapleStatus == .low || $0.stapleStatus == .outOfStock
                        }.count,
                        focus: $navigationStore.inventoryFocus
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 12, trailing: 20))
                    .listRowBackground(AppTheme.canvas)
                    .listRowSeparator(.hidden)
                }
                .listSectionSeparator(.hidden)
            }

            if hasSearchQuery && !hasSearchResults {
                Section {
                    ContentUnavailableView(
                        "没有找到匹配食材",
                        systemImage: "magnifyingglass",
                        description: Text("尝试使用更短的名称，或清除搜索。")
                    )
                    .accessibilityIdentifier("inventory.search.empty")
                }
            } else if showsEmptyInventory {
                Section {
                    ContentUnavailableView(
                        "还没有食材",
                        systemImage: "shippingbox",
                        description: Text("从这里添加食材，库存和保质期会自动显示在列表中。")
                    )
                    Button("添加食材", systemImage: "plus") {
                        recordMode = .manual
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.managementActionFill)
                    .foregroundStyle(AppTheme.onManagementAction)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("inventory.empty.add.button")
                }
            } else if navigationStore.inventoryFocus != .all && !hasSearchResults {
                Section {
                    ContentUnavailableView(
                        "没有符合条件的食材",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("可以清除筛选查看全部食材。")
                    )
                }
            } else {
                if !displayedFreshInventory.isEmpty {
                    Section {
                        ForEach(displayedFreshInventory) { item in
                            Button {
                                onSelectItem(item.id)
                            } label: {
                                InventoryFoodCard(
                                    item: item,
                                    tonight: InventoryTonightLinkage.summary(for: item, in: tonight)
                                )
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(AppTheme.canvas)
                            .listRowSeparator(
                                .hidden
                            )
                            .accessibilityIdentifier("inventory.item.\(item.id.uuidString)")
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("删除", role: .destructive) {
                                    itemPendingDeletion = item
                                }
                            }
                            // The same two destinations the row already has,
                            // surfaced without a swipe. No new behaviour: open
                            // is the row's own tap, delete is the swipe action
                            // and still goes through the confirmation alert.
                            .contextMenu {
                                Button("查看详情", systemImage: "info.circle") {
                                    onSelectItem(item.id)
                                }
                                Button("删除", systemImage: "trash", role: .destructive) {
                                    itemPendingDeletion = item
                                }
                            }
                        }
                    } header: {
                        ListSectionHeader(title: "食材", count: displayedFreshInventory.count)
                    }
                }

                if !displayedStaples.isEmpty || (!hasSearchQuery && !store.pantryStaples.isEmpty) {
                    Section {
                        if displayedStaples.isEmpty {
                            Text("当前筛选下没有常备食材。")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(displayedStaples) { item in
                                Button {
                                    onSelectItem(item.id)
                                } label: {
                                    PantryStapleRow(item: item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        HStack {
                            ListSectionHeader(title: "常备食材", count: displayedStaples.count)
                            Spacer()
                            Menu {
                                Picker("筛选", selection: $stapleFilter) {
                                    ForEach(PantryStapleFilter.allCases) { Text($0.rawValue).tag($0) }
                                }
                            } label: {
                                Text(stapleFilter.rawValue)
                                    .font(.subheadline)
                                    .dynamicTypeSize(...ChromeMetrics.headerTypeLimit)
                                    .frame(minHeight: 44)
                            }
                            .textCase(nil)
                            .accessibilityIdentifier("inventory.staple.filter.button")
                            .accessibilityLabel("常备食材筛选：\(stapleFilter.rawValue)")
                        }
                    }
                } else if !hasSearchQuery && store.pantryStaples.isEmpty && !store.inventory.isEmpty {
                    // No section header here: the ContentUnavailableView title
                    // already reads "还没有常备食材", and a "常备食材 0 项" header
                    // above it repeated the same words twice in a row.
                    Section {
                        ContentUnavailableView(
                            "还没有常备食材",
                            systemImage: "cabinet",
                            description: Text("把常用食材设为常备，库存不足时会提醒补货。")
                        )
                        Button("添加常备食材") { isShowingAddStaple = true }
                            .buttonStyle(.bordered)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("inventory.staple.empty.add.button")
                    }
                }

                if !hasSearchQuery && !restockSuggestions.isEmpty {
                    Section("补货建议") {
                        ForEach(restockSuggestions) { suggestion in
                            Group {
                                if dynamicTypeSize.isAccessibilitySize {
                                    VStack(alignment: .leading, spacing: 8) {
                                        restockSuggestionLabels(suggestion)
                                        restockSuggestionButton(suggestion)
                                    }
                                } else {
                                    HStack(spacing: 12) {
                                        restockSuggestionLabels(suggestion)
                                        Spacer(minLength: 12)
                                        restockSuggestionButton(suggestion)
                                    }
                                }
                            }
                            .frame(minHeight: 44)
                        }
                        let stapleSuggestions = restockSuggestions.filter { $0.source == .pantryStaple }
                        if !stapleSuggestions.isEmpty {
                            Button {
                                stapleSuggestions.forEach(addSuggestion)
                            } label: {
                                Group {
                                    if dynamicTypeSize.isAccessibilitySize {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Image(systemName: "cart.badge.plus")
                                                .accessibilityHidden(true)
                                            Text("加入 \(stapleSuggestions.count) 项常备补货")
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    } else {
                                        Label("加入 \(stapleSuggestions.count) 项常备补货", systemImage: "cart.badge.plus")
                                    }
                                }
                                .frame(minHeight: AppTheme.minimumHitTarget)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(AppTheme.managementActionFill)
                            .foregroundStyle(AppTheme.onManagementAction)
                            .accessibilityIdentifier("inventory.restock.addAll.button")
                        }
                    }
                }

                if !hasSearchQuery {
                    Section {
                        NavigationLink {
                            RecentConsumptionView()
                        } label: {
                            Label("最近消耗", systemImage: "clock.arrow.circlepath")
                        }
                    }
                }
            }

            // Clearance for the floating tab bar as a real trailing row rather
            // than a safe-area inset: with `.listStyle(.plain)` the inset is
            // consumed by the scroll edge effect, and the final row came to
            // rest underneath the expanded bar.
            Section {
                Color.clear
                    .frame(height: ChromeMetrics.bottomClearance)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .accessibilityHidden(true)
            }
            .listSectionSeparator(.hidden)
        }
        // Open page surface: section titles, rows and hairlines directly on the
        // page. The grouped style wrapped every section in a rounded card, which
        // is the shape this replaced.
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppTheme.canvas)
        .environment(\.defaultMinListHeaderHeight, 0)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        // One list-level clearance for the floating tab bar, rather than padding
        // each row: an empty spacer in the bottom safe area, so the last
        // ingredient, the staple empty-state text and CTA, and the final search
        // result can all come to rest fully above the expanded bar.
        .navigationTitle("食材")
        // Large title at normal sizes; at Accessibility sizes it would take
        // most of the first screen, so it collapses to the inline title — still
        // a VoiceOver heading, never truncated or scale-compressed.
        .navigationBarTitleDisplayMode(dynamicTypeSize.isAccessibilitySize ? .inline : .large)
        // Placement is explicit at Accessibility sizes, and stays that way.
        // With `.automatic` and an inline title, UIKit pins the search bar to a
        // fixed ~63pt that cannot fit Accessibility XXXL text: the magnifier and
        // the "搜索食材" prompt are clipped away and the bar renders as an empty
        // grey capsule. Verified again in Phase 1B by removing this and
        // reproducing exactly that empty capsule, so the cost — a taller field
        // at XXXL only — is deliberate. Normal sizes keep `.automatic`, the
        // standard hidden-until-pulled-down behavior.
        .searchable(
            text: $searchText,
            placement: dynamicTypeSize.isAccessibilitySize
                ? .navigationBarDrawer(displayMode: .always)
                : .automatic,
            prompt: "搜索食材"
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("添加食材", systemImage: "plus") {
                    recordMode = .manual
                }
                .frame(minWidth: 44, minHeight: 44)
                .dynamicTypeSize(...ChromeMetrics.symbolTypeLimit)
                .accessibilityIdentifier("inventory.add.button")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("扫描购物小票", systemImage: "camera.viewfinder") {
                        recordMode = .receipt
                    }
                    Button("添加常备食材", systemImage: "cabinet") {
                        isShowingAddStaple = true
                    }
                    // Prepared batches live behind their own entry rather than in
                    // the ingredient list: 卤鸡腿 is not a grocery.
                    Button("备餐", systemImage: "takeoutbag.and.cup.and.straw") {
                        isShowingPreparedComponents = true
                    }
                } label: {
                    // Clamp the glyph only — the menu's own rows keep full
                    // Dynamic Type.
                    Label("更多食材操作", systemImage: "ellipsis.circle")
                        .dynamicTypeSize(...ChromeMetrics.symbolTypeLimit)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityIdentifier("inventory.more.button")
                .accessibilityLabel("更多食材操作")
            }
        }
        .sheet(item: $recordMode) { mode in
            RecordFoodSheet(initialMode: mode)
        }
        .sheet(isPresented: $isShowingAddStaple) {
            AddPantryStapleView()
        }
        .navigationDestination(isPresented: $isShowingPreparedComponents) {
            PreparedComponentsView()
        }
        .navigationDestination(for: InventoryRoute.self) { route in
            switch route {
            case .detail(let itemID):
                InventoryItemDetailView(itemID: itemID)
            }
        }
        .alert("删除这项食材？", isPresented: Binding(
            get: { itemPendingDeletion != nil },
            set: { if !$0 { itemPendingDeletion = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let itemPendingDeletion {
                    store.deleteInventory(itemPendingDeletion.id)
                }
                itemPendingDeletion = nil
            }
            Button("取消", role: .cancel) { itemPendingDeletion = nil }
        } message: {
            Text("此操作会移除库存记录，且无法撤销。")
        }
        .overlay(alignment: .bottom) {
            if let notice = store.inventoryNotice {
                InventoryNoticeOverlay(notice: notice) {
                    store.clearInventoryNotice()
                }
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: store.inventoryNotice)
    }

    private func addSuggestion(_ suggestion: RestockSuggestion) {
        store.addShopping(
            name: suggestion.name,
            quantity: suggestion.suggestedQuantity ?? 1,
            unit: suggestion.unit ?? "份",
            source: suggestion.source == .pantryStaple ? "来自常备货架" : "补货建议"
        )
    }

    private func restockSuggestionLabels(_ suggestion: RestockSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(suggestion.name)
                .accessibilityIdentifier("inventory.restock.name")
            Text(suggestion.reason)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func restockSuggestionButton(_ suggestion: RestockSuggestion) -> some View {
        Button {
            addSuggestion(suggestion)
        } label: {
            Text("加入清单")
                .frame(minHeight: AppTheme.minimumHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("inventory.restock.add.button")
    }
}

private struct InventoryNoticeOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let notice: String
    let onDismiss: () -> Void

    var body: some View {
        FeedbackToast(
            message: notice,
            style: InventoryNoticePresentation.style(for: notice)
        )
        .task(id: notice) {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .snappy) {
                onDismiss()
            }
        }
    }
}

#Preview("库存提示 — 成功") {
    InventoryNoticeOverlay(notice: "已添加 2 项食材", onDismiss: {})
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(KitchenTheme.canvas)
}

#Preview("库存提示 — 错误") {
    InventoryNoticeOverlay(notice: "库存保存失败，请稍后重试。", onDismiss: {})
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(KitchenTheme.canvas)
}

#Preview("库存提示 — 深色") {
    InventoryNoticeOverlay(notice: "库存保存失败，请稍后重试。", onDismiss: {})
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(KitchenTheme.canvas)
        .preferredColorScheme(.dark)
}

#Preview("库存提示 — 辅助功能大字号") {
    InventoryNoticeOverlay(notice: "库存保存失败，请稍后重试。", onDismiss: {})
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding()
        .background(KitchenTheme.canvas)
        .dynamicTypeSize(.accessibility3)
}

/// The one "section title + item count" header for every grouped list in the
/// app. Inventory and Shopping each used to carry their own: same job, but
/// different title weight (semibold vs medium), different count typography
/// (footnote vs subheadline), the count adjacent on one screen and pushed to the
/// trailing edge on the other — and only Inventory's was exposed to VoiceOver as
/// a heading, so the rotor could skip through Inventory's sections but not
/// Shopping's.
private struct ListSectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text("\(count) 项")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .textCase(nil)
        // Headers stay at a heading weight instead of scaling into display-title
        // sizes that would dwarf the rows beneath them.
        .dynamicTypeSize(...ChromeMetrics.headerTypeLimit)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct InventoryFoodCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let item: InventoryItem
    /// `今晚 · 蒜蓉上海青` when tonight's plan uses this food. Resolved by the
    /// caller from real plans, so the row states a relationship rather than
    /// recomputing one.
    var tonight: String? = nil

    private var statusText: String {
        item.isAvailable ? item.expiryStatusText : "缺货 · \(item.expiryStatusText)"
    }

    private var statusColor: Color {
        item.isAvailable ? item.expiryStatus.color : .red
    }

    /// Only genuinely urgent food is coloured. Everything healthy reads as
    /// ordinary secondary text, so the eye lands on what actually needs a
    /// decision instead of on a wall of status.
    private var showsUrgency: Bool {
        !item.isAvailable || item.isExpiringSoon
    }

    var body: some View {
        Group {
            HStack(alignment: .top, spacing: 12) {
                KitchenStatusRail(color: markerColor, length: 28, vertical: true)
                    .padding(.top, 2)
                if dynamicTypeSize.isAccessibilitySize {
                    accessibilityLayout
                } else {
                    standardLayout
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("打开食材详情")
    }

    private var accessibilityLabel: String {
        var parts = ["\(item.name)，\(item.quantity.formatted()) \(item.unit)，\(statusText)"]
        if let tonight { parts.append(tonight) }
        return parts.joined(separator: "，")
    }

    private var markerColor: Color {
        if tonight != nil { return KitchenTheme.sage }
        if item.stapleStatus == .low || item.stapleStatus == .outOfStock { return KitchenTheme.ochre }
        if !item.isAvailable || item.expiryStatus == .expired || item.isExpiringSoon { return KitchenTheme.terracotta }
        return KitchenTheme.separator
    }

    /// name → quantity on one line, then the quiet secondary line, then the
    /// tonight relation. No status glyph: the wording already says it, and a
    /// symbol per row turned the list into an icon column.
    private var standardLayout: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(item.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 12)
                // Higher layout priority so a long ingredient name wraps
                // rather than squeezing the quantity out of the row.
                quantityLabel.layoutPriority(1)
            }
            statusLabel
            tonightLabel
        }
    }

    /// One unambiguous vertical order at Accessibility sizes: name, then expiry
    /// status, then quantity — all left-aligned in a single column. Nothing is
    /// pushed to the trailing edge, so the quantity can never be
    /// squeezed into a narrow column or wrapped onto an unrelated line. Every
    /// string keeps unrestricted Dynamic Type: no `lineLimit(1)`, no
    /// `minimumScaleFactor` — the row just grows taller.
    private var accessibilityLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.name)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
            statusLabel
            quantityLabel
            tonightLabel
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusLabel: some View {
        Text(statusText)
            .font(.footnote)
            .foregroundStyle(showsUrgency ? statusColor : Color.secondary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var tonightLabel: some View {
        if let tonight {
            Text(tonight)
                .font(.caption)
                .foregroundStyle(AppTheme.cookingAccentForeground)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .accessibilityHidden(true)
        }
    }

    private var quantityLabel: some View {
        Text("\(item.quantity.formatted()) \(item.unit)")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            // Trailing only in the default side-by-side layout; at Accessibility
            // sizes the quantity is a left-aligned line in the main column.
            .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
            .accessibilityHidden(true)
    }
}

struct ShoppingView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var store: KitchenStore
    @EnvironmentObject private var navigationStore: AppNavigationStore
    @State private var isShowingStockInConfirm = false
    @State private var isShowingAddItem = false
    @State private var isShowingClearPurchasedConfirm = false
    @State private var searchText = ""
    @State private var isPurchasedExpanded = false
    @State private var isShoppingMode = false
    @State private var isShoppingModePurchasedExpanded = false

    init(previewSearchText: String = "", previewPurchasedExpanded: Bool = false, previewShoppingMode: Bool = false) {
        _searchText = State(initialValue: previewSearchText)
        _isPurchasedExpanded = State(initialValue: previewPurchasedExpanded)
        _isShoppingMode = State(initialValue: previewShoppingMode)
    }

    private var pendingSections: [(ShoppingCategory, [KitchenShoppingItem])] {
        ShoppingListPresentation.sections(items: store.shoppingItems, query: searchText)
    }

    private var summary: ShoppingListSummary {
        ShoppingListSummary(items: store.shoppingItems)
    }

    private var purchasedItems: [KitchenShoppingItem] {
        ShoppingListPresentation.purchasedItems(items: store.shoppingItems, query: searchText)
    }

    private var hasSearchQuery: Bool {
        !ShoppingListPresentation.normalizedQuery(searchText).isEmpty
    }

    private var shouldShowPurchasedItems: Bool {
        ShoppingListPresentation.shouldShowPurchased(
            isExpanded: isPurchasedExpanded,
            query: searchText,
            matchingPurchasedCount: purchasedItems.count
        )
    }

    private var hasSearchResults: Bool {
        !pendingSections.isEmpty || !purchasedItems.isEmpty
    }

    private var bulkActions: ShoppingBulkActionAvailability {
        ShoppingBulkActionAvailability(summary: summary)
    }

    private var shoppingMode: ShoppingModePresentation {
        ShoppingModePresentation(items: store.shoppingItems)
    }

    private var normalShoppingList: some View {
        List {
            if !hasSearchQuery && !store.shoppingItems.isEmpty {
                Section {
                    ShoppingSummaryRow(summary: summary)
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                }
            }

            if store.shoppingItems.isEmpty {
                Section {
                    ContentUnavailableView(
                        "买菜清单是空的",
                        systemImage: "checklist",
                        description: Text("今日计划缺少的食材和手动添加的项目会出现在这里。")
                    )
                    .accessibilityIdentifier("shopping.empty")

                    Button("添加买菜项目", systemImage: "plus") {
                        isShowingAddItem = true
                    }
                    .frame(minHeight: AppTheme.minimumHitTarget)
                    .accessibilityIdentifier("shopping.empty.add.button")
                }
            } else if hasSearchQuery && !hasSearchResults {
                Section {
                    ContentUnavailableView {
                        Label("没有找到匹配项目", systemImage: "magnifyingglass")
                    } description: {
                        Text("尝试使用更短的名称，或清除搜索。")
                    } actions: {
                        Button("清除搜索") {
                            searchText = ""
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.managementActionFill)
                        .foregroundStyle(AppTheme.onManagementAction)
                        .controlSize(.large)
                        .accessibilityIdentifier("shopping.search.clear")
                    }
                }
            } else {
                ForEach(pendingSections, id: \.0) { category, items in
                    Section {
                        ForEach(items) { item in
                            Button { store.toggleShopping(item) } label: {
                                ShoppingItemRow(item: item, isPurchased: false)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("shopping.item.\(item.id.uuidString)")
                            .accessibilityLabel(itemAccessibilityLabel(item, isPurchased: false))
                            .accessibilityHint("双击标记为已购买")
                        }
                    } header: {
                        ListSectionHeader(title: category.rawValue, count: items.count)
                    }
                    .accessibilityIdentifier("shopping.section.\(category.id)")
                }
            }

            if !purchasedItems.isEmpty {
                Section {
                    Button {
                        isPurchasedExpanded.toggle()
                    } label: {
                        HStack {
                            Label("已购买", systemImage: "checkmark.circle")
                                .font(.body.weight(.medium))
                            Spacer()
                            Text("\(summary.purchasedCount) 项")
                                .foregroundStyle(.secondary)
                            Image(systemName: shouldShowPurchasedItems ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("shopping.purchased.toggle")
                    .accessibilityLabel(
                        "已购买，\(summary.purchasedCount) 项，\(shouldShowPurchasedItems ? "已展开" : "已折叠")"
                    )
                    .accessibilityHint("双击以\(shouldShowPurchasedItems ? "折叠" : "展开")已购买项目")

                    if shouldShowPurchasedItems {
                        ForEach(purchasedItems) { item in
                            Button { store.toggleShopping(item) } label: {
                                ShoppingItemRow(item: item, isPurchased: true)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("shopping.item.\(item.id.uuidString)")
                            .accessibilityLabel(itemAccessibilityLabel(item, isPurchased: true))
                            .accessibilityHint("双击取消已购买状态")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(height: ChromeMetrics.bottomClearance)
                .accessibilityHidden(true)
        }
        .navigationTitle("买菜")
    }

    private var shoppingModeList: some View {
        List {
            Section {
                ShoppingModeHeader(presentation: shoppingMode)
            }

            if shoppingMode.isEmpty {
                ContentUnavailableView("买菜清单是空的", systemImage: "checklist")
            } else if hasSearchQuery && !hasSearchResults {
                ContentUnavailableView {
                    Label("没有找到匹配项目", systemImage: "magnifyingglass")
                } description: {
                    Text("尝试使用更短的名称，或清除搜索。")
                } actions: {
                    Button("清除搜索") { searchText = "" }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.managementActionFill)
                        .foregroundStyle(AppTheme.onManagementAction)
                        .controlSize(.large)
                        .accessibilityIdentifier("shopping.mode.search.clear")
                }
            } else if shoppingMode.isCompleted {
                ContentUnavailableView("已全部买齐", systemImage: "checkmark.circle.fill")
                    .accessibilityIdentifier("shopping.mode.completed")
            } else {
                ForEach(pendingSections, id: \.0) { category, items in
                    Section {
                        ForEach(items) { item in
                            Button { store.toggleShopping(item) } label: {
                                ShoppingItemRow(item: item, isPurchased: false, isEmphasized: true)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("shopping.mode.item.\(item.id.uuidString)")
                            .accessibilityLabel(itemAccessibilityLabel(item, isPurchased: false))
                            .accessibilityHint("双击标记为已购买")
                        }
                    } header: {
                        ListSectionHeader(title: category.rawValue, count: items.count)
                    }
                }
            }

            let completed = purchasedItems
            if !completed.isEmpty {
                Section {
                    Button {
                        isShoppingModePurchasedExpanded.toggle()
                    } label: {
                        HStack {
                            Label("已购买", systemImage: "checkmark.circle")
                                .font(.body.weight(.medium))
                            Spacer()
                            Text("\(completed.count) 项")
                                .foregroundStyle(.secondary)
                            Image(systemName: isShoppingModePurchasedExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("shopping.mode.purchased.toggle")
                    .accessibilityLabel("已购买，\(completed.count) 项，\(isShoppingModePurchasedExpanded ? "已展开" : "已折叠")")
                    .accessibilityHint("双击以\(isShoppingModePurchasedExpanded ? "折叠" : "展开")已购买项目")

                    if isShoppingModePurchasedExpanded {
                        ForEach(completed) { item in
                            Button { store.toggleShopping(item) } label: {
                                ShoppingItemRow(item: item, isPurchased: true)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("shopping.mode.item.\(item.id.uuidString)")
                            .accessibilityLabel(itemAccessibilityLabel(item, isPurchased: true))
                            .accessibilityHint("双击取消购买状态")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(height: ChromeMetrics.bottomClearance)
                .accessibilityHidden(true)
        }
        .accessibilityIdentifier("shopping.mode.container")
    }

    var body: some View {
        Group {
            if isShoppingMode {
                shoppingModeList
            } else {
                normalShoppingList
            }
        }
        .navigationTitle(isShoppingMode ? "购物模式" : "买菜")
        .navigationBarTitleDisplayMode(dynamicTypeSize.isAccessibilitySize ? .inline : .large)
        // One searchable for both modes, so Shopping Mode reuses the exact
        // normal-mode search semantics (`ShoppingListPresentation`) instead of a
        // mode-specific duplicate. Searching in the aisle is the point.
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "搜索买菜项目"
        )
        .onAppear(perform: presentRequestedStockInIfNeeded)
        .onChange(of: navigationStore.isShoppingStockInRequested) { _, isRequested in
            if isRequested { presentRequestedStockInIfNeeded() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if isShoppingMode {
                    Button("退出", systemImage: "xmark") { isShoppingMode = false }
                        .frame(minWidth: AppTheme.minimumHitTarget, minHeight: AppTheme.minimumHitTarget)
                        .dynamicTypeSize(...ChromeMetrics.symbolTypeLimit)
                        .accessibilityIdentifier("shopping.mode.exit")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !isShoppingMode {
                    Button("购物模式", systemImage: "cart") {
                        isShoppingMode = true
                    }
                    .disabled(store.shoppingItems.isEmpty)
                    .frame(minWidth: AppTheme.minimumHitTarget, minHeight: AppTheme.minimumHitTarget)
                    .dynamicTypeSize(...ChromeMetrics.symbolTypeLimit)
                    .accessibilityIdentifier("shopping.mode.toggle")
                }
            }
            if !isShoppingMode {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("全部标记为已购买", systemImage: "checkmark.circle") {
                        store.markAllPendingShoppingPurchased()
                    }
                    .disabled(!bulkActions.canMarkAllPurchased)

                    Button("清除已购买", systemImage: "trash", role: .destructive) {
                        // A Menu dismisses in the same update cycle. Schedule the
                        // confirmation for the next main-loop turn so UIKit has
                        // released the menu presentation before SwiftUI presents it.
                        DispatchQueue.main.async {
                            isShowingClearPurchasedConfirm = true
                        }
                    }
                    .disabled(!bulkActions.canClearPurchased)
                    .accessibilityIdentifier("shopping.bulk.clearPurchased")

                    Button("全部入库", systemImage: "shippingbox") {
                        isShowingStockInConfirm = true
                    }
                    .disabled(!bulkActions.canStockInPurchased)
                    .accessibilityIdentifier("shopping.bulk.stockIn")

                    Divider()

                    Button("展开已购买", systemImage: "chevron.down") {
                        isPurchasedExpanded = true
                    }
                    .disabled(!bulkActions.canChangePurchasedExpansion || isPurchasedExpanded)
                    .accessibilityIdentifier("shopping.bulk.expandPurchased")

                    Button("折叠已购买", systemImage: "chevron.up") {
                        isPurchasedExpanded = false
                    }
                    .disabled(!bulkActions.canChangePurchasedExpansion || !isPurchasedExpanded)
                    .accessibilityIdentifier("shopping.bulk.collapsePurchased")
                } label: {
                    Label("购物清单批量操作", systemImage: "ellipsis.circle")
                        .dynamicTypeSize(...ChromeMetrics.symbolTypeLimit)
                        .frame(minWidth: AppTheme.minimumHitTarget, minHeight: AppTheme.minimumHitTarget)
                }
                .accessibilityIdentifier("shopping.bulk.menu")
                .accessibilityLabel("购物清单批量操作")
            }
            }

            // Available in both modes: remembering an item mid-aisle is exactly
            // the Shopping Mode case. Bulk management stays out of the mode; this
            // is single-item entry through the same sheet.
            ToolbarItem(placement: .topBarTrailing) {
                Button("添加", systemImage: "plus") { isShowingAddItem = true }
                    .frame(minWidth: AppTheme.minimumHitTarget, minHeight: AppTheme.minimumHitTarget)
                    .dynamicTypeSize(...ChromeMetrics.symbolTypeLimit)
                    .accessibilityIdentifier("shopping.add.button")
                    .accessibilityLabel("添加买菜项目")
            }
        }
        .sheet(isPresented: $isShowingAddItem) {
            AddShoppingItemView()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .alert("全部入库？", isPresented: $isShowingStockInConfirm) {
            Button("入库") { store.stockInCompletedShopping() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已买的食材将计入库存，此操作无法撤销。")
        }
        .alert(
            "清除 \(summary.purchasedCount) 项已购买项目？",
            isPresented: $isShowingClearPurchasedConfirm,
        ) {
            Button("清除已购买", role: .destructive) {
                store.clearCompletedShopping()
                isPurchasedExpanded = false
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作只会删除已购买项目，待购买项目会保留。")
        }
        .alert(
            "买菜清单",
            isPresented: Binding(
                get: { store.shoppingNotice != nil },
                set: { if !$0 { store.shoppingNotice = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(store.shoppingNotice ?? "")
        }
    }

    private func presentRequestedStockInIfNeeded() {
        guard navigationStore.isShoppingStockInRequested else { return }
        navigationStore.consumeShoppingStockInRequest()
        guard bulkActions.canStockInPurchased else { return }
        isShowingStockInConfirm = true
    }

    private func itemAccessibilityLabel(_ item: KitchenShoppingItem, isPurchased: Bool) -> String {
        let source = item.source == "手动添加" ? "" : "，\(item.source)"
        return "\(item.name)，\(item.quantity.formatted()) \(item.unit)\(source)，\(isPurchased ? "已购买" : "未购买")"
    }
}

private struct ShoppingSummaryRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let summary: ShoppingListSummary

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    pendingSummary
                    secondarySummary
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    pendingSummary
                    Spacer(minLength: 12)
                    secondarySummary
                }
            }
        }
        .dynamicTypeSize(...ChromeMetrics.summaryTypeLimit)
        .accessibilityElement(children: .contain)
    }

    private var pendingSummary: some View {
        Label("\(summary.pendingCount) 项待购买", systemImage: "cart")
            .font(.headline)
            .accessibilityIdentifier("shopping.summary.pending")
            .accessibilityLabel("待购买 \(summary.pendingCount) 项")
    }

    private var secondarySummary: some View {
        HStack(spacing: 8) {
            Text("已购 \(summary.purchasedCount)")
                .accessibilityIdentifier("shopping.summary.purchased")
                .accessibilityLabel("已购买 \(summary.purchasedCount) 项")
            Text("·")
                .accessibilityHidden(true)
            Text("\(summary.categoryCount) 个分类")
                .accessibilityIdentifier("shopping.summary.categories")
                .accessibilityLabel("分类 \(summary.categoryCount) 个")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

private struct ShoppingItemRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let item: KitchenShoppingItem
    let isPurchased: Bool
    var isEmphasized = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: isPurchased ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isPurchased ? Color.secondary : AppTheme.primary)
                .dynamicTypeSize(...ChromeMetrics.symbolTypeLimit)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    name
                    quantity
                    source
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        name
                        source
                    }
                    Spacer(minLength: 12)
                    quantity
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: AppTheme.minimumHitTarget, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var name: some View {
        Text(item.name)
            .font(isEmphasized ? .title3.weight(.semibold) : .body.weight(.medium))
            .foregroundStyle(isPurchased ? .secondary : .primary)
            .strikethrough(isPurchased)
            .multilineTextAlignment(.leading)
            .accessibilityHidden(true)
    }

    private var quantity: some View {
        Text("\(item.quantity.formatted()) \(item.unit)")
            .font(isEmphasized ? .body.weight(.medium) : .subheadline)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var source: some View {
        if !isPurchased, item.source != "手动添加" {
            Text(item.source)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .accessibilityHidden(true)
        }
    }
}

private struct ShoppingModeHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let presentation: ShoppingModePresentation

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    title
                    status
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    title
                    Spacer(minLength: 12)
                    status
                }
            }
        }
        .dynamicTypeSize(...ChromeMetrics.summaryTypeLimit)
        .accessibilityElement(children: .contain)
    }

    private var title: some View {
        Label("购物模式", systemImage: "cart.fill")
            .font(.headline)
    }

    private var status: some View {
        Text(presentation.isCompleted ? "已全部买齐" : "剩余 \(presentation.remainingCount) / 共 \(presentation.totalCount) 项")
            .font(.subheadline)
            .foregroundStyle(presentation.isCompleted ? AppTheme.successInk : .secondary)
            .accessibilityIdentifier("shopping.mode.remaining")
    }
}

private struct ShoppingViewPreview: View {
    @StateObject private var store: KitchenStore
    private let searchText: String
    private let purchasedExpanded: Bool
    private let shoppingMode: Bool

    init(
        items: [KitchenShoppingItem],
        searchText: String = "",
        purchasedExpanded: Bool = false,
        shoppingMode: Bool = false
    ) {
        let store = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.shoppingItems = items
        _store = StateObject(wrappedValue: store)
        self.searchText = searchText
        self.purchasedExpanded = purchasedExpanded
        self.shoppingMode = shoppingMode
    }

    var body: some View {
        NavigationStack {
            ShoppingView(
                previewSearchText: searchText,
                previewPurchasedExpanded: purchasedExpanded,
                previewShoppingMode: shoppingMode
            )
        }
        .environmentObject(store)
        .environmentObject(AppNavigationStore())
    }
}

#Preview("Shopping — categories") {
    ShoppingViewPreview(items: [
        KitchenShoppingItem(name: "番茄", quantity: 2, unit: "个"),
        KitchenShoppingItem(name: "鸡肉", quantity: 500, unit: "克"),
        KitchenShoppingItem(name: "大米", quantity: 1, unit: "袋"),
        KitchenShoppingItem(name: "牛奶", quantity: 1, unit: "盒", isDone: true)
    ])
}

#Preview("Shopping — purchased expanded") {
    ShoppingViewPreview(
        items: [
            KitchenShoppingItem(name: "番茄", quantity: 2, unit: "个"),
            KitchenShoppingItem(name: "牛奶", quantity: 1, unit: "盒", isDone: true)
        ],
        purchasedExpanded: true
    )
}

#Preview("Shopping — no search results") {
    ShoppingViewPreview(
        items: [KitchenShoppingItem(name: "番茄", quantity: 2, unit: "个")],
        searchText: "不存在"
    )
}

#Preview("Shopping — empty") {
    ShoppingViewPreview(items: [])
}

#Preview("Shopping mode — categories") {
    ShoppingViewPreview(items: [KitchenShoppingItem(name: "番茄", quantity: 2, unit: "个"), KitchenShoppingItem(name: "鸡肉", quantity: 1, unit: "盒"), KitchenShoppingItem(name: "牛奶", quantity: 1, unit: "盒", isDone: true)], shoppingMode: true)
}

#Preview("Shopping mode — one remaining") {
    ShoppingViewPreview(items: [KitchenShoppingItem(name: "番茄", quantity: 1, unit: "个")], shoppingMode: true)
}

#Preview("Shopping mode — completed") {
    ShoppingViewPreview(items: [KitchenShoppingItem(name: "牛奶", quantity: 1, unit: "盒", isDone: true)], shoppingMode: true)
}

#Preview("Shopping mode — empty") {
    ShoppingViewPreview(items: [], shoppingMode: true)
}

private struct AddShoppingItemView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: KitchenStore
    @State private var name = ""
    @State private var quantity = 1.0
    @State private var unit = "份"
    @State private var source = "手动添加"
    @State private var remark = ""
    @State private var errorMessage: String?
    @FocusState private var isNameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("买什么") {
                    TextField("名称", text: $name).focused($isNameFocused)
                    TextField("数量", value: $quantity, format: .number).keyboardType(.decimalPad)
                    TextField("单位", text: $unit)
                }
                Section("补充信息") {
                    Picker("来源", selection: $source) {
                        Text("手动添加").tag("手动添加")
                        Text("日常补给").tag("日常补给")
                        Text("常备货架").tag("来自常备货架")
                    }
                    TextField("备注（可选）", text: $remark)
                }
            }
            .navigationTitle("添加买菜项目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("添加", action: save).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            .task { isNameFocused = true }
            .alert("无法添加", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(errorMessage ?? "请检查输入。") }
        }
    }

    private func save() {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, quantity.isFinite, quantity > 0 else {
            errorMessage = "请填写名称和有效数量。"; return
        }
        store.addShopping(name: cleanName, quantity: quantity, unit: unit, source: source, remark: remark)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }
}

/// Wraps a Settings row's text in a `Label` with a leading decorative symbol at
/// normal sizes, and drops the symbol entirely at Accessibility sizes.
///
/// `Label` keeps the icon in its own leading column, which at Accessibility XXXL
/// leaves the text column so narrow that wrapped continuation lines hang back out
/// to the left underneath the icon ("游客" / "模式", "本机功能" / "已全部可用") —
/// legible in theory, ragged and hard to scan in practice. The symbols here carry
/// no information (they are all `accessibilityHidden`), so at those sizes the text
/// simply takes the full row width instead.
private struct SettingsRowLabel<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            content.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Label {
                content
            } icon: {
                Image(systemName: symbol)
                    .dynamicTypeSize(...ChromeMetrics.symbolTypeLimit)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Account/guest row: mode or identity first, an optional plain-language status,
/// then the action. Always a vertical stack, so the action text can never be
/// squeezed against the disclosure chevron, and reads as a single VoiceOver
/// element in that same order.
private struct SettingsAccountRow: View {
    let symbol: String
    let title: String
    let detail: String?
    let action: String

    var body: some View {
        SettingsRowLabel(symbol: symbol) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(action)
                    .font(.footnote)
                    .foregroundStyle(.tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: ChromeMetrics.minimumRowHeight)
        .accessibilityElement(children: .combine)
    }
}

struct SettingsView: View {
    /// Kept as a named constant so the guest-mode UI test asserts the same string
    /// the screen renders, instead of a hand-copied duplicate.
    ///
    /// Wording is deliberately byte-identical to the pre-UI-5A copy. UI-5A's
    /// improvement is *hierarchy* — the mode, local-usability status, and action
    /// moved into the row, and this qualification moved into the section footer —
    /// not rewording. Two static contracts pin this exact string
    /// (`test/ios-native-auth-phase1.test.mjs` and `GuestMergeUIPhase2B3UITests`),
    /// and there is no user-facing gain in churning them for one word.
    static let guestAccountFooter = "无需登录即可继续使用全部本机功能。登录后可为未来跨设备同步做准备，并可选择将本机库存合并到家庭云端；购物清单、计划和菜谱仍只保存在本机。"

    @AppStorage("appearance") private var appearanceRawValue = AppAppearance.system.rawValue
    @AppStorage("expiryNotificationsEnabled") private var notificationsEnabled = false
    @AppStorage("notifyLeadTime1Day") private var notifyLeadTime1Day = true
    @AppStorage("notifyLeadTime3Day") private var notifyLeadTime3Day = false
    @AppStorage("notifyLeadTimeDayOf") private var notifyLeadTimeDayOf = true
    @AppStorage("stapleRestockNotificationsEnabled") private var stapleNotificationsEnabled = false
    @EnvironmentObject private var store: KitchenStore
    @EnvironmentObject private var recipeStore: RecipeStore
    @EnvironmentObject private var authStore: AuthStore
    #if DEBUG
    @EnvironmentObject private var syncSmokeController: SyncSmokeController
    #endif
    @State private var isShowingPermissionDeniedAlert = false
    @State private var isShowingClearDataAlert = false
    #if DEBUG
    @State private var isShowingSyncSmokeConfirmation = false
    #endif

    private var appearance: Binding<AppAppearance> {
        Binding(
            get: { AppAppearance(rawValue: appearanceRawValue) ?? .system },
            set: { appearanceRawValue = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section {
                switch authStore.status {
                case .guest:
                    // Guest is a normal, complete state — not a warning. The row
                    // leads with the mode, states plainly that nothing is missing
                    // locally, and names the action, so the nuanced sync/merge
                    // detail can move to the section footer where iOS puts it.
                    NavigationLink {
                        AuthEntryView()
                    } label: {
                        SettingsAccountRow(
                            symbol: "person.crop.circle",
                            title: "游客模式",
                            detail: "本机功能已全部可用",
                            action: "登录或创建账号"
                        )
                    }
                    .accessibilityIdentifier("settings.account.entry")
                case .signedIn(let user):
                    NavigationLink {
                        AccountView()
                    } label: {
                        SettingsAccountRow(
                            symbol: "person.crop.circle.fill",
                            title: user.email ?? "已登录账号",
                            detail: nil,
                            action: "管理账号与家庭"
                        )
                    }
                    .accessibilityIdentifier("settings.account.entry")
                }

                if let message = authStore.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.account.error")
                }
            } header: {
                Text("账号")
            } footer: {
                if case .guest = authStore.status {
                    Text(Self.guestAccountFooter)
                        .accessibilityIdentifier("settings.account.guest.footer")
                }
            }

            Section("外观") {
                Picker("显示模式", selection: appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .accessibilityIdentifier("settings.appearance.picker")
            }

            Section("菜谱") {
                Picker("菜谱库模式", selection: Binding(
                    get: { recipeStore.libraryMode },
                    set: { mode in Task { await recipeStore.reload(mode: mode) } }
                )) {
                    ForEach(RecipeLibraryMode.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("settings.recipeLibrary.picker")
                if let message = recipeStore.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.recipeLibrary.error")
                }
            }

            // The weekly rhythm is seven values, so it gets its own page rather
            // than seven permanent pickers in the main form.
            Section("用餐节奏") {
                NavigationLink {
                    WeeklyRhythmSettingsView()
                } label: {
                    SettingsRowLabel(symbol: "calendar") {
                        Text("每周用餐节奏")
                    }
                }
                .frame(minHeight: ChromeMetrics.minimumRowHeight)
                .accessibilityIdentifier("settings.weeklyRhythm.link")
            }

            Section {
                Toggle("食材到期提醒", isOn: Binding(
                    get: { notificationsEnabled },
                    set: { handleNotificationsToggle($0) }
                ))
                .accessibilityIdentifier("settings.expiryNotifications.toggle")
                if notificationsEnabled {
                    Toggle(
                        ExpiryNotificationLeadTime.oneDayBefore.title,
                        isOn: $notifyLeadTime1Day
                    )

                    Toggle(
                        ExpiryNotificationLeadTime.threeDaysBefore.title,
                        isOn: $notifyLeadTime3Day
                    )

                    Toggle(
                        ExpiryNotificationLeadTime.dayOf.title,
                        isOn: $notifyLeadTimeDayOf
                    )
                }

                Toggle("常备食材补货提醒", isOn: Binding(
                    get: { stapleNotificationsEnabled },
                    set: { handleStapleNotificationsToggle($0) }
                ))
                .accessibilityIdentifier("settings.stapleNotifications.toggle")

            } header: {
                Text("提醒")
            } footer: {
                Text("首次开启提醒时，会请求系统通知权限。")
            }
            .onChange(of: notifyLeadTime1Day) { _, _ in rescheduleNotifications() }
            .onChange(of: notifyLeadTime3Day) { _, _ in rescheduleNotifications() }
            .onChange(of: notifyLeadTimeDayOf) { _, _ in rescheduleNotifications() }

            // Managing the pantry shelf is a pantry preference, not a reminder
            // setting, so it no longer sits among the notification toggles. Same
            // destination as before.
            Section("常备食材") {
                NavigationLink {
                    PantryStaplesView()
                } label: {
                    SettingsRowLabel(symbol: "cabinet") {
                        Text("管理常备货架")
                    }
                }
                .frame(minHeight: ChromeMetrics.minimumRowHeight)
                .accessibilityIdentifier("settings.pantry.manage.link")
            }

            Section("数据") {
                NavigationLink {
                    BackupRestoreView()
                } label: {
                    SettingsRowLabel(symbol: "externaldrive") {
                        Text("备份与恢复")
                    }
                }
                .frame(minHeight: ChromeMetrics.minimumRowHeight)
                .accessibilityIdentifier("settings.backup.link")
            }

            Section("AI") {
                AIRecommendationProviderSettingsRow()

                NavigationLink {
                    AIServiceDiagnosticsView(authStore: authStore)
                } label: {
                    SettingsRowLabel(symbol: "stethoscope") {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("AI 服务诊断")
                            Text("检查 App 实际网络、认证和模型请求")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(minHeight: ChromeMetrics.minimumRowHeight)
                .accessibilityIdentifier("settings.aiDiagnostics.link")
            }

            Section("关于") {
                LabeledContent("版本", value: appVersion)
                    .accessibilityIdentifier("settings.about.version")
                Text("Kitchen Manager 仅在你主动使用导入或 AI 功能时发送必要内容。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // The destructive action gets its own section, last, so it never sits
            // beside an ordinary setting like 备份与恢复 and cannot be tapped by
            // aiming for a neighbouring row. Confirmation flow is unchanged.
            Section {
                Button("清除全部本地数据", role: .destructive) {
                    isShowingClearDataAlert = true
                }
                .frame(minHeight: ChromeMetrics.minimumRowHeight)
                .accessibilityIdentifier("settings.cleardata.button")
            } footer: {
                Text("此操作无法撤销，且不会影响远端菜谱库。")
            }

            #if DEBUG
            if syncSmokeController.isAvailable {
                Section("开发者") {
                    Text("当前使用内置 AI 与 Render 后端；技术配置不在正式版本显示。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Run Sync Smoke") { isShowingSyncSmokeConfirmation = true }
                        .disabled(syncSmokeController.isRunning)
                    if syncSmokeController.isRunning {
                        ProgressView("Running development sync smoke…")
                    }
                    if let message = syncSmokeController.statusMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("sync-smoke-status")
                    }
                }
            }
            #endif
        }
        // One Settings-level inset so the destructive row and the About footer can
        // come to rest above the floating tab bar instead of under it.
        .safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(height: ChromeMetrics.bottomClearance)
                .accessibilityHidden(true)
        }
        .navigationTitle("我的")
        .alert("无法开启到期提醒", isPresented: $isShowingPermissionDeniedAlert) {
            Button("前往设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请在系统设置中允许 Kitchen Manager 发送通知。")
        }
        .alert("清除全部本地数据？", isPresented: $isShowingClearDataAlert) {
            Button("清除", role: .destructive) {
                store.clearAllLocalData()
                recipeStore.clearLocalData()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会删除本机的库存、常备设置、计划、买菜清单、用户菜谱、收藏和常做记录，无法撤销。远端菜谱库不会被删除。")
        }
        #if DEBUG
        .alert("Run Sync Smoke?", isPresented: $isShowingSyncSmokeConfirmation) {
            Button("Run", role: .destructive) {
                Task {
                    await syncSmokeController.run(
                        authStore: authStore,
                        kitchenStore: store,
                        recipeStore: recipeStore
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will create development test data in Supabase")
        }
        #endif
    }

    private func handleNotificationsToggle(_ newValue: Bool) {
        guard newValue else {
            notificationsEnabled = false
            rescheduleNotifications()
            return
        }
        Task {
            let granted = await ExpiryNotificationScheduler.requestAuthorizationIfNeeded()
            await MainActor.run {
                notificationsEnabled = granted
                if granted {
                    rescheduleNotifications()
                } else {
                    isShowingPermissionDeniedAlert = true
                }
            }
        }
    }

    private func rescheduleNotifications() {
        var leadTimes: Set<ExpiryNotificationLeadTime> = []
        guard notificationsEnabled else {
            ExpiryNotificationScheduler.rescheduleAll(for: store.inventory, leadTimes: [])
            return
        }
        if notifyLeadTime1Day { leadTimes.insert(.oneDayBefore) }
        if notifyLeadTime3Day { leadTimes.insert(.threeDaysBefore) }
        if notifyLeadTimeDayOf { leadTimes.insert(.dayOf) }
        ExpiryNotificationScheduler.rescheduleAll(for: store.inventory, leadTimes: leadTimes)
    }

    private func handleStapleNotificationsToggle(_ enabled: Bool) {
        guard enabled else {
            stapleNotificationsEnabled = false
            PantryRestockNotificationScheduler.sync(for: store.inventory)
            return
        }
        Task {
            let granted = await ExpiryNotificationScheduler.requestAuthorizationIfNeeded()
            await MainActor.run {
                stapleNotificationsEnabled = granted
                if granted {
                    PantryRestockNotificationScheduler.sync(for: store.inventory)
                } else {
                    isShowingPermissionDeniedAlert = true
                }
            }
        }
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }
}

struct BackupRestoreView: View {
    @EnvironmentObject private var store: KitchenStore
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var exportDocument = KitchenBackupDocument()
    @State private var message: String?

    var body: some View {
        List {
            Section("备份与恢复") {
                Button("导出厨房备份", systemImage: "square.and.arrow.up") {
                    do {
                        exportDocument = KitchenBackupDocument(data: try store.exportBackupData())
                        isExporting = true
                    } catch {
                        message = "暂时无法生成备份。"
                    }
                }
                Button("导入厨房备份", systemImage: "square.and.arrow.down") {
                    isImporting = true
                }
            }
            Section {
                Text("备份包含库存、常备规则、计划、购物清单和消耗记录。导入会替换当前厨房数据。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("备份与恢复")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "KitchenManager-Backup"
        ) { result in
            if case .failure = result { message = "备份导出没有完成。" }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                try store.restoreBackupData(Data(contentsOf: url))
                message = "厨房数据已恢复。"
            } catch {
                message = error.localizedDescription
            }
        }
        .alert("备份与恢复", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) { Button("好", role: .cancel) {} } message: { Text(message ?? "") }
    }
}

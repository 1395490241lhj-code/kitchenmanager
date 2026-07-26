import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Shared presentation limits for the Inventory screen's *chrome* only — the
/// navigation title, availability summary, section headers, filter menu, and
/// toolbar glyphs. Food names, quantities, and status text keep unrestricted
/// Dynamic Type; without these caps an Accessibility XXXL first screen is
/// consumed entirely by headings before a single ingredient is readable.
enum InventoryChromeMetrics {
    /// Availability summary: still clearly enlarged, but bounded so the
    /// overview can never outgrow the list it summarizes.
    static let summaryTypeLimit = DynamicTypeSize.accessibility1
    /// Section headers and the staple filter stay at a heading/body weight
    /// rather than scaling into display-title territory.
    static let headerTypeLimit = DynamicTypeSize.accessibility1
    /// Symbols (row status glyph, toolbar icons) grow with text up to this
    /// point and then hold, so they stay inside their 44pt hit targets.
    static let symbolTypeLimit = DynamicTypeSize.xxLarge
    /// Clearance for the floating (iOS 26) tab bar, so the final row, the staple
    /// empty-state text, and any CTA come to rest fully above the bar in its
    /// *expanded* state — `.tabBarMinimizeBehavior(.onScrollDown)` shrinks it
    /// while scrolling, and sizing for the shrunken bar leaves content covered
    /// once it expands again. Added once in the bottom safe area, never per row,
    /// and a fixed inset rather than a screen-height calculation.
    static let bottomClearance: CGFloat = 72
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
    @State private var stapleFilter: PantryStapleFilter = .all
    @State private var itemPendingDeletion: InventoryItem?
    @State private var searchText = ""

    private var restockSuggestions: [RestockSuggestion] {
        RestockSuggestionEngine().generate(kitchenStore: store, recipeStore: recipeStore)
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
            if navigationStore.inventoryFocus != .all {
                Section {
                    LabeledContent {
                        Button("清除") { navigationStore.inventoryFocus = .all }
                            .buttonStyle(.borderless)
                    } label: {
                        Label("正在查看：\(navigationStore.inventoryFocus.title)", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .font(.subheadline)
                    .accessibilityElement(children: .contain)
                }
            }

            if !hasSearchQuery && !store.inventory.isEmpty {
                Section {
                    InventorySummaryRow(
                        availableCount: store.availableInventory.count,
                        expiringCount: store.expiringItems.count,
                        lowStockCount: store.inventory.filter {
                            $0.stapleStatus == .low || $0.stapleStatus == .outOfStock
                        }.count
                    )
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                }
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
                                InventoryFoodCard(item: item)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("inventory.item.\(item.id.uuidString)")
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("删除", role: .destructive) {
                                    itemPendingDeletion = item
                                }
                            }
                        }
                    } header: {
                        InventorySectionHeader(title: "食材", count: displayedFreshInventory.count)
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
                            InventorySectionHeader(title: "常备食材", count: displayedStaples.count)
                            Spacer()
                            Menu {
                                Picker("筛选", selection: $stapleFilter) {
                                    ForEach(PantryStapleFilter.allCases) { Text($0.rawValue).tag($0) }
                                }
                            } label: {
                                Text(stapleFilter.rawValue)
                                    .font(.subheadline)
                                    .dynamicTypeSize(...InventoryChromeMetrics.headerTypeLimit)
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
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("inventory.staple.empty.add.button")
                    }
                }

                if !hasSearchQuery && !restockSuggestions.isEmpty {
                    Section("补货建议") {
                        ForEach(restockSuggestions) { suggestion in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(suggestion.name)
                                    Text(suggestion.reason)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 12)
                                Button("加入清单") {
                                    addSuggestion(suggestion)
                                }
                                .buttonStyle(.borderless)
                            }
                            .frame(minHeight: 44)
                        }
                        let stapleSuggestions = restockSuggestions.filter { $0.source == .pantryStaple }
                        if !stapleSuggestions.isEmpty {
                            Button {
                                stapleSuggestions.forEach(addSuggestion)
                            } label: {
                                Label("加入 \(stapleSuggestions.count) 项常备补货", systemImage: "cart.badge.plus")
                            }
                            .buttonStyle(.borderless)
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
        }
        .listStyle(.insetGrouped)
        // One list-level clearance for the floating tab bar, rather than padding
        // each row: an empty spacer in the bottom safe area, so the last
        // ingredient, the staple empty-state text and CTA, and the final search
        // result can all come to rest fully above the expanded bar.
        .safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(height: InventoryChromeMetrics.bottomClearance)
                .accessibilityHidden(true)
        }
        .navigationTitle("食材")
        // Large title at normal sizes; at Accessibility sizes it would take
        // most of the first screen, so it collapses to the inline title — still
        // a VoiceOver heading, never truncated or scale-compressed.
        .navigationBarTitleDisplayMode(dynamicTypeSize.isAccessibilitySize ? .inline : .large)
        // Placement is explicit at Accessibility sizes. With `.automatic` and an
        // inline title, UIKit pins the search bar to a fixed ~63pt that cannot
        // fit Accessibility XXXL text, so the magnifier and the "搜索食材" prompt
        // were clipped away and the bar rendered as an empty grey capsule.
        // `.navigationBarDrawer(displayMode: .always)` lets the drawer size to its
        // content (~124pt at XXXL) so both actually draw. Normal sizes keep
        // `.automatic` — the standard hidden-until-pulled-down behavior.
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
                .dynamicTypeSize(...InventoryChromeMetrics.symbolTypeLimit)
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
                } label: {
                    // Clamp the glyph only — the menu's own rows keep full
                    // Dynamic Type.
                    Label("更多食材操作", systemImage: "ellipsis.circle")
                        .dynamicTypeSize(...InventoryChromeMetrics.symbolTypeLimit)
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
}

private struct InventoryNoticeOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let notice: String
    let onDismiss: () -> Void

    var body: some View {
        AppFeedbackView(
            message: notice,
            style: InventoryNoticePresentation.style(for: notice)
        )
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 12)
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
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
        .background(Color(.systemGroupedBackground))
}

#Preview("库存提示 — 错误") {
    InventoryNoticeOverlay(notice: "库存保存失败，请稍后重试。", onDismiss: {})
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(Color(.systemGroupedBackground))
}

#Preview("库存提示 — 深色") {
    InventoryNoticeOverlay(notice: "库存保存失败，请稍后重试。", onDismiss: {})
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(Color(.systemGroupedBackground))
        .preferredColorScheme(.dark)
}

#Preview("库存提示 — 辅助功能大字号") {
    InventoryNoticeOverlay(notice: "库存保存失败，请稍后重试。", onDismiss: {})
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding()
        .background(Color(.systemGroupedBackground))
        .dynamicTypeSize(.accessibility3)
}

private struct InventorySummaryRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let availableCount: Int
    let expiringCount: Int
    let lowStockCount: Int

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    primaryCount
                    secondaryStatus
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    primaryCount
                    Spacer(minLength: 12)
                    secondaryStatus
                }
            }
        }
        .frame(minHeight: 44)
        // The summary is a derived overview of the sections below it, so it is
        // capped: still visibly enlarged, but it cannot push the ingredients it
        // describes off the first screen.
        .dynamicTypeSize(...InventoryChromeMetrics.summaryTypeLimit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summaryAccessibilityLabel)
    }

    /// Number stays the prominent element and the "在库" label stays secondary.
    /// At Accessibility sizes the pair stacks so neither has to shrink, and the
    /// count drops from `.title3` to `.headline` so only one level of the
    /// summary reads as a heading.
    @ViewBuilder
    private var primaryCount: some View {
        let count = Text("\(availableCount) 项")
            .font((dynamicTypeSize.isAccessibilitySize ? Font.headline : Font.title3).weight(.semibold))
            .monospacedDigit()
        let caption = Text("在库")
            .font(.subheadline)
            .foregroundStyle(.secondary)

        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                count
                caption
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                count
                caption
            }
        }
    }

    @ViewBuilder
    private var secondaryStatus: some View {
        if expiringCount > 0 {
            Label("\(expiringCount) 项即将到期", systemImage: "calendar.badge.exclamationmark")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        } else if lowStockCount > 0 {
            Label("\(lowStockCount) 项需补货", systemImage: "cart.badge.minus")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var summaryAccessibilityLabel: String {
        var values = ["\(availableCount) 项食材在库"]
        if expiringCount > 0 { values.append("\(expiringCount) 项即将到期") }
        if lowStockCount > 0 { values.append("\(lowStockCount) 项需要补货") }
        return values.joined(separator: "，")
    }
}

private struct InventorySectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(count) 项")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.subheadline.weight(.semibold))
        .textCase(nil)
        // Headers stay at a heading weight instead of scaling into display-title
        // sizes that would dwarf the rows beneath them.
        .dynamicTypeSize(...InventoryChromeMetrics.headerTypeLimit)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct InventoryFoodCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let item: InventoryItem

    private var statusText: String {
        item.isAvailable ? item.expiryStatusText : "缺货 · \(item.expiryStatusText)"
    }

    private var statusColor: Color {
        item.isAvailable ? item.expiryStatus.color : .red
    }

    private var statusSymbol: String {
        if !item.isAvailable { return "exclamationmark.circle.fill" }
        return switch item.expiryStatus {
        case .expired: "xmark.circle.fill"
        case .today, .soon: "calendar.badge.exclamationmark"
        case .upcoming: "calendar"
        case .normal: "checkmark.circle"
        case .unknown: "calendar.badge.questionmark"
        }
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                accessibilityLayout
            } else {
                standardLayout
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name)，\(item.quantity.formatted()) \(item.unit)，\(statusText)")
        .accessibilityHint("打开食材详情")
    }

    private var standardLayout: some View {
        HStack(alignment: .center, spacing: 12) {
            statusIcon
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    statusLabel
                }
                Spacer(minLength: 12)
                // Higher layout priority so a long ingredient name wraps rather
                // than squeezing the quantity out of the row.
                quantityLabel.layoutPriority(1)
            }
        }
    }

    /// One unambiguous vertical order at Accessibility sizes: name, then expiry
    /// status, then quantity — all left-aligned in a single column beside the
    /// icon. Nothing is pushed to the trailing edge, so the quantity can never be
    /// squeezed into a narrow column or wrapped onto an unrelated line. Every
    /// string keeps unrestricted Dynamic Type: no `lineLimit(1)`, no
    /// `minimumScaleFactor` — the row just grows taller.
    private var accessibilityLayout: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
            VStack(alignment: .leading, spacing: 6) {
                Text(item.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                statusLabel
                quantityLabel
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusIcon: some View {
        Image(systemName: statusSymbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(statusColor)
            // Glyph tracks text size up to a limit and then holds, so it stays
            // inside its fixed slot instead of crowding out the food name.
            .dynamicTypeSize(...InventoryChromeMetrics.symbolTypeLimit)
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
    }

    private var statusLabel: some View {
        Text(statusText)
            .font(.footnote)
            .foregroundStyle(statusColor)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .accessibilityHidden(true)
    }

    private var quantityLabel: some View {
        Text("\(item.quantity.formatted()) \(item.unit)")
            .font(.body.weight(.medium))
            .foregroundStyle(.primary)
            .monospacedDigit()
            // Trailing only in the default side-by-side layout; at Accessibility
            // sizes the quantity is a left-aligned line in the main column.
            .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
            .accessibilityHidden(true)
    }
}

struct ShoppingView: View {
    @EnvironmentObject private var store: KitchenStore
    @EnvironmentObject private var navigationStore: AppNavigationStore
    @State private var isShowingStockInConfirm = false
    @State private var isShowingAddItem = false
    @State private var isShowingClearPurchasedConfirm = false
    @State private var searchText = ""
    @State private var isPurchasedExpanded = false
    @State private var isShoppingMode = false

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
            Section {
                HStack(spacing: 16) {
                    ShoppingSummaryValue(
                        value: summary.pendingCount,
                        title: "待购买",
                        systemImage: "cart",
                        accessibilityIdentifier: "shopping.summary.pending"
                    )

                    ShoppingSummaryValue(
                        value: summary.purchasedCount,
                        title: "已购买",
                        systemImage: "checkmark.circle",
                        accessibilityIdentifier: "shopping.summary.purchased"
                    )

                    ShoppingSummaryValue(
                        value: summary.categoryCount,
                        title: "分类",
                        systemImage: "square.grid.2x2",
                        accessibilityIdentifier: "shopping.summary.categories"
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
            }

            if store.shoppingItems.isEmpty {
                Section("待买") {
                    ContentUnavailableView(
                        "买菜清单是空的",
                        systemImage: "checklist",
                        description: Text("今日计划缺少的食材和手动添加的项目会出现在这里。")
                    )
                    .accessibilityIdentifier("shopping.empty")
                }
            } else if hasSearchQuery && !hasSearchResults {
                Section {
                    ContentUnavailableView.search(text: searchText)
                        .accessibilityIdentifier("shopping.search.empty")
                }
            } else {
                ForEach(pendingSections, id: \.0) { category, items in
                    Section(category.rawValue) {
                    ForEach(items) { item in
                        Button { store.toggleShopping(item) } label: {
                            HStack {
                                Image(systemName: "circle")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                    if item.source != "手动添加" {
                                        Text(item.source)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text("\(item.quantity.formatted()) \(item.unit)").foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
                .accessibilityIdentifier("shopping.section.\(category.id)")
                }
            }

            if !store.shoppingItems.filter(\.isDone).isEmpty {
                Section {
                    Button {
                        isPurchasedExpanded.toggle()
                    } label: {
                        HStack {
                            Label("已购买", systemImage: "checkmark.circle.fill")
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
                                Label(item.name, systemImage: "checkmark.circle.fill")
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }
        }
        .navigationTitle("买菜")
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "搜索买菜项目"
        )
        .accessibilityIdentifier("shopping.search")
    }

    private var shoppingModeList: some View {
        List {
            Section {
                HStack {
                    Label("购物模式", systemImage: "cart.fill")
                        .font(.title3.bold())
                    Spacer()
                    Text(shoppingMode.isCompleted ? "已全部买齐" : "剩余 \(shoppingMode.remainingCount) 项")
                        .foregroundStyle(shoppingMode.isCompleted ? .green : .secondary)
                        .accessibilityIdentifier("shopping.mode.remaining")
                }
            }

            if shoppingMode.isEmpty {
                ContentUnavailableView("买菜清单是空的", systemImage: "checklist")
            } else if shoppingMode.isCompleted {
                ContentUnavailableView("已全部买齐", systemImage: "checkmark.circle.fill")
                    .accessibilityIdentifier("shopping.mode.completed")
            } else {
                ForEach(ShoppingListPresentation.sections(items: store.shoppingItems, query: ""), id: \.0) { category, items in
                    Section("\(category.rawValue) · \(items.count) 项") {
                        ForEach(items) { item in
                            Button { store.toggleShopping(item) } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "circle")
                                        .font(.title3)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.name).font(.title3.weight(.semibold))
                                        Text("\(item.quantity.formatted()) \(item.unit)")
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 8)
                            }
                            .foregroundStyle(.primary)
                            .accessibilityLabel("\(item.name)，\(item.quantity.formatted()) \(item.unit)，未购买")
                            .accessibilityHint("双击切换购买状态")
                        }
                    }
                }
            }

            let completed = ShoppingListPresentation.purchasedItems(items: store.shoppingItems, query: "")
            if !completed.isEmpty {
                Section("已购买 · \(completed.count) 项") {
                    ForEach(completed) { item in
                        Button { store.toggleShopping(item) } label: {
                            Label(item.name, systemImage: "checkmark.circle.fill")
                                .strikethrough()
                        }
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(item.name)，已购买")
                        .accessibilityHint("双击取消购买状态")
                    }
                }
            }
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
        .onAppear(perform: presentRequestedStockInIfNeeded)
        .onChange(of: navigationStore.isShoppingStockInRequested) { _, isRequested in
            if isRequested { presentRequestedStockInIfNeeded() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if isShoppingMode {
                    Button("退出", systemImage: "xmark") { isShoppingMode = false }
                        .accessibilityIdentifier("shopping.mode.exit")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(isShoppingMode ? "普通模式" : "购物模式", systemImage: isShoppingMode ? "list.bullet" : "cart") {
                    isShoppingMode.toggle()
                }
                .disabled(!isShoppingMode && store.shoppingItems.isEmpty)
                .accessibilityIdentifier("shopping.mode.toggle")
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
                }
                .accessibilityIdentifier("shopping.bulk.menu")
                .accessibilityLabel("购物清单批量操作")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button("添加", systemImage: "plus") { isShowingAddItem = true }
                    .accessibilityLabel("添加买菜项目")
            }
            }
        }
        .sheet(isPresented: $isShowingAddItem) {
            AddShoppingItemView()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .alert("全部入库？", isPresented: $isShowingStockInConfirm) {
            Button("入库", role: .destructive) { store.stockInCompletedShopping() }
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
}

private struct ShoppingSummaryValue: View {
    let value: Int
    let title: String
    let systemImage: String
    let accessibilityIdentifier: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(value, format: .number)
                    .font(.headline)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
        }
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel("\(title) \(value) 项")
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

struct SettingsView: View {
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
            Section("账号") {
                switch authStore.status {
                case .guest:
                    NavigationLink {
                        AuthEntryView()
                    } label: {
                        LabeledContent("游客模式", value: "登录或创建账号")
                    }
                    Text("无需登录即可继续使用全部本机功能。登录后可为未来跨设备同步做准备，并可选择将本机库存合并到家庭云端；购物清单、计划和菜谱仍只保存在本机。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let message = authStore.errorMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                case .signedIn(let user):
                    NavigationLink {
                        AccountView()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(user.email ?? "已登录账号")
                            Text("管理账号与家庭")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("外观") {
                Picker("显示模式", selection: appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
            }

            Section("菜谱") {
                Picker("菜谱库模式", selection: Binding(
                    get: { recipeStore.libraryMode },
                    set: { mode in Task { await recipeStore.reload(mode: mode) } }
                )) {
                    ForEach(RecipeLibraryMode.allCases) { Text($0.title).tag($0) }
                }
                if let message = recipeStore.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("食材到期提醒", isOn: Binding(
                    get: { notificationsEnabled },
                    set: { handleNotificationsToggle($0) }
                ))
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

                NavigationLink {
                    PantryStaplesView()
                } label: {
                    Text("管理常备货架")
                }
            } header: {
                Text("提醒")
            } footer: {
                Text("首次开启提醒时，会请求系统通知权限。")
            }
            .onChange(of: notifyLeadTime1Day) { _, _ in rescheduleNotifications() }
            .onChange(of: notifyLeadTime3Day) { _, _ in rescheduleNotifications() }
            .onChange(of: notifyLeadTimeDayOf) { _, _ in rescheduleNotifications() }

            Section("数据") {
                NavigationLink("备份与恢复", destination: BackupRestoreView())
                Button("清除全部本地数据", role: .destructive) { isShowingClearDataAlert = true }
            }

            Section("关于") {
                LabeledContent("版本", value: appVersion)
                Text("Kitchen Manager 仅在你主动使用导入或 AI 功能时发送必要内容。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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

import SwiftUI
import UIKit

private enum HomeSheet: Identifiable {
    case smartImport
    case expiry
    case shopping

    var id: String {
        switch self {
        case .smartImport: "smart-import"
        case .expiry: "expiry"
        case .shopping: "shopping"
        }
    }
}

struct HomeView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var recipeStore: RecipeStore
    @EnvironmentObject private var kitchenStore: KitchenStore
    @EnvironmentObject private var navigationStore: AppNavigationStore
    @EnvironmentObject private var recommendationStore: HomeRecommendationStore
    @EnvironmentObject private var authStore: AuthStore

    @State private var activeSheet: HomeSheet?
    @State private var toastMessage: String?
    @State private var isShowingTodayPlan = false
    @State private var isShowingRecommendations = false

    private var sourceRecipes: [Recipe] {
        recipeStore.recipes.isEmpty ? Recipe.samples : recipeStore.recipes
    }

    private var dashboard: HomeDashboardSummary {
        HomeDashboardSummary(
            inventory: kitchenStore.inventory,
            todayPlans: kitchenStore.todayPlans,
            shoppingItems: kitchenStore.shoppingItems
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HomeDashboardHeader(
                    displayName: displayName,
                    householdName: householdName,
                    isRestoringAccount: authStore.activity == .restoring
                )

                TodayPlanSummaryCard(
                    dashboard: dashboard,
                    primaryAction: dashboard.primaryAction,
                    onPrimaryAction: performPrimaryAction,
                    onViewPlan: { isShowingTodayPlan = true }
                )

                if let reminder = dashboard.highestPriorityReminder {
                    HomeAttentionReminderRow(reminder: reminder) {
                        handleReminder(reminder)
                    }
                }

                HomeModuleIssues(
                    issues: HomeDashboardModuleIssue.issues(
                        inventoryNotice: kitchenStore.inventoryNotice,
                        shoppingNotice: kitchenStore.shoppingNotice
                    ),
                    action: { issue in
                        switch issue {
                        case .inventory: navigationStore.showInventory(.all)
                        case .shopping: navigationStore.selectedTab = .shopping
                        }
                    }
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("首页")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    activeSheet = .smartImport
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("home.import.add.button")
                .accessibilityLabel("添加食材")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("添加今日菜品", systemImage: "calendar.badge.plus") { isShowingRecommendations = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityIdentifier("home.add.menu")
                .accessibilityLabel("更多操作")
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    navigationStore.selectedTab = .settings
                } label: {
                    Image(systemName: "person.crop.circle")
                }
                .accessibilityIdentifier("home.settings.button")
                .accessibilityLabel("账号与设置")
            }
        }
        .navigationDestination(isPresented: $isShowingTodayPlan) {
            TodayPlanDetailView()
        }
        .navigationDestination(isPresented: $isShowingRecommendations) {
            RecipeRecommendationBrowserView()
        }
        .sheet(item: $activeSheet) { sheet in
            sheetContent(sheet)
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 14))
                    .padding(.bottom, 18)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: HomeSheet) -> some View {
        switch sheet {
        case .smartImport:
            SmartImportSheet {
                activeSheet = nil
                showToast("已保存到菜谱库")
            }
        case .expiry:
            ExpirySheet { item in
                activeSheet = nil
                recommendationStore.searchQuery = item.name
                isShowingRecommendations = true
                Task {
                    await recommendationStore.searchRecommendations(
                        recipes: sourceRecipes,
                        inventory: kitchenStore.availableInventory.map(\.name),
                        expiringIngredients: kitchenStore.expiringItems.map(\.name)
                    )
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        case .shopping:
            PendingShoppingSheet {
                activeSheet = nil
                navigationStore.selectedTab = .shopping
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var displayName: String? {
        authStore.account?.user.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyHome
    }

    private var householdName: String? {
        authStore.account?.households.first?.name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyHome
    }

    private func showToast(_ message: String) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { toastMessage = message }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            await MainActor.run {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { toastMessage = nil }
            }
        }
    }

    private func performPrimaryAction() {
        switch dashboard.primaryAction {
        case .stockInPurchased:
            navigationStore.showShoppingStockIn()
        case .addTodayPlan:
            isShowingRecommendations = true
        case .viewTodayPlan:
            isShowingTodayPlan = true
        case .browseRecipes:
            navigationStore.selectedTab = .recipes
        }
    }

    private func handleReminder(_ reminder: HomeAttentionReminder) {
        switch reminder {
        case .purchasedAwaitingStockIn:
            navigationStore.showShoppingStockIn()
        case .expiredInventory:
            navigationStore.showInventory(.expired)
        case .expiringInventory:
            navigationStore.showInventory(.expiringSoon)
        case .pendingShopping:
            navigationStore.selectedTab = .shopping
        case .lowStock:
            navigationStore.showInventory(.lowStock)
        }
    }
}

// MARK: - Dashboard V2

private struct HomeDashboardHeader: View {
    let displayName: String?
    let householdName: String?
    let isRestoringAccount: Bool

    private var model: HomeDashboardHeaderModel {
        HomeDashboardHeaderModel(displayName: displayName, householdName: householdName)
    }

    private var dateText: String {
        Date.now.formatted(.dateTime.weekday(.wide).month().day())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(dateText)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(model.title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            if model.shouldShowHousehold, let householdName {
                Label(householdName, systemImage: "person.2")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if isRestoringAccount {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在恢复账号…")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("home.auth.restoring")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home.dashboard.header")
    }
}

private struct TodayPlanSummaryCard: View {
    let dashboard: HomeDashboardSummary
    let primaryAction: HomePrimaryAction
    let onPrimaryAction: () -> Void
    let onViewPlan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("今日计划")
                    .font(.headline)
                Spacer(minLength: 12)
                if dashboard.totalPlanCount > 0 {
                    Text(planProgressText)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            switch dashboard.todayPlanState {
            case .empty:
                VStack(alignment: .leading, spacing: 6) {
                    Label("今天还没有计划", systemImage: "calendar.badge.plus")
                        .font(.title3.weight(.semibold))
                    Text("先选一道想做的菜，晚些时候就不用再纠结。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            case .active, .partial, .completed:
                ForEach(dashboard.displayedPlans) { plan in
                    HStack(spacing: 12) {
                        Image(systemName: plan.isCooked ? "checkmark.circle" : "fork.knife.circle.fill")
                            .foregroundStyle(plan.isCooked ? Color.secondary : AppTheme.primary)
                            .font(.title3)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plan.recipeName)
                                .font(plan.isCooked ? .body : .headline)
                                .foregroundStyle(plan.isCooked ? .secondary : .primary)
                                .lineLimit(2)
                            Text(plan.isCooked ? "已完成" : "\(plan.servings) 人份")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(plan.recipeName)，\(plan.isCooked ? "已完成" : "\(plan.servings) 人份，未完成")")
                }
                if dashboard.additionalPlanCount > 0 {
                    Text("还有 \(dashboard.additionalPlanCount) 道菜")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: onPrimaryAction) {
                Text(primaryActionTitle)
                    .frame(maxWidth: .infinity)
            }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.primary)
                .controlSize(.large)
                .accessibilityIdentifier("home.primary.action.button")

            if dashboard.totalPlanCount > 0, primaryAction != .viewTodayPlan {
                Button("查看今日计划", action: onViewPlan)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("home.today.plan.viewAll")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            dashboard.todayPlanState == .completed
                ? Color(uiColor: .secondarySystemGroupedBackground)
                : Color(uiColor: .systemBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }

    private var planProgressText: String {
        switch dashboard.todayPlanState {
        case .empty: ""
        case .active: "\(dashboard.totalPlanCount) 道待完成"
        case .partial: "已完成 \(dashboard.completedPlanCount)/\(dashboard.totalPlanCount)"
        case .completed: "已全部完成"
        }
    }

    private var primaryActionTitle: String {
        switch primaryAction {
        case .stockInPurchased: "完成入库"
        case .addTodayPlan: "添加今日菜品"
        case .viewTodayPlan: "查看今日计划"
        case .browseRecipes: "浏览菜谱"
        }
    }
}

private struct HomeAttentionReminderRow: View {
    let reminder: HomeAttentionReminder
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("需要留意")
                .font(.headline)
            Button(action: action) {
                HStack(spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.title3)
                        .foregroundStyle(tint)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)
            .accessibilityLabel("\(title)，\(subtitle)")
            .accessibilityHint("双击查看并处理")
        }
        .padding(.horizontal, 2)
    }

    private var title: String {
        switch reminder {
        case .purchasedAwaitingStockIn(let count): "\(count) 项已购买食材等待入库"
        case .expiredInventory(let count): "\(count) 项食材已过期"
        case .expiringInventory(let count): "\(count) 项食材即将到期"
        case .pendingShopping(let count): "买菜清单还有 \(count) 项未完成"
        case .lowStock(let count): "\(count) 项常备食材库存不足"
        }
    }

    private var subtitle: String {
        switch reminder {
        case .purchasedAwaitingStockIn: "确认后计入现有库存"
        case .expiredInventory: "查看并处理已过期食材"
        case .expiringInventory: "优先安排使用这些食材"
        case .pendingShopping: "继续完成本次买菜清单"
        case .lowStock: "查看需要补充的常备食材"
        }
    }

    private var systemImage: String {
        switch reminder {
        case .purchasedAwaitingStockIn: "shippingbox.fill"
        case .expiredInventory: "exclamationmark.circle.fill"
        case .expiringInventory: "clock.fill"
        case .pendingShopping: "cart.fill"
        case .lowStock: "shippingbox"
        }
    }

    private var tint: Color {
        switch reminder {
        case .purchasedAwaitingStockIn: AppTheme.primary
        case .expiredInventory: .red
        case .expiringInventory: AppTheme.warning
        case .pendingShopping: AppTheme.primary
        case .lowStock: .orange
        }
    }

    private var identifier: String {
        switch reminder {
        case .purchasedAwaitingStockIn: "home.shopping.stockIn.button"
        case .expiredInventory: "home.inventory.expired.button"
        case .expiringInventory: "home.inventory.expiring.button"
        case .pendingShopping: "home.shopping.pending.button"
        case .lowStock: "home.inventory.lowstock.button"
        }
    }
}

private struct HomeModuleIssues: View {
    let issues: [HomeDashboardModuleIssue]
    let action: (HomeDashboardModuleIssue) -> Void

    var body: some View {
        ForEach(issues, id: \.self) { issue in
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppTheme.warning)
                    .accessibilityHidden(true)
                Text(issue.title)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier(issue == .inventory ? "home.issue.inventory" : "home.issue.shopping")
                Spacer(minLength: 8)
                Button(issue.actionTitle) { action(issue) }
                    .font(.footnote.weight(.semibold))
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

#Preview("今日计划") {
    TodayPlanSummaryCard(
        dashboard: HomeDashboardSummary(
            inventory: [],
            todayPlans: [
                MealPlanItem(recipeID: "1", recipeName: "番茄炒蛋", servings: 2),
                MealPlanItem(recipeID: "2", recipeName: "清炒时蔬", servings: 1),
                MealPlanItem(recipeID: "3", recipeName: "紫菜蛋花汤", servings: 3, isCooked: true)
            ],
            shoppingItems: []
        ),
        primaryAction: .viewTodayPlan,
        onPrimaryAction: {},
        onViewPlan: {}
    )
    .padding()
    .background(Color(.systemGroupedBackground))
}

#Preview("空首页") {
    VStack(alignment: .leading, spacing: 28) {
        HomeDashboardHeader(displayName: nil, householdName: nil, isRestoringAccount: false)
        TodayPlanSummaryCard(
            dashboard: HomeDashboardSummary(inventory: [], todayPlans: [], shoppingItems: []),
            primaryAction: .addTodayPlan,
            onPrimaryAction: {},
            onViewPlan: {}
        )
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}

#Preview("深色模式") {
    HomeAttentionReminderRow(reminder: .expiringInventory(count: 2), action: {})
    .padding()
    .background(Color(.systemGroupedBackground))
    .preferredColorScheme(.dark)
}

#Preview("辅助功能大字号") {
    TodayPlanSummaryCard(
        dashboard: HomeDashboardSummary(
            inventory: [],
            todayPlans: [MealPlanItem(recipeID: "1", recipeName: "家常豆腐", servings: 2)],
            shoppingItems: []
        ),
        primaryAction: .viewTodayPlan,
        onPrimaryAction: {},
        onViewPlan: {}
    )
    .padding()
    .dynamicTypeSize(.accessibility3)
}

private extension String {
    var nilIfEmptyHome: String? { isEmpty ? nil : self }
}

// MARK: - Smart import

private enum SmartImportRoute: Hashable {
    case xiaohongshu
    case manualRecipe
}

private enum SmartImportChildSheet: String, Identifiable {
    case receipt
    case manualIngredient
    var id: String { rawValue }
}

struct SmartImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path = NavigationPath()
    @State private var childSheet: SmartImportChildSheet?
    var onRecipeSaved: () -> Void

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("菜谱") {
                    NavigationLink(value: SmartImportRoute.xiaohongshu) {
                        SmartImportRow(
                            title: "从小红书导入菜谱",
                            subtitle: "粘贴链接，智能提取食材与步骤",
                            systemImage: "sparkles.rectangle.stack.fill",
                            isPrimary: true
                        )
                    }
                    .accessibilityIdentifier("home.import.recipe.xiaohongshu")
                    NavigationLink(value: SmartImportRoute.manualRecipe) {
                        SmartImportRow(
                            title: "手动创建菜谱",
                            subtitle: "记录自己的菜谱",
                            systemImage: "square.and.pencil",
                            isPrimary: false
                        )
                    }
                    .accessibilityIdentifier("home.import.recipe.manual")
                }

                Section("食材") {
                    Button { childSheet = .receipt } label: {
                        SmartImportRow(
                            title: "扫描购物小票",
                            subtitle: "拍照智能识别商品并加入库存",
                            systemImage: "camera.viewfinder",
                            isPrimary: true
                        )
                    }
                    .accessibilityIdentifier("home.import.food.receipt")
                    Button { childSheet = .manualIngredient } label: {
                        SmartImportRow(
                            title: "手动添加食材",
                            subtitle: "快速记录食材库存",
                            systemImage: "shippingbox",
                            isPrimary: false
                        )
                    }
                    .accessibilityIdentifier("home.import.food.manual")
                }
            }
            .navigationTitle("导入与添加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
            .navigationDestination(for: SmartImportRoute.self) { route in
                switch route {
                case .xiaohongshu:
                    ImportRecipeView(onSaved: finishRecipeImport)
                case .manualRecipe:
                    ManualRecipeView()
                }
            }
            .sheet(item: $childSheet) { sheet in
                switch sheet {
                case .receipt:
                    RecordFoodSheet(initialMode: .receipt)
                case .manualIngredient:
                    RecordFoodSheet(initialMode: .manual)
                }
            }
        }
    }

    private func finishRecipeImport() {
        dismiss()
        onRecipeSaved()
    }
}

private struct SmartImportRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let isPrimary: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(isPrimary ? .white : AppTheme.textSecondary)
                .frame(width: 36, height: 36)
                .background(
                    isPrimary ? AppTheme.brand : AppTheme.textSecondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.subheadline.weight(isPrimary ? .semibold : .regular))
                        .foregroundStyle(.primary)
                    if isPrimary {
                        Text("智能")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(AppTheme.brand)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppTheme.brand.opacity(0.12), in: Capsule())
                    }
                }
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

// MARK: - Today plan detail (secondary page)

struct TodayPlanDetailView: View {
    @EnvironmentObject private var kitchenStore: KitchenStore
    @EnvironmentObject private var recipeStore: RecipeStore
    @State private var activeSheet: TodayPlanSheet?
    @State private var planPendingRemoval: MealPlanItem?
    @State private var isShowingWeeklyPlanner = false
    @State private var isShowingShoppingGeneration = false
    @State private var toastMessage: String?
    @State private var selectedRecipePlan: MealPlanItem?

    private enum TodayPlanSheet: Identifiable {
        case cook(MealPlanItem)
        case cookAll

        var id: String {
            switch self {
            case .cook(let plan): "cook-\(plan.id)"
            case .cookAll: "cook-all"
            }
        }
    }

    var body: some View {
        List {
            if kitchenStore.todayPlans.isEmpty {
                ContentUnavailableView {
                    Label("还没有安排今天吃什么", systemImage: "calendar.badge.plus")
                }
            } else {
                Section("今天 \(kitchenStore.todayPlans.count) 道菜") {
                    ForEach(kitchenStore.todayPlans) { plan in
                        HStack(spacing: 12) {
                            Button {
                                selectedRecipePlan = plan
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: plan.isCooked ? "checkmark.circle.fill" : "fork.knife.circle")
                                        .font(.title2)
                                        .foregroundStyle(plan.isCooked ? AppTheme.success : AppTheme.warning)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(plan.recipeName).font(.headline)
                                        Text(plan.isCooked ? "已完成" : "\(plan.servings) 人份 · 今天")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if !plan.isCooked { Button("做好了") { activeSheet = .cook(plan) }.font(.caption.bold()) }
                        }
                        .contextMenu {
                            Button("移出计划", role: .destructive) { planPendingRemoval = plan }
                        }
                    }
                }

                if !kitchenStore.pendingTodayPlans.isEmpty {
                    Section {
                        Button("全部做完", systemImage: "checkmark.circle") {
                            activeSheet = .cookAll
                        }
                    }
                }

                Section {
                    Button("生成今日购物清单", systemImage: "cart.badge.plus") {
                        isShowingShoppingGeneration = true
                    }
                }
            }

            Section {
                Button {
                    isShowingWeeklyPlanner = true
                } label: {
                    HStack {
                        Image(systemName: "calendar.badge.clock")
                            .foregroundStyle(AppTheme.success)
                        VStack(alignment: .leading) {
                            Text(kitchenStore.weeklyPlan == nil ? "规划本周菜单" : "查看本周计划")
                                .font(.subheadline.bold())
                            Text(weeklyPlanSubtitle)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .navigationTitle("今天的计划")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $isShowingWeeklyPlanner) {
            WeeklyMenuPlannerView()
        }
        .navigationDestination(isPresented: $isShowingShoppingGeneration) {
            ShoppingListGenerationView(source: .todayPlans(kitchenStore.todayPlans))
        }
        .navigationDestination(item: $selectedRecipePlan) { plan in
            if let recipe = recipeStore.recipes.first(where: { $0.id == plan.recipeID }) ?? Recipe.samples.first(where: { $0.id == plan.recipeID }) {
                RecipeDetailView(recipe: recipe, todayPlan: plan)
            } else {
                ContentUnavailableView("菜谱暂不可用", systemImage: "book.closed", description: Text("这份计划保留不变，可以稍后重试。"))
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .cook(let plan):
                CookConsumptionConfirmationView(
                    title: plan.recipeName,
                    planIDs: kitchenStore.hasConsumedPlan(plan.id) ? [] : [plan.id],
                    recipeID: plan.recipeID,
                    recipeName: plan.recipeName
                ) {
                    kitchenStore.markPlanCooked(plan)
                    showToast("已记录消耗，库存已更新")
                }
            case .cookAll:
                CookConsumptionConfirmationView(
                    title: "今日 \(kitchenStore.pendingTodayPlans.count) 道菜",
                    planIDs: kitchenStore.pendingTodayPlans
                        .map(\.id)
                        .filter { !kitchenStore.hasConsumedPlan($0) },
                    recipeID: nil,
                    recipeName: "今日 \(kitchenStore.pendingTodayPlans.count) 道菜"
                ) {
                    kitchenStore.markAllTodayCooked()
                    showToast("今天的计划已全部完成")
                }
            }
        }
        .alert(
            "移出计划？",
            isPresented: Binding(
                get: { planPendingRemoval != nil },
                set: { if !$0 { planPendingRemoval = nil } }
            ),
            presenting: planPendingRemoval
        ) { plan in
            Button("移出", role: .destructive) { kitchenStore.removePlan(plan) }
            Button("取消", role: .cancel) {}
        } message: { plan in
            Text("「\(plan.recipeName)」将从今天的计划中移出。")
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 14))
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var weeklyPlanSubtitle: String {
        guard let plan = kitchenStore.weeklyPlan else {
            return "按顿数、人数生成一周安排"
        }
        let dishCount = plan.days.reduce(0) { $0 + $1.meals.reduce(0) { $0 + $1.recipes.count } }
        return "已安排 \(plan.days.count) 天 · \(dishCount) 道菜"
    }

    private func showToast(_ message: String) {
        withAnimation { toastMessage = message }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            await MainActor.run { withAnimation { toastMessage = nil } }
        }
    }
}

// MARK: - Recommendation browser (secondary page)

struct RecipeRecommendationBrowserView: View {
    @EnvironmentObject private var recipeStore: RecipeStore
    @EnvironmentObject private var kitchenStore: KitchenStore
    @EnvironmentObject private var recommendationStore: HomeRecommendationStore

    @State private var selectedRecipe: Recipe?
    @State private var toastMessage: String?
    @FocusState private var isSearchFocused: Bool

    private var sourceRecipes: [Recipe] {
        recipeStore.recipes.isEmpty ? Recipe.samples : recipeStore.recipes
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                searchBar

                HStack(alignment: .firstTextBaseline) {
                    Text("推荐")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    if !recommendationStore.searchQuery.isEmpty {
                        Text(recommendationStore.recommendedRecipes.isEmpty
                             ? "未找到"
                             : "找到 \(recommendationStore.recommendedRecipes.count) 道")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if recommendationStore.recommendedRecipes.isEmpty {
                    recommendationEmptyState
                } else {
                    TabView(selection: $recommendationStore.currentRecommendationIndex) {
                        ForEach(
                            Array(recommendationStore.recommendedRecipes.enumerated()),
                            id: \.element.id
                        ) { index, recommendation in
                            recommendationCard(recommendation)
                                .tag(index)
                                .padding(.horizontal, 1)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(height: 300)
                    .animation(.easeInOut(duration: 0.18), value: recommendationStore.currentRecommendationIndex)

                    if recommendationStore.recommendedRecipes.count > 1 {
                        HStack(spacing: 5) {
                            ForEach(recommendationStore.recommendedRecipes.indices, id: \.self) { index in
                                Capsule()
                                    .fill(index == recommendationStore.currentRecommendationIndex
                                          ? AppTheme.textSecondary.opacity(0.78)
                                          : AppTheme.textSecondary.opacity(0.20))
                                    .frame(
                                        width: index == recommendationStore.currentRecommendationIndex ? 13 : 5,
                                        height: 5
                                    )
                                    .animation(.easeInOut(duration: 0.16), value: recommendationStore.currentRecommendationIndex)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            "第 \(recommendationStore.currentRecommendationIndex + 1) 道，共 \(recommendationStore.recommendedRecipes.count) 道"
                        )
                    }

                    Button {
                        generateAIRecommendations()
                    } label: {
                        HStack(spacing: 7) {
                            if recommendationStore.isGeneratingRecommendations {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "sparkles")
                            }
                            Text(recommendationStore.isGeneratingRecommendations ? "正在生成…" : "AI 换几道")
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(AppTheme.brand)
                    .disabled(recommendationStore.isSearchingRecommendations
                              || recommendationStore.isGeneratingRecommendations)
                }

                if let error = recommendationStore.recommendationError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("推荐")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: recipeStore.recipes.count) {
            loadDefaultRecommendationsIfNeeded()
        }
        .onDisappear {
            recommendationStore.cancelRequests()
        }
        .navigationDestination(item: $selectedRecipe) { recipe in
            RecipeDetailView(recipe: recipe)
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 14))
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    "比如 番茄炒蛋 / 鸡蛋 番茄",
                    text: $recommendationStore.searchQuery
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isSearchFocused)
                .onSubmit(performRecommendationSearch)

                if !recommendationStore.searchQuery.isEmpty {
                    Button {
                        clearRecommendationSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button(action: performRecommendationSearch) {
                Group {
                    if recommendationStore.isSearchingRecommendations {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("找菜")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(minWidth: 54, minHeight: 44)
                .background(AppTheme.brand, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(recommendationStore.isSearchingRecommendations
                      || recommendationStore.isGeneratingRecommendations)
        }
    }

    private var recommendationEmptyState: some View {
        ContentUnavailableView {
            Label("暂时没有找到合适的菜", systemImage: "sparkles")
        } description: {
            Text("换个菜名，或者输入几样食材试试。")
        } actions: {
            Button("AI 推荐几道", action: generateAIRecommendations)
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.brand)
            if !recommendationStore.searchQuery.isEmpty {
                Button("清除搜索", action: clearRecommendationSearch)
                    .buttonStyle(.bordered)
            }
        }
    }

    private func recommendationCard(_ recommendation: RecipeRecommendation) -> some View {
        let recipe = recommendation.recipe
        let isFavorite = recommendationStore.favoriteRecipeIDs.contains(recipe.id)
        let isAdded = kitchenStore.todayPlans.contains { $0.recipeID == recipe.id }

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(recommendation.source == .ai ? "AI 推荐" : "今日推荐", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.success)
                Spacer()
                Text(recommendation.source == .ai ? "新灵感" : recommendationBadge(recipe))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.success)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(AppTheme.success.opacity(0.10), in: Capsule())
                Menu {
                    Button("加入今天", systemImage: "calendar.badge.plus") {
                        addRecommendationToPlan(recipe)
                    }
                    .disabled(isAdded)
                    Button("查看菜谱", systemImage: "book.pages") {
                        selectedRecipe = recipe
                    }
                    Button(
                        isFavorite ? "取消常做" : "设为常做",
                        systemImage: isFavorite ? "star.slash" : "star"
                    ) {
                        recommendationStore.toggleFavorite(recipeID: recipe.id)
                        showToast(isFavorite ? "已取消常做" : "已设为常做")
                    }
                    Button("不喜欢这道", systemImage: "hand.thumbsdown") {
                        recommendationStore.removeRecommendation(id: recommendation.id)
                        showToast("已减少类似推荐")
                    }
                    Button("推荐有问题", systemImage: "exclamationmark.bubble") {
                        showToast("感谢反馈")
                    }
                    Divider()
                    Button("从本次推荐移除", systemImage: "trash", role: .destructive) {
                        recommendationStore.removeRecommendation(id: recommendation.id)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.primary)
                }
            }

            Text(recipe.title)
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Text(ingredientSummary(recipe))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(recommendation.reason ?? recommendationReason(recipe))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button(isAdded ? "已加入" : "加入计划") {
                    addRecommendationToPlan(recipe)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(AppTheme.brand, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .opacity(isAdded ? 0.62 : 1)
                .disabled(isAdded)

                Button("查看") { selectedRecipe = recipe }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.brand)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(AppTheme.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.textPrimary.opacity(0.05), lineWidth: 1)
        }
        .shadow(color: AppTheme.cardShadow(opacity: 0.035), radius: 9, y: 4)
    }

    private func recommendationBadge(_ recipe: Recipe) -> String {
        let names = kitchenStore.availableInventory.map(\.name)
        let matches = recipe.ingredients.filter { ingredient in
            names.contains { ingredient.localizedCaseInsensitiveContains($0) }
        }.count
        return matches > 0 ? "用到 \(matches) 样在库食材" : "灵感菜"
    }

    private func recommendationReason(_ recipe: Recipe) -> String {
        let expiringNames = kitchenStore.expiringItems.map(\.name)
        if let name = expiringNames.first(where: { expiring in
            recipe.ingredients.contains { $0.localizedCaseInsensitiveContains(expiring) }
        }) {
            return "\(name)快到期了，建议优先用。"
        }
        return kitchenStore.inventory.isEmpty ? "先看看做法，也可以直接加入今天的计划。" : "现有食材匹配度不错，可以先加入计划。"
    }

    private func ingredientSummary(_ recipe: Recipe) -> String {
        recipe.ingredients
            .prefix(3)
            .map { ingredient in
                ingredient.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ingredient
            }
            .joined(separator: " · ")
    }

    private func loadDefaultRecommendationsIfNeeded() {
        recommendationStore.loadDefaultRecommendations(
            recipes: sourceRecipes,
            inventory: kitchenStore.availableInventory.map(\.name),
            expiringIngredients: kitchenStore.expiringItems.map(\.name)
        )
    }

    private func performRecommendationSearch() {
        isSearchFocused = false
        Task {
            await recommendationStore.searchRecommendations(
                recipes: sourceRecipes,
                inventory: kitchenStore.availableInventory.map(\.name),
                expiringIngredients: kitchenStore.expiringItems.map(\.name)
            )
        }
    }

    private func clearRecommendationSearch() {
        isSearchFocused = false
        recommendationStore.clearSearch(
            recipes: sourceRecipes,
            inventory: kitchenStore.availableInventory.map(\.name),
            expiringIngredients: kitchenStore.expiringItems.map(\.name)
        )
    }

    private func generateAIRecommendations() {
        isSearchFocused = false
        Task {
            await recommendationStore.generateNewRecommendations(
                inventory: kitchenStore.availableInventory.map(\.name),
                expiringIngredients: kitchenStore.expiringItems.map(\.name)
            )
        }
    }

    private func addRecommendationToPlan(_ recipe: Recipe) {
        let alreadyAdded = kitchenStore.todayPlans.contains { $0.recipeID == recipe.id }
        kitchenStore.addPlan(recipe: recipe)
        UINotificationFeedbackGenerator().notificationOccurred(
            alreadyAdded ? .warning : .success
        )
        showToast(alreadyAdded ? "已在今天" : "已加入今天")
    }

    private func showToast(_ message: String) {
        withAnimation { toastMessage = message }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            await MainActor.run { withAnimation { toastMessage = nil } }
        }
    }
}

// MARK: - Status sheets (expiry / shopping)

private struct HomeStatusSheetContainer<Content: View>: View {
    let title: String
    @Binding var path: NavigationPath
    private let content: Content

    init(title: String, path: Binding<NavigationPath>, @ViewBuilder content: () -> Content) {
        self.title = title
        self._path = path
        self.content = content()
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                content
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: InventoryRoute.self) { route in
                switch route {
                case .detail(let itemID):
                    InventoryItemDetailView(itemID: itemID)
                }
            }
        }
        .presentationBackground(.thinMaterial)
    }
}

private struct ExpirySheet: View {
    @EnvironmentObject private var store: KitchenStore
    let onUseIngredient: (InventoryItem) -> Void
    // Explicit path + a plain Button that appends to it directly, rather than
    // NavigationLink(value:) — reproduced via a real XCUITest tap that
    // NavigationLink(value:) inside this kind of List can push a stale/wrong
    // item (see InventoryNavigationUITests); a manual append does not.
    @State private var path = NavigationPath()

    var body: some View {
        HomeStatusSheetContainer(title: "临期食材", path: $path) {
            if store.expiringItems.isEmpty {
                ContentUnavailableView("没有临期食材", systemImage: "checkmark.circle")
            } else {
                ForEach(store.expiringItems) { item in
                    HStack(spacing: 12) {
                        Button {
                            path.append(InventoryRoute.detail(item.id))
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name).font(.headline)
                                Text("\(item.quantity.formatted()) \(item.unit)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(item.expiryStatusText)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(item.expiryStatus.color)
                        }
                        .buttonStyle(.plain)

                        Button("用它") { onUseIngredient(item) }
                            .buttonStyle(.bordered)
                            .tint(AppTheme.brand)
                    }
                }
            }
        }
    }
}

private struct PendingShoppingSheet: View {
    @EnvironmentObject private var store: KitchenStore
    let onGoShopping: () -> Void
    @State private var path = NavigationPath()

    var body: some View {
        HomeStatusSheetContainer(title: "待买清单", path: $path) {
            if store.pendingShoppingItems.isEmpty {
                ContentUnavailableView("没有待买项目", systemImage: "cart")
            } else {
                ForEach(store.pendingShoppingItems) { item in
                    Button { store.toggleShopping(item) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "circle")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name)
                                if item.source != "手动添加" {
                                    Text(item.source)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text("\(item.quantity.formatted()) \(item.unit)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                }

                Section {
                    Button("去买菜清单", action: onGoShopping)
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.brand)
                }
            }
        }
    }
}

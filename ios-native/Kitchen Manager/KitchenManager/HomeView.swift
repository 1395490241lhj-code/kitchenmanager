import SwiftUI
import UIKit

/// The Home screen's single primary task, derived entirely from existing
/// `KitchenStore` state — never a separate source of truth. `.active` covers
/// both "today has an unfinished plan" and would cover a future "missing
/// ingredients" variant, but no such state is added here: the app has no
/// reliable per-plan ingredient-availability data (see `HomePrimaryTaskCard`),
/// so guessing would mean fragile, made-up business logic.
private enum HomePrimaryTaskState {
    case active(plan: MealPlanItem, recipe: Recipe?)
    case empty
    case completed
}

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
    @EnvironmentObject private var recipeStore: RecipeStore
    @EnvironmentObject private var kitchenStore: KitchenStore
    @EnvironmentObject private var navigationStore: AppNavigationStore
    @EnvironmentObject private var recommendationStore: HomeRecommendationStore
    @EnvironmentObject private var authStore: AuthStore

    @State private var activeSheet: HomeSheet?
    @State private var toastMessage: String?
    @State private var selectedRecipe: Recipe?
    @State private var isShowingTodayPlan = false
    @State private var isShowingRecommendations = false
    @State private var isShowingWeeklyPlanner = false

    private var sourceRecipes: [Recipe] {
        recipeStore.recipes.isEmpty ? Recipe.samples : recipeStore.recipes
    }

    private var primaryTaskState: HomePrimaryTaskState {
        if let plan = kitchenStore.pendingTodayPlans.first {
            return .active(plan: plan, recipe: sourceRecipes.first { $0.id == plan.recipeID })
        }
        if !kitchenStore.todayPlans.isEmpty {
            return .completed
        }
        return .empty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HomeHeaderView(
                    displayName: displayName,
                    subtitle: headerSubtitle,
                    onOpenSmartImport: {
                        activeSheet = .smartImport
                    }
                )

                HomePrimaryTaskCard(
                    state: primaryTaskState,
                    mealLabel: currentMealLabel,
                    onPrimaryAction: handlePrimaryAction,
                    onViewFullPlan: { isShowingTodayPlan = true },
                    onSwapRecommendation: { isShowingRecommendations = true },
                    onGetRecommendation: { isShowingRecommendations = true }
                )

                KitchenAlertsCard(
                    expiredCount: expiredItemCount,
                    expiringSoonCount: expiringSoonItemCount,
                    pendingShoppingCount: kitchenStore.pendingShoppingItems.count,
                    onShowExpiring: { activeSheet = .expiry },
                    onShowShopping: { activeSheet = .shopping }
                )

                WeeklyPlannerCard(
                    hasPlan: kitchenStore.weeklyPlan != nil,
                    subtitle: weeklyPlannerSubtitle,
                    action: { isShowingWeeklyPlanner = true }
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("首页")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(item: $selectedRecipe) { recipe in
            RecipeDetailView(recipe: recipe)
        }
        .navigationDestination(isPresented: $isShowingTodayPlan) {
            TodayPlanDetailView()
        }
        .navigationDestination(isPresented: $isShowingRecommendations) {
            RecipeRecommendationBrowserView()
        }
        .navigationDestination(isPresented: $isShowingWeeklyPlanner) {
            WeeklyMenuPlannerView()
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
                    .transition(.move(edge: .bottom).combined(with: .opacity))
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

    private func handlePrimaryAction() {
        switch primaryTaskState {
        case .active(let plan, let recipe):
            if let recipe {
                selectedRecipe = recipe
            } else {
                isShowingTodayPlan = true
            }
        case .empty:
            isShowingRecommendations = true
        case .completed:
            isShowingWeeklyPlanner = true
        }
    }

    private var displayName: String? {
        authStore.account?.user.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyHome
    }

    private var currentMealLabel: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 10 { return "早餐" }
        if hour < 15 { return "午餐" }
        return "晚餐"
    }

    private var headerSubtitle: String {
        switch primaryTaskState {
        case .active: return "先把\(currentMealLabel)做好，其它待会儿再说"
        case .completed: return "今天的安排已经完成"
        case .empty: return "今天先把\(currentMealLabel)安排好"
        }
    }

    private var weeklyPlannerSubtitle: String {
        guard let plan = kitchenStore.weeklyPlan else {
            return "按顿数、人数安排接下来一周"
        }

        let dishCount = plan.days.reduce(0) { total, day in
            total + day.meals.reduce(0) { mealTotal, meal in
                mealTotal + meal.recipes.count
            }
        }

        return "已安排 \(plan.days.count) 天 · \(dishCount) 道菜"
    }

    private var expiredItemCount: Int {
        kitchenStore.expiringItems.filter { $0.expiryStatus == .expired }.count
    }

    private var expiringSoonItemCount: Int {
        kitchenStore.expiringItems.count - expiredItemCount
    }

    private func showToast(_ message: String) {
        withAnimation { toastMessage = message }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            await MainActor.run { withAnimation { toastMessage = nil } }
        }
    }
}

private extension String {
    var nilIfEmptyHome: String? { isEmpty ? nil : self }
}

// MARK: - Header

private struct HomeHeaderView: View {
    let displayName: String?
    let subtitle: String
    let onOpenSmartImport: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(greeting)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button(action: onOpenSmartImport) {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(AppTheme.brand, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .accessibilityIdentifier("home.import.add.button")
            .accessibilityLabel("导入与添加")
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let base: String
        if hour < 5 { base = "夜深了" }
        else if hour < 11 { base = "早上好" }
        else if hour < 14 { base = "中午好" }
        else if hour < 18 { base = "下午好" }
        else { base = "晚上好" }
        guard let displayName else { return base }
        return "\(base)，\(displayName)"
    }
}

// MARK: - Primary task card

private struct HomePrimaryTaskCard: View {
    let state: HomePrimaryTaskState
    let mealLabel: String
    let onPrimaryAction: () -> Void
    let onViewFullPlan: () -> Void
    let onSwapRecommendation: () -> Void
    let onGetRecommendation: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppTheme.textPrimary.opacity(0.06), lineWidth: 1)
        }
        .shadow(color: AppTheme.cardShadow(opacity: 0.06), radius: 14, y: 5)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .active(let plan, let recipe):
            activeContent(plan: plan, recipe: recipe)
        case .empty:
            emptyContent
        case .completed:
            completedContent
        }
    }

    @ViewBuilder
    private func activeContent(plan: MealPlanItem, recipe: Recipe?) -> some View {
        Text("今天\(mealLabel)")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)

        HStack(alignment: .top, spacing: 14) {
            dishThumbnail

            VStack(alignment: .leading, spacing: 5) {
                Text(plan.recipeName)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                HStack(spacing: 12) {
                    Label("\(plan.servings) 人份", systemImage: "person.2")
                    if let time = recipe?.cookingTime {
                        Label("\(time) 分钟", systemImage: "clock")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }

        primaryButton(title: "开始做饭")

        HStack {
            Button("查看完整计划", action: onViewFullPlan)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            Spacer()
            Button("换一道推荐", action: onSwapRecommendation)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(AppTheme.textSecondary)
    }

    private var dishThumbnail: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(AppTheme.secondarySurface)
            .frame(width: 56, height: 56)
            .overlay {
                Image(systemName: "fork.knife")
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var emptyContent: some View {
        Text("今天还没安排吃什么")
            .font(.title2.weight(.bold))
            .foregroundStyle(.primary)
        Text("根据现有库存，帮你挑一道合适的菜")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        primaryButton(title: "帮我选一道")
    }

    @ViewBuilder
    private var completedContent: some View {
        Text("今天的计划已完成")
            .font(.title2.weight(.bold))
            .foregroundStyle(.primary)
        Text("可以提前安排明天，或者看看现有库存还能做什么")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        primaryButton(title: "安排明天")
        Button("获取推荐", action: onGetRecommendation)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(AppTheme.textSecondary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }

    private func primaryButton(title: String) -> some View {
        Button(action: onPrimaryAction) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.plain)
        .background(AppTheme.brand, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("home.primary.action.button")
    }
}

// MARK: - Kitchen alerts

private struct KitchenAlertsCard: View {
    let expiredCount: Int
    let expiringSoonCount: Int
    let pendingShoppingCount: Int
    let onShowExpiring: () -> Void
    let onShowShopping: () -> Void

    private var hasAlerts: Bool {
        expiredCount > 0 || expiringSoonCount > 0 || pendingShoppingCount > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("厨房提醒")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                if hasAlerts {
                    Button("查看全部", action: expiredCount > 0 || expiringSoonCount > 0 ? onShowExpiring : onShowShopping)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
            }
            .padding(.bottom, hasAlerts ? 8 : 0)

            if hasAlerts {
                VStack(spacing: 0) {
                    if expiredCount > 0 {
                        AlertRow(
                            text: "\(expiredCount) 件食材已过期",
                            countColor: AppTheme.inventoryExpired,
                            systemImage: "exclamationmark.circle.fill",
                            action: onShowExpiring
                        )
                        if expiringSoonCount > 0 || pendingShoppingCount > 0 { Divider() }
                    }
                    if expiringSoonCount > 0 {
                        AlertRow(
                            text: "\(expiringSoonCount) 样食材将在 3 天内过期",
                            countColor: AppTheme.warning,
                            systemImage: "clock.fill",
                            action: onShowExpiring
                        )
                        if pendingShoppingCount > 0 { Divider() }
                    }
                    if pendingShoppingCount > 0 {
                        AlertRow(
                            text: "购物清单还有 \(pendingShoppingCount) 项未完成",
                            countColor: .secondary,
                            systemImage: "cart.fill",
                            action: onShowShopping
                        )
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.success)
                    Text("厨房状态良好，目前没有需要立即处理的事项")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(16)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.textPrimary.opacity(0.06), lineWidth: 1)
        }
    }
}

private struct AlertRow: View {
    let text: String
    let countColor: Color
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.footnote)
                    .foregroundStyle(countColor)
                    .frame(width: 18)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Smart import

private struct WeeklyPlannerCard: View {
    let hasPlan: Bool
    let subtitle: String
    let action: () -> Void

    private var title: String { hasPlan ? "查看本周食谱" : "规划本周食谱" }
    private var systemImage: String { hasPlan ? "calendar.badge.checkmark" : "calendar.badge.plus" }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.textSecondary.opacity(0.10))
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: systemImage)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(minHeight: 60)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AppTheme.textPrimary.opacity(0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.weekly.planner.card")
        .accessibilityLabel("\(title)，\(subtitle)")
    }
}

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
    @State private var activeSheet: TodayPlanSheet?
    @State private var planPendingRemoval: MealPlanItem?
    @State private var isShowingWeeklyPlanner = false
    @State private var isShowingShoppingGeneration = false
    @State private var toastMessage: String?

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
                            Image(systemName: plan.isCooked ? "checkmark.circle.fill" : "fork.knife.circle")
                                .font(.title2)
                                .foregroundStyle(plan.isCooked ? AppTheme.success : AppTheme.warning)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(plan.recipeName).font(.headline)
                                Text(plan.isCooked ? "已完成" : "\(plan.servings) 人份 · 今天")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !plan.isCooked {
                                Button("做好了") { activeSheet = .cook(plan) }
                                    .font(.caption.bold())
                            }
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

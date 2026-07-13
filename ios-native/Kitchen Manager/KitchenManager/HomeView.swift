import SwiftUI
import UIKit

private enum HomePanelTab: String, CaseIterable {
    case plan = "计划"
    case recommendations = "推荐"
}

private enum HomeSheet: Identifiable {
    case expiry
    case shopping
    case recordFood
    case importRecipe
    case quickShopping
    case cookCalibration(MealPlanItem)
    case cookAllCalibration

    var id: String {
        switch self {
        case .expiry: "expiry"
        case .shopping: "shopping"
        case .recordFood: "record-food"
        case .importRecipe: "import-recipe"
        case .quickShopping: "quick-shopping"
        case .cookCalibration(let plan): "cook-\(plan.id)"
        case .cookAllCalibration: "cook-all"
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var recipeStore: RecipeStore
    @EnvironmentObject private var kitchenStore: KitchenStore
    @EnvironmentObject private var navigationStore: AppNavigationStore
    @EnvironmentObject private var recommendationStore: HomeRecommendationStore

    @State private var selectedPanel: HomePanelTab = .recommendations
    @State private var activeSheet: HomeSheet?
    @State private var toastMessage: String?
    @State private var selectedRecipe: Recipe?
    @State private var isShowingWeeklyPlanner = false
    @State private var isShowingTodayShoppingGeneration = false
    @State private var planPendingRemoval: MealPlanItem?
    @FocusState private var isRecommendationSearchFocused: Bool

    private var sourceRecipes: [Recipe] {
        recipeStore.recipes.isEmpty ? Recipe.samples : recipeStore.recipes
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                statusHeader
                kitchenPanel
                quickActions
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("首页")
        .navigationBarTitleDisplayMode(.large)
        .task(id: recipeStore.recipes.count) {
            loadDefaultRecommendationsIfNeeded()
        }
        .onChange(of: kitchenStore.inventory) {
            loadDefaultRecommendationsIfNeeded()
        }
        .onDisappear {
            recommendationStore.cancelRequests()
        }
        .navigationDestination(item: $selectedRecipe) { recipe in
            RecipeDetailView(recipe: recipe)
        }
        .navigationDestination(isPresented: $isShowingWeeklyPlanner) {
            WeeklyMenuPlannerView()
        }
        .navigationDestination(isPresented: $isShowingTodayShoppingGeneration) {
            ShoppingListGenerationView(source: .todayPlans(kitchenStore.todayPlans))
        }
        .sheet(item: $activeSheet) { sheet in
            sheetContent(sheet)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
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
                    .background(.black.opacity(0.82), in: Capsule())
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(greeting)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(statusTitle)
                .font(.title.weight(.bold))
                .foregroundStyle(.primary)

            Text(statusSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                StatusPill(
                    title: "临期",
                    count: kitchenStore.expiringItems.count,
                    color: AppTheme.warning,
                    background: AppTheme.warning.opacity(0.13),
                    systemImage: "clock"
                ) { activeSheet = .expiry }

                StatusPill(
                    title: "待买",
                    count: kitchenStore.pendingShoppingItems.count,
                    color: AppTheme.shopping,
                    background: AppTheme.shopping.opacity(0.12),
                    systemImage: "cart"
                ) { activeSheet = .shopping }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 12)
    }

    private var kitchenPanel: some View {
        VStack(spacing: 0) {
            Picker("面板", selection: $selectedPanel.animation(.easeInOut(duration: 0.16))) {
                ForEach(HomePanelTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(4)

            Group {
                if selectedPanel == .plan {
                    planPanel
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                } else {
                    recommendationPanel
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .padding(10)
        }
        .padding(10)
        .background(AppTheme.surface.opacity(0.56))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.textPrimary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: AppTheme.cardShadow(opacity: 0.07), radius: 15, y: 6)
    }

    private var planPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("计划")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if !kitchenStore.todayPlans.isEmpty {
                        Text("已经安排 \(kitchenStore.todayPlans.count) 道菜。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !kitchenStore.todayPlans.isEmpty {
                    Menu {
                        if !kitchenStore.pendingTodayPlans.isEmpty {
                            Button("全部做完", systemImage: "checkmark.circle") {
                                activeSheet = .cookAllCalibration
                            }
                        }
                        Button("生成今日购物清单", systemImage: "cart.badge.plus") {
                            isShowingTodayShoppingGeneration = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                }
            }

            if kitchenStore.todayPlans.isEmpty {
                ContentUnavailableView {
                    Label("还没有安排今天吃什么", systemImage: "calendar.badge.plus")
                } actions: {
                    Button("看看推荐") {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            selectedPanel = .recommendations
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.primary)
                }
            } else {
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
                            Button("做好了") { activeSheet = .cookCalibration(plan) }
                                .font(.caption.bold())
                        }
                    }
                    .padding(12)
                    .background(AppTheme.surface.opacity(0.78), in: RoundedRectangle(cornerRadius: 16))
                    .contextMenu {
                        Button("移出计划", role: .destructive) { planPendingRemoval = plan }
                    }
                }
            }

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
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(AppTheme.textSecondary.opacity(0.55))
                }
            }
            .buttonStyle(.plain)
            .padding(12)
            .background(AppTheme.surface.opacity(0.74), in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(AppTheme.textPrimary.opacity(0.07), lineWidth: 1)
            }
        }
    }

    private var recommendationPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("想做什么？")
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
                    .focused($isRecommendationSearchFocused)
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
                .frame(minHeight: 42)
                .background(Color(.secondarySystemGroupedBackground), in: Capsule())

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
                    .frame(minWidth: 54, minHeight: 42)
                    .background(AppTheme.primary, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(recommendationStore.isSearchingRecommendations
                          || recommendationStore.isGeneratingRecommendations)
            }

            Text("推荐")
                .font(.headline)
                .foregroundStyle(.primary)

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
                .frame(height: 282)
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
                    .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.primary)
                .disabled(recommendationStore.isSearchingRecommendations
                          || recommendationStore.isGeneratingRecommendations)
            }

            if let error = recommendationStore.recommendationError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                .tint(AppTheme.primary)
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
                .background(AppTheme.primary, in: Capsule())
                .opacity(isAdded ? 0.62 : 1)
                .disabled(isAdded)

                Button("查看") { selectedRecipe = recipe }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryDark)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(AppTheme.primarySoft, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.textPrimary.opacity(0.05), lineWidth: 1)
        }
        .shadow(color: AppTheme.cardShadow(opacity: 0.035), radius: 9, y: 4)
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("快捷操作")
                .font(.headline)
                .foregroundStyle(.primary)
                .padding(.horizontal, 2)
            HStack(spacing: 12) {
                QuickActionButton(
                    title: "记食材",
                    subtitle: "记录冰箱食材",
                    icon: "shippingbox.fill",
                    isPrimary: true
                ) {
                    activeSheet = .recordFood
                }
                QuickActionButton(
                    title: "导入菜谱",
                    subtitle: "粘贴链接识别",
                    icon: "square.and.arrow.down"
                ) {
                    activeSheet = .importRecipe
                }
            }
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: HomeSheet) -> some View {
        switch sheet {
        case .expiry:
            ExpirySheet { item in
                recommendationStore.searchQuery = item.name
                selectedPanel = .recommendations
                activeSheet = nil
                performRecommendationSearch()
            }
        case .shopping:
            PendingShoppingSheet {
                activeSheet = nil
                navigationStore.selectedTab = .shopping
            }
        case .recordFood:
            RecordFoodSheet()
        case .importRecipe:
            RecipeImportOptionsView {
                activeSheet = nil
                showToast("已保存到菜谱库")
            }
        case .quickShopping:
            QuickShoppingSheet()
        case .cookCalibration(let plan):
            CookConsumptionConfirmationView(
                title: plan.recipeName,
                planIDs: kitchenStore.hasConsumedPlan(plan.id) ? [] : [plan.id],
                recipeID: plan.recipeID,
                recipeName: plan.recipeName
            ) {
                kitchenStore.markPlanCooked(plan)
                showToast("已记录消耗，库存已更新")
            }
        case .cookAllCalibration:
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

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 5 { return "🌙 夜深了" }
        if hour < 11 { return "👋 早上好" }
        if hour < 14 { return "👋 中午好" }
        if hour < 18 { return "👋 下午好" }
        return "🌆 晚上好"
    }

    private var statusTitle: String {
        if !kitchenStore.pendingTodayPlans.isEmpty { return "今天已经安排好了" }
        if !recommendationStore.recommendedRecipes.isEmpty && !kitchenStore.inventory.isEmpty {
            return "今天可以做 \(recommendationStore.recommendedRecipes.count) 道菜"
        }
        return "今天还没决定吃什么"
    }

    private var statusSubtitle: String {
        if !kitchenStore.pendingTodayPlans.isEmpty {
            return "准备做 \(kitchenStore.pendingTodayPlans.count) 道菜。记录消耗后，库存会自动更新。"
        }
        if kitchenStore.inventory.isEmpty { return "先记录几样食材，或者去菜谱里找灵感。" }
        return "先选一道加入计划"
    }

    private var weeklyPlanSubtitle: String {
        guard let plan = kitchenStore.weeklyPlan else {
            return "按顿数、人数生成一周安排"
        }
        let dishCount = plan.days.reduce(0) { $0 + $1.meals.reduce(0) { $0 + $1.recipes.count } }
        return "已安排 \(plan.days.count) 天 · \(dishCount) 道菜"
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
        isRecommendationSearchFocused = false
        Task {
            await recommendationStore.searchRecommendations(
                recipes: sourceRecipes,
                inventory: kitchenStore.availableInventory.map(\.name),
                expiringIngredients: kitchenStore.expiringItems.map(\.name)
            )
        }
    }

    private func clearRecommendationSearch() {
        isRecommendationSearchFocused = false
        recommendationStore.clearSearch(
            recipes: sourceRecipes,
            inventory: kitchenStore.availableInventory.map(\.name),
            expiringIngredients: kitchenStore.expiringItems.map(\.name)
        )
    }

    private func generateAIRecommendations() {
        isRecommendationSearchFocused = false
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

private struct StatusPill: View {
    let title: String
    let count: Int
    let color: Color
    let background: Color
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.footnote.weight(.semibold))
                Text(title)
                Text("\(count)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .opacity(0.45)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(background, in: Capsule())
            .overlay {
                Capsule().stroke(color.opacity(0.16), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .opacity(count == 0 ? 0.70 : 1)
    }
}

private struct QuickActionButton: View {
    let title: String
    let subtitle: String
    let icon: String
    var isPrimary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isPrimary ? AppTheme.primary : AppTheme.textSecondary)
                    .frame(width: 34, height: 34)
                    .background(
                        isPrimary ? AppTheme.primary.opacity(0.12) : AppTheme.textSecondary.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 13)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(
                isPrimary ? AppTheme.primarySoft.opacity(0.72) : AppTheme.surface.opacity(0.72),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(isPrimary ? AppTheme.primary.opacity(0.16) : Color(uiColor: .separator).opacity(0.5), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

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
                            .tint(AppTheme.primary)
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
                        .tint(AppTheme.primary)
                }
            }
        }
    }
}

private struct QuickShoppingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: KitchenStore
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form { TextField("要买什么？", text: $name) }
                .navigationTitle("添加待买物品")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("添加") { store.addShopping(name: name); dismiss() }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}

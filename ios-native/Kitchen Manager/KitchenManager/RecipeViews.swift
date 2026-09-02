import SwiftUI

enum RecipeRoute: Hashable, Identifiable {
    case manual, linkImport, imageImport, aiGenerator
    var id: Self { self }
}

/// Shown wherever `RecipeStore.isDisplayingSamples` is true, so the built-in
/// samples are never presented as the user's own library. Layout follows the
/// existing HomeModuleIssues pattern: stacks vertically at Accessibility sizes
/// so the retry control never gets squeezed off the row.
struct SampleFallbackNotice: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let isRetrying: Bool
    /// nil where no clean reload path exists (recommendation browser).
    let onRetry: (() -> Void)?

    private let message = "菜谱没能加载出来，先显示几道示例菜。"

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    label
                    retryButton
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        label
                        Spacer(minLength: 8)
                        retryButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        label
                        retryButton
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recipe.sampleFallback.notice")
    }

    private var label: some View {
        Label {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.warning)
        }
        .accessibilityIdentifier("recipe.sampleFallback.message")
    }

    @ViewBuilder private var retryButton: some View {
        if let onRetry {
            if isRetrying {
                ProgressView()
                    .controlSize(.small)
                    .frame(minHeight: AppTheme.minimumHitTarget)
                    .accessibilityLabel("正在重新加载")
            } else {
                Button("重试", action: onRetry)
                    .font(.footnote.weight(.semibold))
                    .frame(minHeight: AppTheme.minimumHitTarget)
                    .accessibilityIdentifier("recipe.sampleFallback.retry")
            }
        }
    }
}

private enum RecipeAvailabilityFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case favorites = "收藏"
    case frequent = "常做"
    case cookable = "能做"
    case nearlyCookable = "缺少少量食材"
    var id: String { rawValue }
}

struct RecipeListView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var store: RecipeStore
    @EnvironmentObject private var kitchenStore: KitchenStore
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var route: RecipeRoute?
    @State private var filter: RecipeAvailabilityFilter = .all
    @State private var selectedTag = "全部标签"
    @State private var selectedDifficulty = "全部难度"
    @State private var maximumTime: Int?

    private var sourceRecipes: [Recipe] { store.recipesForDisplay }
    private var tags: [String] { ["全部标签"] + Array(Set(sourceRecipes.flatMap(\.tags))).sorted() }
    private var hasActiveFilters: Bool {
        filter != .all
            || selectedTag != "全部标签"
            || selectedDifficulty != "全部难度"
            || maximumTime != nil
    }

    private var activeFilterDescription: String {
        var values: [String] = []
        if filter != .all { values.append(filter.rawValue) }
        if selectedTag != "全部标签" { values.append(selectedTag) }
        if selectedDifficulty != "全部难度" { values.append(selectedDifficulty) }
        if let maximumTime { values.append("\(maximumTime) 分钟内") }
        return values.joined(separator: " · ")
    }

    private var recipes: [Recipe] {
        sourceRecipes.filter { recipe in
            let matchesSearch = searchText.isEmpty
                || recipe.title.localizedCaseInsensitiveContains(searchText)
                || recipe.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
                || (recipe.ingredients + recipe.seasonings).contains { $0.localizedCaseInsensitiveContains(searchText) }
            let missing = missingCoreIngredientCount(recipe)
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .favorites: matchesFilter = store.favoriteRecipeIDs.contains(recipe.id)
            case .frequent: matchesFilter = store.frequentRecipeIDs.contains(recipe.id)
            case .cookable: matchesFilter = missing == 0
            case .nearlyCookable: matchesFilter = (1...2).contains(missing)
            }
            return matchesSearch && matchesFilter
                && (selectedTag == "全部标签" || recipe.tags.contains(selectedTag))
                && (selectedDifficulty == "全部难度" || recipe.difficulty == selectedDifficulty)
                && (maximumTime == nil || (recipe.cookingTime ?? .max) <= maximumTime!)
        }
    }

    var body: some View {
        List {
            if store.isDisplayingSamples {
                Section {
                    SampleFallbackNotice(isRetrying: store.isLoading) {
                        Task { await store.loadRecipes() }
                    }
                }
            }

            if hasActiveFilters {
                Section {
                    LabeledContent {
                        Button {
                            clearFilters()
                        } label: {
                            Text("清除")
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(AppTheme.brand.opacity(0.08), in: Capsule())
                                .frame(minHeight: AppTheme.minimumHitTarget)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AppTheme.brand)
                        .accessibilityIdentifier("recipe.filter.clear")
                    } label: {
                        Label(activeFilterDescription, systemImage: "line.3.horizontal.decrease.circle")
                            .fontWeight(.medium)
                            .foregroundStyle(AppTheme.brand)
                    }
                    .font(.subheadline)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("recipe.filter.active")
                }
            }

            if recipes.isEmpty {
                ContentUnavailableView {
                    Label(
                        emptyStateTitle,
                        systemImage: searchText.isEmpty && !hasActiveFilters ? "book.closed" : "magnifyingglass"
                    )
                } description: {
                    Text(emptyStateDescription)
                } actions: {
                    if !searchText.isEmpty {
                        Button("清除搜索") {
                            searchText = ""
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.cookingActionFill)
                        .foregroundStyle(AppTheme.onCookingAction)
                        .frame(minHeight: AppTheme.minimumHitTarget)
                        .contentShape(Rectangle())
                        .accessibilityIdentifier("recipe.search.clear")
                    } else if !hasActiveFilters {
                        Button("添加菜谱", systemImage: "plus") {
                            route = .manual
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.cookingActionFill)
                        .foregroundStyle(AppTheme.onCookingAction)
                        .accessibilityIdentifier("recipe.empty.add")
                    }
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(recipes) { recipe in
                        NavigationLink(destination: RecipeDetailView(recipe: recipe)) {
                            RecipeListRow(
                                recipe: recipe,
                                availability: availabilityText(recipe)
                            )
                        }
                        .accessibilityIdentifier("recipe.list.\(recipe.id)")
                    }
                } header: {
                    Text(resultSectionTitle)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(height: ChromeMetrics.bottomClearance)
                .accessibilityHidden(true)
        }
        .navigationTitle("菜谱")
        .navigationBarTitleDisplayMode(dynamicTypeSize.isAccessibilitySize ? .inline : .large)
        .searchable(
            text: $searchText,
            isPresented: $isSearchPresented,
            placement: dynamicTypeSize.isAccessibilitySize
                ? .navigationBarDrawer(displayMode: .always)
                : .automatic,
            prompt: "搜索菜名、食材或标签"
        )
        .refreshable { await store.loadRecipes() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("库存匹配", selection: $filter) { ForEach(RecipeAvailabilityFilter.allCases) { Text($0.rawValue).tag($0) } }
                    Picker("标签", selection: $selectedTag) { ForEach(tags, id: \.self) { Text($0).tag($0) } }
                    Picker("难度", selection: $selectedDifficulty) {
                        ForEach(["全部难度", "简单", "中等", "较难"], id: \.self) { Text($0).tag($0) }
                    }
                    Picker("烹饪时间", selection: $maximumTime) {
                        Text("不限时间").tag(Int?.none)
                        Text("15 分钟内").tag(Int?.some(15)); Text("30 分钟内").tag(Int?.some(30)); Text("60 分钟内").tag(Int?.some(60))
                    }
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                .accessibilityLabel("筛选菜谱")
                .accessibilityIdentifier("recipe.filter.menu")

                Menu {
                    Button { route = .manual } label: { Label("手动添加", systemImage: "square.and.pencil") }
                    Button { route = .linkImport } label: { Label("从链接导入", systemImage: "link") }
                    Button { route = .imageImport } label: { Label("从图片导入", systemImage: "photo.badge.plus") }
                    Button { route = .aiGenerator } label: { Label("AI 做菜", systemImage: "sparkles") }
                } label: { Image(systemName: "plus") }
                .accessibilityLabel("添加菜谱")
            }
        }
        .navigationDestination(item: $route) { route in
            switch route {
            case .manual: ManualRecipeView()
            case .linkImport: ImportRecipeView()
            case .imageImport: RecipeImageImportView()
            case .aiGenerator: AIGeneratorView()
            }
        }
        #if DEBUG
        .task {
            guard ProcessInfo.processInfo.arguments.contains("UITEST_RECIPE_EMPTY_SCREENSHOT") else { return }
            searchText = "没有匹配的测试菜谱"
            isSearchPresented = true
        }
        #endif
    }

    private func missingCoreIngredientCount(_ recipe: Recipe) -> Int {
        recipe.ingredients.filter { line in
            let key = IngredientNormalizer.matchKey(IngredientParser.parse(line).displayName)
            return !kitchenStore.availableInventory.contains { IngredientNormalizer.matchKey($0.name) == key }
        }.count
    }

    private func availabilityText(_ recipe: Recipe) -> String {
        let count = missingCoreIngredientCount(recipe)
        return count == 0 ? "可直接做" : count <= 2 ? "缺 \(count) 样" : "缺少较多"
    }

    private var emptyStateTitle: String {
        if !searchText.isEmpty { return "没有找到匹配菜谱" }
        if hasActiveFilters { return "没有符合筛选的菜谱" }
        return "暂时没有菜谱"
    }

    private var emptyStateDescription: String {
        if !searchText.isEmpty || hasActiveFilters {
            return "试试菜名、食材，或清除部分筛选条件。"
        }
        return "添加一份菜谱，下一餐就有了开始。"
    }

    private var resultSectionTitle: String {
        if !searchText.isEmpty { return "搜索结果 · \(recipes.count) 道" }
        if hasActiveFilters { return "筛选结果 · \(recipes.count) 道" }
        if store.isDisplayingSamples { return "示例菜谱 · \(recipes.count) 道" }
        return "全部菜谱 · \(recipes.count) 道"
    }

    private func clearFilters() {
        filter = .all
        selectedTag = "全部标签"
        selectedDifficulty = "全部难度"
        maximumTime = nil
    }
}

private struct RecipeListRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let recipe: Recipe
    let availability: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(recipe.title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 5) {
                        metadata
                        availabilityStatus
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            metadata
                            Spacer(minLength: 8)
                            availabilityStatus
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            metadata
                            availabilityStatus
                        }
                    }
                }
            }

            if !recipe.tags.isEmpty {
                Text(recipe.tags.prefix(2).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var metadata: some View {
        Text(recipe.summaryText)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var availabilityStatus: some View {
        HStack(spacing: 4) {
            Image(systemName: availability == "可直接做" ? "checkmark.circle.fill" : "basket")
                .accessibilityHidden(true)
            Text(availability)
        }
            .font(.footnote.weight(.medium))
            .foregroundStyle(availability == "可直接做" ? AppTheme.brand : AppTheme.textSecondary)
            .fixedSize(horizontal: true, vertical: false)
    }
}

struct RecipeDetailView: View {
    let recipe: Recipe
    let todayPlan: MealPlanItem?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var recipeStore: RecipeStore
    @EnvironmentObject private var kitchenStore: KitchenStore
    @State private var isShowingShoppingGeneration = false
    @State private var isEditing = false
    @State private var isShowingDeleteAlert = false
    @State private var isShowingCookingMode = false
    @State private var isShowingConsumptionConfirmation = false
    @State private var errorMessage: String?
    @StateObject private var cookingSession: RecipeCookingSession

    init(recipe: Recipe, todayPlan: MealPlanItem? = nil) {
        self.recipe = recipe
        self.todayPlan = todayPlan
        _cookingSession = StateObject(wrappedValue: RecipeCookingSession(servings: todayPlan?.servings ?? 1))
    }

    private var cookingSteps: [String] { recipe.steps.filter { !$0.hasPrefix("小贴士：") } }
    private var tips: [String] { recipe.steps.compactMap { $0.hasPrefix("小贴士：") ? String($0.dropFirst("小贴士：".count)) : nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                recipeHero

                RecipeDetailSection("份量", systemImage: "person.2") {
                    // The recipe's own yield, distinct from the cooking-session
                    // multiplier below: this is what the written quantities mean,
                    // and "未标注" is a real answer for recipes that never said.
                    HStack {
                        Text("基准份量")
                        Spacer()
                        Text(recipe.baseServings.map { "\($0) 人份" } ?? "未标注")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("recipe.detail.baseServings")

                    Stepper(value: $cookingSession.servings, in: 1...12) {
                        Text("当前份量：\(cookingSession.servings) 人份")
                    }
                    .accessibilityIdentifier("recipe.detail.servings")

                    Text("仅调整当前查看和烹饪会话的用量，不会修改原始菜谱。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                RecipeDetailSection("食材", systemImage: "basket") {
                    if recipe.ingredients.isEmpty {
                        Text("暂未记录食材")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(recipe.ingredients.enumerated()), id: \.offset) { index, value in
                            ingredientRow(value, index: index)
                        }
                    }
                }

                if !recipe.seasonings.isEmpty {
                    RecipeDetailSection("调料与辅料", systemImage: "leaf") {
                        ForEach(Array(recipe.seasonings.enumerated()), id: \.offset) { index, value in
                            ingredientRow(value, index: recipe.ingredients.count + index)
                        }
                    }
                }

                RecipeDetailSection("步骤", systemImage: "list.number") {
                    if cookingSteps.isEmpty {
                        Text("暂未记录制作步骤")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(cookingSteps.enumerated()), id: \.offset) { index, step in
                            RecipeStepRow(number: index + 1, text: step)
                        }
                    }
                }

                if !tips.isEmpty {
                    RecipeDetailSection("小贴士", systemImage: "lightbulb") {
                        ForEach(tips, id: \.self) { tip in
                            Label(tip, systemImage: "lightbulb")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

            }
            .padding(.horizontal)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                startCookingAction
                    .padding(.horizontal)
                    .padding(.top, 8)
                    // Gap between the CTA and the bottom system safe area. The tab
                    // bar is hidden for this destination, so the inset now sits
                    // directly on the home indicator inset rather than on the bar —
                    // the previous 20pt was tuned against the bar and reads as dead
                    // space without it. Must NOT reuse the scrolling-content
                    // clearance token (72pt) or the bar re-bloats.
                    .padding(.bottom, 12)
            }
            .background(.bar)
        }
        .navigationTitle("菜谱详情").navigationBarTitleDisplayMode(.inline)
        // Recipe Detail is a focused "cook this now" surface pushed onto the 菜谱
        // tab's own NavigationStack. Without this the floating tab bar stacks
        // directly under the pinned 开始烹饪 CTA — two rounded bars competing at the
        // bottom edge, costing 18.3% of an 844pt screen at default Dynamic Type and
        // 23.3% at Accessibility XXXL, exactly where step text needs the room.
        //
        // Same mechanism the Guest Merge flow uses: SwiftUI scopes it to this
        // destination, so the tab bar returns on its own when Detail is popped —
        // no route-level state, no dependence on the bar's minimize behavior, and
        // the bottom system safe area is left intact for the CTA inset above.
        .toolbarVisibility(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("加入今日计划", systemImage: "calendar.badge.plus") { kitchenStore.addPlan(recipe: recipe) }
                    Button("加入买菜清单", systemImage: "cart.badge.plus") { isShowingShoppingGeneration = true }
                    Button("编辑菜谱", systemImage: "square.and.pencil") { isEditing = true }
                    Button(recipeStore.favoriteRecipeIDs.contains(recipe.id) ? "取消收藏" : "收藏", systemImage: "heart") { recipeStore.toggleFavorite(recipe.id) }
                    Button(recipeStore.frequentRecipeIDs.contains(recipe.id) ? "取消常做" : "设为常做", systemImage: "star") { recipeStore.toggleFrequent(recipe.id) }
                    if recipeStore.userRecipes.contains(where: { $0.id == recipe.id }) {
                        let isOverride = recipeStore.remoteRecipes.contains(where: { $0.id == recipe.id })
                        Button(isOverride ? "重置为默认" : "删除用户菜谱", systemImage: isOverride ? "arrow.counterclockwise" : "trash", role: isOverride ? nil : .destructive) {
                            isShowingDeleteAlert = true
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("菜谱操作")
            }
        }
        .navigationDestination(isPresented: $isShowingShoppingGeneration) { ShoppingListGenerationView(source: .recipe(recipe, servings: 1)) }
        .navigationDestination(isPresented: $isEditing) { RecipeEditView(recipe: recipe) }
        .fullScreenCover(isPresented: $isShowingCookingMode) {
            RecipeCookingModeView(recipe: recipe, session: cookingSession, todayPlan: todayPlan) {
                isShowingCookingMode = false
                isShowingConsumptionConfirmation = true
            } onExit: { isShowingCookingMode = false }
            .environmentObject(kitchenStore)
        }
        .sheet(isPresented: $isShowingConsumptionConfirmation) {
            CookConsumptionConfirmationView(
                title: recipe.title,
                planIDs: todayPlan.map { kitchenStore.hasConsumedPlan($0.id) ? [] : [$0.id] } ?? [],
                recipeID: recipe.id,
                recipeName: recipe.title,
                recipe: todayPlan == nil ? recipe : nil,
                servings: cookingSession.servings
            ) {
                if let todayPlan { kitchenStore.markPlanCooked(todayPlan) }
            }
        }
        .alert(recipeStore.remoteRecipes.contains(where: { $0.id == recipe.id }) ? "重置这份菜谱？" : "删除这份菜谱？", isPresented: $isShowingDeleteAlert) {
            Button(recipeStore.remoteRecipes.contains(where: { $0.id == recipe.id }) ? "重置" : "删除", role: .destructive) { do { try recipeStore.deleteUserRecipe(id: recipe.id) } catch { errorMessage = error.localizedDescription } }
            Button("取消", role: .cancel) {}
        }
        .alert("操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("好", role: .cancel) {} } message: { Text(errorMessage ?? "请稍后重试。") }
    }

    private var recipeHero: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(recipe.title)
                .font(dynamicTypeSize.isAccessibilitySize ? .headline.weight(.bold) : .largeTitle.weight(.bold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if dynamicTypeSize.isAccessibilitySize {
                recipeMetadataVertical
            } else {
                ViewThatFits(in: .horizontal) {
                    recipeMetadataHorizontal
                    recipeMetadataVertical
                }
            }

            if !recipe.tags.isEmpty {
                Text(recipe.tags.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var recipeMetadataHorizontal: some View {
        HStack(spacing: 14) {
            Label("\(cookingSession.servings) 人份", systemImage: "person.2")
            if let cookingTime = recipe.cookingTime { Label("约 \(cookingTime) 分钟", systemImage: "clock") }
            if let difficulty = recipe.difficulty, !difficulty.isEmpty { Label(difficulty, systemImage: "chart.bar") }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private var recipeMetadataVertical: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(cookingSession.servings) 人份", systemImage: "person.2")
            if let cookingTime = recipe.cookingTime { Label("约 \(cookingTime) 分钟", systemImage: "clock") }
            if let difficulty = recipe.difficulty, !difficulty.isEmpty { Label(difficulty, systemImage: "chart.bar") }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private var startCookingAction: some View {
        Button { isShowingCookingMode = true } label: {
            Label("开始烹饪", systemImage: "flame.fill")
                .frame(maxWidth: .infinity)
        }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.cookingActionFill)
            .foregroundStyle(AppTheme.onCookingAction)
            .font(.headline)
            .controlSize(.large)
            .frame(maxWidth: .infinity, minHeight: AppTheme.minimumHitTarget)
            .accessibilityIdentifier("recipe.detail.startCooking")
    }

    @ViewBuilder private func ingredientRow(_ value: String, index: Int) -> some View {
        Button { cookingSession.toggleIngredient(at: index) } label: {
            HStack(spacing: 12) {
                Image(systemName: cookingSession.checkedIngredientIndexes.contains(index) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(cookingSession.checkedIngredientIndexes.contains(index) ? AppTheme.success : .secondary)
                Text(RecipeServingScaler.scaledText(value, multiplier: Double(cookingSession.servings)))
                    .strikethrough(cookingSession.checkedIngredientIndexes.contains(index), color: .secondary)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: AppTheme.minimumHitTarget)
        .contentShape(Rectangle())
        .accessibilityIdentifier("recipe.detail.ingredient.\(index)")
        .accessibilityLabel("\(RecipeServingScaler.scaledText(value, multiplier: Double(cookingSession.servings)))，\(cookingSession.checkedIngredientIndexes.contains(index) ? "已准备" : "未准备")")
    }
}

private struct RecipeDetailSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RecipeStepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(AppTheme.secondarySurface, in: Circle())
            Text(text)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recipe.detail.step.\(number - 1)")
    }
}

private struct RecipeDetailPreview: View {
    let recipe: Recipe

    var body: some View {
        NavigationStack {
            RecipeDetailView(recipe: recipe)
        }
        .environmentObject(RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!))
        .environmentObject(KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!))
    }
}

#Preview("Recipe detail — no steps") {
    RecipeDetailPreview(recipe: Recipe(id: "preview-empty", title: "待补充做法", cookingTime: nil, difficulty: nil, tags: [], ingredients: ["番茄 2 个"], steps: []))
}

#Preview("Recipe detail — long content") {
    RecipeDetailPreview(recipe: Recipe(
        id: "preview-long", title: "慢炖番茄蔬菜浓汤", cookingTime: 75, difficulty: "中等", tags: ["家庭料理", "周末"],
        ingredients: ["新鲜成熟番茄 6 个（去皮切块后保留全部汁水）", "带叶芹菜 1 大把（仔细洗净后切成细末）"],
        seasonings: ["现磨黑胡椒 适量", "蔬菜高汤 800 毫升"],
        steps: ["用中小火慢慢煸炒所有蔬菜，持续搅拌直到边缘微微焦糖化且锅底没有粘连。", "加入番茄和高汤后保持轻微沸腾，炖煮至所有食材完全软烂并根据口味调整浓稠度。"]
    ))
}

#Preview("Recipe detail — large type") {
    RecipeDetailPreview(recipe: Recipe.samples[0])
        .environment(\.dynamicTypeSize, .accessibility3)
}

private struct RecipeEditView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: RecipeStore
    @State private var draft: EditableRecipeDraft
    @State private var errorMessage: String?

    init(recipe: Recipe) {
        _draft = State(initialValue: EditableRecipeDraft(
            id: recipe.id, title: recipe.title,
            // Carried through verbatim, including `nil`: editing a recipe that
            // never stated a yield must not invent one.
            baseServings: recipe.baseServings,
            cookingTime: recipe.cookingTime,
            difficulty: recipe.difficulty ?? "", tagsText: recipe.tags.joined(separator: "，"),
            ingredientsText: recipe.ingredients.joined(separator: "\n"), seasoningsText: recipe.seasonings.joined(separator: "\n"),
            stepsText: recipe.steps.filter { !$0.hasPrefix("小贴士：") }.joined(separator: "\n"),
            tipsText: recipe.steps.compactMap { $0.hasPrefix("小贴士：") ? String($0.dropFirst("小贴士：".count)) : nil }.joined(separator: "\n"),
            source: recipe.source
        ))
    }

    var body: some View {
        Form { RecipeDraftEditorSections(draft: $draft, showsExtendedFields: true) }
            .navigationTitle("编辑菜谱").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("保存") { do { try store.replaceUserRecipe(draft.makeRecipe()); dismiss() } catch { errorMessage = error.localizedDescription } }.disabled(!draft.isSaveEligible) }
            .alert("无法保存", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("好", role: .cancel) {} } message: { Text(errorMessage ?? "请检查内容。") }
    }
}

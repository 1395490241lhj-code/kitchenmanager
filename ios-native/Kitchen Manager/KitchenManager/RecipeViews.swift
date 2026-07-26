import SwiftUI

enum RecipeRoute: Hashable, Identifiable {
    case manual, linkImport, imageImport, aiGenerator
    var id: Self { self }
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
    @EnvironmentObject private var store: RecipeStore
    @EnvironmentObject private var kitchenStore: KitchenStore
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var route: RecipeRoute?
    @State private var filter: RecipeAvailabilityFilter = .all
    @State private var selectedTag = "全部标签"
    @State private var selectedDifficulty = "全部难度"
    @State private var maximumTime: Int?

    private var sourceRecipes: [Recipe] { store.recipes.isEmpty ? Recipe.samples : store.recipes }
    private var tags: [String] { ["全部标签"] + Array(Set(sourceRecipes.flatMap(\.tags))).sorted() }

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
            if recipes.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "暂时没有菜谱" : "没有找到匹配菜谱",
                    systemImage: searchText.isEmpty ? "book.closed" : "magnifyingglass",
                    description: Text(searchText.isEmpty ? "添加一份菜谱，下一餐就有了开始。" : "试试菜名、食材或其他筛选条件。")
                )
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
                    Text(searchText.isEmpty ? "全部菜谱 · \(recipes.count) 道" : "搜索结果 · \(recipes.count) 道")
                        .textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("菜谱")
        .searchable(text: $searchText, isPresented: $isSearchPresented, prompt: "搜索菜名、食材或标签")
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
}

private struct RecipeListRow: View {
    let recipe: Recipe
    let availability: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(recipe.title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)

            HStack(spacing: 8) {
                Text(recipe.summaryText)
                Text(availability)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if !recipe.tags.isEmpty {
                Text(recipe.tags.prefix(2).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
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
            VStack(alignment: .leading, spacing: 24) {
                recipeHero

                RecipeDetailSection("份量", systemImage: "person.2") {
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

                startCookingAction
            }
            .padding(.horizontal)
            .padding(.top, 20)
            .padding(.bottom, 16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("菜谱详情").navigationBarTitleDisplayMode(.inline)
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
                if let todayPlan { kitchenStore.markPlanCooked(todayPlan) }
                isShowingCookingMode = false
            } onExit: { isShowingCookingMode = false }
            .environmentObject(kitchenStore)
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

            if !recipe.tags.isEmpty {
                Text(recipe.tags.joined(separator: " · "))
                    .font(dynamicTypeSize.isAccessibilitySize ? .caption : .subheadline)
                    .foregroundStyle(.secondary)
            }

            if dynamicTypeSize.isAccessibilitySize {
                recipeMetadataVertical
            } else {
                ViewThatFits(in: .horizontal) {
                    recipeMetadataHorizontal
                    recipeMetadataVertical
                }
            }
        }
    }

    private var recipeMetadataHorizontal: some View {
        HStack(spacing: 14) {
            Label("\(cookingSession.servings) 人份", systemImage: "person.2")
            if let cookingTime = recipe.cookingTime { Label("约 \(cookingTime) 分钟", systemImage: "clock") }
            if let difficulty = recipe.difficulty, !difficulty.isEmpty { Label(difficulty, systemImage: "chart.bar") }
        }
        .font(dynamicTypeSize.isAccessibilitySize ? .caption2 : .subheadline)
        .imageScale(dynamicTypeSize.isAccessibilitySize ? .small : .medium)
        .foregroundStyle(.secondary)
    }

    private var recipeMetadataVertical: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(cookingSession.servings) 人份", systemImage: "person.2")
            if let cookingTime = recipe.cookingTime { Label("约 \(cookingTime) 分钟", systemImage: "clock") }
            if let difficulty = recipe.difficulty, !difficulty.isEmpty { Label(difficulty, systemImage: "chart.bar") }
        }
        .font(dynamicTypeSize.isAccessibilitySize ? .caption2 : .subheadline)
        .imageScale(dynamicTypeSize.isAccessibilitySize ? .small : .medium)
        .foregroundStyle(.secondary)
    }

    private var startCookingAction: some View {
        Button("开始烹饪", systemImage: "flame.fill") { isShowingCookingMode = true }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.brand)
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: AppTheme.minimumHitTarget)
            .padding(.top, 8)
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
        .contentShape(Rectangle())
        .padding(.vertical, 3)
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
            VStack(alignment: .leading, spacing: 12) {
                content
            }
        }
        .padding(16)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct RecipeStepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(AppTheme.brand)
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
            id: recipe.id, title: recipe.title, cookingTime: recipe.cookingTime,
            difficulty: recipe.difficulty ?? "", tagsText: recipe.tags.joined(separator: "，"),
            ingredientsText: recipe.ingredients.joined(separator: "\n"), seasoningsText: recipe.seasonings.joined(separator: "\n"),
            stepsText: recipe.steps.filter { !$0.hasPrefix("小贴士：") }.joined(separator: "\n"),
            tipsText: recipe.steps.compactMap { $0.hasPrefix("小贴士：") ? String($0.dropFirst("小贴士：".count)) : nil }.joined(separator: "\n"), source: recipe.source
        ))
    }

    var body: some View {
        Form { RecipeDraftEditorSections(draft: $draft, showsExtendedFields: true) }
            .navigationTitle("编辑菜谱").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("保存") { do { try store.replaceUserRecipe(draft.makeRecipe()); dismiss() } catch { errorMessage = error.localizedDescription } } }
            .alert("无法保存", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("好", role: .cancel) {} } message: { Text(errorMessage ?? "请检查内容。") }
    }
}

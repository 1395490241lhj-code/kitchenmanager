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
        List(recipes) { recipe in
            NavigationLink(destination: RecipeDetailView(recipe: recipe)) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack { Text(recipe.title).font(.headline); Spacer(); availabilityLabel(recipe) }
                    Text(recipe.summaryText).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .overlay { if recipes.isEmpty { ContentUnavailableView.search(text: searchText) } }
        .navigationTitle("菜谱")
        .searchable(text: $searchText, prompt: "搜索菜名、食材或标签")
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
    }

    private func missingCoreIngredientCount(_ recipe: Recipe) -> Int {
        recipe.ingredients.filter { line in
            let key = IngredientNormalizer.matchKey(IngredientParser.parse(line).displayName)
            return !kitchenStore.availableInventory.contains { IngredientNormalizer.matchKey($0.name) == key }
        }.count
    }

    @ViewBuilder private func availabilityLabel(_ recipe: Recipe) -> some View {
        let count = missingCoreIngredientCount(recipe)
        Text(count == 0 ? "可直接做" : count <= 2 ? "缺 \(count) 样" : "缺少较多")
            .font(.caption.weight(.semibold))
            .foregroundStyle(count == 0 ? AppTheme.success : .secondary)
    }
}

struct RecipeDetailView: View {
    let recipe: Recipe
    @EnvironmentObject private var recipeStore: RecipeStore
    @EnvironmentObject private var kitchenStore: KitchenStore
    @State private var isShowingShoppingGeneration = false
    @State private var isEditing = false
    @State private var isShowingDeleteAlert = false
    @State private var errorMessage: String?

    private var cookingSteps: [String] { recipe.steps.filter { !$0.hasPrefix("小贴士：") } }
    private var tips: [String] { recipe.steps.compactMap { $0.hasPrefix("小贴士：") ? String($0.dropFirst("小贴士：".count)) : nil } }

    var body: some View {
        List {
            Section {
                Text(recipe.title).font(.largeTitle.bold())
                if !recipe.tags.isEmpty { Text(recipe.tags.joined(separator: " · ")).foregroundStyle(AppTheme.primary) }
            }
            Section("食材") {
                if recipe.ingredients.isEmpty { Text("暂未记录食材").foregroundStyle(.secondary) }
                else { ForEach(Array(recipe.ingredients.enumerated()), id: \.offset) { _, value in Text(value) } }
            }
            if !recipe.seasonings.isEmpty {
                Section("调料与辅料") { ForEach(Array(recipe.seasonings.enumerated()), id: \.offset) { _, value in Text(value) } }
            }
            Section("步骤") {
                ForEach(Array(cookingSteps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top) { Text("\(index + 1)").font(.caption.bold()).foregroundStyle(AppTheme.primary); Text(step) }
                }
            }
            if !tips.isEmpty { Section("小贴士") { ForEach(tips, id: \.self) { Label($0, systemImage: "lightbulb") } } }
        }
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
        .alert(recipeStore.remoteRecipes.contains(where: { $0.id == recipe.id }) ? "重置这份菜谱？" : "删除这份菜谱？", isPresented: $isShowingDeleteAlert) {
            Button(recipeStore.remoteRecipes.contains(where: { $0.id == recipe.id }) ? "重置" : "删除", role: .destructive) { do { try recipeStore.deleteUserRecipe(id: recipe.id) } catch { errorMessage = error.localizedDescription } }
            Button("取消", role: .cancel) {}
        }
        .alert("操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("好", role: .cancel) {} } message: { Text(errorMessage ?? "请稍后重试。") }
    }
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

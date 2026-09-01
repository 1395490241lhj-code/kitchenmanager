import SwiftUI

// MARK: - Special plan detail

struct SpecialPlanDetailView: View {
    @EnvironmentObject private var kitchenStore: KitchenStore
    @EnvironmentObject private var recipeStore: RecipeStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let planID: UUID
    /// Deleting is owned by the Planner, which also holds the navigation path
    /// and pops this screen in the same update.
    let onDelete: () -> Void
    @State private var sheet: SpecialPlanDetailSheet?
    /// Transient AI menu state. Owned by the screen, never persisted: leaving
    /// the detail discards any unsaved draft.
    @StateObject private var menuDraft = SpecialPlanMenuDraftStore()

    private enum SpecialPlanDetailSheet: Identifiable {
        case edit(SpecialPlan)
        case picker
        case shopping([Recipe])
        case draftDish(SpecialPlanMenuDraftDish)

        var id: String {
            switch self {
            case .edit(let plan): "edit-\(plan.id.uuidString)"
            case .picker: "picker"
            case .shopping: "shopping"
            case .draftDish(let dish): "draft-\(dish.id.uuidString)"
            }
        }
    }

    /// Live plan read from the store, so an edit made in the form sheet shows
    /// immediately instead of rendering a stale snapshot. Deletion pops this
    /// screen through `onDelete`, so the empty branch is only a defensive
    /// placeholder for a route that outlived its plan.
    var body: some View {
        if let plan = kitchenStore.specialPlans.first(where: { $0.id == planID }) {
            content(plan)
        } else {
            ContentUnavailableView(
                "特殊计划不存在",
                systemImage: "calendar.badge.exclamationmark"
            )
        }
    }

    private func content(_ plan: SpecialPlan) -> some View {
        List {
            Section {
                LabeledContent("时间", value: Self.detailDateText(plan.scheduledAt))
                LabeledContent("人数", value: "\(plan.peopleCount) 人")
                    .accessibilityIdentifier("planner.special.peopleCount")
                if !plan.constraintNotes.isEmpty {
                    ForEach(plan.constraintNotes, id: \.self) { note in
                        LabeledContent("备注", value: note)
                    }
                }
                if !plan.notes.isEmpty {
                    LabeledContent("说明", value: plan.notes)
                }
            }

            if menuDraft.hasDraft || menuDraft.isGenerating {
                draftSection(plan)
            } else {
                menuSection(plan)
            }

            if let message = menuDraft.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.warningInk)
                        .accessibilityIdentifier("planner.menu.error")
                }
            }

            if !plan.dishes.isEmpty, menuDraft.hasDraft == false {
                shoppingSection(plan)
            }
        }
        .navigationTitle(plan.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("删除计划", systemImage: "trash")
                    }
                    .accessibilityIdentifier("planner.special.delete")
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel("更多操作")
                }
                Button {
                    sheet = .edit(plan)
                } label: {
                    Image(systemName: "pencil")
                        .accessibilityLabel("编辑特殊计划")
                }
                .accessibilityIdentifier("planner.special.edit")
                Button {
                    sheet = .picker
                } label: {
                    Image(systemName: "plus")
                        .accessibilityLabel("添加菜品")
                }
                .accessibilityIdentifier("planner.special.add.dish")
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .edit(let plan):
                SpecialPlanFormSheet(mode: .edit(plan)) { draft in
                    var updated = plan
                    updated.title = draft.title
                    updated.scheduledAt = draft.scheduledAt
                    updated.peopleCount = draft.peopleCount
                    updated.constraintNotes = draft.constraintNotes
                    updated.notes = draft.notes
                    updated.updatedAt = Date()
                    kitchenStore.updateSpecialPlan(updated)
                }
            case .picker:
                NavigationStack {
                    RecipePickerView { recipe in
                        let dish = SpecialPlanDish(recipeID: recipe.id, recipeName: recipe.title)
                        kitchenStore.addDish(dish, toSpecialPlan: planID)
                    }
                }
            case .shopping(let recipes):
                NavigationStack {
                    ShoppingListGenerationView(
                        source: .selectedRecipes(recipes, servings: 1)
                    )
                }
            case .draftDish(let dish):
                NavigationStack {
                    SpecialPlanDraftDishView(dish: dish)
                }
            }
        }
    }

    // MARK: - Canonical menu

    @ViewBuilder
    private func menuSection(_ plan: SpecialPlan) -> some View {
        Section {
            if plan.dishes.isEmpty {
                Text("还没有菜品，可以让 AI 按人数和忌口设计一份，或从菜谱库添加。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(indexedDishes(plan), id: \.element.id) { _, dish in
                    dishRow(dish, plan: plan)
                }
            }

            Button {
                Task {
                    await menuDraft.generate(
                        for: plan,
                        kitchenStore: kitchenStore,
                        recipeStore: recipeStore
                    )
                }
            } label: {
                Label(
                    plan.dishes.isEmpty ? "AI 帮我设计菜单" : "AI 重新设计菜单",
                    systemImage: "sparkles"
                )
                .frame(minHeight: AppTheme.minimumHitTarget)
            }
            .foregroundStyle(AppTheme.aiAccentForeground)
            .disabled(menuDraft.isBusy)
            .accessibilityIdentifier("planner.menu.generate")
        } header: {
            Text("菜单")
        } footer: {
            Text("菜品引用菜谱库，删除计划不会删除菜谱。")
        }
    }

    // MARK: - Transient AI draft

    @ViewBuilder
    private func draftSection(_ plan: SpecialPlan) -> some View {
        Section {
            if menuDraft.isGenerating {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在设计菜单…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: AppTheme.minimumHitTarget)
                .accessibilityIdentifier("planner.menu.generating")
            } else {
                ForEach(menuDraft.dishes) { dish in
                    draftRow(dish, plan: plan)
                }

                Button {
                    guard menuDraft.save(
                        to: planID,
                        kitchenStore: kitchenStore,
                        recipeStore: recipeStore
                    ) else { return }
                } label: {
                    Label("保存菜单", systemImage: "square.and.arrow.down")
                        .frame(minHeight: AppTheme.minimumHitTarget)
                }
                .disabled(menuDraft.isBusy)
                .accessibilityIdentifier("planner.menu.save")

                Button("放弃这份草稿") {
                    menuDraft.discard()
                }
                .foregroundStyle(.secondary)
                .frame(minHeight: AppTheme.minimumHitTarget)
                .accessibilityIdentifier("planner.menu.discard")
            }
        } header: {
            Text("AI 菜单草稿")
        } footer: {
            Text("保存前这些菜谱不会进入菜谱库。当前菜单按聚餐规模设计，食材用量仍是菜谱原始用量。")
        }
    }

    private func draftRow(_ dish: SpecialPlanMenuDraftDish, plan: SpecialPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(dish.title)
                    .font(.headline)
                    // Leaf-level, never on the enclosing VStack: an
                    // accessibility identifier on a container overrides every
                    // descendant's, which would erase the per-dish button ids
                    // below (same rule the Home section ids follow).
                    .accessibilityIdentifier("planner.menu.draft.dish.\(dish.id.uuidString)")
                if dish.isExistingRecipe {
                    Text("菜谱库")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if menuDraft.replacingDishID == dish.id {
                    ProgressView()
                }
            }
            if let reason = dish.reason, !reason.isEmpty {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Button("查看") {
                    sheet = .draftDish(dish)
                }
                .accessibilityIdentifier("planner.menu.draft.view.\(dish.id.uuidString)")

                Button("换一道") {
                    Task {
                        await menuDraft.replaceDish(
                            id: dish.id,
                            for: plan,
                            kitchenStore: kitchenStore,
                            recipeStore: recipeStore
                        )
                    }
                }
                .accessibilityIdentifier("planner.menu.draft.replace.\(dish.id.uuidString)")

                Button("移除", role: .destructive) {
                    menuDraft.removeDish(id: dish.id)
                }
                .accessibilityIdentifier("planner.menu.draft.remove.\(dish.id.uuidString)")
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
            .disabled(menuDraft.isBusy || menuDraft.replacingDishID != nil)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Shopping

    @ViewBuilder
    private func shoppingSection(_ plan: SpecialPlan) -> some View {
        Section {
            Button {
                sheet = .shopping(resolvedRecipes(plan))
            } label: {
                Label("查看购物需求", systemImage: "cart")
                    .frame(minHeight: AppTheme.minimumHitTarget)
            }
            .disabled(resolvedRecipes(plan).isEmpty)
            .accessibilityIdentifier("planner.shopping.open")
        } header: {
            Text("购物需求")
        } footer: {
            Text("按菜谱原始用量与当前库存比对，人数尚未用于精确换算用量。")
        }
    }

    /// The recipes this plan's dishes point at. A dish whose recipe was deleted
    /// is skipped rather than fabricated, matching how the Today Plan handles a
    /// missing recipe.
    private func resolvedRecipes(_ plan: SpecialPlan) -> [Recipe] {
        plan.dishes.compactMap { recipeStore.recipe(id: $0.recipeID) }
    }

    private func indexedDishes(_ plan: SpecialPlan) -> [(offset: Int, element: SpecialPlanDish)] {
        Array(plan.dishes.enumerated())
    }

    private func dishRow(_ dish: SpecialPlanDish, plan: SpecialPlan) -> some View {
        HStack(spacing: 12) {
            Button {
                kitchenStore.setDishCooked(dish.id, inSpecialPlan: plan.id, isCooked: !dish.isCooked)
            } label: {
                Image(systemName: dish.isCooked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(dish.isCooked ? AppTheme.success : AppTheme.textSecondary)
                    .frame(minWidth: AppTheme.minimumHitTarget, minHeight: AppTheme.minimumHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(dish.isCooked ? "标记未完成" : "标记完成")
            .accessibilityIdentifier("planner.dish.done.\(dish.id.uuidString)")

            NavigationLink(value: PlannerRoute.recipe(dish.recipeID)) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(dish.recipeName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(dish.isCooked ? "已完成" : "待准备")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("planner.dish.recipe.\(dish.id.uuidString)")
        }
        .padding(.vertical, 4)
        .frame(minHeight: dynamicTypeSize.isAccessibilitySize
               ? AppTheme.minimumHitTarget * 1.6
               : AppTheme.minimumHitTarget)
    }

    private static func detailDateText(_ scheduledAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "M月d日 EEEE HH:mm"
        return formatter.string(from: scheduledAt)
    }
}

// MARK: - Draft dish preview

/// Read-only look at what the AI proposed, before it becomes a recipe. Shows
/// the same fields the recipe editor would, so the user can judge the dish
/// without it entering the library first.
struct SpecialPlanDraftDishView: View {
    @Environment(\.dismiss) private var dismiss
    let dish: SpecialPlanMenuDraftDish

    var body: some View {
        List {
            if let reason = dish.reason, !reason.isEmpty {
                Section("推荐理由") {
                    Text(reason)
                }
            }
            Section("食材") {
                ForEach(dish.ingredients, id: \.self) { Text($0) }
            }
            if !dish.seasonings.isEmpty {
                Section("调料与辅料") {
                    ForEach(dish.seasonings, id: \.self) { Text($0) }
                }
            }
            Section("步骤") {
                ForEach(Array(dish.steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step)")
                }
            }
        }
        .navigationTitle(dish.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
    }
}

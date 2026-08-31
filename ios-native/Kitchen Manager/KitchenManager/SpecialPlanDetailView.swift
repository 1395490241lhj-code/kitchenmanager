import SwiftUI

// MARK: - Special plan detail

struct SpecialPlanDetailView: View {
    @EnvironmentObject private var kitchenStore: KitchenStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let planID: UUID
    /// Deleting is owned by the Planner, which also holds the navigation path
    /// and pops this screen in the same update.
    let onDelete: () -> Void
    @State private var sheet: SpecialPlanDetailSheet?

    private enum SpecialPlanDetailSheet: Identifiable {
        case edit(SpecialPlan)
        case picker

        var id: String {
            switch self {
            case .edit(let plan): "edit-\(plan.id.uuidString)"
            case .picker: "picker"
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

            Section {
                if plan.dishes.isEmpty {
                    Text("还没有菜品，从菜谱库添加。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(indexedDishes(plan), id: \.element.id) { _, dish in
                        dishRow(dish, plan: plan)
                    }
                }
            } header: {
                Text("菜单")
            } footer: {
                Text("菜品引用菜谱库，删除计划不会删除菜谱。")
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
            }
        }
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

/// Simple dish add flow: a searchable picker over `RecipeStore.recipesForDisplay`.
/// Deliberately not the full `RecipeListView` (which owns its own routes and
/// mutations); this sheet only ever adds a reference.

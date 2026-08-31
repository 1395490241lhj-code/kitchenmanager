import SwiftUI

// MARK: - Planner
//
// Minimal Planner surface: current week, one section per day, ordinary
// `MealPlanItem` rows next to `SpecialPlan` event rows. Pure projection; no new
// tab, no AI surface, no Home primary-task changes.

/// Route values pushed from the Planner's NavigationStack. Separate type so the
/// Planner never depends on the Recipes tab's route enum.
private enum PlannerRoute: Hashable {
    case specialPlan(UUID)
    case recipe(String)
}

private enum PlannerSheet: Identifiable {
    case create
    case edit(SpecialPlan)
    case pickRecipe(planID: UUID, planIndex: Int)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let plan): "edit-\(plan.id.uuidString)"
        case .pickRecipe(planID: let id, planIndex: let index): "pick-\(id.uuidString)-\(index)"
        }
    }
}

private struct PlannerRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: PlannerEntry
    let title: String
    let detail: String
    let identifier: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(AppTheme.brand)
                .frame(width: 32, alignment: .center)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: dynamicTypeSize.isAccessibilitySize
               ? AppTheme.minimumHitTarget * 1.6
               : AppTheme.minimumHitTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private var icon: String {
        switch entry {
        case .meal: "fork.knife"
        case .specialPlan: "calendar.badge.clock"
        }
    }
}

/// Week heading text, pinned to zh_Hans_CN (same convention as
/// `HomeDatePresentation` / `MealPrepBoard`).
private enum PlannerDateText {
    static func weekRange(start: Date, calendar: Calendar = .current) -> String {
        let end = PlannerProjection.nextWeekStart(after: start, calendar: calendar)
        let endDay = calendar.date(byAdding: .day, value: -1, to: end) ?? end
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M月d日"
        if calendar.isDate(start, inSameDayAs: endDay) {
            return formatter.string(from: start)
        }
        return "\(formatter.string(from: start)) – \(formatter.string(from: endDay))"
    }

    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: date)
    }
}

struct PlannerView: View {
    @EnvironmentObject private var kitchenStore: KitchenStore
    @EnvironmentObject private var recipeStore: RecipeStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var path: [PlannerRoute] = []
    @State private var weekStart: Date
    @State private var sheet: PlannerSheet?
    private let calendar: Calendar
    private let now: Date

    init(
        weekStart: Date? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let reference = now
        self.calendar = calendar
        self.now = reference
        _weekStart = State(initialValue: weekStart ?? PlannerProjection.startOfWeek(containing: reference, calendar: calendar))
    }

    var body: some View {
        NavigationStack(path: $path) {
            weekList
                .navigationTitle("本周安排")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button("本周") {
                                weekStart = PlannerProjection.startOfWeek(containing: now, calendar: calendar)
                            }
                            Button("上一周") {
                                moveWeek(by: -7)
                            }
                            Button("下一周") {
                                moveWeek(by: 7)
                            }
                        } label: {
                            Image(systemName: "calendar")
                                .accessibilityLabel("切换周")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            sheet = .create
                        } label: {
                            Image(systemName: "plus")
                                .accessibilityLabel("新建特殊计划")
                        }
                        .accessibilityIdentifier("planner.special.create")
                    }
                }
                .navigationDestination(for: PlannerRoute.self) { route in
                    switch route {
                    case .specialPlan(let id):
                        if kitchenStore.specialPlans.contains(where: { $0.id == id }) {
                            SpecialPlanDetailView(planID: id) {
                                deleteSpecialPlan(id: id)
                            }
                        } else {
                            ContentUnavailableView("特殊计划不存在", systemImage: "calendar.badge.exclamationmark")
                        }
                    case .recipe(let id):
                        if let recipe = recipeStore.recipe(id: id) {
                            RecipeDetailView(recipe: recipe)
                        } else {
                            ContentUnavailableView("菜谱不存在", systemImage: "questionmark.folder")
                        }
                    }
                }
                .sheet(item: $sheet) { sheet in
                    switch sheet {
                    case .create:
                        SpecialPlanFormSheet(
                            mode: .create,
                            onSave: { draft in
                                var plan = SpecialPlan(
                                    title: draft.title,
                                    scheduledAt: draft.scheduledAt,
                                    peopleCount: draft.peopleCount,
                                    constraintNotes: draft.constraintNotes,
                                    notes: draft.notes
                                )
                                plan.createdAt = Date()
                                plan.updatedAt = plan.createdAt
                                kitchenStore.addSpecialPlan(plan)
                            }
                        )
                    case .edit(let plan):
                        SpecialPlanFormSheet(
                            mode: .edit(plan),
                            onSave: { draft in
                                var updated = plan
                                updated.title = draft.title
                                updated.scheduledAt = draft.scheduledAt
                                updated.peopleCount = draft.peopleCount
                                updated.constraintNotes = draft.constraintNotes
                                updated.notes = draft.notes
                                updated.updatedAt = Date()
                                kitchenStore.updateSpecialPlan(updated)
                            }
                        )
                    case .pickRecipe(let planID, _):
                        NavigationStack {
                            RecipePickerView { recipe in
                                let dish = SpecialPlanDish(
                                    recipeID: recipe.id,
                                    recipeName: recipe.title
                                )
                                kitchenStore.addDish(dish, toSpecialPlan: planID)
                            }
                        }
                    }
                }
        }
    }

    private var weekList: some View {
        List {
            Section {
                HStack {
                    Text(PlannerDateText.weekRange(start: weekStart, calendar: calendar))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if weekStart == PlannerProjection.startOfWeek(containing: now, calendar: calendar) {
                        Text("本周")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            let groups = PlannerProjection.dayGroups(
                inWeekStarting: weekStart,
                entries: PlannerProjection.entries(
                    inWeekStarting: weekStart,
                    meals: kitchenStore.plans,
                    specialPlans: kitchenStore.specialPlans,
                    calendar: calendar
                ),
                calendar: calendar
            )
            ForEach(groups) { group in
                Section(PlannerDateText.day(group.day, calendar: calendar)) {
                    if group.entries.isEmpty {
                        Text("暂无安排")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(group.entries) { entry in
                            row(for: entry)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private func row(for entry: PlannerEntry) -> some View {
        switch entry {
        case .meal(let meal):
            NavigationLink(value: PlannerRoute.recipe(meal.recipeID)) {
                PlannerRow(
                    entry: entry,
                    title: meal.recipeName,
                    detail: meal.isCooked ? "已完成" : "\(meal.servings) 人份",
                    identifier: "planner.meal.\(meal.id.uuidString)"
                )
            }
        case .specialPlan(let plan):
            NavigationLink(value: PlannerRoute.specialPlan(plan.id)) {
                PlannerRow(
                    entry: entry,
                    title: plan.title,
                    detail: plan.detailText,
                    identifier: "planner.special.entry.\(plan.id.uuidString)"
                )
            }
        }
    }

    /// Deletes the plan and pops its detail in the same update, so the user
    /// lands back on the week list with the row already gone. Popping here
    /// rather than inside the detail keeps the navigation state owned by the
    /// view that owns the path.
    private func deleteSpecialPlan(id: UUID) {
        kitchenStore.removeSpecialPlan(id: id)
        path.removeAll { route in
            switch route {
            case .specialPlan(let routeID): return routeID == id
            case .recipe: return false
            }
        }
    }

    private func moveWeek(by days: Int) {
        if let next = calendar.date(byAdding: .day, value: days, to: weekStart) {
            weekStart = next
        }
    }
}

extension SpecialPlan {
    /// "7 人 · 18:30"
    fileprivate var detailText: String {
        let parts = ["\(peopleCount) 人", Self.timeText(scheduledAt)] + constraintNotes.prefix(2)
        return parts.joined(separator: " · ")
    }
}

// MARK: - Special plan detail + form

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
private struct RecipePickerView: View {
    @EnvironmentObject private var recipeStore: RecipeStore
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    let onSelect: (Recipe) -> Void

    private var recipes: [Recipe] {
        let all = recipeStore.recipesForDisplay
        guard !searchText.isEmpty else { return all }
        return all.filter { recipe in
            recipe.title.localizedCaseInsensitiveContains(searchText)
                || recipe.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
                || (recipe.ingredients + recipe.seasonings).contains {
                    $0.localizedCaseInsensitiveContains(searchText)
                }
        }
    }

    var body: some View {
        List(recipes) { recipe in
            Button {
                onSelect(recipe)
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recipe.title).font(.headline)
                        if let time = recipe.cookingTime {
                            Text("\(time) 分钟")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(AppTheme.brand)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("添加菜品")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索菜名或食材")
    }
}

private struct SpecialPlanDraft {
    var title = ""
    var scheduledAt = Date()
    var peopleCount = 2
    var constraintNotes: [String] = []
    var notes = ""
}

private enum SpecialPlanFormMode: Identifiable {
    case create
    case edit(SpecialPlan)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let plan): "edit-\(plan.id.uuidString)"
        }
    }
}

/// Create/Edit form sheet. Owns its dismiss via the environment; the parent
/// supplies only the save callback.
private struct SpecialPlanFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    let mode: SpecialPlanFormMode
    let onSave: (SpecialPlanDraft) -> Void

    @State private var draft: SpecialPlanDraft
    @State private var constraintText = ""

    init(mode: SpecialPlanFormMode, onSave: @escaping (SpecialPlanDraft) -> Void) {
        self.mode = mode
        self.onSave = onSave
        switch mode {
        case .create:
            _draft = State(initialValue: SpecialPlanDraft())
        case .edit(let plan):
            _draft = State(initialValue: SpecialPlanDraft(
                title: plan.title,
                scheduledAt: plan.scheduledAt,
                peopleCount: plan.peopleCount,
                constraintNotes: plan.constraintNotes,
                notes: plan.notes
            ))
        }
        _constraintText = State(initialValue: (mode.editPlan?.constraintNotes ?? []).joined(separator: "\n"))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("活动名称", text: $draft.title)
                    DatePicker(
                        "日期",
                        selection: $draft.scheduledAt,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    Stepper("\(draft.peopleCount) 人", value: $draft.peopleCount, in: 1...99)
                }
                Section("忌口与注意事项") {
                    TextField(
                        "每行一条，例如：1 人不吃辣",
                        text: $constraintText,
                        axis: .vertical
                    )
                    .lineLimit(2...6)
                }
                Section("备注") {
                    TextField("补充说明", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...6)
                }
            }
            .navigationTitle(mode.isEdit ? "编辑特殊计划" : "新建特殊计划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.constraintNotes = constraintText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        onSave(draft)
        dismiss()
    }
}

extension SpecialPlanFormMode {
    fileprivate var isEdit: Bool {
        switch self {
        case .create: false
        case .edit: true
        }
    }

    fileprivate var editPlan: SpecialPlan? {
        switch self {
        case .create: nil
        case .edit(let plan): plan
        }
    }
}

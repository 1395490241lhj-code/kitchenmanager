import SwiftUI

// MARK: - Planner
//
// Minimal Planner surface: current week, one section per day, ordinary
// `MealPlanItem` rows next to `SpecialPlan` event rows. Pure projection; no new
// tab, no AI surface, no Home primary-task changes.

/// Route values pushed from the Planner's NavigationStack. Separate type so the
/// Planner never depends on the Recipes tab's route enum.
/// Shared with `SpecialPlanDetailView`, which pushes recipe routes from its
/// dish rows, so this is file-internal rather than private.
enum PlannerRoute: Hashable {
    case specialPlan(UUID)
    case recipe(String)
    /// An ordinary meal, carried by id rather than by value so the destination
    /// always resolves the current plan: an edit that lands while the detail is
    /// open must not leave a stale copy on the navigation path.
    case plannedMeal(UUID)
}

private enum PlannerSheet: Identifiable {
    case create
    case createMeal
    case editMeal(UUID)
    case pickRecipe(planID: UUID, planIndex: Int)

    var id: String {
        switch self {
        case .create: "create"
        case .createMeal: "create-meal"
        case .editMeal(let id): "edit-meal-\(id.uuidString)"
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
            if case .specialPlan = entry {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                if !detail.isEmpty {
                    Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
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
    /// A menu the creation sheet composed for a plan that was just added. Held
    /// until the detail for that plan is pushed, which seeds its draft store;
    /// cleared when that detail leaves the path so a reopened plan never
    /// resurrects a draft the user already dismissed.
    @State private var pendingDraft: (planID: UUID, dishes: [SpecialPlanMenuDraftDish])?
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
                // Not 本周安排: the toolbar pages to any week, and the list holds
                // ordinary meals as well as special plans. The week actually on
                // screen is stated by the range row at the top of the list, so
                // the title does not repeat it.
                .navigationTitle("用餐计划")
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
                        // Two things can be created here now, so the one control
                        // that creates anything names both rather than standing
                        // for whichever one it used to open. 新建聚餐, not an AI
                        // label: AI is how that composer works, not what the
                        // user is making.
                        Menu {
                            Button("新建一餐") { sheet = .createMeal }
                                .accessibilityIdentifier("planner.meal.create")
                            Button("新建聚餐") { sheet = .create }
                                .accessibilityIdentifier("planner.special.create")
                        } label: {
                            Image(systemName: "plus")
                                .accessibilityLabel("新建")
                        }
                        .accessibilityIdentifier("planner.create.menu")
                    }
                }
                .navigationDestination(for: PlannerRoute.self) { route in
                    switch route {
                    case .specialPlan(let id):
                        if kitchenStore.specialPlans.contains(where: { $0.id == id }) {
                            SpecialPlanDetailView(
                                planID: id,
                                initialDraft: pendingDraft?.planID == id ? pendingDraft?.dishes ?? [] : []
                            ) {
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
                    case .plannedMeal(let id):
                        plannedMealDestination(id)
                    }
                }
                .sheet(item: $sheet) { sheet in
                    switch sheet {
                    case .create:
                        // The week view has no selected day, so the composer
                        // gets no context date: the request names the date, or
                        // the interpretation falls back on its own.
                        SpecialPlanComposerSheet(mode: .create(contextDate: nil)) { result in
                            kitchenStore.addSpecialPlan(result.plan)
                            pendingDraft = (result.plan.id, result.dishes)
                        }
                    case .createMeal:
                        PlannerMealFormView(defaultDate: creationDefaultDate, calendar: calendar) { item in
                            // A meal saved outside the week on screen would
                            // otherwise land somewhere the user cannot see, so
                            // the Planner follows it to its own week.
                            reveal(item)
                        }
                    case .editMeal(let id):
                        if let plan = kitchenStore.plans.first(where: { $0.id == id }) {
                            PlannerMealFormView(editing: plan, calendar: calendar) { item in
                                // Moving a meal is editing its date, so the same
                                // rule applies: follow it to wherever it went.
                                reveal(item)
                            }
                        } else {
                            ContentUnavailableView("这一餐不存在", systemImage: "calendar.badge.exclamationmark")
                        }
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
                .onChange(of: sheet?.id) { _, current in
                    // Push the new plan's detail once the composer has fully
                    // dismissed, so the draft is on screen without a second tap.
                    guard current == nil, let pending = pendingDraft else { return }
                    if !path.contains(.specialPlan(pending.planID)) {
                        path.append(.specialPlan(pending.planID))
                    }
                }
                .onChange(of: path) { _, current in
                    guard let pending = pendingDraft,
                          !current.contains(.specialPlan(pending.planID)) else { return }
                    pendingDraft = nil
                }
        }
    }

    private var weekList: some View {
        List {
            Section {
                HStack {
                    Text(PlannerDateText.weekRange(start: weekStart, calendar: calendar))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(KitchenTheme.textPrimary)
                    Spacer()
                    if weekStart == PlannerProjection.startOfWeek(containing: now, calendar: calendar) {
                        Text("本周")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .plannerRow()
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
            // A week with nothing on it said 暂无安排 seven times and offered no
            // way to create anything: the only control that does is a bare `+`
            // glyph in the toolbar. Seven repetitions of the same absence are
            // not week context — the range row above already carries that — so
            // an entirely empty week collapses to one state that names the
            // absence once and can be acted on.
            if groups.allSatisfy(\.entries.isEmpty) {
                Section {
                    ContentUnavailableView {
                        Label("这一周还没有安排", systemImage: "calendar")
                    } description: {
                        Text("先安排一餐，这一周就有了着落。")
                    } actions: {
                        // Straight into ordinary creation: scheduling the first
                        // meal is what an empty week is for, and 聚餐 stays one
                        // tap away in the toolbar menu.
                        Button("新建一餐") { sheet = .createMeal }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("planner.empty.create")
                    }
                }
                .listRowBackground(Color.clear)
                .plannerRow()
            } else {
                ForEach(groups) { group in
                    Section {
                        // An empty day renders its dated header and nothing
                        // else. 暂无安排 gave a day with no plans the same
                        // vertical weight as a day with one, so a sparse week
                        // read as a wall of absence with the real entries
                        // scattered through it. Empty is the default state of a
                        // week, not news — the header still marks the day, so
                        // the calendar skeleton survives at a fraction of the
                        // height.
                        ForEach(group.entries) { entry in
                            row(for: entry)
                                .plannerRow()
                        }
                    } header: {
                        let today = calendar.isDate(group.day, inSameDayAs: now)
                        Text(PlannerDateText.day(group.day, calendar: calendar) + (today ? " · 今天" : ""))
                            .font(.subheadline.weight(today ? .semibold : .regular))
                            .foregroundStyle(today ? Color.primary : Color.secondary)
                            .accessibilityIdentifier("planner.day.\(calendar.component(.day, from: group.day))")
                            .accessibilityAddTraits(.isHeader)
                            .textCase(nil)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                            .listRowInsets(EdgeInsets(top: 0, leading: KitchenTheme.pageGutter,
                                                     bottom: 0, trailing: KitchenTheme.pageGutter))
                            .background(KitchenTheme.canvas)
                    }
                }
            }
        }
        .plannerList()
    }

    @ViewBuilder
    private func row(for entry: PlannerEntry) -> some View {
        switch entry {
        case .meal(let meal):
            NavigationLink(value: PlannerRoute.plannedMeal(meal.id)) {
                PlannerRow(
                    entry: entry,
                    title: meal.recipeName,
                    // An unstated target shows nothing rather than "1 人份".
                    detail: meal.isCooked ? "已完成" : (meal.plannedServings.map { "\($0) 人份" } ?? ""),
                    identifier: "planner.meal.\(meal.id.uuidString)"
                )
            }
            // Edit is a swipe and a context menu, the two places iOS already
            // puts row actions. Neither is discoverable to VoiceOver, so the
            // custom action carries the same capability for it.
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button("编辑") { sheet = .editMeal(meal.id) }
                    .accessibilityIdentifier("planner.meal.edit.\(meal.id.uuidString)")
            }
            .contextMenu {
                Button("编辑", systemImage: "pencil") { sheet = .editMeal(meal.id) }
                    .accessibilityIdentifier("planner.meal.editMenu.\(meal.id.uuidString)")
            }
            .accessibilityAction(named: "编辑") { sheet = .editMeal(meal.id) }
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
            case .recipe, .plannedMeal: return false
            }
        }
    }

    private func moveWeek(by days: Int) {
        if let next = calendar.date(byAdding: .day, value: days, to: weekStart) {
            weekStart = next
        }
    }

    /// Brings a just-saved meal into view. Creating for another week and moving
    /// a meal to one are the same problem: the result must not land somewhere
    /// the user is not looking.
    private func reveal(_ item: MealPlanItem) {
        let target = PlannerProjection.startOfWeek(containing: item.date, calendar: calendar)
        if target != weekStart { weekStart = target }
    }

    /// Opens an ordinary meal with its own plan attached, so the cooking flow
    /// behind it marks *this* plan cooked. Home and today's plan detail have
    /// always passed the plan; the Planner passed only a recipe id, which is
    /// why the same dish finished from here never completed.
    @ViewBuilder
    private func plannedMealDestination(_ id: UUID) -> some View {
        if let plan = kitchenStore.plans.first(where: { $0.id == id }) {
            if let recipe = recipeStore.recipe(id: plan.recipeID) {
                RecipeDetailView(recipe: recipe, plan: plan)
            } else {
                // Same fallback Home and today's plan detail use: the plan
                // survives a recipe that has gone missing.
                ContentUnavailableView(
                    "菜谱暂不可用",
                    systemImage: "book.closed",
                    description: Text("这份计划保留不变，可以稍后重试。")
                )
            }
        } else {
            ContentUnavailableView("这一餐不存在", systemImage: "calendar.badge.exclamationmark")
        }
    }

    /// The day a new meal starts on: today while the current week is on screen,
    /// otherwise the first day of whatever week is. Uses the Planner's own week
    /// anchor rather than a second definition of where a week begins.
    private var creationDefaultDate: Date {
        weekStart == PlannerProjection.startOfWeek(containing: now, calendar: calendar) ? now : weekStart
    }
}

extension SpecialPlan {
    /// "7 人 · 18:30"
    fileprivate var detailText: String {
        let parts = ["\(peopleCount) 人", Self.timeText(scheduledAt)] + constraintNotes.prefix(2)
        return parts.joined(separator: " · ")
    }
}

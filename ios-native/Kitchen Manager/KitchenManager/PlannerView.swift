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
}

private enum PlannerSheet: Identifiable {
    case create
    case pickRecipe(planID: UUID, planIndex: Int)

    var id: String {
        switch self {
        case .create: "create"
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
                    // An unstated target shows nothing rather than "1 人份".
                    detail: meal.isCooked ? "已完成" : (meal.plannedServings.map { "\($0) 人份" } ?? ""),
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

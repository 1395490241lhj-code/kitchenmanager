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
    case todayShopping
    case weeklyGenerator
    case kitchenAI(Date, UUID?)
    /// 菜谱 in the four-destination IA. Choosing a dish is a planning act, so
    /// the library is a push on the Plan stack rather than a tab of its own.
    case recipeLibrary
}

private enum PlannerSheet: Identifiable {
    case create
    case createMeal
    case editMeal(UUID)
    case completeMeal(UUID)

    var id: String {
        switch self {
        case .create: "create"
        case .createMeal: "create-meal"
        case .editMeal(let id): "edit-meal-\(id.uuidString)"
        case .completeMeal(let id): "complete-meal-\(id.uuidString)"
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
                    // A finished meal steps back the way it already does on
                    // Home: 已完成 in the metadata slot is the same size and
                    // colour as 2 人份, so on a full week the one row that is
                    // done looked exactly like the six that are not.
                    .foregroundStyle(isCooked ? .secondary : .primary)
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

    private var isCooked: Bool {
        if case .meal(let meal) = entry { return meal.isCooked }
        return false
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
    @Environment(\.scenePhase) private var scenePhase
    /// The path this Planner owns when nobody hands it one — the Home sheet
    /// presentation, previews and DEBUG fixtures.
    @State private var ownedPath: [PlannerRoute] = []
    /// One active delete-undo opportunity. A later successful delete replaces
    /// it (never queued); the earlier deletion becomes final. Session-scoped.
    @State private var activeUndo: PlanRemoval?
    /// Identity of the current toast, so a replaced toast is never dismissed
    /// by the expiry task of the toast it replaced.
    @State private var toastToken: UUID?
    @State private var toast: (message: String, style: AppFeedbackStyle, removable: Bool)?
    @State private var weekStart: Date
    @State private var sheet: PlannerSheet?
    /// A menu the creation sheet composed for a plan that was just added. Held
    /// until the detail for that plan is pushed, which seeds its draft store;
    /// cleared when that detail leaves the path so a reopened plan never
    /// resurrects a draft the user already dismissed.
    @State private var pendingDraft: (planID: UUID, dishes: [SpecialPlanMenuDraftDish])?
    /// The weekly generator's store while its route is on the stack. The
    /// generator owns it and hands it over on appear; this layer is the one
    /// that knows when the route is genuinely gone, because the generator
    /// cannot tell being popped from pushing one of its own pickers. Held only
    /// to end the workflow, never read for display.
    @State private var activeWeeklyWorkflow: WeeklyMenuPlannerStore?
    private let calendar: Calendar
    /// A fixed clock, when one was supplied. Only DEBUG fixtures and previews
    /// pass it, and while it is set the Planner's civil day never moves: a
    /// seeded screen has to render the same day it was seeded for.
    private let injectedNow: Date?
    /// The Planner's own civil-day truth, and the only thing here that reads
    /// the clock after `init`. Captured once, then repaired on the two
    /// occasions the day can change underneath a living view — the app coming
    /// back to the foreground, and a significant time change while it is
    /// already there. No timer, and no `Date()` in rendering.
    @State private var currentDate: Date
    /// Supplied when the Planner is a tab root, so `AppNavigationStore` can
    /// seed the stack for a deep link. `nil` keeps the owned path above, which
    /// is what every non-tab presentation still uses.
    private let hostPath: Binding<[PlannerRoute]>?
    private var path: Binding<[PlannerRoute]> { hostPath ?? $ownedPath }

    init(
        weekStart: Date? = nil,
        now: Date? = nil,
        // Autoupdating, not a snapshot. Every civil-day question here — the
        // 今天 marker, the implicit creation default, grouping, and the
        // formatters that read `calendar.timeZone` — has to be answered in the
        // user's *current* time zone. `Calendar.current` is captured once at
        // init, so after a system time-zone change it would keep answering in
        // the old one while `currentDate` refreshed around it. Tests and
        // fixtures still pass a fixed calendar and stay deterministic.
        calendar: Calendar = .autoupdatingCurrent,
        initialPath: [PlannerRoute] = [],
        path: Binding<[PlannerRoute]>? = nil
    ) {
        let reference = now ?? Date()
        self.calendar = calendar
        _ownedPath = State(initialValue: initialPath)
        self.hostPath = path
        self.injectedNow = now
        _currentDate = State(initialValue: reference)
        _weekStart = State(initialValue: weekStart ?? PlannerProjection.startOfWeek(containing: reference, calendar: calendar))
    }

    var body: some View {
        NavigationStack(path: path) {
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
                                refreshCurrentDay()
                                weekStart = PlannerProjection.startOfWeek(containing: currentDate, calendar: calendar)
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
                        Menu {
                            Button("生成今日购物清单", systemImage: "cart.badge.plus") {
                                path.wrappedValue.append(.todayShopping)
                            }
                            .accessibilityIdentifier("planner.shopping.generateToday")
                            Button {
                                path.wrappedValue.append(.weeklyGenerator)
                            } label: {
                                Label {
                                    Text(kitchenStore.weeklyPlan == nil ? "AI 生成一周菜单" : "查看已生成的一周菜单")
                                    Text(weeklyGeneratorSubtitle)
                                } icon: {
                                    Image(systemName: "calendar.badge.clock")
                                }
                            }
                            .accessibilityIdentifier("planner.weekly.open")
                            Button("问 Kitchen AI", systemImage: "sparkles") {
                                path.wrappedValue.append(.kitchenAI(weekStart, nil))
                            }
                            .accessibilityIdentifier("planner.kitchenAI.open")
                        } label: {
                            Label("更多", systemImage: "ellipsis.circle")
                        }
                        .accessibilityIdentifier("planner.tools.menu")
                    }
                    // 菜谱库 is one visible tap from the Plan root rather than a
                    // row inside 更多. Browsing dishes is how a plan gets filled,
                    // so it is a primary planning tool, not a low-frequency one —
                    // and it lost its tab, so burying it would have demoted it
                    // twice. Same route every existing deep link already uses.
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            path.wrappedValue.append(.recipeLibrary)
                        } label: {
                            Image(systemName: "book.closed")
                                // Clamp the glyph the way Inventory's toolbar
                                // actions do, so Accessibility sizes cannot grow
                                // it out of the bar.
                                .dynamicTypeSize(...ChromeMetrics.symbolTypeLimit)
                                .accessibilityLabel("菜谱库")
                        }
                        .accessibilityIdentifier("planner.recipes.open")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        // Two things can be created here now, so the one control
                        // that creates anything names both rather than standing
                        // for whichever one it used to open. 新建聚餐, not an AI
                        // label: AI is how that composer works, not what the
                        // user is making.
                        Menu {
                            Button("新建一餐") { createMeal() }
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
                    case .todayShopping:
                        ShoppingListGenerationView(source: .todayPlans(kitchenStore.todayPlans))
                    case let .kitchenAI(weekStart, specialPlanID):
                        AIConversationView(entryContext: .planner(
                            weekStart: weekStart, specialPlanID: specialPlanID
                        ))
                    case .weeklyGenerator:
                        WeeklyMenuPlannerView(onWorkflowActive: { activeWeeklyWorkflow = $0 }) { summary in
                            weekStart = PlannerProjection.startOfWeek(containing: summary.startDate, calendar: calendar)
                            path.wrappedValue.removeAll()
                        }
                    case .recipeLibrary:
                        RecipeListView()
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
                    case .completeMeal(let id):
                        if let plan = kitchenStore.plans.first(where: { $0.id == id }) {
                            CookConsumptionConfirmationView(
                                title: plan.recipeName,
                                planIDs: [plan.id],
                                recipeID: plan.recipeID,
                                recipeName: plan.recipeName
                            ) {
                                kitchenStore.markPlanCooked(plan)
                                let token = UUID()
                                toastToken = token
                                withAnimation {
                                    toast = (message: "已记录消耗，库存已更新", style: .success, removable: false)
                                }
                                scheduleUndoExpiry(token: token)
                            }
                        } else {
                            ContentUnavailableView("这一餐不存在", systemImage: "calendar.badge.exclamationmark")
                        }
                    }
                }
                .onChange(of: sheet?.id) { _, current in
                    // Push the new plan's detail once the composer has fully
                    // dismissed, so the draft is on screen without a second tap.
                    guard current == nil, let pending = pendingDraft else { return }
                    if !path.wrappedValue.contains(.specialPlan(pending.planID)) {
                        path.wrappedValue.append(.specialPlan(pending.planID))
                    }
                }
            .onChange(of: path.wrappedValue) { _, current in
                guard let pending = pendingDraft,
                      !current.contains(.specialPlan(pending.planID)) else { return }
                pendingDraft = nil
            }
            .onChange(of: path.wrappedValue) { previous, current in
                // Popping the generator abandons the workflow. Its own child
                // pickers and its result screen never touch the path, so they
                // leave it running.
                if previous.contains(.weeklyGenerator), !current.contains(.weeklyGenerator) {
                    endWeeklyWorkflow()
                }
            }
        }
        .overlay(alignment: .bottom) {
            toastOverlay
        }
        // Dismissing the Planner sheet abandons the workflow too. This sits on
        // the stack, not on its root content, so pushes inside the stack do not
        // trigger it.
        .onDisappear {
            endWeeklyWorkflow()
        }
        // The two ways a living Planner can outlive its own civil day. The
        // scene phase covers backgrounding before midnight and returning after
        // it; the significant-time-change notification covers staying
        // foregrounded through midnight, and carries a time-zone or clock
        // change for free. Neither polls.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshCurrentDay() }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.significantTimeChangeNotification
        )) { _ in
            refreshCurrentDay()
        }
    }

    /// Success toasts carry 撤销 plus a VoiceOver-only dismissal (知道了);
    /// error toasts carry an explicit 知道了. Extracted so the action closures
    /// type-check outside the body's builder context.
    @ViewBuilder
    private var toastOverlay: some View {
        if let current = toast {
            if current.removable {
                FeedbackToast(message: current.message, style: current.style,
                              action: (label: "撤销", handler: performUndo))
                    .accessibilityAction(named: "知道了") {
                        withAnimation { self.toast = nil }
                    }
            } else {
                FeedbackToast(message: current.message, style: current.style,
                              action: (label: "知道了", handler: { withAnimation { self.toast = nil } }))
            }
        }
    }

    private var weekList: some View {
        List {
            Section {
                HStack {
                    Text(PlannerDateText.weekRange(start: weekStart, calendar: calendar))
                        .font(.subheadline.weight(.medium))
                        .accessibilityIdentifier("planner.week.range")
                        .foregroundStyle(KitchenTheme.textPrimary)
                    Spacer()
                    if weekStart == PlannerProjection.startOfWeek(containing: currentDate, calendar: calendar) {
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
                        Button("新建一餐") { createMeal() }
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
                        let today = calendar.isDate(group.day, inSameDayAs: currentDate)
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
                if !meal.isCooked {
                    Button("做好了", systemImage: "checkmark.circle") { sheet = .completeMeal(meal.id) }
                        .accessibilityIdentifier("planner.meal.complete.\(meal.id.uuidString)")
                }
                Button("编辑") { sheet = .editMeal(meal.id) }
                    .accessibilityIdentifier("planner.meal.edit.\(meal.id.uuidString)")
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                // No confirmation alert: removal is immediately undoable
                // within the session.
                Button(role: .destructive) {
                    removeMeal(meal.id)
                } label: {
                    Text("移出计划")
                }
                .accessibilityIdentifier("planner.meal.remove.\(meal.id.uuidString)")
            }
            .contextMenu {
                if !meal.isCooked {
                    Button("做好了", systemImage: "checkmark.circle") { sheet = .completeMeal(meal.id) }
                        .accessibilityIdentifier("planner.meal.completeMenu.\(meal.id.uuidString)")
                }
                Button("编辑", systemImage: "pencil") { sheet = .editMeal(meal.id) }
                    .accessibilityIdentifier("planner.meal.editMenu.\(meal.id.uuidString)")
                Button(role: .destructive) {
                    removeMeal(meal.id)
                } label: {
                    Label("移出计划", systemImage: "trash")
                }
                .accessibilityIdentifier("planner.meal.removeMenu.\(meal.id.uuidString)")
            }
            .accessibilityActions {
                if !meal.isCooked {
                    Button("做好了") { sheet = .completeMeal(meal.id) }
                }
            }
            .accessibilityAction(named: "编辑") { sheet = .editMeal(meal.id) }
            .accessibilityAction(named: "移出计划") { removeMeal(meal.id) }
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
        path.wrappedValue.removeAll { route in
            switch route {
            case .specialPlan(let routeID): return routeID == id
            case .recipe, .plannedMeal, .todayShopping, .weeklyGenerator, .kitchenAI, .recipeLibrary: return false
            }
        }
    }

    /// Removes through the durable store contract only. The captured removal
    /// is the single active undo token; a later delete replaces it.
    /// Ends the weekly generation workflow: everything it owns stops, and the
    /// store goes with the route, so a late answer can neither reach a screen
    /// the member left nor survive into the next visit.
    private func endWeeklyWorkflow() {
        activeWeeklyWorkflow?.abandonWorkflow()
        activeWeeklyWorkflow = nil
    }

    private func removeMeal(_ id: UUID) {
        let outcome = kitchenStore.removePlan(id: id)
        switch outcome {
        case .saved(let removal):
            activeUndo = removal
            let token = UUID()
            toastToken = token
            withAnimation {
                toast = (message: "已移出「" + removal.item.recipeName + "」",
                             style: .success, removable: true)
            }
            // AppFeedbackView announces the toast itself, once per message.
            scheduleUndoExpiry(token: token)
        case .notFound:
            break
        case .persistenceFailed:
            // The store publishes only after a durable write, so the row is
            // still present; say so honestly and stay retryable.
            let token = UUID()
            toastToken = token
            withAnimation {
                toast = (message: "移出计划失败，请稍后重试。",
                             style: .error, removable: false)
            }
            scheduleUndoExpiry(token: token)
        }
    }

    /// Restores through the durable contract only. On failure the row stays
    /// absent and the toast is replaced with an error — no false success.
    private func performUndo() {
        guard let removal = activeUndo else { return }
        activeUndo = nil
        let outcome = kitchenStore.restorePlan(removal.item, at: removal.index)
        switch outcome {
        case .saved:
            withAnimation { toast = nil }
        case .notFound, .persistenceFailed:
            let token = UUID()
            toastToken = token
            withAnimation {
                toast = (message: "撤销失败，这一餐仍在计划外。",
                             style: .error, removable: false)
            }
            scheduleUndoExpiry(token: token)
        }
    }

    /// Toasts auto-dismiss on a delay keyed by token, so a stale timer never
    /// clears a newer toast. VoiceOver gets a far longer window, because
    /// reaching 撤销 means navigating to it first and a short timer would make
    /// undo practically unreachable. It still expires: a toast that never
    /// cleared would cover the bottom of the list for the rest of the session,
    /// and 知道了 is only a custom action.
    private func scheduleUndoExpiry(token: UUID) {
        let delay: Duration = UIAccessibility.isVoiceOverRunning ? .seconds(20) : .seconds(4)
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard token == self.toastToken else { return }
            withAnimation { self.toast = nil }
            self.toastToken = nil
        }
    }

    private func moveWeek(by days: Int) {
        if let next = calendar.date(byAdding: .day, value: days, to: weekStart) {
            weekStart = next
        }
    }

    /// Re-reads the clock. The single call site for `Date()` after `init`, and
    /// a no-op while a fixture pins the day.
    private func refreshCurrentDay() {
        guard injectedNow == nil else { return }
        // Assigned unconditionally. A significant time change can move the time
        // zone without moving the civil day, and the day rows are still wrong
        // afterwards: an autoupdating calendar regroups the same instants under
        // the new zone, which only happens if the view is invalidated.
        currentDate = Date()
    }

    /// Implicit creation: no day was named, so the default is resolved now
    /// rather than carried from whenever this Planner was built.
    private func createMeal() {
        refreshCurrentDay()
        sheet = .createMeal
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
    private var weeklyGeneratorSubtitle: String {
        guard let draft = kitchenStore.weeklyPlan else { return "按顿数、人数生成一周安排" }
        return "已生成 \(draft.dayCount) 天 · \(draft.dishCount) 道菜"
    }

    private var creationDefaultDate: Date {
        PlannerProjection.defaultCreationDate(
            inWeekStarting: weekStart,
            now: currentDate,
            calendar: calendar
        )
    }
}

extension SpecialPlan {
    /// "7 人 · 18:30"
    fileprivate var detailText: String {
        let parts = ["\(peopleCount) 人", Self.timeText(scheduledAt)] + constraintNotes.prefix(2)
        return parts.joined(separator: " · ")
    }
}

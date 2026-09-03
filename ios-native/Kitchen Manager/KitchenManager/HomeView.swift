import SwiftUI
import UIKit

private struct ClipboardImportPresentation {
    let handoff: ClipboardRecipeImportURL.Handoff
    let changeCount: Int
}

private enum HomeSheet: Identifiable {
    case smartImport
    case expiry
    case shopping
    case todayRhythm
    case clipboardImport(ClipboardImportPresentation)

    var id: String {
        switch self {
        case .smartImport: "smart-import"
        case .expiry: "expiry"
        case .shopping: "shopping"
        case .todayRhythm: "today-rhythm"
        case .clipboardImport(let presentation): "clipboard-import-\(presentation.changeCount)"
        }
    }
}

struct HomeView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var recipeStore: RecipeStore
    @EnvironmentObject private var kitchenStore: KitchenStore
    @EnvironmentObject private var navigationStore: AppNavigationStore
    @EnvironmentObject private var recommendationStore: HomeRecommendationStore
    @EnvironmentObject private var authStore: AuthStore
    @EnvironmentObject private var sharedImportCoordinator: SharedImportCoordinator
    @EnvironmentObject private var dayRhythmStore: DayRhythmStore
    @EnvironmentObject private var mealPortionStore: MealPortionStore

    @State private var activeSheet: HomeSheet?
    @State private var toastMessage: String?
    @State private var toastStyle: AppFeedbackStyle = .success
    @State private var isShowingTodayPlan = false
    /// The planner, reachable from Home on every day. Separate from
    /// `isShowingTodayPlan`: that one opens today's plan, this one opens every
    /// meal and special plan beyond today. Home's only unconditional route to
    /// it, and the only one there is — see D-031.
    @State private var isShowingPlanner = false
    @State private var isShowingRecommendations = false
    @State private var isShowingPreparedComponents = false
    @State private var selectedPlan: MealPlanItem?
    @State private var selectedRecipe: Recipe?
    @State private var clipboardPromptState = ClipboardPromptSessionState()
    @State private var clipboardDetectionTask: Task<Void, Never>?
    /// Which quick-meal suggestion is showing. Ordinary view state on purpose:
    /// it has to survive a body refresh and the 今天安排 sheet, and it is fine
    /// for a relaunch to start again from the easiest option.
    @State private var quickMealIndex = 0

    private let clipboardDetector: any ClipboardPatternDetecting

    @MainActor
    init() {
        self.clipboardDetector = SystemClipboardPatternDetector()
    }

    private var sourceRecipes: [Recipe] {
        recipeStore.recipesForDisplay
    }

    private var dashboard: HomeDashboardSummary {
        HomeDashboardSummary(
            inventory: kitchenStore.inventory,
            todayPlans: kitchenStore.todayPlans,
            shoppingItems: kitchenStore.shoppingItems,
            // Read-only. A batch going off used to be invisible on Home unless
            // today happened to be a 备餐日; 需要处理 now sees it on every day.
            preparedComponents: kitchenStore.preparedComponents
        )
    }

    /// Food an earlier day set aside for *today*. It is today's food, so it
    /// belongs to Today Context.
    ///
    /// Independent of the eat-out state — a portion set aside still exists even
    /// when the meal is marked as eaten out, and marking a meal 外食 must never
    /// make food that exists disappear.
    private var incomingCarryoverSummaries: [String] {
        guard let incoming = mealPortionStore.incomingReservation(slot: .lunch) else { return [] }
        return [MealPortionCopy.targetDaySummary(incoming.portions)]
    }

    /// Food tonight is holding back for *tomorrow*. It is not today's food and
    /// it is not an attribute of today's rhythm, so it is a footer line rather
    /// than another fragment concatenated onto the day summary.
    private var outgoingCarryoverSummary: String? {
        let dinner = mealPortionStore.portionPlan(slot: .dinner)
        guard dinner.hasReservation else { return nil }
        return MealPortionCopy.sourceDaySummary(dinner.reservedForNextLunchPortions)
    }

    /// Takes one portion off the batch the user tapped. Reuses the P1-B
    /// store API rather than decrementing here, so there is only ever one
    /// implementation of what "eating a portion" means.
    ///
    /// Nothing else is touched: no inventory consumption, no restock, no
    /// shopping line, no plan. `preparedComponents` is published, so the
    /// suggestions recompute on their own — the current one is never patched
    /// by hand, and if the batch was the last portion the existing index clamp
    /// handles whatever the list becomes.
    private func usePreparedPortion(_ id: UUID) {
        guard let previous = kitchenStore.consumePreparedPortion(id: id) else { return }
        showToast(
            previous.portionsRemaining > 1
                ? "已使用 1 份\(previous.name)，还剩 \(previous.portionsRemaining - 1) 份"
                : "\(previous.name)已用完"
        )
    }

    private var moduleIssues: [HomeDashboardModuleIssue] {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("UITEST_SEED_HOME_MODULE_ISSUES") {
            return [.inventory, .shopping]
        }
#endif
        return HomeDashboardModuleIssue.issues(
            inventoryNotice: kitchenStore.inventoryNotice,
            shoppingNotice: kitchenStore.shoppingNotice
        )
    }

    var body: some View {
        // `dashboard` is a computed property: reading it re-filters the whole
        // inventory, the prepared batches, today's plans and the shopping list,
        // and the cost is linear in those. Building it once here and passing
        // that one value around keeps every reader on identical data as well.
        let dashboard = self.dashboard
        let primaryTask = HomePrimaryTask.resolve(
            dayType: dayRhythmStore.effectiveDayType(),
            dinnerIntent: dayRhythmStore.intent(for: .dinner),
            planState: dashboard.todayPlanState,
            totalPlanCount: dashboard.totalPlanCount,
            completedPlanCount: dashboard.completedPlanCount
        )
        let homeRecommendation = recommendationStore.recommendedRecipes.first { recommendation in
            !kitchenStore.todayPlans.contains { $0.recipeID == recommendation.recipe.id }
        } ?? recommendationStore.currentRecommendation
        let needsAttention = primaryTask.needsAttention(from: dashboard.attentionItems)
        return ScrollView {
            // Home V2's three layers, in this order and at three deliberately
            // different weights: what kind of day this is, the one thing to do,
            // and what else is worth handling. Everything else on this page is
            // secondary status and must stay lighter than all three.
            VStack(alignment: .leading, spacing: 24) {
                HomeTodayContext(
                    householdName: householdName,
                    isRestoringAccount: authStore.activity == .restoring,
                    shouldShowHousehold: headerModel.shouldShowHousehold,
                    dayType: dayRhythmStore.effectiveDayType(),
                    eatOutSlots: MealSlot.allCases.filter { dayRhythmStore.intent(for: $0) == .eatOut },
                    incomingCarryover: incomingCarryoverSummaries,
                    onOpenDayRhythm: { activeSheet = .todayRhythm }
                )

                primarySection(
                    task: primaryTask,
                    dashboard: dashboard,
                    recommendation: homeRecommendation
                )

                HomeNeedsAttentionSection(
                    items: needsAttention.visible,
                    additionalCount: needsAttention.additional,
                    onSelect: handleAttention,
                    onViewAll: { navigationStore.showInventory(.all) }
                )

                // Tomorrow's food is not today's context. It sits below the
                // page's own three layers rather than inside the day summary,
                // where it used to be concatenated onto the rhythm line and read
                // as another attribute of today.
                if let outgoing = outgoingCarryoverSummary {
                    HomeCarryoverFooterRow(text: outgoing)
                }

                ForEach(
                    HomeDashboardPresentation.supplementarySections(
                        showsClipboardPrompt: shouldShowClipboardPrompt,
                        hasModuleIssues: !moduleIssues.isEmpty
                    ),
                    id: \.self
                ) { section in
                    switch section {
                    case .clipboardPrompt:
                        if let changeCount = clipboardPromptChangeCount {
                            ClipboardRecipeImportPrompt(
                                onPaste: { pastedText in
                                    handleClipboardPaste(pastedText)
                                },
                                onIgnore: {
                                    clipboardPromptState.ignore(changeCount: changeCount)
                                }
                            )
                        }
                    case .moduleIssues:
                        HomeModuleIssues(
                            issues: moduleIssues,
                            action: { issue in
                                switch issue {
                                case .inventory: navigationStore.showInventory(.all)
                                case .shopping: navigationStore.selectedTab = .shopping
                                }
                            }
                        )
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .safeAreaPadding(.bottom, 112)
        .background(Color(.systemGroupedBackground))
        // Deliberately stable. Home V2 expresses its state in the primary
        // task's own heading (今天做什么 / 今天做这些 / 今天怎么吃 / 今天备的菜 /
        // 今晚), so the navigation layer never moves under the reader.
        .navigationTitle("今天")
        // Same rule Inventory and Recipes use: large at normal sizes, collapsing
        // to inline at Accessibility sizes where a large title would otherwise
        // take most of the first screen. Home used to render its greeting inside
        // the scroll content at `.title3`, so it stayed small at every size and
        // could not collapse — the title measured 17.7pt against the 30.0pt
        // large titles one tab away, and sat 31pt higher on the screen.
        .navigationBarTitleDisplayMode(dynamicTypeSize.isAccessibilitySize ? .inline : .large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("导入与添加", systemImage: "plus") { activeSheet = .smartImport }
                    .frame(minWidth: AppTheme.minimumHitTarget, minHeight: AppTheme.minimumHitTarget)
                    .dynamicTypeSize(...ChromeMetrics.symbolTypeLimit)
                    .accessibilityIdentifier("home.import.add.button")
                    .accessibilityHint("打开菜谱、收据和食材添加选项")
            }
        }
        .navigationDestination(isPresented: $isShowingTodayPlan) {
            TodayPlanDetailView()
        }
        // A sheet, which is the shape the planner has always been presented in.
        // Home is now its only entry point, so this is also the only place that
        // shape is decided.
        .sheet(isPresented: $isShowingPlanner) {
            PlannerView()
        }
        .navigationDestination(isPresented: $isShowingRecommendations) {
            RecipeRecommendationBrowserView()
        }
        // Reuses the existing management page rather than rebuilding an editor
        // inside the board.
        .navigationDestination(isPresented: $isShowingPreparedComponents) {
            PreparedComponentsView()
        }
        // Same pattern TodayPlanDetailView already uses for its rows: an
        // explicit selection + `navigationDestination(item:)`, never
        // `NavigationLink(value:)` — see the ExpirySheet note above for why
        // that form is avoided here. The missing-recipe fallback matches
        // TodayPlanDetailView's so a plan whose recipe is gone still keeps the
        // plan intact instead of dead-ending.
        .navigationDestination(item: $selectedPlan) { plan in
            if let recipe = recipeStore.recipe(id: plan.recipeID) {
                RecipeDetailView(recipe: recipe, todayPlan: plan)
            } else {
                ContentUnavailableView("菜谱暂不可用", systemImage: "book.closed", description: Text("这份计划保留不变，可以稍后重试。"))
            }
        }
        .navigationDestination(item: $selectedRecipe) { recipe in
            RecipeDetailView(recipe: recipe)
        }
        .sheet(item: $activeSheet) { sheet in
            sheetContent(sheet)
        }
        .sheet(item: sharedImportSheetBinding) { request in
            sharedImportSheetContent(request)
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                FeedbackToast(message: toastMessage, style: toastStyle)
            }
        }
        .onAppear {
            dayRhythmStore.refreshForCurrentDay()
            mealPortionStore.refreshForCurrentDay()
            scheduleClipboardDetection()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Covers the app being backgrounded overnight: yesterday's
                // override and eat-out meals are dropped, and a carryover whose
                // day has passed is pruned, before Home re-renders.
                dayRhythmStore.refreshForCurrentDay()
                mealPortionStore.refreshForCurrentDay()
                scheduleClipboardDetection()
            } else {
                cancelClipboardDetection()
            }
        }
        .onChange(of: sharedImportCoordinator.pendingRequest?.id) { _, pendingID in
            if pendingID == nil {
                scheduleClipboardDetection()
            } else {
                cancelClipboardDetection()
            }
        }
        .onChange(of: activeSheet?.id) { _, sheetID in
            if sheetID == nil {
                scheduleClipboardDetection()
            } else {
                cancelClipboardDetection()
            }
        }
        .onDisappear {
            cancelClipboardDetection()
        }
        .task(id: recipeStore.recipes.count) {
            loadDefaultRecommendationsIfNeeded()
#if DEBUG
            recommendationStore.applyHomeUITestStateIfRequested()
#endif
        }
    }

    private var isClipboardPresentationBlocked: Bool {
        ClipboardImportPresentationPolicy.isBlocked(
            hasPendingShare: sharedImportCoordinator.pendingRequest != nil,
            hasActiveSheet: activeSheet != nil
        )
    }

    private var shouldShowClipboardPrompt: Bool {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("UITEST_SEED_HOME_CLIPBOARD") {
            return !isClipboardPresentationBlocked
        }
#endif
        return clipboardPromptState.shouldShowPrompt(
            isAppActive: scenePhase == .active,
            isPresentationBlocked: isClipboardPresentationBlocked
        )
    }

    private var clipboardPromptChangeCount: Int? {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("UITEST_SEED_HOME_CLIPBOARD") {
            return 0
        }
#endif
        return clipboardPromptState.currentChangeCount
    }

    /// Only surfaces the pending shared-import request when nothing else is
    /// already presented from this view — avoids stacking it on top of the
    /// existing Smart Import sheet or any other modal flow.
    private var sharedImportSheetBinding: Binding<SharedImportRequest?> {
        Binding(
            get: { activeSheet == nil ? sharedImportCoordinator.pendingRequest : nil },
            set: { newValue in
                if newValue == nil, let current = sharedImportCoordinator.pendingRequest {
                    sharedImportCoordinator.snooze(current)
                }
            }
        )
    }

    @ViewBuilder
    private func sharedImportSheetContent(_ request: SharedImportRequest) -> some View {
        NavigationStack {
            ImportRecipeView(
                initialURLText: SharedImportCoordinator.prefillText(for: request),
                autoStart: true,
                onSaved: {
                    sharedImportCoordinator.markHandedOff(request)
                    showToast("已保存到菜谱库")
                }
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        sharedImportCoordinator.snooze(request)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: HomeSheet) -> some View {
        switch sheet {
        case .smartImport:
            SmartImportSheet {
                activeSheet = nil
                showToast("已保存到菜谱库")
            }
        case .expiry:
            ExpirySheet { item in
                activeSheet = nil
                recommendationStore.searchQuery = item.name
                isShowingRecommendations = true
                Task {
                    await recommendationStore.searchRecommendations(
                        recipes: sourceRecipes,
                        inventory: kitchenStore.recipeCreationInventory.map(\.name),
                        expiringIngredients: kitchenStore.recipeCreationExpiringItems.map(\.name)
                    )
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        case .shopping:
            PendingShoppingSheet {
                activeSheet = nil
                navigationStore.selectedTab = .shopping
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        case .todayRhythm:
            TodayRhythmSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        case .clipboardImport(let presentation):
            NavigationStack {
                ImportRecipeView(
                    initialURLText: presentation.handoff.urlText,
                    autoStart: presentation.handoff.autoStart,
                    onSaved: { showToast("已保存到菜谱库") }
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { activeSheet = nil }
                    }
                }
            }
        }
    }

    private var displayName: String? {
        authStore.account?.user.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyHome
    }

    private var householdName: String? {
        authStore.account?.households.first?.name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyHome
    }

    /// Drives both the navigation title and whether the household line shows.
    /// Same `HomeDashboardHeaderModel` the header used before it became a real
    /// `navigationTitle`, so the greeting wording stays under its unit tests.
    private var headerModel: HomeDashboardHeaderModel {
        HomeDashboardHeaderModel(displayName: displayName, householdName: householdName)
    }

    private func showToast(_ message: String, style: AppFeedbackStyle = .success) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            toastStyle = style
            toastMessage = message
        }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            await MainActor.run {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { toastMessage = nil }
            }
        }
    }

    private func scheduleClipboardDetection() {
        clipboardDetectionTask?.cancel()
        clipboardPromptState.cancelDetection()
        clipboardDetectionTask = Task { @MainActor in
            // Let ContentView's local Share queue refresh run first so a
            // pending explicit share wins before a clipboard hint is shown.
            await Task.yield()
            guard !Task.isCancelled else { return }
            let changeCount = clipboardDetector.changeCount
            guard clipboardPromptState.beginDetection(
                changeCount: changeCount,
                isAppActive: scenePhase == .active,
                isPresentationBlocked: isClipboardPresentationBlocked
            ) else {
                clipboardDetectionTask = nil
                return
            }

            let result: Bool?
            do {
                result = try await clipboardDetector.containsProbableWebURL()
            } catch {
                result = nil
            }

            guard !Task.isCancelled else { return }
            let latestChangeCount = clipboardDetector.changeCount
            clipboardPromptState.finishDetection(
                changeCount: changeCount,
                latestChangeCount: latestChangeCount,
                probableWebURL: result,
                isAppActive: scenePhase == .active,
                isPresentationBlocked: isClipboardPresentationBlocked
            )
            if clipboardPromptState.inFlightChangeCount == nil {
                clipboardDetectionTask = nil
            }
        }
    }

    private func cancelClipboardDetection() {
        clipboardDetectionTask?.cancel()
        clipboardDetectionTask = nil
        clipboardPromptState.cancelDetection()
    }

    private func handleClipboardPaste(_ pastedText: String) {
        let pastedChangeCount = clipboardDetector.changeCount
        clipboardPromptState.markHandled(changeCount: pastedChangeCount)

        guard scenePhase == .active,
              activeSheet == nil,
              sharedImportCoordinator.pendingRequest == nil
        else {
            showToast("请先完成当前的导入操作", style: .warning)
            return
        }

        guard let handoff = ClipboardRecipeImportURL.makeHandoff(from: pastedText) else {
            showToast("剪贴板中没有可导入的网页链接，请重新复制后再试", style: .warning)
            return
        }

        activeSheet = .clipboardImport(
            ClipboardImportPresentation(
                handoff: handoff,
                changeCount: pastedChangeCount
            )
        )
    }

    private func loadDefaultRecommendationsIfNeeded() {
        recommendationStore.loadDefaultRecommendations(
            recipes: sourceRecipes,
            inventory: kitchenStore.recipeCreationInventory.map(\.name),
            expiringIngredients: kitchenStore.recipeCreationExpiringItems.map(\.name)
        )
    }

    private func generateAIRecommendations() {
        Task {
            await recommendationStore.generateNewRecommendations(
                inventory: kitchenStore.recipeCreationInventory.map(\.name),
                expiringIngredients: kitchenStore.recipeCreationExpiringItems.map(\.name)
            )
        }
    }

    private func addRecommendationToPlan(_ recipe: Recipe) {
        let alreadyAdded = kitchenStore.todayPlans.contains { $0.recipeID == recipe.id }
        kitchenStore.addPlan(recipe: recipe)
        UINotificationFeedbackGenerator().notificationOccurred(alreadyAdded ? .warning : .success)
        showToast(alreadyAdded ? "已在今天" : "已加入今天", style: alreadyAdded ? .warning : .success)
    }

    /// Home's single primary region. The heading comes from `HomePrimaryTask`
    /// and the content follows from its kind, so there is exactly one place
    /// where "what is this screen for right now" is decided.
    ///
    /// Everything below the content is a *link*, never a second card with its
    /// own prominent button. That is the whole difference between decision mode
    /// and execution mode: the capability stays, the weight does not.
    @ViewBuilder
    private func primarySection(
        task: HomePrimaryTask,
        dashboard: HomeDashboardSummary,
        recommendation: RecipeRecommendation?
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HomePrimaryHeader(task: task)

            switch task.kind {
            case .eatOut:
                HomeEatOutPrimary()

            case .planExecution:
                TodayPlanSummaryCard(
                    dashboard: dashboard,
                    onViewPlan: { isShowingTodayPlan = true },
                    onSelectPlan: { selectedPlan = $0 }
                )

            case .recipeRecommendation:
                HomeRecommendationSection(
                    recommendation: recommendation,
                    isLoading: recipeStore.isLoading && recommendationStore.recommendedRecipes.isEmpty,
                    isGenerating: recommendationStore.isGeneratingRecommendations,
                    errorMessage: recommendationStore.recommendationError,
                    noticeMessage: recommendationStore.recommendationNotice,
                    isDisplayingSamples: recipeStore.isDisplayingSamples,
                    isAddedToToday: recommendation.map { candidate in
                        kitchenStore.todayPlans.contains { $0.recipeID == candidate.recipe.id }
                    } ?? false,
                    inventoryNames: kitchenStore.recipeCreationInventory.map(\.name),
                    expiringNames: kitchenStore.recipeCreationExpiringItems.map(\.name),
                    onAddToToday: addRecommendationToPlan,
                    onViewRecipe: { selectedRecipe = $0 },
                    onRefresh: generateAIRecommendations,
                    onViewAll: { isShowingRecommendations = true }
                )

            case .quickMeal:
                let quickMeal = QuickMealAssemblyEngine.assemble(
                    inventory: kitchenStore.inventory,
                    preparedComponents: kitchenStore.preparedComponents
                )
                HomeQuickMealSection(
                    content: QuickMealHomeContent.resolve(
                        result: quickMeal,
                        isEatingOutTonight: dayRhythmStore.intent(for: .dinner) == .eatOut,
                        storedIndex: quickMealIndex,
                        preparedComponents: kitchenStore.preparedComponents
                    ),
                    onRotate: {
                        quickMealIndex = QuickMealRotation.nextIndex(
                            stored: quickMealIndex,
                            count: quickMeal.suggestions.count
                        )
                    },
                    onUsePreparedPortion: usePreparedPortion
                )

            case .mealPrepBoard:
                HomeMealPrepBoardSection(
                    entries: MealPrepBoard.entries(from: kitchenStore.preparedComponents),
                    onAdd: { isShowingPreparedComponents = true }
                )
            }

            // Execution mode keeps recommendation one tap away and nothing more.
            if task.showsRecommendationLink {
                HomeSecondaryLinkRow(
                    title: "想再加一道",
                    systemImage: "sparkles",
                    symbolTint: AppTheme.aiAccentForeground,
                    identifier: "home.recommendation.moreLink",
                    action: { isShowingRecommendations = true }
                )
            }

            // A plan that exists but is not today's headline. Reachable, never
            // prominent: Home must not say 今晚外食 and 开始准备 in one breath.
            if task.secondaryPlanCount > 0 {
                HomeSecondaryLinkRow(
                    title: "今日仍有 \(task.secondaryPlanCount) 道计划",
                    systemImage: "list.bullet",
                    symbolTint: AppTheme.textSecondary,
                    identifier: "home.plan.secondaryLink",
                    action: { isShowingTodayPlan = true }
                )
            }

            // Everything beyond today: later meals, and the special plans that
            // sit among them. Unconditional on purpose, and now Home's *only*
            // route to the planner — the deep one through today's plan detail
            // was removed in D-031 once this one had been verified on a device.
            //
            // It stays a link rather than a card because planning ahead is
            // never today's primary task. The extra top padding is the only
            // thing marking the boundary the two links above do not cross:
            // those are about today, this one is not.
            HomeSecondaryLinkRow(
                title: "用餐计划",
                systemImage: "calendar",
                symbolTint: AppTheme.textSecondary,
                identifier: "home.planner.link",
                action: { isShowingPlanner = true }
            )
            .padding(.top, 4)
        }
    }

    /// Every 需要处理 row goes to the place that can actually resolve it. The
    /// destinations are the ones Home already used; only the row shapes changed.
    private func handleAttention(_ item: HomeAttentionItem) {
        switch item.kind {
        case .expiredInventory:
            navigationStore.showInventory(.expired)
        case .expiringInventory:
            navigationStore.showInventory(.expiringSoon)
        case .lowStock:
            navigationStore.showInventory(.lowStock)
        case .preparedExpiring:
            isShowingPreparedComponents = true
        case .purchasedAwaitingStockIn:
            navigationStore.showShoppingStockIn()
        case .pendingShopping:
            navigationStore.selectedTab = .shopping
        }
    }
}
private struct ClipboardRecipeImportPrompt: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let onPaste: @MainActor @Sendable (String) -> Void
    let onIgnore: () -> Void

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                verticalLayout
            } else {
                ViewThatFits(in: .horizontal) {
                    horizontalLayout
                    verticalLayout
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.clipboard.import.prompt")
    }

    private var horizontalLayout: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "doc.on.clipboard")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                promptText
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) { promptActions }
        }
    }

    private var verticalLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            promptCopy
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { promptActions }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { promptActions }
                    VStack(alignment: .leading, spacing: 8) { promptActions }
                }
            }
        }
    }

    private var promptCopy: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.on.clipboard")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                promptText
            }
        }
    }

    private var promptText: some View {
        Group {
            Text("剪贴板中有菜谱链接")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text("只有点击“粘贴导入”后才会读取内容。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var promptActions: some View {
        ClipboardPasteControl(
            accessibilityLabel: "粘贴导入",
            style: .customLabeled("粘贴导入"),
            usesManagementSecondaryVisual: true,
            onPaste: { pastedText in onPaste(pastedText) }
        )

        Button("忽略", action: onIgnore)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(minHeight: AppTheme.minimumHitTarget)
            .accessibilityIdentifier("home.clipboard.ignore.button")
    }
}

// MARK: - Dashboard V2

/// The date/household/restoring lines that sit under Home's navigation title.
///
/// The greeting itself is the real `navigationTitle` and the add button is a
/// real toolbar item, so Home gets the same large-title metrics, the same
/// toolbar capsule position and the same scroll-collapse behaviour as
/// Inventory, Shopping and Recipes instead of hand-rolling a smaller header.
/// What stays here is what a `navigationTitle` cannot express — and it lands in
/// the same place Recipes already puts "全部菜谱 · 19 道": a secondary line
/// directly beneath the title.
// MARK: - 1. Today Context
//
// Deliberately not a card. The day is stated in plain type directly on the
// grouped canvas, so the page opens with a fact rather than with a container,
// and the primary region below is the first surface the eye lands on.
//
// Before Home V2 this was a `.footnote` secondary line that read
// 快手日 · 晚餐外食 · 午餐已留 1 份. That put the single most consequential state
// on the screen — the one that decides what the whole primary region shows — at
// the lowest weight on the page, next to the date and the household name.
private struct HomeTodayContext: View {
    let householdName: String?
    let isRestoringAccount: Bool
    let shouldShowHousehold: Bool
    let dayType: DayType
    /// Only the meals that differ from the default. `household` is the norm and
    /// is never spelled out.
    let eatOutSlots: [MealSlot]
    /// Food an earlier day left for today. Today's food, so it belongs here.
    let incomingCarryover: [String]
    let onOpenDayRhythm: () -> Void

    private var dateText: String { HomeDatePresentation.text(for: .now) }

    /// Everything that departs from an ordinary version of this day.
    private var exceptions: [String] {
        eatOutSlots.map(\.eatOutSummary) + incomingCarryover
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(dateText)
                .font(.subheadline)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("home.today.date")

            Button(action: onOpenDayRhythm) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: dayType.homeSymbolName)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(dayType.homeTint)
                            .dynamicTypeSize(...ChromeMetrics.symbolTypeLimit)
                            .accessibilityHidden(true)
                        Text(dayType.homeSummaryTitle)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .dynamicTypeSize(...ChromeMetrics.symbolTypeLimit)
                            .accessibilityHidden(true)
                        Spacer(minLength: 0)
                    }
                    // The sentence that makes the day type stop reading as
                    // metadata: it says what today is for, in the reader's own
                    // words, and the primary region below follows from it.
                    // No identifiers on these: they are inside a Button whose
                    // own accessibility label already carries every word (see
                    // `accessibilityLabel` below), and a SwiftUI accessibility
                    // modifier on an ancestor overrides its descendants' — so an
                    // id here would silently erase `home.dayRhythm.row`.
                    Text(dayType.homeExplanation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if !exceptions.isEmpty {
                        Text(exceptions.joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // Deliberately uncapped below the symbol: the explanation
                // follows the full Dynamic Type range and wraps at Accessibility
                // sizes, pushing the rest of Home down. Keeping every word
                // legible outranks keeping the primary task on the first screen.
                .frame(maxWidth: .infinity, minHeight: AppTheme.minimumHitTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("查看并调整今天的用餐安排")
            .accessibilityIdentifier("home.dayRhythm.row")

            if shouldShowHousehold, let householdName {
                Label(householdName, systemImage: "person.2")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if isRestoringAccount {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在恢复账号…")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("home.auth.restoring")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessibilityLabel: String {
        (["今天：\(dayType.homeSummaryTitle)", dayType.homeExplanation] + exceptions)
            .joined(separator: "，")
    }
}

extension DayType {
    /// Home only. Kept beside the day's other display values rather than in a
    /// view, so the four rhythms cannot drift apart across surfaces.
    var homeSymbolName: String {
        switch self {
        case .cooking: return "fork.knife"
        case .quick: return "bolt.fill"
        case .mealPrep: return "shippingbox.fill"
        case .flexible: return "sun.max.fill"
        }
    }

    /// Semantic roles only — cooking green for the cooking path, management blue
    /// for the put-by/production day, neutral for a day with no fixed shape.
    /// 快手日 borrows the `warningInk` hue because it reads as "quick", not
    /// because anything is wrong; it is a text-safe token either way.
    var homeTint: Color {
        switch self {
        case .cooking: return AppTheme.cookingAccentForeground
        case .quick: return AppTheme.warningInk
        case .mealPrep: return AppTheme.managementAccentForeground
        case .flexible: return AppTheme.textSecondary
        }
    }
}

// MARK: - 2. One primary task

/// The heading for Home's single primary region. This is where the page's state
/// is visible, which is what lets the navigation title stay a stable 今天.
private struct HomePrimaryHeader: View {
    let task: HomePrimaryTask

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                title
                detail
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 2) {
                title
                detail
            }
        }
    }

    private var title: some View {
        Text(task.title)
            .font(.title2.weight(.bold))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("home.primary.title")
    }

    @ViewBuilder private var detail: some View {
        if let detail = task.detail {
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("home.primary.detail")
        }
    }
}

/// Tonight is settled. Home states that and stops — it does not invent a task,
/// and it does not quietly fall back to proposing a meal.
private struct HomeEatOutPrimary: View {
    var body: some View {
        Text("今天不用准备晚餐")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: AppTheme.minimumHitTarget, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous)
            )
            .accessibilityIdentifier("home.primary.eatOut")
    }
}

/// A link that sits under the primary content. Never a card, never prominent —
/// this shape is how a demoted capability stays reachable.
private struct HomeSecondaryLinkRow: View {
    let title: String
    let systemImage: String
    var symbolTint: Color = AppTheme.brand
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.subheadline)
                    .foregroundStyle(symbolTint)
                    .frame(width: 22)
                    .dynamicTypeSize(...ChromeMetrics.symbolTypeLimit)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.brand)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .dynamicTypeSize(...ChromeMetrics.symbolTypeLimit)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: AppTheme.minimumHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

/// Execution mode's content: what was already decided, and one way to start.
///
/// The card no longer carries a `.title3` heading of its own — `HomePrimaryHeader`
/// owns the title now, which is what stops Home from showing three or four
/// same-weight section headings competing for the same attention.
private struct TodayPlanSummaryCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let dashboard: HomeDashboardSummary
    let onViewPlan: () -> Void
    let onSelectPlan: (MealPlanItem) -> Void

    var body: some View {
        if let leadPlan = dashboard.displayedPlans.first {
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 0) {
                    ForEach(Array(dashboard.displayedPlans.enumerated()), id: \.element.id) { index, plan in
                        planRow(plan)
                        if index < dashboard.displayedPlans.count - 1 {
                            Divider().padding(.leading, 34)
                        }
                    }
                }

                if dashboard.additionalPlanCount > 0 {
                    Text("另有 \(dashboard.additionalPlanCount) 道")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("home.today.plan.overflow")
                }

                // The one prominent control on the whole page in this state.
                Button(leadPlan.isCooked ? "查看菜谱" : "开始准备") {
                    onSelectPlan(leadPlan)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.cookingActionFill)
                .foregroundStyle(AppTheme.onCookingAction)
                .homeActionControl()
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("home.today.plan.start")

                // Named after where it goes, not after how much it shows. It
                // used to read 查看全部, the same words the recommendation card
                // uses for a completely different destination, and a reader who
                // learned it there had no way to tell this one apart — least of
                // all with VoiceOver, where the card around it is not there to
                // disambiguate. `今天的计划` is the destination's own title.
                Button("今天的计划", action: onViewPlan)
                    .foregroundStyle(AppTheme.brand)
                    .homeActionControl()
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("home.today.plan.viewAll")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous))
        }
    }

    private func planRow(_ plan: MealPlanItem) -> some View {
        Button {
            onSelectPlan(plan)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: plan.isCooked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(plan.isCooked ? AppTheme.success : AppTheme.textSecondary)
                    .font(.title3)
                    .dynamicTypeSize(...ChromeMetrics.symbolTypeLimit)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.recipeName)
                        .font(.headline)
                        .foregroundStyle(plan.isCooked ? .secondary : .primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    // No target stated means no serving count to show. Printing
                    // "1 人份" would assert a choice the user never made.
                    Text(plan.isCooked ? "已完成" : (plan.plannedServings.map { "\($0) 人份" } ?? "今天"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .dynamicTypeSize(...ChromeMetrics.symbolTypeLimit)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: AppTheme.minimumHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(plan.recipeName)，\(plan.isCooked ? "已完成" : (plan.plannedServings.map { "\($0) 人份，未完成" } ?? "未完成"))")
        .accessibilityHint("打开菜谱并开始准备")
        .accessibilityIdentifier("home.today.plan.row.\(plan.recipeID)")
    }
}

/// Decision mode's content. Unchanged in behaviour — same recommendation, same
/// three actions, same loading / error / sample states. What changed is that it
/// no longer owns a `.title3` heading and no longer sits beside a Today Plan
/// card of equal weight: `HomePrimaryHeader` names it, and it renders only when
/// it *is* the primary task.
private struct HomeRecommendationSection: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let recommendation: RecipeRecommendation?
    let isLoading: Bool
    let isGenerating: Bool
    let errorMessage: String?
    let noticeMessage: String?
    let isDisplayingSamples: Bool
    let isAddedToToday: Bool
    let inventoryNames: [String]
    let expiringNames: [String]
    let onAddToToday: (Recipe) -> Void
    let onViewRecipe: (Recipe) -> Void
    let onRefresh: () -> Void
    let onViewAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isDisplayingSamples {
                SampleFallbackNotice(isRetrying: isLoading, onRetry: nil)
            }

            if let recommendation {
                recommendationCard(recommendation)
            } else if isLoading || isGenerating {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在准备今日推荐…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 88)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous))
                .accessibilityIdentifier("home.recommendation.loading")
            } else {
                Label("暂时没有合适的推荐", systemImage: "sparkles")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                    .padding(.horizontal, 16)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous))
                    .accessibilityIdentifier("home.recommendation.empty")
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(AppTheme.warningInk)
                    .accessibilityIdentifier("home.recommendation.error")
            }

            if let noticeMessage {
                Label(noticeMessage, systemImage: "bolt.horizontal.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("home.recommendation.notice")
            }

            // The refresh and browse affordances live below the card rather than
            // beside a section title, so nothing competes with the primary
            // heading. AI stays visually subordinate to cooking, as before.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { auxiliaryButtons }
                VStack(alignment: .leading, spacing: 0) { auxiliaryButtons }
            }
        }
    }

    @ViewBuilder private var auxiliaryButtons: some View {
        Button(action: onRefresh) {
            HStack(spacing: 6) {
                if isGenerating {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AppTheme.aiAccentForeground)
                } else {
                    Image(systemName: "sparkles")
                        .dynamicTypeSize(...ChromeMetrics.symbolTypeLimit)
                }
                Text(isGenerating ? "正在生成…" : "AI 换几道")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(AppTheme.aiAccentForeground)
            .frame(minHeight: AppTheme.minimumHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isGenerating)
        .accessibilityIdentifier("home.recommendation.refresh")

        Button(action: onViewAll) {
            Text("查看全部")
                .font(.subheadline.weight(.medium))
                .frame(minHeight: AppTheme.minimumHitTarget)
                .contentShape(Rectangle())
        }
        .foregroundStyle(AppTheme.brand)
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.recommendation.viewAll")
    }

    private func recommendationCard(_ recommendation: RecipeRecommendation) -> some View {
        let recipe = recommendation.recipe
        return VStack(alignment: .leading, spacing: 10) {
            Text(recipe.title)
                .font(.title3.weight(.bold))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .accessibilityIdentifier("home.recommendation.title")
            Text(ingredientSummary(recipe))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .accessibilityIdentifier("home.recommendation.ingredients")
            Text(recommendation.reason ?? recommendationReason(recipe))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .accessibilityIdentifier("home.recommendation.reason")

            Button(isAddedToToday ? "已加入今天" : "加入今天") { onAddToToday(recipe) }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.cookingActionFill)
                .foregroundStyle(AppTheme.onCookingAction)
                .homeActionControl()
                .disabled(isAddedToToday)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("home.recommendation.addToday")

            Button("查看菜谱") { onViewRecipe(recipe) }
                .buttonStyle(.bordered)
                .tint(AppTheme.cookingAccentForeground.opacity(0.45))
                .foregroundStyle(AppTheme.cookingAccentForeground)
                .homeActionControl()
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("home.recommendation.viewRecipe")
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous))
    }

    private func recommendationReason(_ recipe: Recipe) -> String {
        if let name = expiringNames.first(where: { expiring in
            recipe.ingredients.contains { $0.localizedCaseInsensitiveContains(expiring) }
        }) {
            return "\(name)快到期了，建议优先用。"
        }
        return inventoryNames.isEmpty ? "先看看做法，也可以直接加入今天。" : "现有食材匹配度不错，可以先加入今天。"
    }

    private func ingredientSummary(_ recipe: Recipe) -> String {
        recipe.ingredients
            .prefix(3)
            .map { $0.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? $0 }
            .joined(separator: " · ")
    }
}

// MARK: - 3. Needs attention
//
// Replaces the count chips (即将到期 2) and the separate shopping reminder row
// with one lightweight, named list. A count could not be acted on from Home and
// did not say which food was at risk; a named row can be read and tapped.
//
// The section is deliberately quieter than the primary task: a `.subheadline`
// label rather than a `.title3` heading, and plain rows rather than a card with
// its own controls.
private struct HomeNeedsAttentionSection: View {
    let items: [HomeAttentionItem]
    let additionalCount: Int
    let onSelect: (HomeAttentionItem) -> Void
    let onViewAll: () -> Void

    var body: some View {
        if items.isEmpty {
            // A single reassuring line, with no heading above it. An empty
            // section should not claim a heading's worth of the page.
            Label("今天没有需要处理的食材", systemImage: "checkmark.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: AppTheme.minimumHitTarget, alignment: .leading)
                .accessibilityIdentifier("home.attention.healthy")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("需要处理")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.leading, 4)
                    .accessibilityIdentifier("home.attention.section")

                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        HomeAttentionRow(item: item) { onSelect(item) }
                        if index < items.count - 1 || additionalCount > 0 {
                            Divider().padding(.leading, 34)
                        }
                    }

                    // Never a silent cap: what the list left out is stated and
                    // reachable.
                    if additionalCount > 0 {
                        Button(action: onViewAll) {
                            HStack(spacing: 12) {
                                Image(systemName: "ellipsis.circle")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .frame(width: 22)
                                    .dynamicTypeSize(...ChromeMetrics.symbolTypeLimit)
                                    .accessibilityHidden(true)
                                Text("还有 \(additionalCount) 项")
                                    .font(.subheadline)
                                    .foregroundStyle(AppTheme.brand)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .dynamicTypeSize(...ChromeMetrics.symbolTypeLimit)
                                    .accessibilityHidden(true)
                            }
                            .frame(minHeight: AppTheme.minimumHitTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("home.attention.overflow")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous)
                )
            }
        }
    }
}

private struct HomeAttentionRow: View {
    let item: HomeAttentionItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: item.kind.systemImage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(item.kind.tint)
                    .frame(width: 22)
                    .dynamicTypeSize(...ChromeMetrics.symbolTypeLimit)
                    .accessibilityHidden(true)
                // Name first, always. At Accessibility sizes the detail stacks
                // under it rather than truncating either half.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Text(item.name).foregroundStyle(.primary)
                        Text("·").foregroundStyle(.secondary)
                        Text(item.detail).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).foregroundStyle(.primary)
                        Text(item.detail).foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .dynamicTypeSize(...ChromeMetrics.symbolTypeLimit)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: AppTheme.minimumHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name)，\(item.detail)")
        .accessibilityHint(item.kind.accessibilityHint)
        .accessibilityIdentifier(item.kind.identifier(for: item))
    }
}

private extension HomeAttentionItem.Kind {
    var systemImage: String {
        switch self {
        case .expiredInventory: "exclamationmark.circle.fill"
        case .preparedExpiring: "takeoutbag.and.cup.and.straw.fill"
        case .expiringInventory: "clock.fill"
        case .purchasedAwaitingStockIn: "shippingbox.fill"
        case .pendingShopping: "cart.fill"
        case .lowStock: "shippingbox"
        }
    }

    var tint: Color {
        switch self {
        case .expiredInventory: AppTheme.inventoryExpired
        case .preparedExpiring: AppTheme.warningInk
        case .expiringInventory: AppTheme.inventoryExpiring
        case .purchasedAwaitingStockIn, .pendingShopping: AppTheme.primary
        case .lowStock: AppTheme.textSecondary
        }
    }

    var accessibilityHint: String {
        switch self {
        case .expiredInventory, .expiringInventory: "查看并处理这项食材"
        case .preparedExpiring: "打开备餐记录"
        case .purchasedAwaitingStockIn: "确认后计入现有库存"
        case .pendingShopping: "继续完成本次买菜清单"
        case .lowStock: "查看需要补充的常备食材"
        }
    }

    /// The two batch operations keep the identifiers they have always had, so
    /// the existing stock-in and shopping tests still address the same control.
    /// Per-item rows are addressed by name, which is what a test asserting
    /// "Home names the food" needs to look for.
    func identifier(for item: HomeAttentionItem) -> String {
        switch self {
        case .purchasedAwaitingStockIn: "home.shopping.stockIn.button"
        case .pendingShopping: "home.shopping.pending.button"
        case .expiredInventory: "home.attention.expired.\(item.name)"
        case .expiringInventory: "home.attention.expiring.\(item.name)"
        case .preparedExpiring: "home.attention.prepared.\(item.name)"
        case .lowStock: "home.attention.lowStock.\(item.name)"
        }
    }
}

/// Tomorrow's food, stated once, below everything the page is actually about.
private struct HomeCarryoverFooterRow: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "arrow.turn.down.right")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
            .frame(maxWidth: .infinity, minHeight: AppTheme.minimumHitTarget, alignment: .leading)
            .accessibilityIdentifier("home.carryover.outgoing")
    }
}

private extension View {
    func homeActionControl() -> some View {
        font(.subheadline.weight(.semibold))
            .controlSize(.regular)
            .buttonBorderShape(.capsule)
            .frame(minHeight: AppTheme.minimumHitTarget)
    }
}

private struct HomeModuleIssues: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let issues: [HomeDashboardModuleIssue]
    let action: (HomeDashboardModuleIssue) -> Void

    var body: some View {
        ForEach(issues, id: \.self) { issue in
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    verticalIssue(issue)
                } else {
                    ViewThatFits(in: .horizontal) {
                        horizontalIssue(issue)
                        verticalIssue(issue)
                    }
                }
            }
            .padding(10)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous))
        }
    }

    private func horizontalIssue(_ issue: HomeDashboardModuleIssue) -> some View {
        HStack(spacing: 10) {
            issueIcon
            issueText(issue)
            Spacer(minLength: 8)
            issueAction(issue)
        }
    }

    private func verticalIssue(_ issue: HomeDashboardModuleIssue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                issueIcon
                issueText(issue)
                Spacer(minLength: 0)
            }
            issueAction(issue)
        }
    }

    private var issueIcon: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(AppTheme.warning)
            .accessibilityHidden(true)
    }

    private func issueText(_ issue: HomeDashboardModuleIssue) -> some View {
        Text(issue.title)
            .font(.footnote)
            .foregroundStyle(.primary)
            .accessibilityIdentifier(issue == .inventory ? "home.issue.inventory" : "home.issue.shopping")
    }

    private func issueAction(_ issue: HomeDashboardModuleIssue) -> some View {
        Button(issue.actionTitle) { action(issue) }
            .font(.footnote.weight(.semibold))
            .frame(minHeight: AppTheme.minimumHitTarget)
    }
}

#Preview("今日计划") {
    TodayPlanSummaryCard(
        dashboard: HomeDashboardSummary(
            inventory: [],
            todayPlans: [
                MealPlanItem(recipeID: "1", recipeName: "番茄炒蛋", plannedServings: 2),
                MealPlanItem(recipeID: "2", recipeName: "清炒时蔬", plannedServings: 1),
                MealPlanItem(recipeID: "3", recipeName: "紫菜蛋花汤", plannedServings: 3, isCooked: true)
            ],
            shoppingItems: []
        ),
        onViewPlan: {},
        onSelectPlan: { _ in }
    )
    .padding()
    .background(Color(.systemGroupedBackground))
}

#Preview("空首页") {
    VStack(alignment: .leading, spacing: 24) {
        HomeTodayContext(
            householdName: nil,
            isRestoringAccount: false,
            shouldShowHousehold: false,
            dayType: .flexible,
            eatOutSlots: [],
            incomingCarryover: [],
            onOpenDayRhythm: {}
        )
        HomeNeedsAttentionSection(items: [], additionalCount: 0, onSelect: { _ in }, onViewAll: {})
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}

#Preview("需要处理 — 具名行") {
    HomeNeedsAttentionSection(
        items: [
            HomeAttentionItem(id: "1", kind: .expiredInventory, name: "过期生菜", detail: "已过期 1 天"),
            HomeAttentionItem(id: "2", kind: .preparedExpiring, name: "卤鸡腿", detail: "建议明天前吃完"),
            HomeAttentionItem(id: "3", kind: .expiringInventory, name: "上海青", detail: "明天到期"),
            HomeAttentionItem(id: "4", kind: .lowStock, name: "鸡蛋", detail: "库存偏低")
        ],
        additionalCount: 2,
        onSelect: { _ in },
        onViewAll: {}
    )
    .padding()
    .background(Color(.systemGroupedBackground))
}

#Preview("今晚外食") {
    VStack(alignment: .leading, spacing: 12) {
        HomePrimaryHeader(
            task: HomePrimaryTask.resolve(
                dayType: .cooking, dinnerIntent: .eatOut,
                planState: .active, totalPlanCount: 1, completedPlanCount: 0
            )
        )
        HomeEatOutPrimary()
        HomeSecondaryLinkRow(
            title: "今日仍有 1 道计划",
            systemImage: "list.bullet",
            symbolTint: AppTheme.textSecondary,
            identifier: "home.plan.secondaryLink",
            action: {}
        )
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}

#Preview("深色模式") {
    HomeNeedsAttentionSection(
        items: [
            HomeAttentionItem(id: "1", kind: .expiringInventory, name: "上海青", detail: "明天到期"),
            HomeAttentionItem(id: "2", kind: .lowStock, name: "鸡蛋", detail: "库存偏低")
        ],
        additionalCount: 0,
        onSelect: { _ in },
        onViewAll: {}
    )
    .padding()
    .background(Color(.systemGroupedBackground))
    .preferredColorScheme(.dark)
}

#Preview("辅助功能大字号") {
    TodayPlanSummaryCard(
        dashboard: HomeDashboardSummary(
            inventory: [],
            todayPlans: [MealPlanItem(recipeID: "1", recipeName: "家常豆腐", plannedServings: 2)],
            shoppingItems: []
        ),
        onViewPlan: {},
        onSelectPlan: { _ in }
    )
    .padding()
    .dynamicTypeSize(.accessibility3)
}

#Preview("已完成计划") {
    TodayPlanSummaryCard(
        dashboard: HomeDashboardSummary(
            inventory: [],
            todayPlans: [MealPlanItem(recipeID: "1", recipeName: "红烧豆腐", plannedServings: 2, isCooked: true)],
            shoppingItems: []
        ),
        onViewPlan: {},
        onSelectPlan: { _ in }
    )
    .padding()
    .background(Color(.systemGroupedBackground))
}

#Preview("待入库提醒") {
    HomeNeedsAttentionSection(
        items: [HomeAttentionItem(id: "1", kind: .purchasedAwaitingStockIn, name: "已买的 2 项", detail: "等待入库")],
        additionalCount: 0,
        onSelect: { _ in },
        onViewAll: {}
    )
    .padding()
    .background(Color(.systemGroupedBackground))
}

#Preview("剪贴板提示") {
    ClipboardRecipeImportPrompt(onPaste: { _ in }, onIgnore: {})
        .padding()
        .background(Color(.systemGroupedBackground))
}

#Preview("本地保存问题") {
    HomeModuleIssues(issues: [.inventory], action: { _ in })
        .padding()
        .background(Color(.systemGroupedBackground))
}

#Preview("长名称") {
    VStack(alignment: .leading, spacing: 20) {
        HomeTodayContext(
            householdName: "一个同样很长、仍需完整理解的家庭名称",
            isRestoringAccount: false,
            shouldShowHousehold: true,
            dayType: .cooking,
            eatOutSlots: [.lunch, .dinner],
            incomingCarryover: [MealPortionCopy.targetDaySummary(2)],
            onOpenDayRhythm: {}
        )
        TodayPlanSummaryCard(
            dashboard: HomeDashboardSummary(
                inventory: [],
                todayPlans: [MealPlanItem(recipeID: "long", recipeName: "一份菜名很长但仍应保持清晰易读的家常晚餐", plannedServings: 4)],
                shoppingItems: []
            ),
            onViewPlan: {},
            onSelectPlan: { _ in }
        )
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}

#Preview("首页 Toast — 成功") {
    FeedbackToast(message: "已保存到菜谱库", style: .success)
        .padding()
        .background(Color(.systemGroupedBackground))
}

#Preview("首页 Toast — 提醒 / 深色") {
    FeedbackToast(message: "请先完成当前的导入操作", style: .warning)
        .padding()
        .background(Color(.systemGroupedBackground))
        .preferredColorScheme(.dark)
}

#Preview("首页 Toast — 错误 / 大字号") {
    FeedbackToast(message: "库存保存失败，请稍后重试。", style: .error)
        .padding()
        .background(Color(.systemGroupedBackground))
        .dynamicTypeSize(.accessibility3)
}

private extension String {
    var nilIfEmptyHome: String? { isEmpty ? nil : self }
}

// MARK: - Smart import

private enum SmartImportRoute: Hashable {
    case xiaohongshu
    case manualRecipe
}

private enum SmartImportChildSheet: String, Identifiable {
    case receipt
    case manualIngredient
    var id: String { rawValue }
}

struct SmartImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path = NavigationPath()
    @State private var childSheet: SmartImportChildSheet?
    var onRecipeSaved: () -> Void

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("菜谱") {
                    NavigationLink(value: SmartImportRoute.xiaohongshu) {
                        SmartImportRow(
                            title: "从小红书导入菜谱",
                            subtitle: "粘贴链接，智能提取食材与步骤",
                            systemImage: "sparkles.rectangle.stack.fill",
                            accent: AppTheme.brand
                        )
                    }
                    .accessibilityIdentifier("home.import.recipe.xiaohongshu")
                    NavigationLink(value: SmartImportRoute.manualRecipe) {
                        SmartImportRow(
                            title: "手动创建菜谱",
                            subtitle: "记录自己的菜谱",
                            systemImage: "square.and.pencil",
                            accent: nil
                        )
                    }
                    .accessibilityIdentifier("home.import.recipe.manual")
                }

                Section("食材") {
                    Button { childSheet = .receipt } label: {
                        SmartImportRow(
                            title: "扫描购物小票",
                            subtitle: "拍照智能识别商品并加入库存",
                            systemImage: "camera.viewfinder",
                            accent: AppTheme.primary
                        )
                    }
                    .accessibilityIdentifier("home.import.food.receipt")
                    Button { childSheet = .manualIngredient } label: {
                        SmartImportRow(
                            title: "手动添加食材",
                            subtitle: "快速记录食材库存",
                            systemImage: "shippingbox",
                            accent: nil
                        )
                    }
                    .accessibilityIdentifier("home.import.food.manual")
                }
            }
            .navigationTitle("导入与添加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
            .navigationDestination(for: SmartImportRoute.self) { route in
                switch route {
                case .xiaohongshu:
                    ImportRecipeView(onSaved: finishRecipeImport)
                case .manualRecipe:
                    ManualRecipeView()
                }
            }
            .sheet(item: $childSheet) { sheet in
                switch sheet {
                case .receipt:
                    RecordFoodSheet(initialMode: .receipt)
                case .manualIngredient:
                    RecordFoodSheet(initialMode: .manual)
                }
            }
        }
    }

    private func finishRecipeImport() {
        dismiss()
        onRecipeSaved()
    }
}

private struct SmartImportRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let accent: Color?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(accent == nil ? AppTheme.textSecondary : .white)
                .frame(width: 36, height: 36)
                .background(
                    accent ?? AppTheme.textSecondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.subheadline.weight(accent == nil ? .regular : .semibold))
                        .foregroundStyle(.primary)
                    if accent != nil {
                        Text("智能")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(AppTheme.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppTheme.textSecondary.opacity(0.12), in: Capsule())
                    }
                }
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

// MARK: - Today plan detail (secondary page)

struct TodayPlanDetailView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var kitchenStore: KitchenStore
    @EnvironmentObject private var recipeStore: RecipeStore
    @State private var activeSheet: TodayPlanSheet?
    @State private var planPendingRemoval: MealPlanItem?
    @State private var isShowingWeeklyPlanner = false
    @State private var isShowingShoppingGeneration = false
    @State private var toastMessage: String?
    @State private var toastStyle: AppFeedbackStyle = .success
    @State private var selectedRecipePlan: MealPlanItem?

    private enum TodayPlanSheet: Identifiable {
        case cook(MealPlanItem)
        case cookAll

        var id: String {
            switch self {
            case .cook(let plan): "cook-\(plan.id)"
            case .cookAll: "cook-all"
            }
        }
    }

    var body: some View {
        List {
            if kitchenStore.todayPlans.isEmpty {
                ContentUnavailableView {
                    Label("还没有安排今天吃什么", systemImage: "calendar.badge.plus")
                }
            } else {
                Section("今天 \(kitchenStore.todayPlans.count) 道菜") {
                    ForEach(kitchenStore.todayPlans) { plan in
                        Group {
                            if dynamicTypeSize.isAccessibilitySize {
                                VStack(alignment: .leading, spacing: 8) {
                                    planDetailButton(plan)
                                    completionButton(plan)
                                }
                            } else {
                                HStack(spacing: 12) {
                                    planDetailButton(plan)
                                    completionButton(plan)
                                }
                            }
                        }
                        .contextMenu {
                            Button("移出计划", role: .destructive) { planPendingRemoval = plan }
                        }
                    }
                }

                if !kitchenStore.pendingTodayPlans.isEmpty {
                    Section {
                        Button {
                            activeSheet = .cookAll
                        } label: {
                            Label("全部做完", systemImage: "checkmark.circle")
                                .foregroundStyle(AppTheme.brand)
                        }
                    }
                }

                Section {
                    Button("生成今日购物清单", systemImage: "cart.badge.plus") {
                        isShowingShoppingGeneration = true
                    }
                }
            }

            // The AI weekly-menu generator, and only it. The planner used to sit
            // directly beneath it as 查看本周安排 · 特殊计划 — two adjacent rows
            // with the same icon, both saying 本周, going to two unrelated
            // screens. That route was removed in D-031 (Home reaches the planner
            // in one tap now, on every day), and what is left says plainly that
            // this is the generator rather than the planner.
            Section {
                Button {
                    isShowingWeeklyPlanner = true
                } label: {
                    HStack {
                        Image(systemName: "calendar.badge.clock")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(kitchenStore.weeklyPlan == nil ? "AI 生成一周菜单" : "查看已生成的一周菜单")
                                .font(.subheadline.bold())
                            Text(weeklyPlanSubtitle)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier("today.plan.weeklyMenu.link")
            }
        }
        .navigationTitle("今天的计划")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $isShowingWeeklyPlanner) {
            WeeklyMenuPlannerView()
        }
        .navigationDestination(isPresented: $isShowingShoppingGeneration) {
            ShoppingListGenerationView(source: .todayPlans(kitchenStore.todayPlans))
        }
        .navigationDestination(item: $selectedRecipePlan) { plan in
            if let recipe = recipeStore.recipe(id: plan.recipeID) {
                RecipeDetailView(recipe: recipe, todayPlan: plan)
            } else {
                ContentUnavailableView("菜谱暂不可用", systemImage: "book.closed", description: Text("这份计划保留不变，可以稍后重试。"))
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .cook(let plan):
                CookConsumptionConfirmationView(
                    title: plan.recipeName,
                    planIDs: kitchenStore.hasConsumedPlan(plan.id) ? [] : [plan.id],
                    recipeID: plan.recipeID,
                    recipeName: plan.recipeName
                ) {
                    kitchenStore.markPlanCooked(plan)
                    showToast("已记录消耗，库存已更新")
                }
            case .cookAll:
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
                FeedbackToast(message: toastMessage, style: toastStyle)
            }
        }
    }

    private func planDetailButton(_ plan: MealPlanItem) -> some View {
        Button {
            selectedRecipePlan = plan
        } label: {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(plan.recipeName)
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(plan.isCooked ? "已完成" : (plan.plannedServings.map { "\($0) 人份 · 今天" } ?? "今天"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: plan.isCooked ? "checkmark.circle.fill" : "fork.knife.circle")
                            .font(.title2)
                            .foregroundStyle(plan.isCooked ? AppTheme.success : AppTheme.textSecondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(plan.recipeName).font(.headline)
                            Text(plan.isCooked ? "已完成" : (plan.plannedServings.map { "\($0) 人份 · 今天" } ?? "今天"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func completionButton(_ plan: MealPlanItem) -> some View {
        if !plan.isCooked {
            Button {
                activeSheet = .cook(plan)
            } label: {
                Text("做好了")
                    .font(.caption.bold())
                    .frame(minHeight: AppTheme.minimumHitTarget)
                    .contentShape(Rectangle())
            }
            .tint(AppTheme.brand)
            .accessibilityIdentifier("today.plan.complete.button")
        }
    }

    private var weeklyPlanSubtitle: String {
        guard let plan = kitchenStore.weeklyPlan else {
            return "按顿数、人数生成一周安排"
        }
        let dishCount = plan.days.reduce(0) { $0 + $1.meals.reduce(0) { $0 + $1.recipes.count } }
        return "已安排 \(plan.days.count) 天 · \(dishCount) 道菜"
    }

    private func showToast(_ message: String, style: AppFeedbackStyle = .success) {
        withAnimation { toastMessage = message; toastStyle = style }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            await MainActor.run { withAnimation { toastMessage = nil } }
        }
    }
}

// MARK: - Recommendation browser (secondary page)

struct RecipeRecommendationBrowserView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var recipeStore: RecipeStore
    @EnvironmentObject private var kitchenStore: KitchenStore
    @EnvironmentObject private var recommendationStore: HomeRecommendationStore

    @State private var selectedRecipe: Recipe?
    @State private var toastMessage: String?
    @State private var toastStyle: AppFeedbackStyle = .success
    @FocusState private var isSearchFocused: Bool

    private var sourceRecipes: [Recipe] {
        recipeStore.recipesForDisplay
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                searchBar

                if recipeStore.isDisplayingSamples {
                    // No retry here: the recommendation list is already built
                    // from these recipes, and recomputing it cleanly would mean
                    // clearing the user's active search. The Recipe tab owns retry.
                    SampleFallbackNotice(isRetrying: recipeStore.isLoading, onRetry: nil)
                }

                HStack(alignment: .firstTextBaseline) {
                    Text(recipeStore.isDisplayingSamples ? "示例推荐" : "推荐")
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

                if recommendationStore.recommendedRecipes.isEmpty {
                    recommendationEmptyState
                } else if dynamicTypeSize.isAccessibilitySize {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(recommendationStore.recommendedRecipes) { recommendation in
                            recommendationCard(recommendation)
                                .padding(.horizontal, 1)
                        }
                    }
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
                    .frame(height: 300)
                    .accessibilityIdentifier("recommendation.pager")
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
                        .accessibilityIdentifier("recommendation.pageIndicator")
                        .accessibilityLabel(
                            "第 \(recommendationStore.currentRecommendationIndex + 1) 道，共 \(recommendationStore.recommendedRecipes.count) 道"
                        )
                    }

                }

                if !recommendationStore.recommendedRecipes.isEmpty {
                    Button {
                        generateAIRecommendations()
                    } label: {
                        HStack(spacing: 7) {
                            if recommendationStore.isGeneratingRecommendations {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(AppTheme.aiAccentForeground)
                            } else {
                                Image(systemName: "sparkles")
                            }
                            Text(recommendationStore.isGeneratingRecommendations ? "正在生成…" : "AI 换几道")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.aiAccentForeground)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(AppTheme.aiAccentForeground.opacity(0.30))
                    .accessibilityIdentifier("recommendation.regenerate.button")
                    .disabled(recommendationStore.isSearchingRecommendations
                              || recommendationStore.isGeneratingRecommendations)
                }

                if let error = recommendationStore.recommendationError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let notice = recommendationStore.recommendationNotice {
                    Label(notice, systemImage: "bolt.horizontal.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("recommendation.notice")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("推荐")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: recipeStore.recipes.count) {
            loadDefaultRecommendationsIfNeeded()
        }
        .onDisappear {
            recommendationStore.cancelRequests()
        }
        .navigationDestination(item: $selectedRecipe) { recipe in
            RecipeDetailView(recipe: recipe)
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                FeedbackToast(message: toastMessage, style: toastStyle)
            }
        }
    }

    private var searchBar: some View {
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
                .focused($isSearchFocused)
                .onSubmit(performRecommendationSearch)
                .accessibilityIdentifier("recommendation.search.field")

                if !recommendationStore.searchQuery.isEmpty {
                    Button {
                        clearRecommendationSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: AppTheme.minimumHitTarget, minHeight: AppTheme.minimumHitTarget)
                    .accessibilityLabel("清除搜索")
                    .accessibilityIdentifier("recommendation.search.clear")
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(AppTheme.secondarySurface, in: RoundedRectangle(cornerRadius: AppTheme.radiusCompact, style: .continuous))

            Button(action: performRecommendationSearch) {
                Group {
                    if recommendationStore.isSearchingRecommendations {
                        ProgressView()
                            .tint(AppTheme.onCookingAction)
                    } else {
                        Text("找菜")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.onCookingAction)
                .frame(
                    minWidth: AppTheme.minimumHitTarget,
                    minHeight: AppTheme.minimumHitTarget
                )
                .background(AppTheme.cookingActionFill, in: RoundedRectangle(cornerRadius: AppTheme.radiusCompact, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("recommendation.search.button")
            .disabled(recommendationStore.isSearchingRecommendations
                      || recommendationStore.isGeneratingRecommendations)
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
                .tint(AppTheme.cookingActionFill)
                .foregroundStyle(AppTheme.onCookingAction)
            if !recommendationStore.searchQuery.isEmpty {
                Button("清除搜索", action: clearRecommendationSearch)
                    .buttonStyle(.bordered)
            }
        }
    }

    private func recommendationCard(_ recommendation: RecipeRecommendation) -> some View {
        let recipe = recommendation.recipe
        let isFrequent = recipeStore.frequentRecipeIDs.contains(recipe.id)
        let isAdded = kitchenStore.todayPlans.contains { $0.recipeID == recipe.id }

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(recommendation.source == .ai ? "AI 推荐" : "今日推荐", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer()
                Text(recommendation.source == .ai ? "新灵感" : recommendationBadge(recipe))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(AppTheme.textSecondary.opacity(0.10), in: Capsule())
                Menu {
                    Button("加入今天", systemImage: "calendar.badge.plus") {
                        addRecommendationToPlan(recipe)
                    }
                    .disabled(isAdded)
                    Button("查看菜谱", systemImage: "book.pages") {
                        selectedRecipe = recipe
                    }
                    Button(
                        isFrequent ? "取消常做" : "设为常做",
                        systemImage: isFrequent ? "star.slash" : "star"
                    ) {
                        recipeStore.toggleFrequent(recipe.id)
                        showToast(isFrequent ? "已取消常做" : "已设为常做")
                    }
                    Divider()
                    Button("从本次推荐移除", systemImage: "trash", role: .destructive) {
                        recommendationStore.removeRecommendation(id: recommendation.id)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.primary)
                        .frame(width: AppTheme.minimumHitTarget, height: AppTheme.minimumHitTarget)
                }
                .accessibilityLabel("推荐操作")
                .accessibilityIdentifier("recommendation.\(recipe.id).menu")
            }

            Text(recipe.title)
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .accessibilityIdentifier("recommendation.\(recipe.id).title")
            Text(ingredientSummary(recipe))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .accessibilityIdentifier("recommendation.\(recipe.id).ingredients")
            Text(recommendation.reason ?? recommendationReason(recipe))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("recommendation.\(recipe.id).reason")
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button(isAdded ? "已加入" : "加入计划") {
                    addRecommendationToPlan(recipe)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.onCookingAction)
                .frame(maxWidth: .infinity, minHeight: AppTheme.minimumHitTarget)
                .background(AppTheme.cookingActionFill, in: RoundedRectangle(cornerRadius: AppTheme.radiusCompact, style: .continuous))
                .opacity(isAdded ? 0.62 : 1)
                .disabled(isAdded)
                .accessibilityIdentifier("recommendation.\(recipe.id).addPlan")

                Button("查看") { selectedRecipe = recipe }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: AppTheme.minimumHitTarget)
                    .background(AppTheme.textSecondary.opacity(0.12), in: RoundedRectangle(cornerRadius: AppTheme.radiusCompact, style: .continuous))
                    .accessibilityIdentifier("recommendation.\(recipe.id).view")
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(AppTheme.secondarySurface, in: RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous)
                .stroke(AppTheme.separator.opacity(0.28), lineWidth: 0.5)
        }
        .shadow(color: AppTheme.cardShadow(opacity: 0.035), radius: 9, y: 4)
    }

    private func recommendationBadge(_ recipe: Recipe) -> String {
        let names = kitchenStore.recipeCreationInventory.map(\.name)
        let matches = recipe.ingredients.filter { ingredient in
            names.contains { ingredient.localizedCaseInsensitiveContains($0) }
        }.count
        return matches > 0 ? "用到 \(matches) 样在库食材" : "灵感菜"
    }

    private func recommendationReason(_ recipe: Recipe) -> String {
        let expiringNames = kitchenStore.recipeCreationExpiringItems.map(\.name)
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
            inventory: kitchenStore.recipeCreationInventory.map(\.name),
            expiringIngredients: kitchenStore.recipeCreationExpiringItems.map(\.name)
        )
    }

    private func performRecommendationSearch() {
        isSearchFocused = false
        Task {
            await recommendationStore.searchRecommendations(
                recipes: sourceRecipes,
                inventory: kitchenStore.recipeCreationInventory.map(\.name),
                expiringIngredients: kitchenStore.recipeCreationExpiringItems.map(\.name)
            )
        }
    }

    private func clearRecommendationSearch() {
        isSearchFocused = false
        recommendationStore.clearSearch(
            recipes: sourceRecipes,
            inventory: kitchenStore.recipeCreationInventory.map(\.name),
            expiringIngredients: kitchenStore.recipeCreationExpiringItems.map(\.name)
        )
    }

    private func generateAIRecommendations() {
        isSearchFocused = false
        Task {
            await recommendationStore.generateNewRecommendations(
                inventory: kitchenStore.recipeCreationInventory.map(\.name),
                expiringIngredients: kitchenStore.recipeCreationExpiringItems.map(\.name)
            )
        }
    }

    private func addRecommendationToPlan(_ recipe: Recipe) {
        let alreadyAdded = kitchenStore.todayPlans.contains { $0.recipeID == recipe.id }
        kitchenStore.addPlan(recipe: recipe)
        UINotificationFeedbackGenerator().notificationOccurred(
            alreadyAdded ? .warning : .success
        )
        showToast(alreadyAdded ? "已在今天" : "已加入今天", style: alreadyAdded ? .warning : .success)
    }

    private func showToast(_ message: String, style: AppFeedbackStyle = .success) {
        withAnimation { toastMessage = message; toastStyle = style }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            await MainActor.run { withAnimation { toastMessage = nil } }
        }
    }
}

// MARK: - Status sheets (expiry / shopping)

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
                        .tint(AppTheme.managementActionFill)
                        .foregroundStyle(AppTheme.onManagementAction)
                }
            }
        }
    }
}

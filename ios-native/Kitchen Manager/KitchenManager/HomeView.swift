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
    case clipboardImport(ClipboardImportPresentation)

    var id: String {
        switch self {
        case .smartImport: "smart-import"
        case .expiry: "expiry"
        case .shopping: "shopping"
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

    @State private var activeSheet: HomeSheet?
    @State private var toastMessage: String?
    @State private var toastStyle: AppFeedbackStyle = .success
    @State private var isShowingTodayPlan = false
    @State private var isShowingRecommendations = false
    @State private var selectedPlan: MealPlanItem?
    @State private var selectedRecipe: Recipe?
    @State private var clipboardPromptState = ClipboardPromptSessionState()
    @State private var clipboardDetectionTask: Task<Void, Never>?

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
            shoppingItems: kitchenStore.shoppingItems
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
        // inventory, today's plans and the shopping list, and the cost is
        // linear in inventory size. Body used to read it three times (the
        // card, the primary action, and the reminder section — four when a
        // reminder is showing). Building it once here and passing that one
        // value around keeps every reader on identical data as well.
        let dashboard = self.dashboard
        let supplementaryReminder = supplementaryReminder(for: dashboard)
        let homeRecommendation = recommendationStore.recommendedRecipes.first { recommendation in
            !kitchenStore.todayPlans.contains { $0.recipeID == recommendation.recipe.id }
        } ?? recommendationStore.currentRecommendation
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HomeDashboardHeader(
                    householdName: householdName,
                    isRestoringAccount: authStore.activity == .restoring,
                    shouldShowHousehold: headerModel.shouldShowHousehold
                )

                if dashboard.totalPlanCount > 0 {
                    TodayPlanSummaryCard(
                        dashboard: dashboard,
                        onViewPlan: { isShowingTodayPlan = true },
                        onSelectPlan: { selectedPlan = $0 }
                    )
                }

                HomeRecommendationSection(
                    recommendation: homeRecommendation,
                    isLoading: recipeStore.isLoading && recommendationStore.recommendedRecipes.isEmpty,
                    isGenerating: recommendationStore.isGeneratingRecommendations,
                    errorMessage: recommendationStore.recommendationError,
                    isDisplayingSamples: recipeStore.isDisplayingSamples,
                    isAddedToToday: homeRecommendation.map {
                        recommendation in kitchenStore.todayPlans.contains { $0.recipeID == recommendation.recipe.id }
                    } ?? false,
                    inventoryNames: kitchenStore.availableInventory.map(\.name),
                    expiringNames: kitchenStore.expiringItems.map(\.name),
                    onAddToToday: addRecommendationToPlan,
                    onViewRecipe: { selectedRecipe = $0 },
                    onRefresh: generateAIRecommendations,
                    onViewAll: { isShowingRecommendations = true }
                )

                HomeInventoryAttentionSummary(dashboard: dashboard) {
                    handleReminder($0)
                }

                ForEach(
                    HomeDashboardPresentation.supplementarySections(
                        hasReminder: supplementaryReminder != nil,
                        showsClipboardPrompt: shouldShowClipboardPrompt,
                        hasModuleIssues: !moduleIssues.isEmpty
                    ),
                    id: \.self
                ) { section in
                    switch section {
                    case .reminder:
                        if let reminder = supplementaryReminder {
                            HomeAttentionReminderRow(reminder: reminder) {
                                handleReminder(reminder)
                            }
                        }
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
        .navigationTitle(headerModel.title)
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
        .navigationDestination(isPresented: $isShowingRecommendations) {
            RecipeRecommendationBrowserView()
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
            scheduleClipboardDetection()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
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
                        inventory: kitchenStore.availableInventory.map(\.name),
                        expiringIngredients: kitchenStore.expiringItems.map(\.name)
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

    private func supplementaryReminder(for dashboard: HomeDashboardSummary) -> HomeAttentionReminder? {
        if dashboard.purchasedShoppingCount > 0 {
            return .purchasedAwaitingStockIn(count: dashboard.purchasedShoppingCount)
        }
        if dashboard.pendingShoppingCount > 0 {
            return .pendingShopping(count: dashboard.pendingShoppingCount)
        }
        return nil
    }

    private func loadDefaultRecommendationsIfNeeded() {
        recommendationStore.loadDefaultRecommendations(
            recipes: sourceRecipes,
            inventory: kitchenStore.availableInventory.map(\.name),
            expiringIngredients: kitchenStore.expiringItems.map(\.name)
        )
    }

    private func generateAIRecommendations() {
        Task {
            await recommendationStore.generateNewRecommendations(
                inventory: kitchenStore.availableInventory.map(\.name),
                expiringIngredients: kitchenStore.expiringItems.map(\.name)
            )
        }
    }

    private func addRecommendationToPlan(_ recipe: Recipe) {
        let alreadyAdded = kitchenStore.todayPlans.contains { $0.recipeID == recipe.id }
        kitchenStore.addPlan(recipe: recipe)
        UINotificationFeedbackGenerator().notificationOccurred(alreadyAdded ? .warning : .success)
        showToast(alreadyAdded ? "已在今天" : "已加入今天", style: alreadyAdded ? .warning : .success)
    }

    private func handleReminder(_ reminder: HomeAttentionReminder) {
        switch reminder {
        case .purchasedAwaitingStockIn:
            navigationStore.showShoppingStockIn()
        case .expiredInventory:
            navigationStore.showInventory(.expired)
        case .expiringInventory:
            navigationStore.showInventory(.expiringSoon)
        case .pendingShopping:
            navigationStore.selectedTab = .shopping
        case .lowStock:
            navigationStore.showInventory(.lowStock)
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
        .background(AppTheme.secondarySurface, in: RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous)
                .stroke(AppTheme.separator.opacity(0.22), lineWidth: 0.5)
        }
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
private struct HomeDashboardHeader: View {
    let householdName: String?
    let isRestoringAccount: Bool
    let shouldShowHousehold: Bool

    private var dateText: String { HomeDatePresentation.text(for: .now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(dateText)
                .font(.footnote)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .foregroundStyle(.secondary)
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.dashboard.header")
    }
}

private struct TodayPlanSummaryCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let dashboard: HomeDashboardSummary
    let onViewPlan: () -> Void
    let onSelectPlan: (MealPlanItem) -> Void

    var body: some View {
        if let plan = dashboard.displayedPlans.first {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("今日计划")
                        .font(.headline)
                        .accessibilityIdentifier("home.today.plan.card")
                    Text(planProgressText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }

                Button {
                    onSelectPlan(plan)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: plan.isCooked ? "checkmark.circle" : "fork.knife.circle")
                            .foregroundStyle(plan.isCooked ? AppTheme.success : AppTheme.textSecondary)
                            .font(.title3)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plan.recipeName)
                                .font(.headline)
                                .foregroundStyle(plan.isCooked ? .secondary : .primary)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                            Text(planSubtitle(plan))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: AppTheme.minimumHitTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(plan.recipeName)，\(plan.isCooked ? "已完成" : "\(plan.servings) 人份，未完成")")
                .accessibilityHint("打开菜谱并开始准备")
                .accessibilityIdentifier("home.today.plan.row.\(plan.recipeID)")

                ViewThatFits(in: .horizontal) {
                    planActions(axis: .horizontal, plan: plan)
                    planActions(axis: .vertical, plan: plan)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous)
                    .stroke(AppTheme.separator.opacity(0.34), lineWidth: 0.5)
            }
        }
    }

    private func planActions(axis: Axis, plan: MealPlanItem) -> some View {
        Group {
            if axis == .horizontal {
                HStack(spacing: 8) { actionButtons(plan: plan) }
            } else {
                VStack(spacing: 8) { actionButtons(plan: plan) }
            }
        }
    }

    @ViewBuilder
    private func actionButtons(plan: MealPlanItem) -> some View {
        Button(plan.isCooked ? "查看菜谱" : "开始准备") {
            onSelectPlan(plan)
        }
        .buttonStyle(.borderedProminent)
        .tint(AppTheme.cookingActionFill)
        .foregroundStyle(AppTheme.onCookingAction)
        .homeActionControl()
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("home.today.plan.start")

        Button("查看全部", action: onViewPlan)
            .foregroundStyle(AppTheme.brand)
            .homeActionControl()
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("home.today.plan.viewAll")
    }

    private var planProgressText: String {
        switch dashboard.todayPlanState {
        case .empty: ""
        case .active: "\(dashboard.totalPlanCount) 道待完成"
        case .partial: "已完成 \(dashboard.completedPlanCount)/\(dashboard.totalPlanCount)"
        case .completed: "已全部完成"
        }
    }

    private func planSubtitle(_ plan: MealPlanItem) -> String {
        let remaining = max(0, dashboard.totalPlanCount - 1)
        let status = plan.isCooked ? "已完成" : "\(plan.servings) 人份"
        return remaining > 0 ? "\(status) · 另有 \(remaining) 道" : status
    }
}

private struct HomeRecommendationSection: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let recommendation: RecipeRecommendation?
    let isLoading: Bool
    let isGenerating: Bool
    let errorMessage: String?
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
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    sectionTitle
                    Spacer(minLength: 8)
                    refreshButton
                    viewAllButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            refreshButton
                            viewAllButton
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            refreshButton
                            viewAllButton
                        }
                    }
                }
            }

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
                .background(AppTheme.secondarySurface, in: RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous))
                .accessibilityIdentifier("home.recommendation.loading")
            } else {
                Label("暂时没有合适的推荐", systemImage: "sparkles")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                    .padding(.horizontal, 16)
                    .background(AppTheme.secondarySurface, in: RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous))
                    .accessibilityIdentifier("home.recommendation.empty")
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(AppTheme.warningInk)
                    .accessibilityIdentifier("home.recommendation.error")
            }
        }
    }

    private var sectionTitle: some View {
        Text("今日推荐")
            .font(.title3.weight(.semibold))
            .accessibilityIdentifier("home.recommendation.section")
    }

    private var viewAllButton: some View {
        Button("查看全部", action: onViewAll)
            .foregroundStyle(AppTheme.brand)
            .homeActionControl()
            .accessibilityIdentifier("home.recommendation.viewAll")
    }

    private var refreshButton: some View {
        Button(action: onRefresh) {
            HStack(spacing: 6) {
                if isGenerating {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AppTheme.aiAccentForeground)
                } else {
                    Image(systemName: "sparkles")
                }
                Text(isGenerating ? "正在生成…" : "AI 换几道")
            }
            .foregroundStyle(AppTheme.aiAccentForeground)
        }
        .buttonStyle(.bordered)
        .tint(AppTheme.aiAccentForeground.opacity(0.30))
        .homeActionControl()
        .disabled(isGenerating)
        .accessibilityIdentifier("home.recommendation.refresh")
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

            ViewThatFits(in: .horizontal) {
                recommendationActions(recipe, axis: .horizontal)
                recommendationActions(recipe, axis: .vertical)
            }
        }
        .padding(16)
        .background(AppTheme.secondarySurface, in: RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous)
                .stroke(AppTheme.separator.opacity(0.28), lineWidth: 0.5)
        }
    }

    private func recommendationActions(_ recipe: Recipe, axis: Axis) -> some View {
        Group {
            if axis == .horizontal {
                HStack(spacing: 8) { recommendationButtons(recipe) }
            } else {
                VStack(spacing: 8) { recommendationButtons(recipe) }
            }
        }
    }

    @ViewBuilder
    private func recommendationButtons(_ recipe: Recipe) -> some View {
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

private struct HomeInventoryAttentionSummary: View {
    let dashboard: HomeDashboardSummary
    let action: (HomeAttentionReminder) -> Void

    private var reminders: [HomeAttentionReminder] {
        var result: [HomeAttentionReminder] = []
        if dashboard.expiredCount > 0 { result.append(.expiredInventory(count: dashboard.expiredCount)) }
        if dashboard.expiringSoonCount > 0 { result.append(.expiringInventory(count: dashboard.expiringSoonCount)) }
        if dashboard.lowStockCount > 0 { result.append(.lowStock(count: dashboard.lowStockCount)) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("库存待处理")
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("home.inventory.summary")

            if reminders.isEmpty {
                Label("今天没有需要处理的食材", systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: AppTheme.minimumHitTarget)
                    .accessibilityIdentifier("home.inventory.healthy")
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { reminderButtons(reminders) }
                    if reminders.count > 2 {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) { reminderButtons(Array(reminders.prefix(2))) }
                            reminderButtons(Array(reminders.dropFirst(2)))
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) { reminderButtons(reminders) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func reminderButtons(_ reminders: [HomeAttentionReminder]) -> some View {
        ForEach(reminders, id: \.identifier) { reminder in
            Button { action(reminder) } label: {
                HStack(spacing: 6) {
                    Image(systemName: reminder.compactSystemImage)
                        .foregroundStyle(reminder.compactTint)
                        .accessibilityHidden(true)
                    Text(reminder.compactTitle)
                        .foregroundStyle(AppTheme.textPrimary)
                }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .frame(minHeight: AppTheme.minimumHitTarget)
                    .background(reminder.compactTint.opacity(0.10), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(reminder.compactTitle)
            .accessibilityHint("查看并处理")
            .accessibilityIdentifier(reminder.identifier)
        }
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

private extension HomeAttentionReminder {
    var compactTitle: String {
        switch self {
        case .expiredInventory(let count): "已过期 \(count)"
        case .expiringInventory(let count): "即将到期 \(count)"
        case .lowStock(let count): "需补货 \(count)"
        case .purchasedAwaitingStockIn(let count): "待入库 \(count)"
        case .pendingShopping(let count): "待购买 \(count)"
        }
    }

    var compactSystemImage: String {
        switch self {
        case .expiredInventory: "exclamationmark.circle.fill"
        case .expiringInventory: "clock.fill"
        case .lowStock: "shippingbox"
        case .purchasedAwaitingStockIn: "shippingbox.fill"
        case .pendingShopping: "cart.fill"
        }
    }

    var compactTint: Color {
        switch self {
        case .expiredInventory: AppTheme.inventoryExpired
        case .expiringInventory: AppTheme.inventoryExpiring
        case .lowStock: AppTheme.textSecondary
        case .purchasedAwaitingStockIn, .pendingShopping: AppTheme.primary
        }
    }

    var identifier: String {
        switch self {
        case .purchasedAwaitingStockIn: "home.shopping.stockIn.button"
        case .expiredInventory: "home.inventory.expired.button"
        case .expiringInventory: "home.inventory.expiring.button"
        case .pendingShopping: "home.shopping.pending.button"
        case .lowStock: "home.inventory.lowstock.button"
        }
    }
}

private struct HomeAttentionReminderRow: View {
    let reminder: HomeAttentionReminder
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 15)
        .padding(.vertical, 8)
        .background(AppTheme.secondarySurface, in: RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous)
                .stroke(AppTheme.separator.opacity(0.22), lineWidth: 0.5)
        }
        .accessibilityIdentifier(identifier)
        .accessibilityLabel("\(title)，\(subtitle)")
        .accessibilityHint("双击查看并处理")
    }

    private var title: String {
        switch reminder {
        case .purchasedAwaitingStockIn(let count): "\(count) 项已购买食材等待入库"
        case .expiredInventory(let count): "\(count) 项食材已过期"
        case .expiringInventory(let count): "\(count) 项食材即将到期"
        case .pendingShopping(let count): "买菜清单还有 \(count) 项未完成"
        case .lowStock(let count): "\(count) 项常备食材库存不足"
        }
    }

    private var subtitle: String {
        switch reminder {
        case .purchasedAwaitingStockIn: "确认后计入现有库存"
        case .expiredInventory: "查看并处理已过期食材"
        case .expiringInventory: "优先安排使用这些食材"
        case .pendingShopping: "继续完成本次买菜清单"
        case .lowStock: "查看需要补充的常备食材"
        }
    }

    private var systemImage: String {
        switch reminder {
        case .purchasedAwaitingStockIn: "shippingbox.fill"
        case .expiredInventory: "exclamationmark.circle.fill"
        case .expiringInventory: "clock.fill"
        case .pendingShopping: "cart.fill"
        case .lowStock: "shippingbox"
        }
    }

    private var tint: Color {
        switch reminder {
        case .purchasedAwaitingStockIn: AppTheme.primary
        case .expiredInventory: AppTheme.inventoryExpired
        case .expiringInventory: AppTheme.warning
        case .pendingShopping: AppTheme.primary
        case .lowStock: AppTheme.warning
        }
    }

    private var identifier: String {
        switch reminder {
        case .purchasedAwaitingStockIn: "home.shopping.stockIn.button"
        case .expiredInventory: "home.inventory.expired.button"
        case .expiringInventory: "home.inventory.expiring.button"
        case .pendingShopping: "home.shopping.pending.button"
        case .lowStock: "home.inventory.lowstock.button"
        }
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
            .background(AppTheme.secondarySurface, in: RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous)
                    .stroke(AppTheme.separator.opacity(0.22), lineWidth: 0.5)
            }
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
                MealPlanItem(recipeID: "1", recipeName: "番茄炒蛋", servings: 2),
                MealPlanItem(recipeID: "2", recipeName: "清炒时蔬", servings: 1),
                MealPlanItem(recipeID: "3", recipeName: "紫菜蛋花汤", servings: 3, isCooked: true)
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
    VStack(alignment: .leading, spacing: 28) {
        HomeDashboardHeader(householdName: nil, isRestoringAccount: false, shouldShowHousehold: false)
        HomeInventoryAttentionSummary(
            dashboard: HomeDashboardSummary(inventory: [], todayPlans: [], shoppingItems: []),
            action: { _ in }
        )
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}

#Preview("深色模式") {
    HomeAttentionReminderRow(reminder: .expiringInventory(count: 2), action: {})
    .padding()
    .background(Color(.systemGroupedBackground))
    .preferredColorScheme(.dark)
}

#Preview("辅助功能大字号") {
    TodayPlanSummaryCard(
        dashboard: HomeDashboardSummary(
            inventory: [],
            todayPlans: [MealPlanItem(recipeID: "1", recipeName: "家常豆腐", servings: 2)],
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
            todayPlans: [MealPlanItem(recipeID: "1", recipeName: "红烧豆腐", servings: 2, isCooked: true)],
            shoppingItems: []
        ),
        onViewPlan: {},
        onSelectPlan: { _ in }
    )
    .padding()
    .background(Color(.systemGroupedBackground))
}

#Preview("待入库提醒") {
    HomeAttentionReminderRow(reminder: .purchasedAwaitingStockIn(count: 2), action: {})
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
        HomeDashboardHeader(
            householdName: "一个同样很长、仍需完整理解的家庭名称",
            isRestoringAccount: false,
            shouldShowHousehold: true
        )
        TodayPlanSummaryCard(
            dashboard: HomeDashboardSummary(
                inventory: [],
                todayPlans: [MealPlanItem(recipeID: "long", recipeName: "一份菜名很长但仍应保持清晰易读的家常晚餐", servings: 4)],
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

            Section {
                Button {
                    isShowingWeeklyPlanner = true
                } label: {
                    HStack {
                        Image(systemName: "calendar.badge.clock")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(kitchenStore.weeklyPlan == nil ? "规划本周菜单" : "查看本周计划")
                                .font(.subheadline.bold())
                            Text(weeklyPlanSubtitle)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .foregroundStyle(.primary)
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
                        Text(plan.isCooked ? "已完成" : "\(plan.servings) 人份 · 今天")
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
                            Text(plan.isCooked ? "已完成" : "\(plan.servings) 人份 · 今天")
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
        let names = kitchenStore.availableInventory.map(\.name)
        let matches = recipe.ingredients.filter { ingredient in
            names.contains { ingredient.localizedCaseInsensitiveContains($0) }
        }.count
        return matches > 0 ? "用到 \(matches) 样在库食材" : "灵感菜"
    }

    private func recommendationReason(_ recipe: Recipe) -> String {
        let expiringNames = kitchenStore.expiringItems.map(\.name)
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
            inventory: kitchenStore.availableInventory.map(\.name),
            expiringIngredients: kitchenStore.expiringItems.map(\.name)
        )
    }

    private func performRecommendationSearch() {
        isSearchFocused = false
        Task {
            await recommendationStore.searchRecommendations(
                recipes: sourceRecipes,
                inventory: kitchenStore.availableInventory.map(\.name),
                expiringIngredients: kitchenStore.expiringItems.map(\.name)
            )
        }
    }

    private func clearRecommendationSearch() {
        isSearchFocused = false
        recommendationStore.clearSearch(
            recipes: sourceRecipes,
            inventory: kitchenStore.availableInventory.map(\.name),
            expiringIngredients: kitchenStore.expiringItems.map(\.name)
        )
    }

    private func generateAIRecommendations() {
        isSearchFocused = false
        Task {
            await recommendationStore.generateNewRecommendations(
                inventory: kitchenStore.availableInventory.map(\.name),
                expiringIngredients: kitchenStore.expiringItems.map(\.name)
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

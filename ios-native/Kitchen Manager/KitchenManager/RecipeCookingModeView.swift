import SwiftUI

struct RecipeCookingModeView: View {
    let recipe: Recipe
    @ObservedObject var session: RecipeCookingSession
    let todayPlan: MealPlanItem?
    let onFinish: () -> Void
    let onExit: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var timer = CookingTimerController()
    @State private var screenAwake = ScreenAwakeController()
    @State private var isShowingExitOptions = false
    @State private var isShowingIngredientSheet = false

    private var steps: [String] { recipe.steps.filter { !$0.hasPrefix("小贴士：") } }
    private var currentStep: String { steps.indices.contains(session.currentStepIndex) ? steps[session.currentStepIndex] : "这份菜谱还没有制作步骤。" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if steps.isEmpty {
                    ContentUnavailableView("还没有制作步骤", systemImage: "list.number", description: Text("可以返回详情编辑菜谱后再开始烹饪。"))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            cookingProgress

                            VStack(alignment: .leading, spacing: 16) {
                                Text("第 \(session.currentStepIndex + 1) 步")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                Text(currentStep)
                                    .font(.title2.weight(.semibold))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("recipe.cooking.currentStep")
                                Button {
                                    session.toggleStep(at: session.currentStepIndex)
                                } label: {
                                    Label(
                                        session.completedStepIndexes.contains(session.currentStepIndex) ? "已完成此步骤" : "标记此步骤完成",
                                        systemImage: session.completedStepIndexes.contains(session.currentStepIndex) ? "checkmark.circle.fill" : "circle"
                                    )
                                }
                                .buttonStyle(.bordered)
                                .tint(AppTheme.brand)
                                .frame(minHeight: AppTheme.minimumHitTarget)
                                .accessibilityIdentifier("recipe.cooking.step.complete")
                            }

                            timerPanel
                            stepControls
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 24)
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(recipe.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("退出", systemImage: "xmark") { isShowingExitOptions = true }
                        .accessibilityIdentifier("recipe.cooking.exit")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(steps.indices, id: \.self) { index in
                            Button("第 \(index + 1) 步") { session.moveToStep(index, stepCount: steps.count) }
                        }
                    } label: { Label("跳转步骤", systemImage: "list.number") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                finishCookingAction
            }
        }
        .onAppear { screenAwake.activate() }
        .onDisappear { screenAwake.deactivate(); timer.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { screenAwake.deactivate() }
            else if phase == .active { screenAwake.activate() }
        }
        .confirmationDialog("结束烹饪？", isPresented: $isShowingExitOptions, titleVisibility: .visible) {
            Button("保留进度") { onExit() }
            Button(todayPlan == nil ? "结束烹饪" : "完成今日计划") { finishCooking() }
            Button("取消", role: .cancel) {}
        } message: { Text("保留进度会返回详情；完成后会先确认本次食材消耗。") }
        .sheet(isPresented: $isShowingIngredientSheet) {
            NavigationStack {
                List {
                    Section("当前份量：\(session.servings) 人份") {
                        ForEach(Array((recipe.ingredients + recipe.seasonings).enumerated()), id: \.offset) { index, ingredient in
                            Label(RecipeServingScaler.scaledText(ingredient, multiplier: Double(session.servings)), systemImage: session.checkedIngredientIndexes.contains(index) ? "checkmark.circle.fill" : "circle")
                        }
                    }
                }
                .navigationTitle("本步食材")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { isShowingIngredientSheet = false } } }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var cookingProgress: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("烹饪进度")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(session.currentStepIndex + 1) / \(steps.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(session.currentStepIndex + 1), total: Double(steps.count))
                .tint(AppTheme.textSecondary)
                .accessibilityLabel("烹饪进度 \(session.currentStepIndex + 1) / \(steps.count)")
        }
    }

    @ViewBuilder private var stepControls: some View {
        ViewThatFits(in: .horizontal) {
            stepControlsHorizontal
            stepControlsVertical
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    private var stepControlsHorizontal: some View {
        HStack(spacing: 12) {
            Button("上一步", systemImage: "chevron.left") { session.previous(stepCount: steps.count) }
                .buttonStyle(.bordered)
                .tint(AppTheme.textSecondary)
                .disabled(session.currentStepIndex == 0)
                .accessibilityIdentifier("recipe.cooking.previous")
            Button("查看食材", systemImage: "basket") { isShowingIngredientSheet = true }
                .buttonStyle(.bordered)
                .tint(AppTheme.textSecondary)
                .accessibilityIdentifier("recipe.cooking.ingredients")
            Button("下一步", systemImage: "chevron.right") { session.next(stepCount: steps.count) }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.brand)
                .disabled(session.currentStepIndex >= steps.count - 1)
                .accessibilityIdentifier("recipe.cooking.next")
        }
        .frame(maxWidth: .infinity)
    }

    private var stepControlsVertical: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("下一步", systemImage: "chevron.right") { session.next(stepCount: steps.count) }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.brand)
                .disabled(session.currentStepIndex >= steps.count - 1)
                .accessibilityIdentifier("recipe.cooking.next")
            HStack(spacing: 12) {
                Button("上一步", systemImage: "chevron.left") { session.previous(stepCount: steps.count) }
                    .buttonStyle(.bordered)
                    .tint(AppTheme.textSecondary)
                    .disabled(session.currentStepIndex == 0)
                    .accessibilityIdentifier("recipe.cooking.previous")
                Button("查看食材", systemImage: "basket") { isShowingIngredientSheet = true }
                    .buttonStyle(.bordered)
                    .tint(AppTheme.textSecondary)
                    .accessibilityIdentifier("recipe.cooking.ingredients")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var timerPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label("步骤计时", systemImage: "timer").font(.headline); Spacer(); Text(timerText).monospacedDigit().accessibilityLabel("剩余时间 \(timerText)") }
            if timer.state.status == .idle || timer.state.status == .finished {
                Menu("开始计时", systemImage: "play.fill") {
                    if let seconds = RecipeStepTimerSuggestion.seconds(in: currentStep) { Button("按步骤时长（\(seconds / 60) 分钟）") { timer.start(seconds: seconds) } }
                    ForEach([1, 3, 5, 10, 15, 20, 30], id: \.self) { minutes in Button("\(minutes) 分钟") { timer.start(seconds: minutes * 60) } }
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.textSecondary)
                .accessibilityIdentifier("recipe.cooking.timer.start")
            } else {
                HStack {
                    Button(timer.state.status == .running ? "暂停" : "继续") { timer.state.status == .running ? timer.pause() : timer.resume() }
                    Button("取消", role: .destructive) { timer.cancel() }.accessibilityIdentifier("recipe.cooking.timer.cancel")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .background(AppTheme.secondarySurface, in: RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous)
                .stroke(AppTheme.separator.opacity(0.28), lineWidth: 0.5)
        }
    }

    private var timerText: String { String(format: "%02d:%02d", timer.state.remainingSeconds / 60, timer.state.remainingSeconds % 60) }
    private var finishCookingAction: some View {
        Button(todayPlan == nil ? "结束烹饪" : "完成今日计划") { finishCooking() }
            .buttonStyle(.bordered)
            .tint(AppTheme.brand)
            .frame(maxWidth: .infinity, minHeight: AppTheme.minimumHitTarget)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(.systemBackground))
            .accessibilityIdentifier("recipe.cooking.finish")
    }
    private func finishCooking() { screenAwake.deactivate(); timer.cancel(); onFinish() }
}

#Preview("Cooking mode") {
    RecipeCookingModeView(recipe: Recipe.samples[0], session: RecipeCookingSession(servings: 2), todayPlan: nil, onFinish: {}, onExit: {})
}

#Preview("Cooking mode dark", traits: .fixedLayout(width: 390, height: 844)) {
    RecipeCookingModeView(recipe: Recipe.samples[1], session: RecipeCookingSession(), todayPlan: nil, onFinish: {}, onExit: {})
        .preferredColorScheme(.dark)
}

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
            VStack(spacing: 22) {
                if steps.isEmpty {
                    ContentUnavailableView("还没有制作步骤", systemImage: "list.number", description: Text("可以返回详情编辑菜谱后再开始烹饪。"))
                } else {
                    ProgressView(value: Double(session.currentStepIndex + 1), total: Double(steps.count))
                        .accessibilityLabel("烹饪进度 \(session.currentStepIndex + 1) / \(steps.count)")
                    Text("第 \(session.currentStepIndex + 1) 步，共 \(steps.count) 步")
                        .font(.headline).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text(currentStep).font(.title2.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                session.toggleStep(at: session.currentStepIndex)
                            } label: {
                                Label(session.completedStepIndexes.contains(session.currentStepIndex) ? "已完成此步骤" : "标记此步骤完成", systemImage: session.completedStepIndexes.contains(session.currentStepIndex) ? "checkmark.circle.fill" : "circle")
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("recipe.cooking.step.complete")

                            timerPanel
                        }
                        .padding(.vertical, 8)
                    }
                    stepControls
                }
            }
            .padding()
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
                Button(todayPlan == nil ? "结束烹饪" : "完成今日计划") { finishCooking() }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.primary)
                    .frame(maxWidth: .infinity).padding(.horizontal).padding(.vertical, 8)
                    .accessibilityIdentifier("recipe.cooking.finish")
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
        } message: { Text("保留进度会返回详情；结束烹饪不会自动扣减库存。") }
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

    @ViewBuilder private var stepControls: some View {
        HStack(spacing: 12) {
            Button("上一步", systemImage: "chevron.left") { session.previous(stepCount: steps.count) }
                .buttonStyle(.bordered).disabled(session.currentStepIndex == 0)
                .accessibilityIdentifier("recipe.cooking.previous")
            Button("查看食材", systemImage: "basket") { isShowingIngredientSheet = true }
                .buttonStyle(.bordered)
            Button("下一步", systemImage: "chevron.right") { session.next(stepCount: steps.count) }
                .buttonStyle(.borderedProminent).disabled(session.currentStepIndex >= steps.count - 1)
                .accessibilityIdentifier("recipe.cooking.next")
        }
        .frame(maxWidth: .infinity)
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
                .accessibilityIdentifier("recipe.cooking.timer.start")
            } else {
                HStack {
                    Button(timer.state.status == .running ? "暂停" : "继续") { timer.state.status == .running ? timer.pause() : timer.resume() }
                    Button("取消", role: .destructive) { timer.cancel() }.accessibilityIdentifier("recipe.cooking.timer.cancel")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding().background(AppTheme.secondarySurface, in: RoundedRectangle(cornerRadius: 16))
    }

    private var timerText: String { String(format: "%02d:%02d", timer.state.remainingSeconds / 60, timer.state.remainingSeconds % 60) }
    private func finishCooking() { screenAwake.deactivate(); timer.cancel(); onFinish() }
}

#Preview("Cooking mode") {
    RecipeCookingModeView(recipe: Recipe.samples[0], session: RecipeCookingSession(servings: 2), todayPlan: nil, onFinish: {}, onExit: {})
}

#Preview("Cooking mode dark", traits: .fixedLayout(width: 390, height: 844)) {
    RecipeCookingModeView(recipe: Recipe.samples[1], session: RecipeCookingSession(), todayPlan: nil, onFinish: {}, onExit: {})
        .preferredColorScheme(.dark)
}

import SwiftUI
import UIKit

/// The waiting state for a whole-recipe request: what is running, said in
/// words, and the one way out of it. Both `AI 做菜` surfaces show the same
/// three parts, so the markup lives once in this file — the sentence and the
/// identifier stay at the call site, because generating a recipe and replacing
/// one are different events. Deliberately not shared with the weekly surface:
/// the presentation layer is not generalized yet.
private struct AIGenerationWaitRow: View {
    let message: String
    let cancelIdentifier: String
    let cancel: () -> Void

    var body: some View {
        HStack {
            ProgressView()
            Text(message)
                .foregroundStyle(.secondary)
            Spacer(minLength: KitchenTheme.pageGutter)
            Button(action: cancel) {
                // The height sits on the label so the tap target really is
                // that tall; a borderless button is only as big as what it
                // draws.
                Text("取消").frame(minHeight: ChromeMetrics.minimumRowHeight)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier(cancelIdentifier)
        }
    }
}

struct AIGeneratorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var kitchenStore: KitchenStore
    @EnvironmentObject private var navigationStore: AppNavigationStore
    #if DEBUG
    @EnvironmentObject private var recipeStore: RecipeStore
    #endif
    @StateObject private var generatorStore = AIRecipeGeneratorStore()
    @State private var isShowingConfirmation = false

    var body: some View {
        Form {
            inventorySection

            Section("手动补充食材") {
                TextField(
                    "鸡蛋、番茄、鸡胸肉",
                    text: $generatorStore.customIngredientsText,
                    axis: .vertical
                )
                .lineLimit(2...5)
                Text("支持逗号、顿号、空格或换行分隔。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("用餐人数") {
                Stepper(
                    "\(generatorStore.servings) 人",
                    value: $generatorStore.servings,
                    in: 1...12
                )
            }

            Section("口味偏好") {
                ForEach(AIRecipeGeneratorStore.flavorOptions, id: \.self) { flavor in
                    Toggle(
                        flavor,
                        isOn: Binding(
                            get: { generatorStore.selectedFlavors.contains(flavor) },
                            set: { isSelected in
                                if isSelected {
                                    generatorStore.selectedFlavors.insert(flavor)
                                } else {
                                    generatorStore.selectedFlavors.remove(flavor)
                                }
                            }
                        )
                    )
                }
            }

            Section("烹饪偏好") {
                Picker("最长时间", selection: $generatorStore.maxCookingTime) {
                    Text("不限").tag(Int?.none)
                    Text("15 分钟内").tag(Int?.some(15))
                    Text("30 分钟内").tag(Int?.some(30))
                    Text("45 分钟内").tag(Int?.some(45))
                    Text("60 分钟内").tag(Int?.some(60))
                }

                Picker("菜系", selection: $generatorStore.cuisine) {
                    ForEach(AIRecipeGeneratorStore.cuisineOptions, id: \.self) { cuisine in
                        Text(cuisine).tag(cuisine)
                    }
                }
            }

            Section("忌口或不使用") {
                TextField(
                    "例如：花生、香菜、乳制品",
                    text: $generatorStore.excludedIngredientsText,
                    axis: .vertical
                )
                .lineLimit(2...5)
            }

            Section("额外要求") {
                TextField(
                    "例如：适合带饭、不要油炸",
                    text: $generatorStore.additionalRequest,
                    axis: .vertical
                )
                .lineLimit(3...6)
            }

            Section {
                if generatorStore.isGenerating {
                    // The waiting state takes the generate action's own place
                    // rather than covering the form: same row, same section.
                    AIGenerationWaitRow(
                        message: "正在生成菜谱…",
                        cancelIdentifier: "ai.generate.cancel"
                    ) {
                        generatorStore.cancelGeneration()
                    }
                } else {
                    Button {
                        Task {
                            if await generatorStore.generate(
                                inventory: kitchenStore.recipeCreationInventory
                            ) {
                                isShowingConfirmation = true
                            }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            Label("生成菜谱", systemImage: "sparkles")
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.managementActionFill)
                    .foregroundStyle(AppTheme.onManagementAction)
                }
            }
        }
        .navigationTitle("AI 做菜")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            generatorStore.prepareInventory(kitchenStore.recipeCreationInventory)
            #if DEBUG
            // Deterministic UI-test seeds for the confirmation screen, which
            // normally requires a real AI generation. A valid draft exercises
            // the save success path; a draft without ingredients verifies
            // invalid save and plan actions stay disabled.
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("UITEST_SEED_AI_CONFIRMATION") {
                // The success fixture's title/ingredients are fixed, so a
                // prior run's saved recipe (persisted across app launches)
                // would otherwise make the fingerprint-based duplicate guard
                // in `saveUserRecipe` reject a second save.
                recipeStore.clearLocalData()
                generatorStore.generatedDraft = EditableRecipeDraft(
                    title: "番茄炒蛋（UI 测试）",
                    ingredientsText: "鸡蛋\n番茄",
                    stepsText: "鸡蛋打散备用\n番茄切块后与鸡蛋同炒"
                )
                isShowingConfirmation = true
            }
            if arguments.contains("UITEST_SEED_AI_CONFIRMATION_FAILURE") {
                generatorStore.generatedDraft = EditableRecipeDraft(
                    title: "缺食材测试菜谱"
                )
                isShowingConfirmation = true
            }
            #endif
        }
        .onDisappear {
            generatorStore.cancelGeneration()
        }
        .navigationDestination(isPresented: $isShowingConfirmation) {
            AIRecipeConfirmationView(generatorStore: generatorStore) { destination in
                dismiss()
                switch destination {
                case .recipeLibrary: navigationStore.showRecipeLibrary()
                case .today: navigationStore.selectedTab = .today
                }
            }
        }
        .alert(
            "暂时无法生成菜谱",
            isPresented: errorBinding
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(generatorStore.errorMessage ?? "请稍后重试，或者调整食材和要求。")
        }
    }

    @ViewBuilder
    private var inventorySection: some View {
        Section {
            if kitchenStore.recipeCreationInventory.isEmpty {
                ContentUnavailableView(
                    "冰箱里还没有食材",
                    systemImage: "shippingbox",
                    description: Text("仍然可以手动输入想使用的食材。")
                )
            } else {
                ForEach(kitchenStore.recipeCreationInventory) { item in
                    Button {
                        if generatorStore.selectedInventoryIDs.contains(item.id) {
                            generatorStore.selectedInventoryIDs.remove(item.id)
                        } else {
                            generatorStore.selectedInventoryIDs.insert(item.id)
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name)
                                    .foregroundStyle(.primary)
                                Text("\(item.quantity.formatted()) \(item.unit)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let days = item.remainingDays {
                                Text(expiryText(days))
                                    .font(.caption.weight(days <= 3 ? .semibold : .regular))
                                    .foregroundStyle(days <= 3 ? AppTheme.warning : .secondary)
                            }
                            Image(
                                systemName: generatorStore.selectedInventoryIDs.contains(item.id)
                                    ? "checkmark.circle.fill"
                                    : "circle"
                            )
                            .foregroundStyle(
                                generatorStore.selectedInventoryIDs.contains(item.id)
                                    ? AppTheme.primary
                                    : Color.secondary
                            )
                        }
                    }
                }
            }
        } header: {
            Text("从冰箱选择")
        } footer: {
            if !kitchenStore.recipeCreationInventory.isEmpty {
                HStack {
                    Button("全选临期食材") {
                        generatorStore.selectAllExpiring(kitchenStore.recipeCreationInventory)
                    }
                    .disabled(kitchenStore.recipeCreationExpiringItems.isEmpty)
                    Spacer()
                    Button("清除选择") {
                        generatorStore.selectedInventoryIDs.removeAll()
                    }
                    .disabled(generatorStore.selectedInventoryIDs.isEmpty)
                }
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { generatorStore.errorMessage != nil },
            set: { if !$0 { generatorStore.errorMessage = nil } }
        )
    }

    private func expiryText(_ remainingDays: Int) -> String {
        if remainingDays < 0 { return "已过期" }
        if remainingDays == 0 { return "今天到期" }
        return "剩 \(remainingDays) 天"
    }
}

/// Where the confirmation wants the app to land once it closes. Deliberately
/// not an `AppTab`: the library it can ask for is a push on the Plan tab, not
/// a top-level destination.
enum AIRecipeFinishDestination {
    case recipeLibrary
    case today
}

private struct AIRecipeConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var recipeStore: RecipeStore
    @EnvironmentObject private var kitchenStore: KitchenStore
    @ObservedObject var generatorStore: AIRecipeGeneratorStore
    let onFinish: (AIRecipeFinishDestination) -> Void

    private enum ConfirmationAction {
        case saveAndPlan, saveOnly, addToPlan
    }

    @State private var performingAction: ConfirmationAction?

    var body: some View {
        Form {
            if generatorStore.generatedDraft != nil {
                if generatorStore.isGenerating {
                    // The draft below is still the member's and stays editable
                    // while its replacement is being prepared, so the waiting
                    // state sits above it as one more row. This is the only
                    // wait presentation on this screen.
                    Section {
                        AIGenerationWaitRow(
                            message: "正在重新生成…",
                            cancelIdentifier: "ai.regenerate.cancel"
                        ) {
                            generatorStore.cancelGeneration()
                        }
                    }
                }
                RecipeDraftEditorSections(
                    draft: draftBinding,
                    showsExtendedFields: true
                )

                if generatorStore.hasSavedCurrentDraft
                    || generatorStore.hasAddedCurrentDraftToPlan {
                    Section {
                        if generatorStore.hasSavedCurrentDraft {
                            Label("已保存到菜谱库", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(AppTheme.successInk)
                        }
                        if generatorStore.hasAddedCurrentDraftToPlan {
                            Label("已加入今日计划", systemImage: "calendar.badge.checkmark")
                                .foregroundStyle(AppTheme.successInk)
                        }
                    }
                }

                Section {
                    Button {
                        Task { await saveAndAddToPlan() }
                    } label: {
                        actionLabel("保存并加入计划", systemImage: "checkmark.circle", isActive: performingAction == .saveAndPlan)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.managementActionFill)
                    .foregroundStyle(AppTheme.onManagementAction)
                    .disabled(performingAction != nil || generatorStore.isGenerating || !isDraftSaveEligible)

                    Button {
                        Task { await saveOnly() }
                    } label: {
                        actionLabel("仅保存", systemImage: "square.and.arrow.down", isActive: performingAction == .saveOnly)
                    }
                    .buttonStyle(.bordered)
                    .disabled(performingAction != nil || generatorStore.isGenerating || !isDraftSaveEligible)
                }

                Section {
                    Menu {
                        Button("仅加入今日计划", systemImage: "calendar.badge.plus") {
                            Task { await addToPlanOnly() }
                        }
                        .disabled(generatorStore.hasAddedCurrentDraftToPlan || !isDraftSaveEligible)

                        Button("重新生成", systemImage: "arrow.clockwise") {
                            Task {
                                await generatorStore.generate(
                                    inventory: kitchenStore.recipeCreationInventory,
                                    regenerate: true
                                )
                            }
                        }

                        Divider()

                        Button("放弃结果", systemImage: "xmark", role: .destructive) {
                            dismiss()
                        }
                    } label: {
                        Label("更多操作", systemImage: "ellipsis.circle")
                    }
                    .disabled(performingAction != nil || generatorStore.isGenerating)
                }
            } else {
                ContentUnavailableView(
                    "没有生成结果",
                    systemImage: "sparkles",
                    description: Text("返回后可以调整食材和要求重新生成。")
                )
            }
        }
        .navigationTitle("确认菜谱")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            generatorStore.cancelGeneration()
        }
        .alert(
            "无法完成操作",
            isPresented: errorBinding
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(generatorStore.errorMessage ?? "请稍后重试。")
        }
    }

    private var draftBinding: Binding<EditableRecipeDraft> {
        Binding(
            get: { generatorStore.generatedDraft ?? EditableRecipeDraft() },
            set: { generatorStore.generatedDraft = $0 }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { generatorStore.errorMessage != nil },
            set: { if !$0 { generatorStore.errorMessage = nil } }
        )
    }

    private var isDraftSaveEligible: Bool {
        generatorStore.generatedDraft?.isSaveEligible == true
    }

    private func actionLabel(_ title: String, systemImage: String, isActive: Bool) -> some View {
        HStack {
            Spacer()
            if isActive {
                ProgressView()
            } else {
                Label(title, systemImage: systemImage)
            }
            Spacer()
        }
    }

    @MainActor
    private func saveOnly() async {
        guard performingAction == nil else { return }
        performingAction = .saveOnly
        await Task.yield()
        do {
            _ = try generatorStore.save(into: recipeStore)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            finish(at: .recipeLibrary)
        } catch {
            generatorStore.errorMessage = error.localizedDescription
            performingAction = nil
        }
    }

    @MainActor
    private func addToPlanOnly() async {
        guard performingAction == nil else { return }
        performingAction = .addToPlan
        await Task.yield()
        do {
            _ = try generatorStore.addToPlan(kitchenStore)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            finish(at: .today)
        } catch {
            generatorStore.errorMessage = error.localizedDescription
            performingAction = nil
        }
    }

    @MainActor
    private func saveAndAddToPlan() async {
        guard performingAction == nil else { return }
        performingAction = .saveAndPlan
        await Task.yield()
        do {
            let recipe = try generatorStore.save(into: recipeStore)
            _ = try generatorStore.addToPlan(kitchenStore, recipe: recipe)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            finish(at: .today)
        } catch {
            generatorStore.errorMessage = error.localizedDescription
            performingAction = nil
        }
    }

    @MainActor
    private func finish(at destination: AIRecipeFinishDestination) {
        dismiss()
        Task {
            await Task.yield()
            onFinish(destination)
        }
    }
}

struct ImportRecipeView: View {
    /// The only thing the client truthfully knows while the request is out: it
    /// is waiting for one. `/api/recipe-import-from-url` answers in a single
    /// response and reports no intermediate steps, and there is no latency
    /// evidence to promise a duration from.
    static let importingStatus = "正在读取链接并整理菜谱…"
    /// Stops the import and stays here, with the pasted link untouched.
    static let cancelImportLabel = "取消"

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: RecipeStore
    @EnvironmentObject private var navigationStore: AppNavigationStore

    @State private var urlText = ""
    @State private var isImporting = false
    @State private var isSaving = false
    @State private var isSaved = false
    @State private var result: LinkExtractResult?
    @State private var extractErrorMessage: String?
    @State private var saveErrorMessage: String?
    @State private var editableDraft: EditableRecipeDraft?
    @State private var draftWarnings: [String] = []
    @State private var hasAutoStarted = false
    /// The real network-driving import Task. Held here so `.onDisappear` and
    /// the in-place cancel can actually stop the in-flight
    /// `/api/recipe-import-from-url` request.
    @State private var importTask: Task<Void, Never>?

    /// The one network call this screen makes. A DEBUG launch argument can
    /// substitute a stub so a UI test can observe the waiting state without a
    /// provider; production always wires the real service.
    private let extract: (String) async throws -> LinkExtractResult
    var onSaved: (() -> Void)? = nil

    /// Set only by the Share Extension pending-request handoff
    /// (`HomeView.sharedImportSheetContent`) — every other call site keeps
    /// the default `false` and still requires the user to tap "开始导入"
    /// themselves. Deliberately a separate parameter rather than inferred
    /// from `initialURLText` being non-empty, since a future manual prefill
    /// entry point could pass initial text without wanting an automatic
    /// network call.
    private let autoStart: Bool

    /// `initialURLText` lets callers (e.g. the Share Extension handoff via
    /// `SharedImportCoordinator`) prefill the same field a user would
    /// otherwise paste into by hand — no separate import path.
    init(initialURLText: String = "", autoStart: Bool = false, onSaved: (() -> Void)? = nil) {
        _urlText = State(initialValue: initialURLText)
        self.autoStart = autoStart
        self.onSaved = onSaved
        #if DEBUG
        if LinkImportStubFixture.isEnabled {
            self.extract = LinkImportStubFixture.extract
            return
        }
        #endif
        let service = LinkExtractService()
        self.extract = { try await service.extract(from: $0) }
    }

    /// Pure decision logic for whether `.task` should kick off `importLink()`
    /// automatically, pulled out of the view body so it's directly unit
    /// testable without constructing SwiftUI state.
    static func shouldAutoStartImport(
        autoStart: Bool,
        hasAutoStarted: Bool,
        isImporting: Bool,
        hasDraft: Bool
    ) -> Bool {
        autoStart && !hasAutoStarted && !isImporting && !hasDraft
    }

    /// Same "single active request" guard `startImport()` uses, pulled out
    /// so it's directly unit testable: a manual tap, a Retry tap, and the
    /// auto-start `.task` all funnel through `startImport()`, which only
    /// creates a new `importTask` when this returns `true`.
    static func shouldStartImport(hasActiveTask: Bool) -> Bool {
        !hasActiveTask
    }

    /// Single entry point for every trigger (manual tap, Retry, auto-start)
    /// — owns the real import Task's lifecycle without duplicating any of
    /// `importLink()`'s business logic. Cancelling `importTask` (in
    /// `.onDisappear`) propagates through the plain `await` chain into
    /// `LinkExtractService`/`APIClient`/`URLSession`, since `importLink()`
    /// runs directly on this Task rather than spawning a child one.
    private func startImport() {
        guard Self.shouldStartImport(hasActiveTask: importTask != nil) else { return }
        importTask = Task {
            await importLink()
            importTask = nil
        }
    }

    var body: some View {
        Form {
            Section("菜谱链接") {
                TextField("粘贴链接或完整分享文案", text: $urlText, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                ClipboardPasteControl(
                    accessibilityLabel: "粘贴导入",
                    style: .customLabeled("粘贴导入"),
                    onPaste: { pastedText in urlText = pastedText }
                )
                .frame(minHeight: 44)
            }

            Section {
                Button {
                    startImport()
                } label: {
                    HStack {
                        Spacer()
                        if isImporting {
                            ProgressView().tint(AppTheme.onManagementAction)
                            Text(Self.importingStatus)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                            Text("开始导入")
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.managementActionFill)
                .foregroundStyle(AppTheme.onManagementAction)
                .disabled(
                    urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || isImporting
                    || isSaving
                )

                if isImporting {
                    // Stop and stay: the link stays in the field, nothing is
                    // written, and leaving the screen remains the other way out.
                    Button(Self.cancelImportLabel) { importTask?.cancel() }
                        .frame(minHeight: AppTheme.minimumHitTarget)
                        .accessibilityIdentifier("import.link.cancel")
                }
            }

            if let result {
                Section("来源") {
                    Text(result.title).font(.headline)
                    if let author = result.sourceAuthor {
                        LabeledContent("作者", value: author)
                    }
                    Text(result.canonicalURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack {
                        if result.usedTranscript { Label("已使用口播", systemImage: "waveform") }
                        if result.usedOCR { Label("已使用字幕", systemImage: "text.viewfinder") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if let extractErrorMessage {
                Section("导入失败") {
                    Label(extractErrorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Button("重试", systemImage: "arrow.clockwise") {
                        startImport()
                    }
                    .disabled(isImporting)
                }
            }

            if editableDraft != nil {
                RecipeDraftEditorSections(draft: editableDraftBinding)

                if !draftWarnings.isEmpty {
                    Section("需要确认") {
                        ForEach(draftWarnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.circle")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section {
                    Button {
                        Task { await saveRecipe() }
                    } label: {
                        HStack {
                            Spacer()
                            if isSaving {
                                ProgressView()
                                    .tint(AppTheme.onManagementAction)
                            } else {
                                Label(
                                    isSaved ? "已保存" : "保存到菜谱库",
                                    systemImage: isSaved ? "checkmark.circle.fill" : "square.and.arrow.down"
                                )
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.managementActionFill)
                    .foregroundStyle(AppTheme.onManagementAction)
                    .accessibilityIdentifier("import.result.save")
                    .disabled(!canSave || isSaving || isSaved)
                }
            }
        }
        .navigationTitle("导入菜谱")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("UITEST_SEED_IMPORT_RESULT") {
                editableDraft = EditableRecipeDraft(
                    id: "ui-test-import-result",
                    title: "零网络导入测试菜谱",
                    ingredientsText: "番茄 2 个\n鸡蛋 2 个",
                    stepsText: "1. 番茄切块\n2. 鸡蛋炒熟后与番茄同炒"
                )
                isSaved = false
                return
            }
            #endif
            // Runs once per presentation (SwiftUI keys `.task` to view
            // identity, not to body re-evaluation) — `hasAutoStarted` is
            // still checked explicitly so a re-entrant call can never fire
            // a second request for the same sheet instance. A fresh sheet
            // presentation (e.g. the next pending shared import) gets a
            // fresh `ImportRecipeView` with fresh `@State`, so auto-start
            // can happen again there — that's the intended per-request
            // behavior, not a bug.
            guard Self.shouldAutoStartImport(
                autoStart: autoStart,
                hasAutoStarted: hasAutoStarted,
                isImporting: isImporting,
                hasDraft: editableDraft != nil
            ) else { return }
            hasAutoStarted = true
            startImport()
        }
        .onDisappear {
            // Cancels the real network-driving Task, not just the cosmetic
            // progress animation — cancellation propagates through the
            // plain `await` chain into `LinkExtractService`/`APIClient`,
            // which cancels the underlying `URLSessionTask`.
            importTask?.cancel()
        }
        .alert(
            "无法保存菜谱",
            isPresented: Binding(
                get: { saveErrorMessage != nil },
                set: { if !$0 { saveErrorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? "请稍后重试。")
        }
    }

    private var editableDraftBinding: Binding<EditableRecipeDraft> {
        Binding(
            get: { editableDraft ?? EditableRecipeDraft() },
            set: { editableDraft = $0 }
        )
    }

    private var canSave: Bool {
        guard let editableDraft else { return false }
        return editableDraft.isSaveEligible
    }

    @MainActor
    private func importLink() async {
        isImporting = true
        result = nil
        extractErrorMessage = nil
        resetDraft()

        defer { isImporting = false }

        do {
            let inputURL = try LinkExtractService.firstHTTPURL(in: urlText).absoluteString
            guard !store.containsImportedSource(inputURL) else {
                throw UserRecipeSaveError.sourceAlreadyImported
            }
            let imported = try await extract(urlText)
            // The network call above is the only real suspension point,
            // and cancellation is expected to already surface as a thrown
            // `LinkExtractError.cancelled`/`CancellationError` from it in
            // the overwhelming majority of cases. This extra check only
            // guards the narrow race where the response finished arriving
            // in the same instant the Task was cancelled — without it, a
            // dismiss-right-as-the-network-returns could still write a
            // draft into a view that's going away. No request-generation
            // token is needed beyond this: `startImport()` guarantees at
            // most one `importTask` exists at a time for this view.
            try Task.checkCancellation()
            guard !store.containsImportedSource(imported.canonicalURL) else {
                throw UserRecipeSaveError.sourceAlreadyImported
            }
            guard let parsedRecipe = imported.recipe else {
                throw AIRecipeParseError.missingRecipe
            }
            result = imported
            var draft = EditableRecipeDraft(
                title: parsedRecipe.name,
                tagsText: (parsedRecipe.tags ?? []).joined(separator: "，"),
                ingredientsText: (parsedRecipe.ingredients ?? []).map(\.displayText).joined(separator: "\n"),
                seasoningsText: (parsedRecipe.seasonings ?? []).map(\.displayText).joined(separator: "\n"),
                stepsText: (parsedRecipe.method ?? []).map(EditableRecipeDraft.cleanStep).joined(separator: "\n")
            )
            draft.id = stableImportID(imported.canonicalURL)
            draft.source = RecipeSourceMetadata(
                platform: "xiaohongshu",
                originalURL: imported.originalURL,
                canonicalURL: imported.canonicalURL,
                importedAt: Date(),
                title: imported.sourceTitle,
                author: imported.sourceAuthor
            )
            editableDraft = draft
            draftWarnings = imported.warnings
            isSaved = false
        } catch is CancellationError {
            // Cancellation is a lifecycle event, not an import failure: no
            // error text, no alert, no draft, no retry prompt — the sheet
            // is on its way to disappearing (or already has), so quietly
            // stop instead of writing any further state.
            return
        } catch LinkExtractError.cancelled {
            return
        } catch {
            extractErrorMessage = Self.importErrorMessage(for: error)
        }
    }

    /// What a failed link import is allowed to say. Only errors written for a
    /// member speak for themselves; anything else becomes this flow's own
    /// sentence, so no status code, backend payload or URLSession text reaches
    /// the screen.
    ///
    /// `LinkExtractError.server` passes because it already translates the
    /// backend's code into product copy — including the import flow's own
    /// rate-limit guidance — and never mentions the HTTP status. The remaining
    /// cases describe the backend rather than the member's link.
    /// `AIRecipeParseError.server` carries the backend's own words verbatim, so
    /// it can never pass, whether or not anything reaches it today.
    static func importErrorMessage(for error: Error) -> String {
        let fallback = "暂时无法解析这个链接，请稍后重试。"
        switch error {
        case let link as LinkExtractError:
            switch link {
            case .emptyInput, .server:
                return link.localizedDescription
            case .invalidEndpoint, .invalidURL, .invalidResponse, .invalidJSON:
                return fallback
            case .cancelled:
                // Handled before this and never shown.
                return fallback
            }
        case let parse as AIRecipeParseError:
            switch parse {
            case .emptyText, .missingRecipe:
                return parse.localizedDescription
            case .invalidResponse, .server:
                return fallback
            }
        case let save as UserRecipeSaveError:
            return save.localizedDescription
        default:
            return fallback
        }
    }

    private func stableImportID(_ url: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in url.lowercased().utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return "user-xhs-\(String(hash, radix: 16))"
    }

    @MainActor
    private func saveRecipe() async {
        guard let editableDraft, canSave, !isSaving, !isSaved else { return }
        isSaving = true
        saveErrorMessage = nil
        await Task.yield()

        do {
            let recipe = try editableDraft.makeRecipe()
            try store.saveUserRecipe(recipe)
            isSaved = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            isSaving = false
            if let onSaved {
                onSaved()
            } else {
                navigationStore.showRecipeLibrary()
                dismiss()
            }
        } catch {
            isSaving = false
            saveErrorMessage = error.localizedDescription
        }
    }

    private func resetDraft() {
        editableDraft = nil
        draftWarnings = []
        isSaved = false
    }
}

struct ManualRecipeView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: RecipeStore
    @State private var draft = EditableRecipeDraft(tagsText: "手动添加")
    @State private var errorMessage: String?

    var body: some View {
        Form { RecipeDraftEditorSections(draft: $draft, showsExtendedFields: true) }
        .navigationTitle("手动添加")
        .toolbar {
            Button("保存") { save() }
                .disabled(!draft.isSaveEligible)
        }
        .alert("无法保存菜谱", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(errorMessage ?? "请检查内容。") }
    }

    private func save() {
        do {
            try store.saveUserRecipe(draft.makeRecipe())
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#if DEBUG
/// A stand-in for the link importer's network call: waits long enough for a UI
/// test to read the waiting state and cancel it, honours cancellation exactly
/// like the real request, then answers with one fixed recipe. Selected by the
/// `UITEST_LINK_IMPORT_STUB` launch argument only.
enum LinkImportStubFixture {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("UITEST_LINK_IMPORT_STUB") }

    static func extract(from input: String) async throws -> LinkExtractResult {
        try await Task.sleep(for: .seconds(6))
        let recipe = try JSONDecoder().decode(
            AIParsedRecipe.self,
            from: Data(#"{"name":"测试导入菜谱","tags":["家常菜"],"ingredients":[{"name":"番茄","quantity":"2","unit":"个"}],"steps":["番茄切块","炒熟"]}"#.utf8)
        )
        return LinkExtractResult(
            title: "测试导入菜谱",
            text: "",
            rawJSON: "",
            recipe: recipe,
            originalURL: input,
            canonicalURL: "https://example.com/uitest-link-import",
            sourceTitle: "测试来源",
            sourceAuthor: nil,
            warnings: [],
            usedTranscript: false,
            usedOCR: false
        )
    }
}
#endif

#if DEBUG
/// Presents the production confirmation screen with a seeded draft and a
/// regeneration already in flight — the state the 更多操作 menu would produce.
/// XCUITest cannot reach it through that menu, because a Menu living in a Form
/// row does not open under automation, and driving it through the generator's
/// own push races the generator's \`onDisappear\`, which cancels generation
/// mid-transition. Hosting the real view directly, the way the planner
/// regression host already does, avoids both. Same view, same store, same
/// stub; no product-facing route to regeneration is added.
struct AIRecipeRegenerationHost: View {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("UITEST_SEED_AI_REGENERATING")
    }

    @EnvironmentObject private var kitchenStore: KitchenStore
    @StateObject private var generatorStore = AIRecipeGeneratorStore()

    var body: some View {
        NavigationStack {
            AIRecipeConfirmationView(generatorStore: generatorStore) { _ in }
        }
        .task {
            // The request needs something to ask for; this entry skips the
            // generator form that would normally have supplied it.
            generatorStore.customIngredientsText = "鸡蛋"
            generatorStore.generatedDraft = EditableRecipeDraft(
                title: "番茄炒蛋（UI 测试）",
                baseServings: 2,
                ingredientsText: "鸡蛋\n番茄",
                stepsText: "鸡蛋打散备用\n番茄切块后与鸡蛋同炒"
            )
            _ = await generatorStore.generate(
                inventory: kitchenStore.recipeCreationInventory,
                regenerate: true
            )
        }
    }
}
#endif

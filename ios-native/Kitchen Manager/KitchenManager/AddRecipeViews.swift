import SwiftUI
import UIKit

struct AIGeneratorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var kitchenStore: KitchenStore
    @EnvironmentObject private var navigationStore: AppNavigationStore
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
                Button {
                    Task {
                        if await generatorStore.generate(
                            inventory: kitchenStore.availableInventory
                        ) {
                            isShowingConfirmation = true
                        }
                    }
                } label: {
                    HStack {
                        Spacer()
                        if generatorStore.isGenerating {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Label("生成菜谱", systemImage: "sparkles")
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.primary)
                .disabled(generatorStore.isGenerating)
            }
        }
        .navigationTitle("AI 做菜")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            generatorStore.prepareInventory(kitchenStore.availableInventory)
        }
        .onDisappear {
            generatorStore.cancelGeneration()
        }
        .navigationDestination(isPresented: $isShowingConfirmation) {
            AIRecipeConfirmationView(generatorStore: generatorStore) { destination in
                dismiss()
                navigationStore.selectedTab = destination
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
            if kitchenStore.availableInventory.isEmpty {
                ContentUnavailableView(
                    "冰箱里还没有食材",
                    systemImage: "shippingbox",
                    description: Text("仍然可以手动输入想使用的食材。")
                )
            } else {
                ForEach(kitchenStore.availableInventory) { item in
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
            if !kitchenStore.availableInventory.isEmpty {
                HStack {
                    Button("全选临期食材") {
                        generatorStore.selectAllExpiring(kitchenStore.availableInventory)
                    }
                    .disabled(kitchenStore.expiringItems.isEmpty)
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

private struct AIRecipeConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var recipeStore: RecipeStore
    @EnvironmentObject private var kitchenStore: KitchenStore
    @ObservedObject var generatorStore: AIRecipeGeneratorStore
    let onFinish: (AppTab) -> Void

    @State private var isPerformingAction = false

    var body: some View {
        Form {
            if generatorStore.generatedDraft != nil {
                RecipeDraftEditorSections(
                    draft: draftBinding,
                    showsExtendedFields: true
                )

                if generatorStore.hasSavedCurrentDraft
                    || generatorStore.hasAddedCurrentDraftToPlan {
                    Section {
                        if generatorStore.hasSavedCurrentDraft {
                            Label("已保存到菜谱库", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(AppTheme.success)
                        }
                        if generatorStore.hasAddedCurrentDraftToPlan {
                            Label("已加入今日计划", systemImage: "calendar.badge.checkmark")
                                .foregroundStyle(AppTheme.success)
                        }
                    }
                }

                Section {
                    Button {
                        Task { await saveAndAddToPlan() }
                    } label: {
                        actionLabel("保存并加入计划", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.primary)
                    .disabled(isPerformingAction || generatorStore.isGenerating)

                    Button {
                        Task { await saveOnly() }
                    } label: {
                        actionLabel("仅保存", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isPerformingAction || generatorStore.isGenerating)
                }

                Section {
                    Menu {
                        Button("仅加入今日计划", systemImage: "calendar.badge.plus") {
                            Task { await addToPlanOnly() }
                        }
                        .disabled(generatorStore.hasAddedCurrentDraftToPlan)

                        Button("重新生成", systemImage: "arrow.clockwise") {
                            Task {
                                await generatorStore.generate(
                                    inventory: kitchenStore.availableInventory,
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
                    .disabled(isPerformingAction || generatorStore.isGenerating)
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
        .toolbar {
            if generatorStore.isGenerating {
                ToolbarItem(placement: .topBarTrailing) {
                    ProgressView()
                }
            }
        }
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

    private func actionLabel(_ title: String, systemImage: String) -> some View {
        HStack {
            Spacer()
            if isPerformingAction {
                ProgressView()
            } else {
                Label(title, systemImage: systemImage)
            }
            Spacer()
        }
    }

    @MainActor
    private func saveOnly() async {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        await Task.yield()
        do {
            _ = try generatorStore.save(into: recipeStore)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            finish(at: .recipes)
        } catch {
            generatorStore.errorMessage = error.localizedDescription
            isPerformingAction = false
        }
    }

    @MainActor
    private func addToPlanOnly() async {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        await Task.yield()
        do {
            _ = try generatorStore.addToPlan(kitchenStore)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            finish(at: .today)
        } catch {
            generatorStore.errorMessage = error.localizedDescription
            isPerformingAction = false
        }
    }

    @MainActor
    private func saveAndAddToPlan() async {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        await Task.yield()
        do {
            let recipe = try generatorStore.save(into: recipeStore)
            _ = try generatorStore.addToPlan(kitchenStore, recipe: recipe)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            finish(at: .today)
        } catch {
            generatorStore.errorMessage = error.localizedDescription
            isPerformingAction = false
        }
    }

    @MainActor
    private func finish(at destination: AppTab) {
        dismiss()
        Task {
            await Task.yield()
            onFinish(destination)
        }
    }
}

struct ImportRecipeView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: RecipeStore
    @EnvironmentObject private var navigationStore: AppNavigationStore

    @State private var urlText = ""
    @State private var isImporting = false
    @State private var isSaving = false
    @State private var isSaved = false
    @State private var importStage: RecipeImportStage?
    @State private var progressTask: Task<Void, Never>?
    @State private var result: LinkExtractResult?
    @State private var extractErrorMessage: String?
    @State private var saveErrorMessage: String?
    @State private var editableDraft: EditableRecipeDraft?
    @State private var draftWarnings: [String] = []

    private let extractService = LinkExtractService()
    var onSaved: (() -> Void)? = nil

    var body: some View {
        Form {
            Section("菜谱链接") {
                TextField("粘贴链接或完整分享文案", text: $urlText, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("粘贴剪贴板") { urlText = UIPasteboard.general.string ?? urlText }
            }

            Section {
                Button {
                    Task { await importLink() }
                } label: {
                    HStack {
                        Spacer()
                        if let importStage {
                            ProgressView()
                            Text(importStage.rawValue)
                        } else {
                            Label("开始导入", systemImage: "square.and.arrow.down")
                        }
                        Spacer()
                    }
                }
                .disabled(
                    urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || isImporting
                    || isSaving
                )
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
                        Task { await importLink() }
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
                                    .tint(.white)
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
                    .tint(AppTheme.primary)
                    .disabled(!canSave || isSaving || isSaved)
                }
            }
        }
        .navigationTitle("导入菜谱")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            progressTask?.cancel()
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
        return !editableDraft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    private func importLink() async {
        isImporting = true
        result = nil
        extractErrorMessage = nil
        resetDraft()

        startProgress()
        defer {
            progressTask?.cancel()
            progressTask = nil
            importStage = nil
            isImporting = false
        }

        do {
            let inputURL = try LinkExtractService.firstHTTPURL(in: urlText).absoluteString
            guard !store.containsImportedSource(inputURL) else {
                throw UserRecipeSaveError.sourceAlreadyImported
            }
            let imported = try await extractService.extract(from: urlText)
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
            return
        } catch {
            extractErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func startProgress() {
        progressTask?.cancel()
        importStage = .parsingLink
        progressTask = Task {
            let stages = Array(RecipeImportStage.allCases.dropFirst())
            for stage in stages {
                try? await Task.sleep(for: .seconds(1.1))
                guard !Task.isCancelled else { return }
                importStage = stage
            }
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
                navigationStore.selectedTab = .recipes
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

private enum RecipeImportStage: String, CaseIterable {
    case parsingLink = "正在解析链接"
    case readingPage = "正在读取页面"
    case extractingVideo = "正在提取视频"
    case recognizingSpeech = "正在识别语音"
    case recognizingSubtitles = "正在识别字幕"
    case organizingRecipe = "正在整理菜谱"
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
                .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

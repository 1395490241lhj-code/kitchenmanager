import AVFoundation
import Combine
import PhotosUI
import SwiftUI
import UIKit

// MARK: - Network DTO / service

/// Reuses `AIGeneratedRecipeDTO` (and its `AIGeneratedIngredientDTO`) from the AI-generated
/// recipe feature instead of declaring a near-identical recipe/ingredient shape.
struct RecipeImageExtractionResponse: Decodable {
    let rawText: String?
    let recipe: AIGeneratedRecipeDTO
    let warnings: [String]?
    let confidence: Double?
}

struct RecipeImageExtractionResult {
    let draft: EditableRecipeDraft
    let warnings: [String]
    let rawText: String?
}

enum RecipeImageImportError: LocalizedError {
    case invalidImage
    case invalidResponse
    case noRecipeFound

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "无法读取这张图片，请重新选择。"
        case .invalidResponse:
            return "AI 返回的数据无法识别，请重新识别或换一张图片。"
        case .noRecipeFound:
            return "没有识别到完整菜谱。请尝试选择更清晰、包含食材和步骤的图片。"
        }
    }
}

/// Reuses the generic `/api/ai-chat` vision proxy already used by receipt scanning —
/// there is no separate OCR endpoint, and the backend doesn't restrict `taskType` values.
struct RecipeImageExtractionService {
    private let chatService = AIChatService()

    func extract(jpegDatas: [Data]) async throws -> RecipeImageExtractionResult {
        // Only a single image is sent per request today (the backend accepts one
        // `imageBase64` field), but the signature stays array-based so a future
        // multi-image flow (ingredients photo + steps photo) doesn't need a new service.
        guard let jpegData = jpegDatas.first else {
            throw RecipeImageImportError.invalidImage
        }

        let imageBase64 = "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
        let content = try await chatService.request(
            prompt: Self.prompt,
            taskType: "recipe-image",
            imageBase64: imageBase64,
            timeout: 60
        )

        guard let data = content.data(using: .utf8),
              let response = try? JSONDecoder().decode(RecipeImageExtractionResponse.self, from: data) else {
            throw RecipeImageImportError.invalidResponse
        }

        let name = response.recipe.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let ingredients = response.recipe.ingredients.map(\.displayText).filter { !$0.isEmpty }
        let steps = response.recipe.steps.map(EditableRecipeDraft.cleanStep).filter { !$0.isEmpty }

        // Only bail out when nothing usable came back at all (e.g. a non-recipe photo).
        // A photo with only ingredients or only steps still produces a partial, editable
        // draft — the existing draft validation catches missing fields at save time.
        guard !(name.isEmpty && ingredients.isEmpty && steps.isEmpty) else {
            throw RecipeImageImportError.noRecipeFound
        }

        var draft = EditableRecipeDraft(
            title: name,
            servings: min(max(response.recipe.servings ?? 2, 1), 12),
            cookingTime: response.recipe.cookingTime,
            difficulty: response.recipe.difficulty ?? "",
            tagsText: response.recipe.tags.joined(separator: "，"),
            ingredientsText: ingredients.joined(separator: "\n"),
            seasoningsText: response.recipe.seasonings
                .map(\.displayText)
                .filter { !$0.isEmpty }
                .joined(separator: "\n"),
            stepsText: steps.joined(separator: "\n"),
            tipsText: response.recipe.tips
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        )
        draft.id = "user-image-\(UUID().uuidString.lowercased())"
        draft.source = RecipeSourceMetadata(
            platform: "image",
            originalURL: "",
            canonicalURL: "",
            importedAt: Date(),
            title: nil,
            author: nil
        )

        var warnings = response.warnings ?? []
        if let confidence = response.confidence, confidence < 0.6 {
            warnings.append("部分内容可能识别不准确，请保存前检查。")
        }
        if ingredients.isEmpty { warnings.append("没有识别到食材，请手动补充。") }
        if steps.isEmpty { warnings.append("没有识别到制作步骤，请手动补充。") }

        var seenWarnings = Set<String>()
        let dedupedWarnings = warnings.filter { seenWarnings.insert($0).inserted }

        return RecipeImageExtractionResult(draft: draft, warnings: dedupedWarnings, rawText: response.rawText)
    }

    private static let prompt = """
    你是 Kitchen Manager 的菜谱图片识别助手。这张图片可能是小红书或网页菜谱截图、纸质菜谱、食谱书页面、手写菜谱、菜谱卡或包装盒上的烹饪说明。请阅读图片中的文字并整理成结构化菜谱。

    任务：
    1. 识别图片里的文字：菜名、食材、用量、步骤、标题和小标题，保持原文顺序，把被换行拆开的同一项合并。
    2. 整理成菜谱：判断哪部分是菜名，区分主食材与调料和辅料，去除广告、水印和无关文字，清除步骤原有的编号（例如“1.”“1、”“第一步”“Step 1”），修正明显的 OCR 错别字，如果图片中有明确写出就识别份量、烹饪时间和难度。

    严格要求：
    - 只使用图片中真实出现的信息，不要编造图片里不存在的食材、用量或步骤。
    - 图片没有提供的数量、时间或难度，对应字段返回 null，不要猜测填充。
    - 如果是手写内容或部分文字模糊，仍然返回你能确定的部分，不要因为个别文字无法辨认就放弃整份结果。
    - 如果图片明显不是菜谱（风景、人像、无关文档等），recipe.name 返回空字符串，ingredients 和 steps 返回空数组。
    - 如果你对某些字段做了修正或不确定，在 warnings 里用一句话提示用户核对。
    - ingredients 只能放菜品主体原料，如鸡肉、土豆、番茄、鸡蛋、猪肉、青椒。seasonings 放腌制、调味、勾芡、炝锅、炸制和辅助材料；盐、糖、生抽、料酒、食用油、豆粉、淀粉、生粉、水淀粉、花椒、豆瓣酱、少许葱姜蒜、清水和高汤必须放 seasonings。
    - 只返回 JSON 对象，不要 Markdown、代码围栏或额外解释。

    严格 JSON 格式：
    {
      "rawText": "图片中识别出的原始文字，仅用于调试",
      "recipe": {
        "name": "菜名",
        "servings": 2,
        "cookingTime": 30,
        "difficulty": "中等",
        "tags": ["川菜"],
        "ingredients": [{"name": "鸡腿肉", "quantity": "300", "unit": "克"}],
        "seasonings": [{"name": "生抽", "quantity": "1", "unit": "汤匙"}],
        "steps": ["鸡腿肉切丁并腌制。", "调制碗汁。"],
        "tips": []
      },
      "warnings": [],
      "confidence": 0.88
    }
    """
}

// MARK: - Duplicate detection

enum DuplicateRecipeMatcher {
    nonisolated static func findPossibleDuplicate(for draft: EditableRecipeDraft, in recipes: [Recipe]) -> Recipe? {
        let title = normalizedTitle(draft.title)
        guard !title.isEmpty else { return nil }
        let draftIngredients = Set(
            EditableRecipeDraft.nonEmptyLines(draft.ingredientsText).map(normalizedIngredientName)
        )

        return recipes.first { recipe in
            let recipeTitle = normalizedTitle(recipe.title)
            guard !recipeTitle.isEmpty else { return false }
            if recipeTitle == title { return true }

            let titlesOverlap = recipeTitle.contains(title) || title.contains(recipeTitle)
            guard !draftIngredients.isEmpty else { return false }
            let recipeIngredients = Set(recipe.ingredients.map(normalizedIngredientName))
            let overlap = draftIngredients.intersection(recipeIngredients)
            let ratio = Double(overlap.count) / Double(draftIngredients.count)
            return titlesOverlap ? ratio >= 0.4 : ratio >= 0.7
        }
    }

    nonisolated private static func normalizedTitle(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { !$0.isWhitespace }
    }

    nonisolated private static func normalizedIngredientName(_ value: String) -> String {
        value
            .split(whereSeparator: \Character.isWhitespace)
            .first
            .map(String.init)?
            .lowercased() ?? value.lowercased()
    }
}

// MARK: - Store

enum RecipeImageImportStage: String, CaseIterable {
    case uploading = "正在上传图片"
    case recognizingText = "正在识别文字"
    case organizing = "正在整理食材和步骤"
    case finalizing = "正在生成预览"
}

@MainActor
final class RecipeImageImportStore: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var isPreparingImage = false
    @Published private(set) var isRecognizing = false
    @Published private(set) var stage: RecipeImageImportStage?
    @Published var errorMessage: String?
    @Published var draft: EditableRecipeDraft?
    @Published private(set) var warnings: [String] = []
    @Published private(set) var rawText: String?

    private var jpegData: Data?
    private var recognitionTask: Task<Void, Never>?
    private var stageTask: Task<Void, Never>?
    private var selectionID = UUID()

    var canRecognize: Bool { jpegData != nil && !isPreparingImage && !isRecognizing }

    func setImage(_ newImage: UIImage) {
        recognitionTask?.cancel()
        stageTask?.cancel()
        selectionID = UUID()
        let currentID = selectionID
        image = newImage
        draft = nil
        warnings = []
        rawText = nil
        jpegData = nil
        errorMessage = nil
        isPreparingImage = true
        Task {
            await Task.yield()
            do {
                let result = try ImageUploadProcessor(preset: .recipeDocument).process(newImage)
                guard selectionID == currentID else { return }
                image = result.0
                jpegData = result.1
            } catch {
                guard selectionID == currentID else { return }
                image = nil
                errorMessage = error.localizedDescription
            }
            if selectionID == currentID { isPreparingImage = false }
        }
    }

    func removeImage() {
        recognitionTask?.cancel()
        stageTask?.cancel()
        selectionID = UUID()
        image = nil
        jpegData = nil
        draft = nil
        warnings = []
        rawText = nil
        isPreparingImage = false
        isRecognizing = false
        stage = nil
    }

    func cancel() {
        recognitionTask?.cancel()
        recognitionTask = nil
        stageTask?.cancel()
        stageTask = nil
        isRecognizing = false
        stage = nil
    }

    func recognize() {
        guard let jpegData else { return }
        recognitionTask?.cancel()
        let currentID = selectionID
        isRecognizing = true
        errorMessage = nil
        draft = nil
        warnings = []
        startStageProgression()

        recognitionTask = Task {
            do {
                let result = try await RecipeImageExtractionService().extract(jpegDatas: [jpegData])
                try Task.checkCancellation()
                guard currentID == selectionID else { return }
                draft = result.draft
                warnings = result.warnings
                rawText = result.rawText
            } catch is CancellationError {
                return
            } catch {
                guard currentID == selectionID else { return }
                errorMessage = error.localizedDescription
            }
            if currentID == selectionID {
                isRecognizing = false
                stageTask?.cancel()
                stage = nil
            }
        }
    }

    private func startStageProgression() {
        stageTask?.cancel()
        stage = .uploading
        stageTask = Task {
            for nextStage in RecipeImageImportStage.allCases.dropFirst() {
                try? await Task.sleep(for: .seconds(1.3))
                guard !Task.isCancelled else { return }
                stage = nextStage
            }
        }
    }
}

// MARK: - View

struct RecipeImageImportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var recipeStore: RecipeStore
    @EnvironmentObject private var navigationStore: AppNavigationStore
    @StateObject private var store = RecipeImageImportStore()

    @State private var photoItem: PhotosPickerItem?
    @State private var isShowingCamera = false
    @State private var isShowingCameraDeniedAlert = false
    @State private var isSaving = false
    @State private var isSaved = false
    @State private var saveErrorMessage: String?
    @State private var pendingDuplicateMatch: Recipe?
    @State private var isShowingDuplicateAlert = false
    @State private var matchedRecipeForViewing: Recipe?

    var body: some View {
        Form {
            imageSection

            if let stage = store.stage {
                Section {
                    HStack {
                        ProgressView()
                        Text(stage.rawValue)
                    }
                }
            }

            if !store.warnings.isEmpty {
                Section("需要确认") {
                    ForEach(store.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            if store.draft != nil {
                RecipeDraftEditorSections(draft: draftBinding, showsExtendedFields: true)

#if DEBUG
                if let rawText = store.rawText, !rawText.isEmpty {
                    Section("识别原文（仅 DEBUG 可见）") {
                        Text(rawText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
#endif

                Section {
                    Button {
                        attemptSave()
                    } label: {
                        HStack {
                            Spacer()
                            if isSaving {
                                ProgressView().tint(.white)
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
        .navigationTitle("从图片导入菜谱")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $matchedRecipeForViewing) { recipe in
            RecipeDetailView(recipe: recipe)
        }
        .sheet(isPresented: $isShowingCamera) {
            CameraPicker { store.setImage($0) }
                .ignoresSafeArea()
        }
        .onChange(of: photoItem) { _, newValue in
            guard let newValue else { return }
            Task {
                if let data = try? await newValue.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    store.setImage(image)
                } else {
                    store.errorMessage = "无法读取这张图片，请选择其他照片。"
                }
            }
        }
        .onDisappear {
            store.cancel()
        }
        .alert("无法使用相机", isPresented: $isShowingCameraDeniedAlert) {
            Button("前往设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请在系统设置中允许 Kitchen Manager 使用相机，或改从相册选择图片。")
        }
        .alert(
            "识别失败",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("好") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "请稍后重试。")
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
        .alert(
            "可能已经有类似菜谱",
            isPresented: $isShowingDuplicateAlert,
            presenting: pendingDuplicateMatch
        ) { match in
            Button("查看已有菜谱") { matchedRecipeForViewing = match }
            Button("仍然保存") { performSave() }
            Button("取消", role: .cancel) {}
        } message: { match in
            Text("已有一份「\(match.title)」，请确认后再决定是否保存。")
        }
    }

    @ViewBuilder
    private var imageSection: some View {
        Section {
            if let image = store.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("已选择的菜谱图片预览")
                HStack {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("换一张", systemImage: "photo")
                    }
                    Spacer()
                    Button("删除", systemImage: "trash", role: .destructive) {
                        store.removeImage()
                    }
                }

                if store.isPreparingImage {
                    ProgressView("正在准备图片…")
                } else if store.draft == nil && !store.isRecognizing {
                    Button {
                        store.recognize()
                    } label: {
                        Label("开始识别", systemImage: "sparkles")
                    }
                    .disabled(!store.canRecognize)
                }
            } else {
                ContentUnavailableView(
                    "从图片导入菜谱",
                    systemImage: "text.viewfinder",
                    description: Text("保证文字清晰，避免反光和阴影，尽量包含完整菜名、食材和步骤。长菜谱可以分段拍摄，截图不要裁掉关键内容。")
                )
                HStack {
                    Button("拍照", systemImage: "camera") { requestCamera() }
                        .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                    Spacer()
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("从相册选择", systemImage: "photo.on.rectangle")
                    }
                }
            }
        } footer: {
            Text("图片会压缩后发送到 Kitchen Manager 后端进行识别，识别完成后不会长期保存原图。")
        }
    }

    private var draftBinding: Binding<EditableRecipeDraft> {
        Binding(
            get: { store.draft ?? EditableRecipeDraft() },
            set: { store.draft = $0 }
        )
    }

    private var canSave: Bool {
        guard let draft = store.draft else { return false }
        return !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func attemptSave() {
        guard let draft = store.draft, canSave, !isSaving, !isSaved else { return }
        if let match = DuplicateRecipeMatcher.findPossibleDuplicate(for: draft, in: recipeStore.recipes) {
            pendingDuplicateMatch = match
            isShowingDuplicateAlert = true
            return
        }
        performSave()
    }

    private func performSave() {
        guard let draft = store.draft, !isSaving, !isSaved else { return }
        isSaving = true
        saveErrorMessage = nil
        Task {
            await Task.yield()
            do {
                let recipe = try draft.makeRecipe()
                try recipeStore.saveUserRecipe(recipe)
                isSaved = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                isSaving = false
                navigationStore.selectedTab = .recipes
                dismiss()
            } catch {
                isSaving = false
                saveErrorMessage = error.localizedDescription
            }
        }
    }

    private func requestCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isShowingCamera = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted { isShowingCamera = true } else { isShowingCameraDeniedAlert = true }
                }
            }
        case .denied, .restricted:
            isShowingCameraDeniedAlert = true
        @unknown default:
            isShowingCameraDeniedAlert = true
        }
    }
}

import AVFoundation
import Combine
import PhotosUI
import SwiftUI
import UIKit

enum FoodInputMode: String, CaseIterable, Identifiable {
    case receipt = "拍小票"
    case manual = "手动输入"

    var id: String { rawValue }
}

struct ReceiptItemDraft: Identifiable, Hashable {
    let id = UUID()
    var isSelected = true
    var name: String
    var quantity: Double
    var unit: String
    var category: String
    var confidence: String
    /// nil only for pantry/staple-categorized items (see `InventoryExpirySuggestion`),
    /// which deliberately stay undated. Ordinary items always get a real date —
    /// there is no more user-facing "启用保质期" toggle for this.
    var expiryDate: Date?

    var needsReview: Bool {
        confidence.lowercased() != "high"
    }
}

private struct ManualInventoryDraft: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var quantity: Double
    var unit: String
    var expiryDate: Date
    /// Set only by a genuine user interaction with the DatePicker (never by
    /// the initial auto-suggestion), so re-parsing the raw text as the user
    /// keeps typing never silently overwrites a date they already chose.
    var hasUserEditedExpiry = false

    var key: String {
        "\(IngredientNormalizer.matchKey(name))|\(IngredientNormalizer.normalizedUnit(unit))"
    }
}

struct ImageUploadPreset {
    let maximumLongSide: CGFloat
    let maximumBytes: Int
    let qualityUpperBound: CGFloat
    let qualityLowerBound: CGFloat
    let qualityStep: CGFloat

    /// Shopping receipts: small printed text, favors smaller uploads over top-end sharpness.
    static let receipt = ImageUploadPreset(
        maximumLongSide: 2000,
        maximumBytes: 3_600_000,
        qualityUpperBound: 0.80,
        qualityLowerBound: 0.56,
        qualityStep: 0.08
    )

    /// Recipe documents/screenshots: keep small text legible, stay under the backend's
    /// base64 upload ceiling (raw bytes ✕ ~1.33 must stay below AI_IMAGE_MAX_BASE64_BYTES).
    static let recipeDocument = ImageUploadPreset(
        maximumLongSide: 2400,
        maximumBytes: 2_900_000,
        qualityUpperBound: 0.85,
        qualityLowerBound: 0.78,
        qualityStep: 0.07
    )
}

enum ImageUploadError: LocalizedError {
    case invalidImage
    case imageTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "无法读取这张图片，请选择其他照片。"
        case .imageTooLarge:
            return "图片压缩后仍然太大，请重新拍摄更清晰、范围更紧凑的照片。"
        }
    }
}

struct ImageUploadProcessor {
    var preset: ImageUploadPreset = .receipt

    func process(_ image: UIImage) throws -> (UIImage, Data) {
        guard image.size.width > 0, image.size.height > 0 else {
            throw ImageUploadError.invalidImage
        }
        let scale = min(1, preset.maximumLongSide / max(image.size.width, image.size.height))
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let normalized = UIGraphicsImageRenderer(size: targetSize, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        var quality = preset.qualityUpperBound
        while quality >= preset.qualityLowerBound {
            if let data = normalized.jpegData(compressionQuality: quality), data.count <= preset.maximumBytes {
                return (normalized, data)
            }
            quality -= preset.qualityStep
        }
        throw ImageUploadError.imageTooLarge
    }
}

struct ReceiptRecognitionService {
    private let aiService = AIChatService()

    func recognize(jpegData: Data) async throws -> [ReceiptItemDraft] {
        let imageBase64 = "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
        let content = try await aiService.request(
            prompt: Self.prompt,
            taskType: "receipt",
            imageBase64: imageBase64,
            timeout: 50
        )
        guard let data = content.data(using: .utf8),
              let response = try? JSONDecoder().decode(ReceiptAIResponse.self, from: data) else {
            throw ReceiptImportError.invalidResponse
        }

        let items = response.inventory.map { ($0, "冷藏") }
            + response.pantry.map { ($0, "常备") }
            + response.review.map { ($0, "待确认") }
        let drafts = items.compactMap { item, fallbackCategory -> ReceiptItemDraft? in
            let name = (item.name ?? item.canonicalName ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let category = item.storage?.nilIfEmpty ?? fallbackCategory
            let explicitExpiryDate = item.expiryDate.flatMap(Self.date(from:))
            let suggestedExpiryDate = explicitExpiryDate ?? InventoryExpirySuggestion.suggestedExpiryDate(
                for: name,
                category: category
            )
            return ReceiptItemDraft(
                name: name,
                quantity: item.quantity.flatMap(Double.init) ?? 1,
                unit: item.unit?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "份",
                category: category,
                confidence: item.confidence ?? "medium",
                expiryDate: suggestedExpiryDate
            )
        }
        guard !drafts.isEmpty else { throw ReceiptImportError.noFoodItems }
        return drafts
    }

    private static func date(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        return dateFormatter.date(from: value)
    }

    private static let prompt = """
    识别这张购物小票，只提取适合家庭厨房管理的食品。忽略店名、地址、日期、会员信息、卡号、支付方式、税费、小计、总价、折扣、袋费和条形码。不要输出或复述这些隐私字段。
    严格返回 JSON，不要 Markdown：
    {"inventory":[{"name":"番茄","qty":2,"unit":"个","storage":"冷藏","expiryDate":null,"confidence":"high"}],"pantry":[],"review":[],"ignored":[]}
    要求：name 使用常见中文食材名；数量未知填 1；单位未知填“份”；storage 只能是冷藏、冷冻、常温或常备；如果小票明确打印到期日，以 yyyy-MM-dd 写入 expiryDate，否则填 null；confidence 只能是 high、medium、low。不确定但像食品的项目放 review，不要猜测；非食品放 ignored。同一商品重复时尽量合并。普通生鲜放 inventory，葱姜蒜和调味干货放 pantry，加工食品和无法确认的食品放 review。
    """
}

@MainActor
final class ReceiptImportStore: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var items: [ReceiptItemDraft] = []
    @Published private(set) var isPreparingImage = false
    @Published private(set) var isRecognizing = false
    @Published var errorMessage: String?

    private var jpegData: Data?
    private var recognitionTask: Task<Void, Never>?
    private var selectionID = UUID()

    var selectedCount: Int { items.filter(\.isSelected).count }
    var canRecognize: Bool { jpegData != nil && !isPreparingImage && !isRecognizing }

    func setImage(_ newImage: UIImage) {
        recognitionTask?.cancel()
        selectionID = UUID()
        let currentID = selectionID
        image = newImage
        items = []
        jpegData = nil
        errorMessage = nil
        isPreparingImage = true
        Task {
            await Task.yield()
            do {
                let result = try ImageUploadProcessor().process(newImage)
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
        selectionID = UUID()
        image = nil
        jpegData = nil
        items = []
        isPreparingImage = false
        isRecognizing = false
    }

    func cancel() {
        recognitionTask?.cancel()
        recognitionTask = nil
        isRecognizing = false
    }

    func recognize() {
        guard let jpegData else { return }
        recognitionTask?.cancel()
        let currentID = selectionID
        isRecognizing = true
        errorMessage = nil
        recognitionTask = Task {
            do {
                let result = try await ReceiptRecognitionService().recognize(jpegData: jpegData)
                try Task.checkCancellation()
                guard currentID == selectionID else { return }
                items = result
            } catch is CancellationError {
                return
            } catch {
                guard currentID == selectionID else { return }
                errorMessage = error.localizedDescription
            }
            if currentID == selectionID { isRecognizing = false }
        }
    }

    func toggleAll() {
        let shouldSelect = selectedCount != items.count
        for index in items.indices { items[index].isSelected = shouldSelect }
    }

    func update(_ item: ReceiptItemDraft) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
    }

    func remove(_ id: ReceiptItemDraft.ID) {
        items.removeAll { $0.id == id }
    }

    #if DEBUG
    /// UI-test-only seam so `UITEST_SEED_RECEIPT_ITEMS` can populate the
    /// confirmation list without a real camera + OCR round trip.
    func seedForUITest(_ items: [ReceiptItemDraft]) {
        self.items = items
    }
    #endif

    @discardableResult
    func importSelected(into kitchenStore: KitchenStore) -> Int {
        let payload = items.filter(\.isSelected).map {
            InventoryImportItem(
                name: $0.name,
                quantity: $0.quantity,
                unit: $0.unit,
                expiryDate: $0.expiryDate,
                isStaple: $0.category == "常备",
                category: $0.category
            )
        }
        return kitchenStore.importInventory(payload)
    }
}

struct RecordFoodSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var kitchenStore: KitchenStore
    @EnvironmentObject private var navigationStore: AppNavigationStore
    @StateObject private var receiptStore = ReceiptImportStore()
    @State private var inputMode: FoodInputMode
    @State private var manualText = ""
    @State private var manualDrafts: [ManualInventoryDraft] = []
    @State private var photoItem: PhotosPickerItem?
    @State private var isShowingCamera = false
    @State private var isShowingCameraDeniedAlert = false

    init(initialMode: FoodInputMode = .receipt) {
        _inputMode = State(initialValue: initialMode)
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("录入方式", selection: $inputMode) {
                    ForEach(FoodInputMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if inputMode == .receipt { receiptContent } else { manualContent }
            }
            .navigationTitle("记食材")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .sheet(isPresented: $isShowingCamera) {
                CameraPicker { receiptStore.setImage($0) }
                    .ignoresSafeArea()
            }
            .alert("无法使用相机", isPresented: $isShowingCameraDeniedAlert) {
                Button("前往设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("请在系统设置中允许 Kitchen Manager 使用相机，或改从相册选择小票。")
            }
            .alert("小票识别失败", isPresented: Binding(
                get: { receiptStore.errorMessage != nil },
                set: { if !$0 { receiptStore.errorMessage = nil } }
            )) {
                Button("好") { receiptStore.errorMessage = nil }
            } message: {
                Text(receiptStore.errorMessage ?? "请稍后重试。")
            }
            .onChange(of: photoItem) { _, newValue in
                guard let newValue else { return }
                Task {
                    if let data = try? await newValue.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        receiptStore.setImage(image)
                    } else {
                        receiptStore.errorMessage = "无法读取这张图片，请选择其他照片。"
                    }
                }
            }
            .onChange(of: manualText) { _, _ in
                refreshManualDrafts()
            }
            .onDisappear { receiptStore.cancel() }
            #if DEBUG
            // UI-test-only seed hook: lets ManualEntryExpiryUITests-style tests
            // exercise the compact receipt confirmation list (many recognized
            // items, scrolling, delete) without a real camera + OCR round trip.
            // Only runs when KitchenManagerUITests passes this launch argument.
            .onAppear {
                guard ProcessInfo.processInfo.arguments.contains("UITEST_SEED_RECEIPT_ITEMS"),
                      receiptStore.items.isEmpty else { return }
                let names = [
                    "韭菜花", "菠菜", "番茄", "黄瓜", "鸡胸肉", "猪肉", "鱼片", "虾", "牛奶", "鸡蛋",
                    "豆腐", "苹果", "冷冻鱼", "大米", "食用油", "盐", "生抽", "面包", "香肠", "咖啡豆"
                ]
                receiptStore.seedForUITest(names.enumerated().map { index, name in
                    ReceiptItemDraft(
                        name: name,
                        quantity: 1,
                        unit: "份",
                        category: "",
                        confidence: index % 5 == 0 ? "low" : "high",
                        expiryDate: InventoryExpirySuggestion.suggestedExpiryDate(for: name)
                    )
                })
            }
            #endif
        }
    }

    @ViewBuilder
    private var receiptContent: some View {
        Section {
            if let image = receiptStore.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("已选择的小票预览")
                HStack {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("换一张", systemImage: "photo")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    Button("删除", systemImage: "trash", role: .destructive) {
                        receiptStore.removeImage()
                    }
                    .buttonStyle(.borderless)
                }
            } else {
                ContentUnavailableView(
                    "拍照识别小票",
                    systemImage: "camera.viewfinder",
                    description: Text("保持小票平整、文字清晰，避免反光和阴影，并拍下完整内容。过长的小票可分段拍摄后分别导入。")
                )
                HStack {
                    Button("拍照", systemImage: "camera") { requestCamera() }
                        .buttonStyle(.borderless)
                    Spacer()
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("从相册选择", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.borderless)
                }
            }

            if receiptStore.isPreparingImage {
                ProgressView("正在压缩图片…")
            } else if receiptStore.image != nil && receiptStore.items.isEmpty {
                Button {
                    receiptStore.recognize()
                } label: {
                    if receiptStore.isRecognizing {
                        HStack { ProgressView(); Text("正在识别小票…") }
                    } else {
                        Label("开始识别", systemImage: "sparkles")
                    }
                }
                .disabled(!receiptStore.canRecognize)
            }
        } footer: {
            Text("图片会压缩后发送到 Kitchen Manager 后端进行识别，不会保存在 App 或服务器中。")
        }

        if !receiptStore.items.isEmpty {
            Section {
                Button(receiptStore.selectedCount == receiptStore.items.count ? "全部取消" : "全选") {
                    receiptStore.toggleAll()
                }
            } header: {
                Text("识别到 \(receiptStore.items.count) 项")
            }

            Section {
                ForEach(receiptStore.items) { item in
                    ReceiptIngredientCompactRow(
                        item: Binding(
                            get: { receiptStore.items.first(where: { $0.id == item.id }) ?? item },
                            set: { receiptStore.update($0) }
                        ),
                        onDelete: { receiptStore.remove(item.id) }
                    )
                }
            }

            Section {
                Button {
                    let count = receiptStore.importSelected(into: kitchenStore)
                    guard count > 0 else { return }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    navigationStore.selectedTab = .inventory
                    dismiss()
                } label: {
                    Label("确认入库（\(receiptStore.selectedCount)）", systemImage: "shippingbox.and.arrow.backward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.primary)
                .disabled(receiptStore.selectedCount == 0)
            }
        }
    }

    @ViewBuilder
    private var manualContent: some View {
        Section("每行一种食材") {
            TextField("番茄、鸡蛋2个、韭菜花一份", text: $manualText, axis: .vertical)
                .lineLimit(6...12)
        }

        if !manualDrafts.isEmpty {
            Section("确认入库信息") {
                ForEach($manualDrafts) { $draft in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("食材名", text: $draft.name)
                            TextField("数量", value: $draft.quantity, format: .number)
                                .keyboardType(.decimalPad)
                            TextField("单位", text: $draft.unit)
                                .frame(width: 52)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            DatePicker("保质期", selection: $draft.expiryDate, displayedComponents: .date)
                                .onChange(of: draft.expiryDate) { _, _ in
                                    draft.hasUserEditedExpiry = true
                                }
                            Text("系统根据食材类型自动建议，可手动调整")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }

        Section {
            Button("确认入库", systemImage: "shippingbox.and.arrow.backward") {
                let items = manualItems
                guard kitchenStore.importInventory(items) > 0 else { return }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                navigationStore.selectedTab = .inventory
                dismiss()
            }
            .disabled(manualDrafts.isEmpty)
        }
    }

    private var manualItems: [InventoryImportItem] {
        manualDrafts.map {
            InventoryImportItem(
                name: $0.name,
                quantity: $0.quantity,
                unit: $0.unit,
                expiryDate: $0.expiryDate
            )
        }
    }

    private func refreshManualDrafts() {
        // Look up the FULL previous draft (not just its date) by content key,
        // so a user's manual date edit survives further edits to the raw text
        // — only a draft the user has never touched gets its date recomputed.
        let existingDraftsByKey = Dictionary(
            manualDrafts.map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let refreshedDrafts: [ManualInventoryDraft] = manualText
            .components(separatedBy: CharacterSet(charactersIn: "\n,，、;；"))
            .compactMap { line -> ManualInventoryDraft? in
                let parsed = IngredientParser.parse(line)
                let name = IngredientNormalizer.normalizedName(parsed.displayName)
                guard !name.isEmpty else { return nil }
                let unit = parsed.unit ?? "份"
                let quantity = parsed.quantity ?? 1
                let key = "\(IngredientNormalizer.matchKey(name))|\(IngredientNormalizer.normalizedUnit(unit))"

                if let existing = existingDraftsByKey[key], existing.hasUserEditedExpiry {
                    return ManualInventoryDraft(
                        name: name,
                        quantity: quantity,
                        unit: unit,
                        expiryDate: existing.expiryDate,
                        hasUserEditedExpiry: true
                    )
                }

                let suggestedDate = InventoryExpirySuggestion.suggestedExpiryDate(for: name) ?? Date()
                return ManualInventoryDraft(
                    name: name,
                    quantity: quantity,
                    unit: unit,
                    expiryDate: suggestedDate
                )
            }
        manualDrafts = refreshedDrafts
    }

    private func requestCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            receiptStore.errorMessage = "当前设备无法使用相机。"
            return
        }
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

/// Compact single-row layout for a recognized receipt item, replacing the
/// previous per-item `Section` (which stacked 4 separate Form rows and a
/// full Section's worth of grouped-list chrome, making each item ~200pt+
/// tall). This renders as two lines inside a shared `Section`'s `ForEach`,
/// with no nested `Form`/`Section`, so many items stay scrollable and light.
private struct ReceiptIngredientCompactRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var item: ReceiptItemDraft
    var onDelete: () -> Void

    private var selectionLabel: String {
        "选择 \(item.name.isEmpty ? "食材" : item.name)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    item.isSelected.toggle()
                } label: {
                    Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.isSelected ? AppTheme.primary : Color.secondary)
                }
                .buttonStyle(.plain)
                .frame(minWidth: AppTheme.minimumHitTarget, minHeight: AppTheme.minimumHitTarget)
                .contentShape(Rectangle())
                .accessibilityIdentifier("receiptItemSelection")
                .accessibilityLabel(selectionLabel)
                .accessibilityValue(item.isSelected ? "已选中" : "未选中")
                .accessibilityHint("双击切换选择状态")

                TextField("食材名", text: $item.name)
                    .accessibilityIdentifier("receiptItemName")

                if item.needsReview {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("识别置信度较低，请确认")
                }

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .frame(minWidth: AppTheme.minimumHitTarget, minHeight: AppTheme.minimumHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("receiptItemDelete")
            }

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    quantityAndExpiryStack
                } else {
                    quantityAndExpiryRow
                }
            }
        }
        .padding(.vertical, 4)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }

    @ViewBuilder
    private var quantityAndExpiryRow: some View {
        HStack(spacing: 8) {
            quantityFields
            Spacer(minLength: 0)
            expiryControl
        }
    }

    @ViewBuilder
    private var quantityAndExpiryStack: some View {
        VStack(alignment: .leading, spacing: 8) {
            quantityFields
            expiryControl
        }
    }

    @ViewBuilder
    private var quantityFields: some View {
        HStack(spacing: 8) {
            TextField("数量", value: $item.quantity, format: .number)
                .keyboardType(.decimalPad)
                .frame(minWidth: 64, alignment: .leading)
            TextField("单位", text: $item.unit)
                .frame(minWidth: 56, alignment: .leading)
        }
    }

    @ViewBuilder
    private var expiryControl: some View {
        if let expiryDate = item.expiryDate {
            HStack(spacing: 6) {
                Text("到期")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DatePicker(
                    "到期日期",
                    selection: Binding(get: { expiryDate }, set: { item.expiryDate = $0 }),
                    displayedComponents: .date
                )
                .labelsHidden()
                .datePickerStyle(.compact)
                .fixedSize()
            }
        } else {
            Text("常备食材无需保质期")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ReceiptIngredientCompactRowPreview: View {
    @State private var item: ReceiptItemDraft

    init(item: ReceiptItemDraft) {
        _item = State(initialValue: item)
    }

    var body: some View {
        Form {
            ReceiptIngredientCompactRow(item: $item, onDelete: {})
        }
    }
}

#Preview("小票行 — 已选") {
    ReceiptIngredientCompactRowPreview(item: ReceiptItemDraft(
        name: "番茄",
        quantity: 2,
        unit: "个",
        category: "蔬菜",
        confidence: "high",
        expiryDate: Date()
    ))
}

#Preview("小票行 — 未选") {
    ReceiptIngredientCompactRowPreview(item: ReceiptItemDraft(
        isSelected: false,
        name: "牛奶",
        quantity: 1,
        unit: "盒",
        category: "乳制品",
        confidence: "high",
        expiryDate: Date()
    ))
}

#Preview("小票行 — 长名称") {
    ReceiptIngredientCompactRowPreview(item: ReceiptItemDraft(
        name: "超市自有品牌低脂高钙纯牛奶家庭装",
        quantity: 1,
        unit: "箱",
        category: "乳制品",
        confidence: "low",
        expiryDate: Date()
    ))
}

#Preview("小票行 — 辅助功能大字号") {
    ReceiptIngredientCompactRowPreview(item: ReceiptItemDraft(
        name: "超市自有品牌低脂高钙纯牛奶家庭装",
        quantity: 1,
        unit: "箱",
        category: "乳制品",
        confidence: "low",
        expiryDate: Date()
    ))
    .dynamicTypeSize(.accessibility3)
}

struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraPicker
        init(parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

private struct ReceiptAIResponse: Decodable {
    var inventory: [ReceiptAIItem] = []
    var pantry: [ReceiptAIItem] = []
    var review: [ReceiptAIItem] = []

    enum CodingKeys: CodingKey { case inventory, pantry, review }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inventory = try container.decodeIfPresent([ReceiptAIItem].self, forKey: .inventory) ?? []
        pantry = try container.decodeIfPresent([ReceiptAIItem].self, forKey: .pantry) ?? []
        review = try container.decodeIfPresent([ReceiptAIItem].self, forKey: .review) ?? []
    }
}

private struct ReceiptAIItem: Decodable {
    let name: String?
    let canonicalName: String?
    let quantity: String?
    let unit: String?
    let storage: String?
    let expiryDate: String?
    let confidence: String?

    enum CodingKeys: String, CodingKey {
        case name, canonicalName, qty, unit, storage, expiryDate, expiry_date, confidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try? container.decode(String.self, forKey: .name)
        canonicalName = try? container.decode(String.self, forKey: .canonicalName)
        if let number = try? container.decode(Double.self, forKey: .qty) {
            quantity = String(number)
        } else {
            quantity = try? container.decode(String.self, forKey: .qty)
        }
        unit = try? container.decode(String.self, forKey: .unit)
        storage = try? container.decode(String.self, forKey: .storage)
        expiryDate = (try? container.decode(String.self, forKey: .expiryDate))
            ?? (try? container.decode(String.self, forKey: .expiry_date))
        confidence = try? container.decode(String.self, forKey: .confidence)
    }
}

private enum ReceiptImportError: LocalizedError {
    case invalidResponse, noFoodItems

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "AI 返回的数据无法识别，请重新拍摄或稍后重试。"
        case .noFoodItems: "没有识别到可入库的食材，请确认小票完整清晰。"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

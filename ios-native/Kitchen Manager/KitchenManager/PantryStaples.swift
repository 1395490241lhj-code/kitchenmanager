import SwiftUI
import UserNotifications

enum PantryRestockNotificationScheduler {
    private static let stateKey = "native_km_staple_notification_states_v1"

    static func sync(for items: [InventoryItem]) {
        let defaults = UserDefaults.standard
        let enabled = defaults.bool(forKey: "stapleRestockNotificationsEnabled")
        let staples = items.filter(\.isStaple)
        let identifiers = staples.map { "staple-restock-\($0.id.uuidString)" }
        let current = Dictionary(uniqueKeysWithValues: staples.map { ($0.id.uuidString, $0.stapleStatus.rawValue) })
        guard enabled else {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
            defaults.set(current, forKey: stateKey)
            return
        }

        let previous = defaults.dictionary(forKey: stateKey) as? [String: Int] ?? [:]
        for item in staples {
            let key = item.id.uuidString
            let status = item.stapleStatus
            let identifier = "staple-restock-\(key)"
            if status != .low && status != .outOfStock {
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
            }
            let prior = previous[key].flatMap(StapleStockStatus.init(rawValue:))
            let shouldNotify = (prior == .sufficient && status == .low)
                || ((prior == .sufficient || prior == .low) && status == .outOfStock)
            guard shouldNotify else { continue }

            let content = UNMutableNotificationContent()
            content.title = status == .outOfStock ? "\(item.name)没有了" : "\(item.name)快用完了"
            content.body = "当前剩余 \(item.quantity.formatted()) \(item.unit)，可以加入买菜清单。"
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            )
            UNUserNotificationCenter.current().add(request)
        }
        defaults.set(current, forKey: stateKey)
    }

    static func remove(for id: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: ["staple-restock-\(id.uuidString)"]
        )
        var states = UserDefaults.standard.dictionary(forKey: stateKey) as? [String: Int] ?? [:]
        states.removeValue(forKey: id.uuidString)
        UserDefaults.standard.set(states, forKey: stateKey)
    }
}

enum PantryStapleFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case needsRestock = "需要补货"
    case sufficient = "库存充足"
    case missingThreshold = "未设置阈值"

    var id: String { rawValue }

    func includes(_ item: InventoryItem) -> Bool {
        switch self {
        case .all: return true
        case .needsRestock: return item.stapleStatus == .low || item.stapleStatus == .outOfStock
        case .sufficient: return item.stapleStatus == .sufficient
        case .missingThreshold: return item.stapleStatus == .unknown
        }
    }
}

struct PantryStapleRow: View {
    @EnvironmentObject private var store: KitchenStore
    let item: InventoryItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.stapleStatus == .outOfStock ? "cabinet.fill" : "cabinet")
                .foregroundStyle(item.stapleStatus.color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                Text(item.stapleTrackingMode == .status
                     ? "状态跟踪 · \(item.stapleAvailabilityStatus.title)"
                     : "当前 \(item.quantity.formatted()) \(item.unit) · 最低 \(minimumText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let progress = item.stapleStockProgress {
                    StapleStockProgressBar(value: progress, color: item.stapleStatus.color)
                        .accessibilityHidden(true)
                }
            }
            Spacer()
            if item.stapleTrackingMode == .status {
                Button {
                    store.cycleStapleStatus(item.id)
                } label: {
                    Label(item.stapleAvailabilityStatus.title, systemImage: statusSymbol)
                }
                .buttonStyle(.bordered)
                .tint(item.stapleStatus.color)
                .accessibilityLabel("\(item.name)，\(item.stapleAvailabilityStatus.title)，点击切换状态")
            } else {
                HStack(spacing: 7) {
                    Button { store.adjustStapleQuantity(item.id, by: -1) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .accessibilityLabel("减少\(item.name)")
                    Text(item.quantity.formatted()).monospacedDigit().frame(minWidth: 24)
                    Button { store.adjustStapleQuantity(item.id, by: 1) } label: {
                        Image(systemName: "plus.circle")
                    }
                    .accessibilityLabel("增加\(item.name)")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var minimumText: String {
        item.lowStockThreshold.map { "\($0.formatted()) \(item.unit)" } ?? "未设置"
    }

    private var statusSymbol: String {
        switch item.stapleStatus {
        case .outOfStock: "xmark.circle.fill"
        case .low: "exclamationmark.circle.fill"
        case .unknown: "questionmark.circle"
        case .sufficient: "checkmark.circle.fill"
        }
    }
}

private struct StapleStockProgressBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Color.secondary.opacity(0.16))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(color)
                        .frame(width: proxy.size.width * min(max(value, 0), 1))
                }
        }
        .frame(height: 3)
        .frame(maxWidth: 112)
    }
}

struct AddPantryStapleView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: KitchenStore
    @State private var name = ""
    @State private var quantity = 0.0
    @State private var unit = "份"
    @State private var minimumQuantity: Double?
    @State private var defaultRestockQuantity: Double?
    @State private var autoSuggest = true
    @State private var note = ""
    @State private var category = ""
    @State private var trackingMode: StapleTrackingMode = .quantity
    @State private var availabilityStatus: StapleAvailabilityStatus = .available
    @State private var errorMessage: String?

    private let presets = ["鸡蛋", "牛奶", "大米", "面粉", "食用油", "盐", "糖", "生抽", "醋", "黑胡椒", "葱", "姜", "蒜", "咖啡豆"]
    private let statusPresets = Set(["食用油", "盐", "糖", "生抽", "醋", "黑胡椒", "葱", "姜", "蒜"])

    var body: some View {
        NavigationStack {
            Form {
                if !store.inventory.filter({ !$0.isStaple }).isEmpty {
                    Section("从现有库存选择") {
                        ForEach(store.inventory.filter { !$0.isStaple }) { item in
                            Button {
                                name = item.name
                                quantity = item.quantity
                                unit = item.unit
                            } label: {
                                HStack {
                                    Text(item.name)
                                    Spacer()
                                    Text("\(item.quantity.formatted()) \(item.unit)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("常用预设") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(presets, id: \.self) { preset in
                                Button(preset) {
                                    name = preset
                                    trackingMode = statusPresets.contains(preset) ? .status : .quantity
                                }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }

                stapleFields
            }
            .navigationTitle("添加常备食材")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
            }
            .alert("无法保存", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) { Button("好", role: .cancel) {} } message: {
                Text(errorMessage ?? "请检查输入。")
            }
        }
    }

    @ViewBuilder private var stapleFields: some View {
        Section("库存") {
            TextField("名称", text: $name)
            Picker("跟踪方式", selection: $trackingMode) {
                ForEach(StapleTrackingMode.allCases) { Text($0.title).tag($0) }
            }
            if trackingMode == .quantity {
                TextField("当前数量", value: $quantity, format: .number).keyboardType(.decimalPad)
                TextField("单位", text: $unit)
            } else {
                Picker("当前状态", selection: $availabilityStatus) {
                    ForEach(StapleAvailabilityStatus.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        Section("补货规则") {
            TextField("最低库存", value: $minimumQuantity, format: .number).keyboardType(.decimalPad)
            TextField("默认补货数量（可选）", value: $defaultRestockQuantity, format: .number).keyboardType(.decimalPad)
            Toggle("自动生成补货建议", isOn: $autoSuggest)
        }
        Section("其他") {
            TextField("分类（可选）", text: $category)
            TextField("备注（可选）", text: $note, axis: .vertical)
        }
    }

    private func save() {
        do {
            try store.saveStaple(
                id: nil,
                name: name,
                quantity: quantity,
                unit: unit,
                minimumQuantity: minimumQuantity,
                defaultRestockQuantity: defaultRestockQuantity,
                autoSuggestRestock: autoSuggest,
                note: note,
                category: category,
                trackingMode: trackingMode,
                availabilityStatus: availabilityStatus
            )
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct InventoryItemDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: KitchenStore
    let itemID: UUID
    @State private var isShowingDeleteAlert = false

    private var index: Int? { store.inventory.firstIndex(where: { $0.id == itemID }) }

    /// Every field binding below resolves the current index fresh at
    /// get/set time via `itemID`, rather than closing over the `Int` this
    /// render pass happened to find — a Toggle/TextField/Picker binding
    /// created during one `body` evaluation can still be invoked once more
    /// by SwiftUI while this view is transitioning out (e.g. right after
    /// "删除库存" shrinks `store.inventory`), and a binding that captured a
    /// stale index would then subscript a now-too-short array and crash.
    /// Resolving fresh here means a post-delete invocation just becomes a
    /// harmless no-op (get returns `defaultValue`, set does nothing).
    private func binding<Value>(_ keyPath: WritableKeyPath<InventoryItem, Value>, default defaultValue: Value) -> Binding<Value> {
        Binding(
            get: { store.inventory.first(where: { $0.id == itemID })?[keyPath: keyPath] ?? defaultValue },
            set: { newValue in
                guard let idx = store.inventory.firstIndex(where: { $0.id == itemID }) else { return }
                store.inventory[idx][keyPath: keyPath] = newValue
            }
        )
    }

    var body: some View {
        Form {
            if let index {
                Section("库存") {
                    TextField("名称", text: binding(\.name, default: ""))
                    TextField("当前数量", value: binding(\.quantity, default: 0), format: .number)
                        .keyboardType(.decimalPad)
                    TextField("单位", text: binding(\.unit, default: ""))
                }
                if !store.inventory[index].isStaple {
                    Section("保质期") {
                        Toggle("设置保质期", isOn: Binding(
                            get: { store.inventory.first(where: { $0.id == itemID })?.expiryDate != nil },
                            set: { isEnabled in
                                guard let idx = store.inventory.firstIndex(where: { $0.id == itemID }) else { return }
                                store.inventory[idx].expiryDate = isEnabled
                                    ? InventoryExpirySuggestion.suggestedExpiryDate(
                                        for: store.inventory[idx].name
                                    ) ?? Date()
                                    : nil
                            }
                        ))
                        if let expiryDate = store.inventory[index].expiryDate {
                            DatePicker(
                                "到期日期",
                                selection: Binding(
                                    get: { store.inventory.first(where: { $0.id == itemID })?.expiryDate ?? expiryDate },
                                    set: { newValue in
                                        guard let idx = store.inventory.firstIndex(where: { $0.id == itemID }) else { return }
                                        store.inventory[idx].expiryDate = newValue
                                    }
                                ),
                                displayedComponents: .date
                            )
                            LabeledContent("状态", value: store.inventory[index].expiryStatusText)
                        } else {
                            Text("未设置保质期")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("常备货架") {
                    Toggle("设为常备食材", isOn: Binding(
                        get: { store.inventory.first(where: { $0.id == itemID })?.isStaple ?? false },
                        set: { enabled in
                            if enabled {
                                guard let idx = store.inventory.firstIndex(where: { $0.id == itemID }) else { return }
                                store.inventory[idx].isStaple = true
                            } else {
                                store.cancelStaple(itemID)
                            }
                        }
                    ))
                    if store.inventory[index].isStaple {
                        Picker("跟踪方式", selection: binding(\.stapleTrackingMode, default: .quantity)) {
                            ForEach(StapleTrackingMode.allCases) { Text($0.title).tag($0) }
                        }
                        if store.inventory[index].stapleTrackingMode == .quantity {
                            TextField("最低库存", value: binding(\.lowStockThreshold, default: nil), format: .number)
                                .keyboardType(.decimalPad)
                        } else {
                            Picker("当前状态", selection: binding(\.stapleAvailabilityStatus, default: .available)) {
                                ForEach(StapleAvailabilityStatus.allCases) { Text($0.title).tag($0) }
                            }
                        }
                        TextField("默认补货数量", value: binding(\.defaultRestockQuantity, default: nil), format: .number)
                            .keyboardType(.decimalPad)
                        Toggle("自动生成补货建议", isOn: binding(\.autoSuggestRestock, default: false))
                        TextField("分类（可选）", text: optionalText(binding(\.stapleCategory, default: nil)))
                        TextField("备注（可选）", text: optionalText(binding(\.stapleNote, default: nil)), axis: .vertical)
                        LabeledContent("当前状态", value: store.inventory[index].stapleStatus.label)
                    }
                }
                Section {
                    if store.inventory[index].isStaple {
                        Button("取消常备（保留库存）") { store.cancelStaple(itemID) }
                    }
                    Button("删除库存", role: .destructive) { isShowingDeleteAlert = true }
                }
            } else {
                ContentUnavailableView("食材不存在", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle(index.map { store.inventory[$0].name } ?? "食材详情")
        .navigationBarTitleDisplayMode(.inline)
        .alert("删除这项库存？", isPresented: $isShowingDeleteAlert) {
            Button("删除", role: .destructive) { store.deleteInventory(itemID); dismiss() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除库存与取消常备不同，此操作会移除该库存记录。")
        }
    }

    private func optionalText(_ value: Binding<String?>) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}

struct PantryStaplesView: View {
    @EnvironmentObject private var store: KitchenStore
    @State private var isAdding = false
    // A plain Button setting this optional, plus .navigationDestination(item:),
    // instead of NavigationLink(value:) — a real XCUITest tap reproduced
    // NavigationLink(value:) inside a List/ForEach over a live store array
    // pushing a stale/wrong item (see InventoryNavigationUITests).
    @State private var selectedItemID: UUID?

    var body: some View {
        List {
            if store.pantryStaples.isEmpty {
                ContentUnavailableView(
                    "还没有常备食材",
                    systemImage: "cabinet",
                    description: Text("添加常用食材并设置最低库存后，会在不足时生成补货建议。")
                )
            } else {
                ForEach(store.pantryStaples) { item in
                    Button {
                        selectedItemID = item.id
                    } label: {
                        PantryStapleRow(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("管理常备货架")
        .toolbar {
            Button("添加", systemImage: "plus") { isAdding = true }
        }
        .sheet(isPresented: $isAdding) { AddPantryStapleView() }
        .navigationDestination(item: $selectedItemID) { itemID in
            InventoryItemDetailView(itemID: itemID)
        }
    }
}

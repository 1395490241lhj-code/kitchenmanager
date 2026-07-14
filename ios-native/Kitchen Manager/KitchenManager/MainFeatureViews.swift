import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct InventoryView: View {
    @EnvironmentObject private var store: KitchenStore
    @EnvironmentObject private var recipeStore: RecipeStore
    /// Pushes onto the tab-root NavigationPath directly, rather than relying on
    /// NavigationLink(value:)'s own resolution — a LazyVGrid of many value-linked
    /// cards inside a List Section was reproducibly (via a real XCUITest tap, not
    /// just code review) pushing the wrong/stale item onto the stack. A plain
    /// Button that calls this closure sidesteps that resolution path entirely.
    var onSelectItem: (UUID) -> Void
    @State private var recordMode: FoodInputMode?
    @State private var isShowingAddStaple = false
    @State private var stapleFilter: PantryStapleFilter = .all
    @State private var itemPendingDeletion: InventoryItem?

    private var restockSuggestions: [RestockSuggestion] {
        RestockSuggestionEngine().generate(kitchenStore: store, recipeStore: recipeStore)
    }

    var body: some View {
        List {
            Section {
                HStack {
                    StatusMetric(title: "在库", value: "\(store.availableInventory.count)", color: .green)
                    StatusMetric(title: "快到期", value: "\(store.expiringItems.count)", color: .orange)
                    StatusMetric(title: "已缺货", value: "\(store.inventory.filter { !$0.isAvailable }.count)", color: .red)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section("新鲜食材") {
                if store.sortedFreshInventory.isEmpty {
                    ContentUnavailableView(
                        "还没有食材",
                        systemImage: "shippingbox",
                        description: Text("从首页记录冰箱食材后，会在这里显示库存和保质期。")
                    )
                    Button("快速记录食材", systemImage: "plus") {
                        recordMode = .manual
                    }
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 145, maximum: 210), spacing: 10)],
                        spacing: 10
                    ) {
                        ForEach(store.sortedFreshInventory) { item in
                            Button {
                                onSelectItem(item.id)
                            } label: {
                                InventoryFoodCard(item: item)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("删除", role: .destructive) {
                                    itemPendingDeletion = item
                                }
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    .listRowBackground(Color.clear)
                }
            }

            Section {
                let staples = store.pantryStaples.filter(stapleFilter.includes)
                if staples.isEmpty {
                    if store.pantryStaples.isEmpty {
                        ContentUnavailableView(
                            "还没有常备食材",
                            systemImage: "cabinet",
                            description: Text("把鸡蛋、牛奶、大米等常用食材设为常备，库存不足时会提醒补货。")
                        )
                        Button("添加常备食材") { isShowingAddStaple = true }
                    } else {
                        Text("当前筛选下没有常备食材。")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(staples) { item in
                        Button {
                            onSelectItem(item.id)
                        } label: {
                            PantryStapleRow(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                HStack {
                    Text("常备货架")
                    Spacer()
                    Menu(stapleFilter.rawValue) {
                        Picker("筛选", selection: $stapleFilter) {
                            ForEach(PantryStapleFilter.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                    .textCase(nil)
                }
            }

            if !restockSuggestions.isEmpty {
                Section("补货建议") {
                    ForEach(restockSuggestions) { suggestion in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.name)
                                Text(suggestion.reason).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("加入清单") {
                                addSuggestion(suggestion)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    let stapleSuggestions = restockSuggestions.filter { $0.source == .pantryStaple }
                    if !stapleSuggestions.isEmpty {
                        Button("补齐常备货架（\(stapleSuggestions.count)）") {
                            stapleSuggestions.forEach(addSuggestion)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.primary)
                    }
                }
            }

            Section {
                NavigationLink("最近消耗", destination: RecentConsumptionView())
            }
        }
        .navigationTitle("食材")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("添加食材", systemImage: "square.and.pencil") {
                        recordMode = .manual
                    }
                    Button("添加常备食材", systemImage: "cabinet") {
                        isShowingAddStaple = true
                    }
                } label: {
                    Label("录入食材", systemImage: "plus")
                }
                .accessibilityLabel("录入食材")
            }
        }
        .sheet(item: $recordMode) { mode in
            RecordFoodSheet(initialMode: mode)
        }
        .sheet(isPresented: $isShowingAddStaple) {
            AddPantryStapleView()
        }
        .navigationDestination(for: InventoryRoute.self) { route in
            switch route {
            case .detail(let itemID):
                InventoryItemDetailView(itemID: itemID)
            }
        }
        .alert("删除这项食材？", isPresented: Binding(
            get: { itemPendingDeletion != nil },
            set: { if !$0 { itemPendingDeletion = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let itemPendingDeletion {
                    store.deleteInventory(itemPendingDeletion.id)
                }
                itemPendingDeletion = nil
            }
            Button("取消", role: .cancel) { itemPendingDeletion = nil }
        } message: {
            Text("此操作会移除库存记录，且无法撤销。")
        }
        .overlay(alignment: .bottom) {
            if let notice = store.inventoryNotice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 8, y: 3)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(2.2))
                        withAnimation { store.clearInventoryNotice() }
                    }
            }
        }
        .animation(.snappy, value: store.inventoryNotice)
    }

    private func addSuggestion(_ suggestion: RestockSuggestion) {
        store.addShopping(
            name: suggestion.name,
            quantity: suggestion.suggestedQuantity ?? 1,
            unit: suggestion.unit ?? "份",
            source: suggestion.source == .pantryStaple ? "来自常备货架" : "补货建议"
        )
    }
}

private struct InventoryFoodCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: InventoryItem

    private var statusText: String {
        item.isAvailable ? item.expiryStatusText : "缺货 · \(item.expiryStatusText)"
    }

    private var statusColor: Color {
        item.isAvailable ? item.expiryStatus.color : .red
    }

    private var progress: Double {
        item.expiryProgress ?? (item.expiryDate == nil ? 0.16 : 0)
    }

    private var progressColor: Color {
        item.expiryProgress == nil ? .secondary : item.expiryStatus.color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 4)

                Text("\(item.quantity.formatted()) \(item.unit)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            Text(statusText)
                .font(.caption.weight(.medium))
                .foregroundStyle(statusColor)
                .lineLimit(1)

            InventoryExpiryProgressBar(value: progress, color: progressColor)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(item.expiryStatus.backgroundColor, in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .stroke(AppTheme.separator.opacity(0.32), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 15))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name)，\(item.quantity.formatted()) \(item.unit)，\(statusText)")
        .accessibilityHint("打开食材详情")
        .animation(reduceMotion ? nil : .snappy, value: item.expiryStatus)
        .animation(reduceMotion ? nil : .snappy, value: item.expiryProgress)
    }
}

private struct InventoryExpiryProgressBar: View {
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
        .frame(height: 4)
    }
}

struct ShoppingView: View {
    @EnvironmentObject private var store: KitchenStore
    @State private var isShowingStockInConfirm = false
    @State private var isShowingAddItem = false

    var body: some View {
        List {
            Section("待买") {
                if store.pendingShoppingItems.isEmpty {
                    ContentUnavailableView(
                        "买菜清单是空的",
                        systemImage: "checklist",
                        description: Text("今日计划缺少的食材和手动添加的项目会出现在这里。")
                    )
                } else {
                    ForEach(store.pendingShoppingItems) { item in
                        Button { store.toggleShopping(item) } label: {
                            HStack {
                                Image(systemName: "circle")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                    if item.source != "手动添加" {
                                        Text(item.source)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text("\(item.quantity.formatted()) \(item.unit)").foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }

            Section("已买") {
                let completed = store.shoppingItems.filter(\.isDone)
                if completed.isEmpty {
                    Text("买好的食材会留在这里，确认后可以全部入库。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(completed) { item in
                        Button { store.toggleShopping(item) } label: {
                            Label(item.name, systemImage: "checkmark.circle.fill")
                        }
                    }
                }
            }
        }
        .navigationTitle("买菜")
        .safeAreaInset(edge: .bottom) {
            Button("全部入库") { isShowingStockInConfirm = true }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(!store.shoppingItems.contains(where: \.isDone))
                .padding()
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("添加", systemImage: "plus") { isShowingAddItem = true }
                    .accessibilityLabel("添加买菜项目")
            }
        }
        .sheet(isPresented: $isShowingAddItem) {
            AddShoppingItemView()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .alert("全部入库？", isPresented: $isShowingStockInConfirm) {
            Button("入库", role: .destructive) { store.stockInCompletedShopping() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已买的食材将计入库存，此操作无法撤销。")
        }
    }
}

private struct AddShoppingItemView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: KitchenStore
    @State private var name = ""
    @State private var quantity = 1.0
    @State private var unit = "份"
    @State private var source = "手动添加"
    @State private var remark = ""
    @State private var errorMessage: String?
    @FocusState private var isNameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("买什么") {
                    TextField("名称", text: $name).focused($isNameFocused)
                    TextField("数量", value: $quantity, format: .number).keyboardType(.decimalPad)
                    TextField("单位", text: $unit)
                }
                Section("补充信息") {
                    Picker("来源", selection: $source) {
                        Text("手动添加").tag("手动添加")
                        Text("日常补给").tag("日常补给")
                        Text("常备货架").tag("来自常备货架")
                    }
                    TextField("备注（可选）", text: $remark)
                }
            }
            .navigationTitle("添加买菜项目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("添加", action: save).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            .task { isNameFocused = true }
            .alert("无法添加", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(errorMessage ?? "请检查输入。") }
        }
    }

    private func save() {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, quantity.isFinite, quantity > 0 else {
            errorMessage = "请填写名称和有效数量。"; return
        }
        store.addShopping(name: cleanName, quantity: quantity, unit: unit, source: source, remark: remark)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }
}

struct SettingsView: View {
    @AppStorage("appearance") private var appearanceRawValue = AppAppearance.system.rawValue
    @AppStorage("expiryNotificationsEnabled") private var notificationsEnabled = false
    @AppStorage("notifyLeadTime1Day") private var notifyLeadTime1Day = true
    @AppStorage("notifyLeadTime3Day") private var notifyLeadTime3Day = false
    @AppStorage("notifyLeadTimeDayOf") private var notifyLeadTimeDayOf = true
    @AppStorage("stapleRestockNotificationsEnabled") private var stapleNotificationsEnabled = false
    @EnvironmentObject private var store: KitchenStore
    @EnvironmentObject private var recipeStore: RecipeStore
    @EnvironmentObject private var authStore: AuthStore
    #if DEBUG
    @EnvironmentObject private var syncSmokeController: SyncSmokeController
    #endif
    @State private var isShowingPermissionDeniedAlert = false
    @State private var isShowingClearDataAlert = false
    #if DEBUG
    @State private var isShowingSyncSmokeConfirmation = false
    #endif

    private var appearance: Binding<AppAppearance> {
        Binding(
            get: { AppAppearance(rawValue: appearanceRawValue) ?? .system },
            set: { appearanceRawValue = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section("账号") {
                switch authStore.status {
                case .guest:
                    NavigationLink {
                        AuthEntryView()
                    } label: {
                        LabeledContent("游客模式", value: "登录或创建账号")
                    }
                    Text("无需登录即可继续使用全部本机功能。登录后可为未来跨设备同步做准备。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let message = authStore.errorMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                case .signedIn(let user):
                    NavigationLink {
                        AccountView()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(user.email ?? "已登录账号")
                            Text("管理账号与家庭")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("外观") {
                Picker("显示模式", selection: appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
            }

            Section("菜谱") {
                Picker("菜谱库模式", selection: Binding(
                    get: { recipeStore.libraryMode },
                    set: { mode in Task { await recipeStore.reload(mode: mode) } }
                )) {
                    ForEach(RecipeLibraryMode.allCases) { Text($0.title).tag($0) }
                }
                if let message = recipeStore.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("食材到期提醒", isOn: Binding(
                    get: { notificationsEnabled },
                    set: { handleNotificationsToggle($0) }
                ))
                if notificationsEnabled {
                    Toggle(
                        ExpiryNotificationLeadTime.oneDayBefore.title,
                        isOn: $notifyLeadTime1Day
                    )

                    Toggle(
                        ExpiryNotificationLeadTime.threeDaysBefore.title,
                        isOn: $notifyLeadTime3Day
                    )

                    Toggle(
                        ExpiryNotificationLeadTime.dayOf.title,
                        isOn: $notifyLeadTimeDayOf
                    )
                }

                Toggle("常备食材补货提醒", isOn: Binding(
                    get: { stapleNotificationsEnabled },
                    set: { handleStapleNotificationsToggle($0) }
                ))

                NavigationLink {
                    PantryStaplesView()
                } label: {
                    Text("管理常备货架")
                }
            } header: {
                Text("提醒")
            } footer: {
                Text("首次开启提醒时，会请求系统通知权限。")
            }
            .onChange(of: notifyLeadTime1Day) { _, _ in rescheduleNotifications() }
            .onChange(of: notifyLeadTime3Day) { _, _ in rescheduleNotifications() }
            .onChange(of: notifyLeadTimeDayOf) { _, _ in rescheduleNotifications() }

            Section("数据") {
                NavigationLink("备份与恢复", destination: BackupRestoreView())
                Button("清除全部本地数据", role: .destructive) { isShowingClearDataAlert = true }
            }

            Section("关于") {
                LabeledContent("版本", value: appVersion)
                Text("Kitchen Manager 仅在你主动使用导入或 AI 功能时发送必要内容。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            #if DEBUG
            if syncSmokeController.isAvailable {
                Section("开发者") {
                    Text("当前使用内置 AI 与 Render 后端；技术配置不在正式版本显示。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Run Sync Smoke") { isShowingSyncSmokeConfirmation = true }
                        .disabled(syncSmokeController.isRunning)
                    if syncSmokeController.isRunning {
                        ProgressView("Running development sync smoke…")
                    }
                    if let message = syncSmokeController.statusMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("sync-smoke-status")
                    }
                }
            }
            #endif
        }
        .navigationTitle("我的")
        .alert("无法开启到期提醒", isPresented: $isShowingPermissionDeniedAlert) {
            Button("前往设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请在系统设置中允许 Kitchen Manager 发送通知。")
        }
        .alert("清除全部本地数据？", isPresented: $isShowingClearDataAlert) {
            Button("清除", role: .destructive) {
                store.clearAllLocalData()
                recipeStore.clearLocalData()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会删除本机的库存、常备设置、计划、买菜清单、用户菜谱、收藏和常做记录，无法撤销。远端菜谱库不会被删除。")
        }
        #if DEBUG
        .alert("Run Sync Smoke?", isPresented: $isShowingSyncSmokeConfirmation) {
            Button("Run", role: .destructive) {
                Task {
                    await syncSmokeController.run(
                        authStore: authStore,
                        kitchenStore: store,
                        recipeStore: recipeStore
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will create development test data in Supabase")
        }
        #endif
    }

    private func handleNotificationsToggle(_ newValue: Bool) {
        guard newValue else {
            notificationsEnabled = false
            rescheduleNotifications()
            return
        }
        Task {
            let granted = await ExpiryNotificationScheduler.requestAuthorizationIfNeeded()
            await MainActor.run {
                notificationsEnabled = granted
                if granted {
                    rescheduleNotifications()
                } else {
                    isShowingPermissionDeniedAlert = true
                }
            }
        }
    }

    private func rescheduleNotifications() {
        var leadTimes: Set<ExpiryNotificationLeadTime> = []
        guard notificationsEnabled else {
            ExpiryNotificationScheduler.rescheduleAll(for: store.inventory, leadTimes: [])
            return
        }
        if notifyLeadTime1Day { leadTimes.insert(.oneDayBefore) }
        if notifyLeadTime3Day { leadTimes.insert(.threeDaysBefore) }
        if notifyLeadTimeDayOf { leadTimes.insert(.dayOf) }
        ExpiryNotificationScheduler.rescheduleAll(for: store.inventory, leadTimes: leadTimes)
    }

    private func handleStapleNotificationsToggle(_ enabled: Bool) {
        guard enabled else {
            stapleNotificationsEnabled = false
            PantryRestockNotificationScheduler.sync(for: store.inventory)
            return
        }
        Task {
            let granted = await ExpiryNotificationScheduler.requestAuthorizationIfNeeded()
            await MainActor.run {
                stapleNotificationsEnabled = granted
                if granted {
                    PantryRestockNotificationScheduler.sync(for: store.inventory)
                } else {
                    isShowingPermissionDeniedAlert = true
                }
            }
        }
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }
}

struct BackupRestoreView: View {
    @EnvironmentObject private var store: KitchenStore
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var exportDocument = KitchenBackupDocument()
    @State private var message: String?

    var body: some View {
        List {
            Section("备份与恢复") {
                Button("导出厨房备份", systemImage: "square.and.arrow.up") {
                    do {
                        exportDocument = KitchenBackupDocument(data: try store.exportBackupData())
                        isExporting = true
                    } catch {
                        message = "暂时无法生成备份。"
                    }
                }
                Button("导入厨房备份", systemImage: "square.and.arrow.down") {
                    isImporting = true
                }
            }
            Section {
                Text("备份包含库存、常备规则、计划、购物清单和消耗记录。导入会替换当前厨房数据。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("备份与恢复")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "KitchenManager-Backup"
        ) { result in
            if case .failure = result { message = "备份导出没有完成。" }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                try store.restoreBackupData(Data(contentsOf: url))
                message = "厨房数据已恢复。"
            } catch {
                message = error.localizedDescription
            }
        }
        .alert("备份与恢复", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) { Button("好", role: .cancel) {} } message: { Text(message ?? "") }
    }
}

private struct StatusMetric: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 5) {
            Text(value).font(.title3.bold()).foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(AppTheme.secondarySurface, in: RoundedRectangle(cornerRadius: 14))
    }
}

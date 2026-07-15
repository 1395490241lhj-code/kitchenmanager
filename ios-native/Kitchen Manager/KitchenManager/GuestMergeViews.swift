import SwiftUI

/// Inline entry point shown in the account page's own Section (not a new
/// top-level screen) when a signed-in user has local Guest inventory and both
/// `INVENTORY_MERGE_UI_ENABLED` and `INVENTORY_SYNC_ENABLED` are on. Every
/// network-touching action is delegated to `GuestMergeController` /
/// `SyncCoordinator` — this view only reads published state and calls
/// controller methods.
struct GuestMergePromptView: View {
    @ObservedObject var controller: GuestMergeController
    let userId: UUID
    let householdId: UUID
    let householdName: String
    let kitchenStore: KitchenStore
    @EnvironmentObject private var authStore: AuthStore
    @State private var isShowingSheet = false

    var body: some View {
        if controller.isUIEnabled, controller.isFeatureEnabled,
           let summary = controller.summary, summary.hasMergeableInventory {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("发现本地库存")
                        .font(.subheadline.weight(.semibold))
                    Text("有 \(summary.inventoryCount) 条本地库存尚未合并到「\(householdName)」。可以先查看合并预览，确认后再上传；随时可以稍后处理。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                HStack(spacing: 12) {
                    Button {
                        isShowingSheet = true
                    } label: {
                        Text(promptButtonTitle)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("guestMergePromptButton")
                }
            } footer: {
                Text("购物清单、计划和菜谱不受影响，本次只涉及库存。")
            }
            .sheet(isPresented: $isShowingSheet) {
                NavigationStack {
                    InventoryMergeFlowView(
                        controller: controller,
                        userId: userId,
                        householdId: householdId,
                        householdName: householdName,
                        kitchenStore: kitchenStore
                    )
                }
            }
            .task {
                await controller.preparePreview(userId: userId, householdId: householdId, kitchenStore: kitchenStore, authStore: authStore)
            }
        }
    }

    private var promptButtonTitle: String {
        switch controller.session?.status {
        case .none, .detected, .previewReady: "查看并合并"
        case .awaitingConfirmation, .preparing, .uploading: "继续处理合并"
        case .conflict: "处理合并冲突"
        case .completed: "查看合并结果"
        case .cancelled, .failed: "重新查看合并预览"
        case .rollbackPending, .rolledBack: "查看库存合并记录"
        }
    }
}

/// Shown in the account page when the user is signed in but either has no
/// mergeable Guest inventory, or the merge UI/feature is off — gives the user
/// a clear, non-alarming explanation instead of silence. Never itself
/// triggers any network call.
struct InventorySyncStatusView: View {
    @ObservedObject var controller: GuestMergeController
    @EnvironmentObject private var authStore: AuthStore
    let householdId: UUID?
    @State private var pendingCount: Int?
    @State private var enrollmentStatus: InventorySyncEnrollmentStatus = .notEnrolled

    var body: some View {
        Section {
            LabeledContent("状态", value: statusText)
            if let pendingCount, pendingCount > 0 {
                LabeledContent("待同步", value: "\(pendingCount) 项")
            }
            if let error = controller.lastSyncErrorMessage {
                Text(error).foregroundStyle(.red).font(.footnote)
            }
            if let blocked = controller.inventoryMutationBlockedMessage {
                Text(blocked).foregroundStyle(.orange).font(.footnote)
            }
            if canSyncNow {
                Button {
                    guard let householdId else { return }
                    Task {
                        await controller.syncNow(authStore: authStore, householdId: householdId)
                        await refreshPendingCount()
                    }
                } label: {
                    if controller.isSyncing {
                        HStack { ProgressView(); Text("正在同步…") }
                    } else {
                        Text("立即同步库存")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .buttonStyle(.bordered)
                .disabled(controller.isSyncing)
                .accessibilityIdentifier("inventorySyncNowButton")
            }
        } header: {
            Text("库存同步")
        } footer: {
            Text("只同步库存；购物清单、计划和菜谱不受影响。不会自动同步——只有点击“立即同步库存”才会联网。")
        }
        .task {
            await refreshPendingCount()
            await refreshEnrollmentStatus()
        }
    }

    private var canSyncNow: Bool {
        controller.isFeatureEnabled && householdId != nil && authStore.currentUserID != nil
    }

    private var statusText: String {
        if !controller.isFeatureEnabled { return "尚未开启" }
        if authStore.currentUserID == nil { return "尚未登录" }
        if householdId == nil { return "没有可同步的家庭" }
        if enrollmentStatus == .notEnrolled || enrollmentStatus == .mergeRequired { return "尚未完成合并" }
        if controller.isSyncing { return "正在同步" }
        switch controller.lastSyncOutcome {
        case .completed: return "已同步"
        case .paused(let error) where error == .notAuthenticated: return "需要重新登录"
        case .paused: return "暂时离线"
        case .failed: return "同步遇到问题，可重试"
        case .disabled, .none: return (pendingCount ?? 0) > 0 ? "待同步 \(pendingCount ?? 0) 项" : "已同步"
        case .alreadyRunning: return "正在同步"
        }
    }

    private func refreshPendingCount() async {
        guard let householdId else {
            pendingCount = nil
            return
        }
        pendingCount = await controller.pendingInventoryCount(householdId: householdId)
    }

    private func refreshEnrollmentStatus() async {
        guard let userId = authStore.currentUserID, let householdId else {
            enrollmentStatus = .notEnrolled
            return
        }
        enrollmentStatus = await controller.enrollmentStatus(userId: userId, householdId: householdId)
    }
}

/// Single sheet that steps through preview → conflicts → progress → result,
/// driven entirely by `controller.session?.status`. Kept as one flow (no
/// animated transitions) to stay simple and to avoid disturbing the existing
/// account page's own navigation.
struct InventoryMergeFlowView: View {
    @ObservedObject var controller: GuestMergeController
    let userId: UUID
    let householdId: UUID
    let householdName: String
    let kitchenStore: KitchenStore
    @EnvironmentObject private var authStore: AuthStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            // A failed remote read takes precedence over everything else —
            // including an existing session — since neither "no mergeable
            // inventory" nor a possibly-stale prior plan may safely be shown
            // in its place; the household's real cloud state is unknown.
            if let fetchFailure = controller.previewFetchFailureMessage {
                InventoryMergePreviewFetchFailureView(message: fetchFailure) {
                    Task {
                        await controller.preparePreview(
                            userId: userId, householdId: householdId, kitchenStore: kitchenStore, authStore: authStore
                        )
                    }
                }
            } else if controller.isBusy && controller.session == nil {
                InventoryMergeProgressView(message: "正在准备合并预览…")
            } else if let session = controller.session {
                switch session.status {
                case .detected, .previewReady, .awaitingConfirmation, .failed, .cancelled:
                    InventoryMergePreviewView(controller: controller, householdName: householdName, onDismiss: { dismiss() })
                case .conflict:
                    InventoryMergeConflictView(controller: controller)
                case .preparing, .uploading, .rollbackPending:
                    InventoryMergeProgressView(message: progressMessage(for: session.status))
                case .completed, .rolledBack:
                    InventoryMergeResultView(controller: controller)
                }
            } else {
                ContentUnavailableView("没有可合并的库存", systemImage: "shippingbox")
            }
        }
        .navigationTitle("合并库存")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("稍后处理") { dismiss() }
                    .accessibilityIdentifier("guestMergeDismissLater")
            }
        }
    }

    private func progressMessage(for status: GuestMergeSessionStatus) -> String {
        switch status {
        case .preparing: "正在准备上传…"
        case .uploading: "正在合并库存…"
        case .rollbackPending: "正在回滚新增记录…"
        default: "正在处理…"
        }
    }
}

/// Shown instead of any plan/empty-state when the production preview's
/// read-only remote fetch itself failed — never displays raw HTTP status,
/// UUIDs, tokens, or internal error text, only the plain-language copy
/// already produced by `GuestMergeController.userFacingSyncError`. Confirm
/// is entirely unreachable from here; the only action is retrying preview.
struct InventoryMergePreviewFetchFailureView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("无法读取家庭库存", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("重试") { onRetry() }
                .frame(minHeight: 44)
                .accessibilityIdentifier("guestMergeRetryPreviewButton")
        }
    }
}

struct InventoryMergePreviewView: View {
    @ObservedObject var controller: GuestMergeController
    let householdName: String
    @EnvironmentObject private var authStore: AuthStore
    let onDismiss: () -> Void
    @State private var isShowingCancelConfirmation = false

    private var plan: InventoryMergePlan? { controller.plan }

    private var failureMessage: String? {
        guard controller.session?.status == .failed else { return nil }
        return controller.lastErrorMessage ?? userFacingErrorMessage(for: controller.session?.lastErrorCode)
    }

    var body: some View {
        Form {
            if let error = failureMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
            Section("预计结果") {
                LabeledContent("合并目标", value: householdName)
                LabeledContent("本地库存", value: "\(plan?.sourceCount ?? 0) 条")
                LabeledContent("家庭云端库存", value: "\(plan?.knownRemoteItemCount ?? 0) 条")
                LabeledContent("预计新增", value: "\(plan?.creates.count ?? 0) 条")
                LabeledContent("预计更新", value: "\(plan?.updates.count ?? 0) 条")
                LabeledContent("完全一致（无需处理）", value: "\(plan?.exactMatches.count ?? 0) 条")
            }
            if let plan, !plan.conflicts.isEmpty {
                Section("需要处理的冲突") {
                    if !plan.quantityConflicts.isEmpty {
                        LabeledContent("数量不同", value: "\(plan.quantityConflicts.count) 条")
                    }
                    if !plan.expiryConflicts.isEmpty {
                        LabeledContent("保质期不同", value: "\(plan.expiryConflicts.count) 条")
                    }
                    if !plan.metadataConflicts.isEmpty {
                        LabeledContent("其他信息不同", value: "\(plan.metadataConflicts.count) 条")
                    }
                    if !plan.ambiguousConflicts.isEmpty {
                        LabeledContent("可能重复", value: "\(plan.ambiguousConflicts.count) 条")
                    }
                }
            }
            Section {
                Text("只合并库存，不会上传购物清单、计划或菜谱。")
                Text("本步骤不会写入云端；确认后如有冲突不会自动覆盖，需要逐条选择。")
                Text("可以随时取消，也可以稍后处理。")
                Text("完成后的新增记录可在限定时间内回滚。")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            Section {
                Button {
                    Task {
                        await controller.confirmMerge(authStore: authStore)
                    }
                } label: {
                    Text(controller.session?.status == .failed ? "重试合并" : "确认合并库存")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.isBusy || plan == nil)
                .accessibilityIdentifier("guestMergeConfirmButton")

                if let plan, !plan.conflicts.isEmpty {
                    Text("有 \(plan.conflicts.count) 条存在冲突，确认后仍会先处理没有冲突的条目；冲突条目需要单独选择。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("取消本次合并", role: .destructive) { isShowingCancelConfirmation = true }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("guestMergeCancelButton")
            }
        }
        .alert("取消合并？", isPresented: $isShowingCancelConfirmation) {
            Button("取消合并", role: .destructive) {
                Task { await controller.cancel() }
            }
            Button("再想想", role: .cancel) {}
        } message: {
            Text("本机库存不会有任何改动。")
        }
    }

    /// Maps the session's own recorded error code (a debug string, e.g.
    /// derived from `SyncRunOutcome`) to plain, user-facing copy — never the
    /// raw technical text, an HTTP status, or any transport/server detail.
    private func userFacingErrorMessage(for code: String?) -> String? {
        guard let code else { return nil }
        if code.contains("notAuthenticated") { return "需要重新登录后再试。" }
        if code.contains("forbidden") || code.contains("unauthorized") { return "需要重新登录后再试。" }
        if code.contains("payloadTooLarge") { return "本次合并内容过大，请稍后重试。" }
        if code.contains("backendUnavailable") { return "服务暂时不可用，请稍后重试。" }
        if code.contains("disabled") { return "库存同步尚未开启。" }
        if code.contains("paused") { return "暂时离线，请稍后重试。" }
        return "合并失败，可稍后重试。"
    }
}

struct InventoryMergeConflictView: View {
    @ObservedObject var controller: GuestMergeController
    @State private var pendingChoice: [UUID: InventoryMergeConflictChoice] = [:]

    var body: some View {
        Form {
            Section {
                Text("以下条目需要你逐条选择，不会自动覆盖。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(controller.plan?.conflicts ?? []) { candidate in
                Section {
                    LabeledContent("本机", value: localDescription(for: candidate))
                    LabeledContent("家庭", value: remoteDescription(for: candidate))
                    if let reason = candidate.conflictReason {
                        Text(reasonText(reason))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Picker("选择", selection: choiceBinding(for: candidate.localItemId)) {
                        Text("保留本机").tag(InventoryMergeConflictChoice.keepLocal)
                        Text("保留家庭").tag(InventoryMergeConflictChoice.keepRemote)
                        Text("两条都保留").tag(InventoryMergeConflictChoice.keepBoth)
                        Text("稍后处理").tag(InventoryMergeConflictChoice.skip)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("guestMergeConflictPicker-\(candidate.localItemId.uuidString)")

                    if pendingChoice[candidate.localItemId] == .keepBoth, candidate.remoteItemId == candidate.localItemId {
                        Text("家庭库存中已有这条记录，选择“两条都保留”会为本机这条创建一条独立的新库存记录，不会覆盖原有记录。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("guestMergeKeepBothForkNotice-\(candidate.localItemId.uuidString)")
                    }
                } header: {
                    Text(candidate.name)
                }
            }
        }
        .navigationTitle("处理冲突")
    }

    private func choiceBinding(for id: UUID) -> Binding<InventoryMergeConflictChoice> {
        Binding(
            get: { pendingChoice[id] ?? .keepRemote },
            set: { newValue in
                pendingChoice[id] = newValue
                Task { await controller.resolveConflict(candidateId: id, choice: newValue) }
            }
        )
    }

    private func localDescription(for candidate: InventoryMergeCandidate) -> String {
        var parts = [quantityText(candidate.localQuantity, candidate.unit)]
        if let expiry = candidate.localExpiryDate {
            parts.append(expiryText(expiry))
        }
        return parts.joined(separator: " · ")
    }

    private func remoteDescription(for candidate: InventoryMergeCandidate) -> String {
        guard let remoteQuantity = candidate.remoteQuantity else { return "—" }
        var parts = [quantityText(remoteQuantity, candidate.unit)]
        if let expiry = candidate.remoteExpiryDate {
            parts.append(expiryText(expiry))
        }
        return parts.joined(separator: " · ")
    }

    private func reasonText(_ reason: InventoryMergeConflictReason) -> String {
        switch reason {
        case .quantityMismatch: "本机与家庭的数量不同。"
        case .expiryMismatch: "本机与家庭的保质期不同。"
        case .metadataMismatch: "本机与家庭的常备食材设置（分类/阈值/补货量）不同。"
        case .ambiguousDuplicate: "家庭库存中有一条名称和单位相同的记录，无法确定是否为同一条，需要你确认。"
        case .multipleRemoteCandidates: "家庭库存中有多条名称和单位相同的记录，无法自动选择，需要你确认。"
        }
    }

    private func quantityText(_ quantity: Double, _ unit: String) -> String {
        let formatted = quantity.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", quantity)
            : String(quantity)
        return "\(formatted)\(unit)"
    }

    private func expiryText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return "保质期至 \(formatter.string(from: date))"
    }
}

struct InventoryMergeProgressView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}

struct InventoryMergeResultView: View {
    @ObservedObject var controller: GuestMergeController
    @EnvironmentObject private var authStore: AuthStore
    @State private var isShowingRollbackConfirmation = false

    var body: some View {
        Form {
            if let session = controller.session {
                Section("合并结果") {
                    LabeledContent("已合并", value: "\(session.uploadedItemCount) 条")
                    LabeledContent("冲突", value: "\(session.conflictCount) 条")
                    LabeledContent("失败", value: "\(session.failedCount) 条")
                }

                if session.status == .completed, session.rollbackAvailableUntil != nil {
                    Section {
                        Button("回滚本次新增记录", role: .destructive) { isShowingRollbackConfirmation = true }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .accessibilityIdentifier("guestMergeRollbackButton")
                    } footer: {
                        Text("只回滚本次新增的记录，不影响合并前已存在的家庭库存或本机库存。")
                    }
                }
                if session.status == .rolledBack {
                    Text("已回滚本次新增的记录。").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("合并结果")
        .alert("回滚本次新增记录？", isPresented: $isShowingRollbackConfirmation) {
            Button("回滚", role: .destructive) {
                Task { await controller.rollback(authStore: authStore) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("本机库存不会被删除。")
        }
    }
}

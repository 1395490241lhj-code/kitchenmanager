import SwiftUI

/// Inline entry point shown in the account page's own Section (not a new
/// top-level screen) when a signed-in user has local Guest inventory and the
/// feature is enabled. Every network-touching action is delegated to
/// `GuestMergeController` / `SyncCoordinator` — this view only reads
/// published state and calls controller methods.
struct GuestMergePromptView: View {
    @ObservedObject var controller: GuestMergeController
    let userId: UUID
    let householdId: UUID
    let kitchenStore: KitchenStore
    @State private var isShowingSheet = false

    var body: some View {
        if controller.isFeatureEnabled, let summary = controller.summary, summary.hasMergeableInventory {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("发现本机游客库存")
                        .font(.subheadline.weight(.semibold))
                    Text("本机有 \(summary.inventoryCount) 条库存记录尚未加入当前家庭。可以先查看合并预览，确认后再上传；随时可以稍后处理。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                Button {
                    isShowingSheet = true
                } label: {
                    Text(promptButtonTitle)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("guestMergePromptButton")
            } footer: {
                Text("购物清单、计划和菜谱不受影响，本次只涉及库存。")
            }
            .sheet(isPresented: $isShowingSheet) {
                NavigationStack {
                    InventoryMergeFlowView(
                        controller: controller,
                        userId: userId,
                        householdId: householdId,
                        kitchenStore: kitchenStore
                    )
                }
            }
            .task {
                await controller.preparePreview(userId: userId, householdId: householdId, kitchenStore: kitchenStore)
            }
        }
    }

    private var promptButtonTitle: String {
        switch controller.session?.status {
        case .none, .detected, .previewReady: "查看合并预览"
        case .awaitingConfirmation, .preparing, .uploading: "继续处理合并"
        case .conflict: "处理合并冲突"
        case .completed: "查看合并结果"
        case .cancelled, .failed: "重新查看合并预览"
        case .rollbackPending, .rolledBack: "查看库存合并记录"
        }
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
    let kitchenStore: KitchenStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if controller.isBusy && controller.session == nil {
                InventoryMergeProgressView(message: "正在准备合并预览…")
            } else if let session = controller.session {
                switch session.status {
                case .detected, .previewReady, .awaitingConfirmation, .failed, .cancelled:
                    InventoryMergePreviewView(controller: controller, onDismiss: { dismiss() })
                case .conflict:
                    InventoryMergeConflictView(controller: controller)
                case .preparing, .uploading, .rollbackPending:
                    InventoryMergeProgressView(message: "正在合并库存…")
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
}

struct InventoryMergePreviewView: View {
    @ObservedObject var controller: GuestMergeController
    @EnvironmentObject private var authStore: AuthStore
    let onDismiss: () -> Void
    @State private var isShowingCancelConfirmation = false

    private var plan: InventoryMergePlan? { controller.plan }

    var body: some View {
        Form {
            if let error = controller.lastErrorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
            Section("预计结果") {
                LabeledContent("本机游客库存", value: "\(plan?.sourceCount ?? 0) 条")
                LabeledContent("预计新增", value: "\(plan?.creates.count ?? 0) 条")
                LabeledContent("预计更新", value: "\(plan?.updates.count ?? 0) 条")
                LabeledContent("可能冲突", value: "\(plan?.conflicts.count ?? 0) 条")
                LabeledContent("已跳过（完全一致）", value: "\(plan?.skippedItemIds.count ?? 0) 条")
            }
            Section {
                Text("合并目标：当前家庭库存")
                Text("购物清单、今日计划、周菜单和菜谱不会上传，只会合并库存。")
                Text("可以随时取消；确认后如有冲突不会自动覆盖，需要逐条选择。")
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
                    Text("确认合并库存")
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
                Section(candidate.name) {
                    LabeledContent("本机数量", value: quantityText(candidate.localQuantity, candidate.unit))
                    LabeledContent("家庭数量", value: candidate.remoteQuantity.map { quantityText($0, candidate.unit) } ?? "—")

                    Picker("选择", selection: choiceBinding(for: candidate.localItemId)) {
                        Text("保留本机").tag(InventoryMergeConflictChoice.keepLocal)
                        Text("保留家庭").tag(InventoryMergeConflictChoice.keepRemote)
                        Text("两条都保留").tag(InventoryMergeConflictChoice.keepBoth)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("guestMergeConflictPicker-\(candidate.localItemId.uuidString)")
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

    private func quantityText(_ quantity: Double, _ unit: String) -> String {
        let formatted = quantity.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", quantity)
            : String(quantity)
        return "\(formatted)\(unit)"
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

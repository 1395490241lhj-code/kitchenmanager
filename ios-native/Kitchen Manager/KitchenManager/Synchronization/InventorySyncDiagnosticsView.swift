import SwiftUI

/// Phase 2B-5: Debug/dogfood-gated, read-only diagnostics screen. Only ever
/// visible when `controller.showsDiagnosticsScreen` is true (i.e. both
/// `INVENTORY_SYNC_DOGFOOD_ENABLED` and `INVENTORY_SYNC_DIAGNOSTICS_ENABLED`
/// are on) — never reachable in an ordinary Release build. The only actions
/// offered are refresh, export, retry manual sync, and help; nothing here
/// deletes data, clears the queue, or forces a version/cursor.
struct InventorySyncDiagnosticsEntryView: View {
    @ObservedObject var controller: GuestMergeController
    let kitchenStore: KitchenStore
    let userId: UUID?
    let householdId: UUID?

    var body: some View {
        if controller.showsDiagnosticsScreen {
            Section {
                NavigationLink("库存同步诊断") {
                    InventorySyncDiagnosticsScreen(
                        controller: controller, kitchenStore: kitchenStore, userId: userId, householdId: householdId
                    )
                }
            }
        }
    }
}

private struct InventorySyncDiagnosticsScreen: View {
    @ObservedObject var controller: GuestMergeController
    @EnvironmentObject private var authStore: AuthStore
    let kitchenStore: KitchenStore
    let userId: UUID?
    let householdId: UUID?

    @State private var snapshot: InventorySyncDiagnosticsSnapshot?
    @State private var issues: [InventorySyncConsistencyIssue] = []
    @State private var exportText: String?
    @State private var isShowingHelp = false

    var body: some View {
        Form {
            if let snapshot {
                Section("环境") {
                    LabeledContent("环境", value: snapshot.environment)
                    LabeledContent("功能开关", value: snapshot.isFeatureEnabled ? "开" : "关")
                    LabeledContent("Dogfood", value: snapshot.isDogfoodEnabled ? "开" : "关")
                    LabeledContent("已登录", value: snapshot.currentUserPresent ? "是" : "否")
                    LabeledContent("有家庭", value: snapshot.householdPresent ? "是" : "否")
                    LabeledContent("加入状态", value: snapshot.enrollmentState)
                }
                Section("同步状态") {
                    LabeledContent("待同步", value: "\(snapshot.pendingCount)")
                    LabeledContent("冲突", value: "\(snapshot.conflictCount)")
                    LabeledContent("失败", value: "\(snapshot.failedCount)")
                    if let age = snapshot.oldestPendingAge {
                        LabeledContent("最早待同步时长", value: "\(Int(age))秒")
                    }
                    LabeledContent("上次结果", value: snapshot.lastSyncResult ?? "无")
                    if let completed = snapshot.lastSyncCompletedAt {
                        LabeledContent("上次完成时间", value: completed.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let mergeState = snapshot.activeMergeSessionState {
                        LabeledContent("合并会话", value: mergeState)
                    }
                }
                Section("本机数据") {
                    LabeledContent("已同步项", value: "\(snapshot.localSyncedItemCount)")
                    LabeledContent("仅本机项", value: "\(snapshot.localGuestOnlyItemCount)")
                    LabeledContent("已删除标记", value: "\(snapshot.localTombstoneCount)")
                }
                if !issues.isEmpty {
                    Section("一致性检查") {
                        ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                            Text(issue.code.rawValue).font(.footnote).foregroundStyle(.orange)
                        }
                    }
                } else {
                    Section("一致性检查") {
                        Text("未发现异常").foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView("正在读取诊断信息…")
            }

            Section {
                Button("刷新诊断信息") { Task { await refresh() } }
                if let exportText {
                    ShareLink(item: exportText) { Text("导出脱敏诊断摘要") }
                } else {
                    Button("导出脱敏诊断摘要") { prepareExport() }
                }
                if canRetrySync {
                    Button("重试手动同步") {
                        Task {
                            guard let householdId else { return }
                            await controller.syncNow(authStore: authStore, householdId: householdId)
                            await refresh()
                        }
                    }
                }
                Button("帮助") { isShowingHelp = true }
            } footer: {
                Text("只读诊断，不会修改或删除任何本机或远端数据。")
            }
        }
        .navigationTitle("库存同步诊断")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .alert("库存同步诊断", isPresented: $isShowingHelp) {
            Button("好的", role: .cancel) {}
        } message: {
            Text("此页面仅用于开发/内测阶段查看同步状态，不会自动同步，也不提供删除或强制覆盖操作。")
        }
    }

    private var canRetrySync: Bool {
        controller.isFeatureEnabled && !controller.isSyncing && householdId != nil && userId != nil
    }

    private func refresh() async {
        let newSnapshot = await controller.diagnosticsSnapshot(
            kitchenStore: kitchenStore, userId: userId, householdId: householdId,
            environmentName: snapshot?.environment ?? "unknown",
            appBuild: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { version in
                "\(version) (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))"
            } ?? "unknown"
        )
        snapshot = newSnapshot
        issues = await controller.consistencyCheck(kitchenStore: kitchenStore, userId: userId, householdId: householdId)
        exportText = nil
    }

    private func prepareExport() {
        guard let snapshot else { return }
        exportText = String(data: snapshot.redactedJSON(), encoding: .utf8)
    }
}

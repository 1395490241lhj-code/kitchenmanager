import SwiftUI

/// Settings/Account/Delete Account. Never merges with Sign Out — see
/// `docs/ACCOUNT_DELETION_DESIGN.md` §"Deletion semantics" for why these stay
/// five distinct actions rather than one ambiguous button.
struct AccountDeletionView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authStore: AuthStore
    @EnvironmentObject private var kitchenStore: KitchenStore
    @ObservedObject var controller: AccountDeletionController

    @State private var confirmationText = ""
    @State private var showIrreversibleAlert = false
    @State private var showReauthenticationSheet = false
    @State private var showFinalDeletionAlert = false
    @State private var selectedHouseholdIdForTransfer: UUID?
    @State private var selectedNewOwner: TransferCandidate?

    private var requiresTypedConfirmation: Bool { confirmationText == "DELETE" }

    /// What a completed deletion does to this device. Mirrors
    /// `KitchenStore.clearAllLocalData()`, which the deletion runs: every kitchen
    /// table is cleared and only the recipe library is left.
    static let localDataNotice = "删除完成后会自动退出登录，并清除本机的库存、买菜清单、用餐计划、每周菜单、聚餐计划、备餐组件和做饭消耗记录（菜谱库保留），无法恢复。之后仍可以游客模式使用。需要保留这些数据，请先到「设置 › 备份与恢复」导出备份。"

    var body: some View {
        Form {
            Section {
                Text("删除账号会永久移除你的登录身份，并清除这台设备上的厨房数据，与「退出登录」不同——退出登录不会删除任何数据，仍可随时重新登录。")
            } header: {
                Text("这与退出登录不同")
            }

            if controller.needsLocalCleanup {
                localCleanupSection
            } else if controller.isLoadingPreview {
                Section { ProgressView("正在检查账号状态…") }
            } else if let preview = controller.preview {
                previewSection(preview)
                if preview.requiresOwnershipTransfer {
                    transferSection
                }
                if preview.canDelete {
                    confirmationSection
                }
            } else if let message = controller.errorMessage {
                Section {
                    Text(message).foregroundStyle(.red)
                    Button("重试") { Task { await controller.loadPreview(authStore: authStore) } }
                }
            }
        }
        .navigationTitle("删除账号")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            controller.refreshLocalCleanupOwnership(authStore: authStore, kitchenStore: kitchenStore)
            await controller.loadPreview(authStore: authStore)
        }
        .onChange(of: controller.didComplete) { _, completed in
            if completed { dismiss() }
        }
        .alert("此操作不可撤销", isPresented: $showIrreversibleAlert) {
            Button("取消", role: .cancel) {}
            Button("继续", role: .destructive) { showReauthenticationSheet = true }
        } message: {
            Text("删除后，你的账号身份、家庭成员关系与同步记录将被永久移除或匿名化，本机的厨房数据也会被清除，且无法恢复。建议先导出备份。")
        }
        .sheet(isPresented: $showReauthenticationSheet) {
            AccountDeletionReauthenticationView(controller: controller) {
                showReauthenticationSheet = false
                showFinalDeletionAlert = true
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .alert("最后确认删除账号", isPresented: $showFinalDeletionAlert) {
            Button("取消", role: .cancel) {}
            Button("删除账号", role: .destructive) {
                Task { await controller.confirmDeletion(authStore: authStore, kitchenStore: kitchenStore) }
            }
        } message: {
            Text("身份已重新验证。确认后将永久删除账号，且无法恢复。")
        }
    }

    private var localCleanupSection: some View {
        Section {
            Text(controller.localCleanupBlockedReason == nil
                 ? "账号已删除，本机清理未完成" : "此前账号已删除，本机清理已暂停")
                .font(.headline)
                .accessibilityIdentifier(controller.localCleanupBlockedReason == nil
                                         ? "account.delete.localCleanupPending" : "account.delete.localCleanupBlocked")
            if let message = controller.errorMessage {
                Text(message).foregroundStyle(.red)
            }
            Button {
                Task { await controller.retryLocalCleanup(authStore: authStore, kitchenStore: kitchenStore) }
            } label: {
                HStack {
                    if controller.isConfirming { ProgressView() }
                    Text("重试本机清理")
                }
            }
            .disabled(controller.isConfirming || controller.localCleanupBlockedReason != nil)
            .accessibilityIdentifier("account.delete.retryLocalCleanup")
        } footer: {
            Text(controller.localCleanupBlockedReason == nil
                 ? "只重试尚未完成的本机清理或退出登录，不会再次请求删除账号。菜谱库、收藏和常做记录会保留。"
                 : "当前上下文不再属于此前的删除操作。当前账号和本机数据会保留，此处不会执行清理或退出登录。")
        }
    }

    private func previewSection(_ preview: AccountDeletionPreview) -> some View {
        Section("影响范围") {
            LabeledContent("所属家庭数", value: "\(preview.householdCount)")
            LabeledContent("担任所有者的家庭数", value: "\(preview.ownedHouseholdCount)")
            if preview.requiresHouseholdDeletion {
                Text("你是唯一成员的家庭将随账号一起删除。")
                    .foregroundStyle(.orange)
            }
            if let blockingReason = preview.blockingReason {
                Text(AccountDeletionError(code: blockingReason).localizedDescription)
                    .foregroundStyle(.red)
                    .accessibilityLabel(Text("删除受阻：\(AccountDeletionError(code: blockingReason).localizedDescription)"))
            }
        }
    }

    private var transferSection: some View {
        Section("需要先转移所有权") {
            Text("以下家庭还有其他成员，需要先指定新的所有者，才能删除账号。")
            if controller.isLoadingCandidates {
                ProgressView()
            } else if controller.transferCandidates.isEmpty {
                Button("加载可选成员") {
                    // The household id isn't in the coarse preview response by
                    // design (see docs/ACCOUNT_DELETION_DESIGN.md — preview
                    // never returns a household id/name); this reuses the
                    // household list the account screen already fetched via
                    // /api/me, which the user already has legitimate access to.
                    if let household = authStore.account?.households.first(where: { $0.role == "owner" }) {
                        selectedHouseholdIdForTransfer = household.id
                        Task { await controller.loadTransferCandidates(householdId: household.id, authStore: authStore) }
                    }
                }
            } else {
                Picker("新的所有者", selection: $selectedNewOwner) {
                    Text("请选择").tag(TransferCandidate?.none)
                    ForEach(controller.transferCandidates) { candidate in
                        Text(candidate.displayName.isEmpty ? "成员" : candidate.displayName).tag(TransferCandidate?.some(candidate))
                    }
                }
                Button("转移所有权") {
                    guard let householdId = selectedHouseholdIdForTransfer, let newOwner = selectedNewOwner else { return }
                    Task {
                        if await controller.transferOwnership(householdId: householdId, newOwnerUserId: newOwner.userId, authStore: authStore) {
                            selectedNewOwner = nil
                            selectedHouseholdIdForTransfer = nil
                        }
                    }
                }
                .disabled(selectedNewOwner == nil || controller.isTransferring)
            }
        }
    }

    private var confirmationSection: some View {
        Section {
            Text("请输入 DELETE 以确认删除账号。")
            TextField("DELETE", text: $confirmationText)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .accessibilityLabel(Text("输入 DELETE 以确认"))

            if let message = controller.errorMessage {
                Text(message).foregroundStyle(.red)
            }

            Button(role: .destructive) {
                showIrreversibleAlert = true
            } label: {
                HStack {
                    Spacer()
                    if controller.isConfirming { ProgressView() }
                    else { Text("删除账号") }
                    Spacer()
                }
            }
            .disabled(!requiresTypedConfirmation || controller.isConfirming)
            .accessibilityLabel(Text("删除账号，此操作不可撤销"))
        } footer: {
            Text(Self.localDataNotice)
        }
    }
}

private struct AccountDeletionReauthenticationView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authStore: AuthStore
    @ObservedObject var controller: AccountDeletionController
    let onVerified: () -> Void

    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("为了保护你的账号，请重新验证身份后再继续删除。")
                }

                Section("密码") {
                    SecureField("输入当前密码", text: $password)
                        .textContentType(.password)
                        .accessibilityLabel(Text("当前密码"))
                }

                if let message = controller.errorMessage {
                    Section { Text(message).foregroundStyle(.red) }
                }

                Section {
                    Button {
                        Task {
                            let verified = await controller.reauthenticateForDeletion(
                                password: password,
                                authStore: authStore
                            )
                            password = ""
                            if verified {
                                onVerified()
                                dismiss()
                            }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if controller.isReauthenticating { ProgressView() }
                            else { Text("重新验证") }
                            Spacer()
                        }
                    }
                    .disabled(password.isEmpty || controller.isReauthenticating)
                    .accessibilityLabel(Text("重新验证身份"))
                }
            }
            .navigationTitle("验证身份")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onDisappear { password = "" }
        }
    }
}

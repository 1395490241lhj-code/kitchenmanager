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
    @State private var selectedHouseholdIdForTransfer: UUID?
    @State private var selectedNewOwner: TransferCandidate?

    private var requiresTypedConfirmation: Bool { confirmationText == "DELETE" }

    var body: some View {
        Form {
            Section {
                Text("删除账号会永久移除你的登录身份，与「退出登录」不同——退出登录不会删除任何数据，仍可随时重新登录。")
            } header: {
                Text("这与退出登录不同")
            }

            if controller.isLoadingPreview {
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
        .task { await controller.loadPreview(authStore: authStore) }
        .onChange(of: controller.didComplete) { _, completed in
            if completed { dismiss() }
        }
        .alert("此操作不可撤销", isPresented: $showIrreversibleAlert) {
            Button("取消", role: .cancel) {}
            Button("确认删除", role: .destructive) {
                Task { await controller.confirmDeletion(authStore: authStore, kitchenStore: kitchenStore) }
            }
        } message: {
            Text("删除后，你的账号身份、家庭成员关系与同步记录将被永久移除或匿名化，且无法恢复。")
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
                Text(AccountDeletionError(code: blockingReason).localizedDescription ?? "")
                    .foregroundStyle(.red)
                    .accessibilityLabel(Text("删除受阻：\(AccountDeletionError(code: blockingReason).localizedDescription ?? "")"))
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
            Text("删除完成后会自动退出登录，本机可继续以游客模式使用。")
        }
    }
}

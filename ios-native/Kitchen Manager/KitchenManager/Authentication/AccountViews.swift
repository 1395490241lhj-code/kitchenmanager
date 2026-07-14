import SwiftUI

struct AuthEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authStore: AuthStore
    @StateObject private var form = AuthFormModel()

    var body: some View {
        Form {
            Section {
                Picker("方式", selection: $form.mode) {
                    ForEach(AuthFormMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.segmented)
                .onChange(of: form.mode) { _, _ in form.resetMessages() }
            }

            Section("账号") {
                TextField("邮箱", text: $form.email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码", text: $form.password)
                if form.mode == .signUp {
                    SecureField("再次输入密码", text: $form.passwordConfirmation)
                }
            }

            if let message = form.validationMessage ?? authStore.errorMessage {
                Section { Text(message).foregroundStyle(.red) }
            }
            if let email = authStore.confirmationEmail {
                Section("检查邮箱") {
                    Text("确认邮件已发送至 \(email)。完成确认后即可登录。")
                }
            }

            Section {
                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        Spacer()
                        if authStore.activity == .submitting { ProgressView() }
                        else { Text(form.mode.title) }
                        Spacer()
                    }
                }
                .disabled(authStore.activity == .submitting)
            } footer: {
                Text("登录只用于账号身份。当前库存、计划和菜谱仍保存在本机，不会自动上传。")
            }
        }
        .navigationTitle(form.mode.title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: authStore.status) { _, status in
            if case .signedIn = status { dismiss() }
        }
    }

    private func submit() async {
        guard form.validate() else { return }
        if form.mode == .signIn {
            _ = await authStore.signIn(email: form.normalizedEmail, password: form.password)
        } else {
            _ = await authStore.signUp(email: form.normalizedEmail, password: form.password)
        }
    }
}

struct AccountView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authStore: AuthStore
    @EnvironmentObject private var kitchenStore: KitchenStore
    @EnvironmentObject private var recipeStore: RecipeStore
    @EnvironmentObject private var guestMergeController: GuestMergeController
    @State private var isConfirmingSignOut = false

    private var defaultHousehold: AccountHousehold? {
        authStore.account?.households.first(where: { $0.role == "owner" })
            ?? authStore.account?.households.first
    }

    var body: some View {
        Form {
            if case .signedIn(let user) = authStore.status {
                Section("账号") {
                    LabeledContent("邮箱", value: authStore.account?.user.email ?? user.email ?? "未提供")
                    if let name = authStore.account?.user.displayName, !name.isEmpty {
                        LabeledContent("名称", value: name)
                    }
                }

                Section("家庭") {
                    if let households = authStore.account?.households, !households.isEmpty {
                        ForEach(households) { household in
                            LabeledContent(household.name, value: household.roleTitle)
                        }
                    } else if let message = authStore.accountMessage {
                        Text(message).foregroundStyle(.secondary)
                        Button("重试") { Task { await authStore.refreshAccount() } }
                    } else {
                        ProgressView("正在读取账号资料…")
                    }
                }

                if let userId = authStore.currentUserID, let household = defaultHousehold {
                    GuestMergePromptView(
                        controller: guestMergeController,
                        userId: userId,
                        householdId: household.id,
                        householdName: household.name,
                        kitchenStore: kitchenStore
                    )
                    InventorySyncStatusView(controller: guestMergeController, householdId: household.id)
                }

                Section {
                    Button("退出登录", role: .destructive) { isConfirmingSignOut = true }
                } footer: {
                    Text("退出登录不会删除本机的库存、计划、购物清单或菜谱。")
                }

                InventorySyncDiagnosticsEntryView(
                    controller: guestMergeController, kitchenStore: kitchenStore,
                    userId: authStore.currentUserID, householdId: defaultHousehold?.id
                )
            }
        }
        .navigationTitle("账号")
        .navigationBarTitleDisplayMode(.inline)
        .alert("退出登录？", isPresented: $isConfirmingSignOut) {
            Button("退出", role: .destructive) { Task { await authStore.signOut() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("本机厨房数据会保留，并继续支持游客模式。")
        }
        .onChange(of: authStore.status) { _, status in
            if status == .guest { dismiss() }
        }
        .task {
            guestMergeController.detect(kitchenStore: kitchenStore, recipeStore: recipeStore)
        }
    }
}

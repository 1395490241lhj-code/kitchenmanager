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
    @EnvironmentObject private var accountDeletionController: AccountDeletionController
    @State private var isConfirmingSignOut = false

    private var defaultHousehold: AccountHousehold? {
        authStore.account?.households.first(where: { $0.role == "owner" })
            ?? authStore.account?.households.first
    }

    var body: some View {
        Form {
            if case .signedIn(let user) = authStore.status {
                Section("账号") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(authStore.account?.user.displayName ?? "已登录账号")
                            .font(.headline)
                        Text(authStore.account?.user.email ?? user.email ?? "未提供")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("account.identity.summary")

                    if let message = authStore.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("account.auth.error")
                    }
                }

                Section("家庭") {
                    if fixtureKeepsAccountLoading {
                        ProgressView("正在读取账号资料…")
                            .accessibilityIdentifier("account.household.loading")
                    } else if let households = authStore.account?.households, !households.isEmpty {
                        ForEach(households) { household in
                            LabeledContent {
                                Text(household.roleTitle)
                                    .foregroundStyle(.secondary)
                            } label: {
                                Label(household.name, systemImage: "person.2")
                            }
                            .accessibilityIdentifier("account.household.\(household.id.uuidString)")
                        }
                    } else if let message = authStore.accountMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("account.household.error")
                        Button("重试") { Task { await authStore.refreshAccount() } }
                            .frame(minHeight: 44)
                    } else {
                        ProgressView("正在读取账号资料…")
                            .accessibilityIdentifier("account.household.loading")
                    }
                }

                #if DEBUG
                if let fixture = AccountLifecycleFixture.active {
                    fixtureSyncSection(fixture)
                } else {
                    liveSyncAndMergeSections
                }
                #else
                liveSyncAndMergeSections
                #endif

                Section {
                    Button("退出登录", role: .destructive) { isConfirmingSignOut = true }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("account.signout.button")
                } footer: {
                    Text("退出登录不会删除本机的库存、计划、购物清单或菜谱。")
                }

                Section {
                    NavigationLink("删除账号") {
                        AccountDeletionView(controller: accountDeletionController)
                    }
                    .accessibilityIdentifier("account.delete.link")
                } footer: {
                    Text("永久删除你的登录身份，与退出登录不同。")
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 72)
        }
        .task(id: authStore.currentUserID) {
            guestMergeController.detect(kitchenStore: kitchenStore, recipeStore: recipeStore)
        }
    }

    @ViewBuilder
    private var liveSyncAndMergeSections: some View {
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
    }

    private var fixtureKeepsAccountLoading: Bool {
        #if DEBUG
        return AccountLifecycleFixture.active == .loading
        #else
        return false
        #endif
    }

    #if DEBUG
    private func fixtureSyncSection(_ fixture: AccountLifecycleFixture) -> some View {
        Section("库存同步") {
            InventorySyncStatusSectionContent(
                presentation: InventorySyncPresentation.make(
                    state: fixture.syncPresentationState,
                    detail: fixture.syncDetail
                ),
                onAction: fixture.syncPresentationState.isActionSafeForFixture ? {} : nil
            )
            if fixture == .owner,
               let userId = authStore.currentUserID,
               let household = defaultHousehold {
                NavigationLink("查看库存合并") {
                    InventoryMergeFlowView(
                        controller: guestMergeController,
                        userId: userId,
                        householdId: household.id,
                        householdName: household.name,
                        kitchenStore: kitchenStore
                    )
                }
                .accessibilityIdentifier("account.merge.link")
            }
            Text("测试状态仅展示界面，不会连接网络或修改同步数据。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
    #endif
}

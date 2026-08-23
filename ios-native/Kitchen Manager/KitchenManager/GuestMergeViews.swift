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
        TimelineView(.periodic(from: .now, by: 1)) { context in
            InventorySyncStatusSection(
                presentation: presentation(now: context.date),
                onAction: canSyncNow ? { performSync() } : nil
            )
        }
        .task(id: refreshTaskID) {
            await refreshPendingCount()
            await refreshEnrollmentStatus()
        }
    }

    private var refreshTaskID: String {
        let user = authStore.currentUserID?.uuidString ?? "guest"
        let household = householdId?.uuidString ?? "none"
        let status = controller.session?.status.rawValue ?? "none"
        return "\(user):\(household):\(status)"
    }

    private var canSyncNow: Bool {
        controller.isFeatureEnabled && householdId != nil && authStore.currentUserID != nil
    }

    private func presentation(now: Date) -> InventorySyncPresentation {
        let state: InventorySyncPresentationState
        if !controller.isFeatureEnabled {
            state = .featureDisabled
        } else if authStore.currentUserID == nil {
            state = .noHousehold
        } else if householdId == nil {
            state = .noHousehold
        } else if controller.clientUpgradeRequired {
            state = .upgradeRequired
        } else if let retryAfter = controller.rateLimitedRetryAfter {
            state = .rateLimited(retryAfter: retryAfter)
        } else if controller.isSyncing {
            state = .syncing
        } else if enrollmentStatus == .notEnrolled || enrollmentStatus == .mergeRequired {
            state = .notEnrolled
        } else {
            switch controller.lastSyncOutcome {
            case .completed:
                state = (pendingCount ?? 0) > 0 ? .pending(count: pendingCount ?? 0) : .completed
            case .paused(let error) where error == .notAuthenticated:
                state = .error
            case .paused:
                state = .offline
            case .failed:
                state = .error
            case .disabled, .none:
                state = (pendingCount ?? 0) > 0 ? .pending(count: pendingCount ?? 0) : .idle
            case .alreadyRunning:
                state = .syncing
            }
        }

        return InventorySyncPresentation.make(
            state: state,
            now: now,
            detail: controller.lastSyncErrorMessage ?? controller.inventoryMutationBlockedMessage
        )
    }

    private func performSync() {
        guard let householdId else { return }
        Task {
            await controller.syncNow(authStore: authStore, householdId: householdId)
            await refreshPendingCount()
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

/// Shared presentation shell used by the live status view and the DEBUG-only
/// account fixture. The action closure is injected so fixture buttons are safe
/// local no-ops and can never call a real sync path.
struct InventorySyncStatusSection: View {
    let presentation: InventorySyncPresentation
    let onAction: (() -> Void)?

    var body: some View {
        Section {
            InventorySyncStatusSectionContent(presentation: presentation, onAction: onAction)
        } header: {
            Text("库存同步")
        } footer: {
            Text("只同步库存；购物清单、计划和菜谱不受影响。不会自动同步——只有点击同步按钮才会联网。")
        }
    }
}

struct InventorySyncStatusSectionContent: View {
    let presentation: InventorySyncPresentation
    let onAction: (() -> Void)?

    var body: some View {
        Group {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.title)
                        .font(.body.weight(.semibold))
                        .accessibilityIdentifier("account.sync.status")
                    Text(presentation.message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: presentation.systemImage)
                    .foregroundStyle(presentation.state.isErrorLike ? .orange : .secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(presentation.title)，\(presentation.message)")

            if let pendingCount = presentation.pendingCount {
                LabeledContent("待同步", value: "\(pendingCount) 项")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("inventorySyncPendingCount")
            }

            if let detail = presentation.detail {
                Label(detail, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("account.sync.error")
            }

            if let actionTitle = presentation.actionTitle, let onAction {
                Button(actionTitle, action: onAction)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .buttonStyle(.bordered)
                    .disabled(!presentation.actionEnabled)
                    .accessibilityIdentifier("inventorySyncNowButton")
            }
        }
    }
}

private extension InventorySyncPresentationState {
    var isErrorLike: Bool {
        switch self {
        case .offline, .error, .rateLimited, .upgradeRequired: true
        default: false
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
    let householdName: String
    let kitchenStore: KitchenStore
    @EnvironmentObject private var authStore: AuthStore
    @Environment(\.dismiss) private var dismiss
    @State private var didFinishPreviewRequest = false
    @State private var previewAttempt = 0

    var body: some View {
        Group {
            if !didFinishPreviewRequest {
                InventoryMergeProgressView(message: "正在准备合并预览…")
            // A failed remote read takes precedence over everything else —
            // including an existing session — since neither "no mergeable
            // inventory" nor a possibly-stale prior plan may safely be shown
            // in its place; the household's real cloud state is unknown.
            } else if let fetchFailure = controller.previewFetchFailureMessage {
                InventoryMergePreviewFetchFailureView(message: fetchFailure) {
                    retryPreview()
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
        // The merge flow is a focused decision surface. From the account page it is
        // *pushed* onto that tab's own NavigationStack rather than presented
        // modally, so without this the floating tab bar stays on screen and
        // overlaps the confirm/cancel area — at Accessibility sizes the minimized
        // "我的" pill sat directly on top of the planned-item counts, and the
        // confirm button rendered behind the bar.
        //
        // Applied once at the body root so it covers every state this view can
        // show (loading, empty remote, counts, fetch error, unauthorized, offline,
        // retry, legacy regenerated, conflict, and the defer/cancel exits) instead
        // of being opted into per branch. SwiftUI scopes it to this destination, so
        // the tab bar comes back on its own when the flow is popped or dismissed —
        // no route-level state, no dependence on scroll position or the tab bar's
        // minimize behavior, and the bottom system safe area is left intact.
        .toolbarVisibility(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("稍后处理") { dismiss() }
                    .accessibilityIdentifier("guestMergeDismissLater")
            }
        }
        .task(id: previewTaskID) {
            await controller.preparePreview(
                userId: userId,
                householdId: householdId,
                kitchenStore: kitchenStore,
                authStore: authStore
            )
            didFinishPreviewRequest = true
        }
    }

    private var previewRequestID: String {
        "\(userId.uuidString):\(householdId.uuidString)"
    }

    private var previewTaskID: String {
        "\(previewRequestID):\(previewAttempt)"
    }

    private func retryPreview() {
        didFinishPreviewRequest = false
        previewAttempt += 1
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

    /// UI-5B2B-B2A: all counts and copy come from the pure presentation mapping,
    /// never from the plan's own aggregates, so `readyToUpload`/`confirmMerge`
    /// keep their exact prior meaning.
    private var summary: InventoryMergeSummaryPresentation? {
        plan.map(InventoryMergeSummaryPresentation.make)
    }
    private var reasonRows: [InventoryMergeConflictReasonPresentation] {
        plan.map(InventoryMergeConflictReasonPresentation.make) ?? []
    }
    private var editingAvailability: InventoryMergeChoiceEditingAvailability {
        InventoryMergeChoiceEditingAvailability.make(session: controller.session)
    }
    private var confirmation: InventoryMergeConfirmationPresentation? {
        summary.map { InventoryMergeConfirmationPresentation.make(summary: $0, session: controller.session) }
    }

    private var failureMessage: String? {
        guard controller.session?.status == .failed else { return nil }
        return controller.lastErrorMessage ?? userFacingErrorMessage(for: controller.session?.lastErrorCode)
    }

    var body: some View {
        Form {
            if let error = failureMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
            if controller.clientUpgradeRequired {
                Section {
                    Text("当前版本过旧，更新后才能继续使用家庭同步。")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("guestMergeUpgradeRequiredMessage")
                } footer: {
                    Text("本机库存不受影响，可以继续离线使用；确认合并需要先更新 App。")
                }
            }
            Section("预计结果") {
                LabeledContent("合并目标", value: householdName)
                LabeledContent("本地库存", value: "\(plan?.sourceCount ?? 0) 条")
                LabeledContent("家庭云端库存", value: "\(plan?.knownRemoteItemCount ?? 0) 条")
                // 计划 rather than 将: once this session has partially confirmed,
                // the plan still lists candidates it already uploaded, and no
                // per-item upload state exists to separate them. See
                // `InventoryMergeReviewFooterPresentation`.
                LabeledContent("计划新增", value: "\(summary?.willCreate ?? 0) 条")
                    .accessibilityIdentifier("guestMergeSummaryWillCreate")
                LabeledContent("计划更新", value: "\(summary?.willUpdate ?? 0) 条")
                    .accessibilityIdentifier("guestMergeSummaryWillUpdate")
                // Zero-count secondary rows stay hidden, except 仍待处理, which is
                // always shown once anything still needs a decision.
                if let summary, summary.keptRemote > 0 {
                    LabeledContent("保留家庭（不上传）", value: "\(summary.keptRemote) 条")
                        .accessibilityIdentifier("guestMergeSummaryKeptRemote")
                }
                if let summary, summary.skippedThisTime > 0 {
                    LabeledContent("本次跳过", value: "\(summary.skippedThisTime) 条")
                        .accessibilityIdentifier("guestMergeSummarySkipped")
                }
                if let summary, summary.stillNeedsDecision > 0 {
                    LabeledContent("仍待处理", value: "\(summary.stillNeedsDecision) 条")
                        .accessibilityIdentifier("guestMergeSummaryStillNeedsDecision")
                }
                LabeledContent("完全一致（无需处理）", value: "\(summary?.nothingToDo ?? 0) 条")
                    .accessibilityIdentifier("guestMergeSummaryNothingToDo")
            }
            if !reasonRows.isEmpty {
                Section("需要处理的冲突") {
                    // Unresolved only. The plan's own `quantityConflicts`-style
                    // properties match on `conflictReason` alone, so a
                    // partly-resolved plan previously reported more outstanding
                    // work here than actually remained.
                    ForEach(reasonRows, id: \.reason) { row in
                        LabeledContent(row.title, value: "\(row.count) 条")
                            .accessibilityIdentifier("guestMergeConflictReason-\(row.reason.rawValue)")
                    }
                }
            }
            // UI-5B2B-B2B: the only production route to the conflict screen used
            // to be the `.conflict` flow root, which `confirmMerge` alone can
            // produce. Before a first confirm every `userChoice` was therefore
            // nil, 查看处理结果 never appeared, and choices could not be made —
            // let alone reviewed or edited — until after an upload had already
            // happened. This link is that missing entry point. It only navigates:
            // no confirm, no status change, no network.
            if let summary, summary.stillNeedsDecision > 0, editingAvailability.isEditable {
                Section {
                    NavigationLink {
                        InventoryMergeConflictView(controller: controller, mode: .preConfirmNavigation)
                    } label: {
                        LabeledContent("确认前处理冲突", value: "\(summary.stillNeedsDecision) 条待处理")
                    }
                    .accessibilityIdentifier("guestMergePreConfirmConflictLink")
                } footer: {
                    Text("可以在确认合并前先选择处理方式，也可以先合并其他没有冲突的条目。")
                }
            }
            if let summary, summary.resolvedCount > 0 {
                Section {
                    NavigationLink {
                        InventoryMergeResolvedReviewView(controller: controller)
                    } label: {
                        LabeledContent("查看处理结果", value: summary.resolvedSummaryText)
                    }
                    .accessibilityIdentifier("guestMergeResolvedReviewLink")
                } footer: {
                    Text("仅供查看，不在此修改。")
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
                    Text(controller.session?.status == .failed ? "重试合并" : (confirmation?.buttonTitle ?? "确认合并库存"))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                // Unchanged: still enabled while conflicts remain — that is the
                // existing partial-merge path, and this phase only rewords it.
                .disabled(controller.isBusy || plan == nil || controller.clientUpgradeRequired)
                .accessibilityIdentifier("guestMergeConfirmButton")

                if let confirmation {
                    Text(confirmation.supportingCopy)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("guestMergeConfirmSupportingCopy")
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
        // No bottom spacer: the floating tab bar is now hidden for the whole merge
        // flow (`toolbarVisibility(.hidden, for: .tabBar)` on the flow root), so the
        // confirmation copy needs only the system safe area. The 260pt inset that
        // previously stood in for this left a large dead gap and masked the real
        // obstruction rather than removing it.
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

/// Title plus plain-language consequence for one conflict choice.
///
/// Pure value mapping, deliberately free of SwiftUI and of any controller or
/// plan reference, so it can be unit-tested directly and cannot mutate the
/// candidate or the plan. Wording avoids fork / hash / remote ID / mutation /
/// snapshot: it describes the outcome in the user's own terms.
nonisolated struct InventoryMergeConflictChoicePresentation: Equatable {
    let choice: InventoryMergeConflictChoice
    let title: String
    let consequence: String

    /// Fixed display order, independent of the enum's declaration order.
    static let orderedChoices: [InventoryMergeConflictChoice] = [.keepLocal, .keepRemote, .keepBoth, .skip]

    /// - Parameter isSameRemoteRecord: true when this candidate matched one
    ///   definite existing family record (same stable id). It changes what
    ///   `keepLocal` and `keepBoth` actually do, so it changes the copy.
    static func make(
        choice: InventoryMergeConflictChoice,
        isSameRemoteRecord: Bool
    ) -> InventoryMergeConflictChoicePresentation {
        switch choice {
        case .keepLocal:
            return .init(
                choice: choice,
                title: "保留本机",
                consequence: isSameRemoteRecord
                    ? "用本机的内容更新家庭库存里的同一条记录，家庭原来的内容会被替换。"
                    : "把本机这条新增到家庭库存，家庭现有的记录保持不变。"
            )
        case .keepRemote:
            return .init(
                choice: choice,
                title: "保留家庭",
                consequence: "家庭库存里的记录保持不变，本机这条的不同内容本次不会上传。"
            )
        case .keepBoth:
            return .init(
                choice: choice,
                title: "两条都保留",
                consequence: isSameRemoteRecord
                    ? "家庭库存里已有这条记录，会为本机这条单独新增一份，不会覆盖家庭原有的记录。"
                    : "把本机这条作为另一条记录加入家庭库存，两条都会保留。"
            )
        case .skip:
            return .init(
                choice: choice,
                title: "本次跳过",
                consequence: "本次合并不会上传这条，家庭库存和本机库存都保持现在的样子。"
            )
        }
    }
}

/// One full-width, tappable choice row. No fixed height, so the title and the
/// consequence both wrap freely at Accessibility sizes.
private struct InventoryMergeConflictChoiceRow: View {
    let presentation: InventoryMergeConflictChoicePresentation
    let isSelected: Bool
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation.title)
                        .foregroundStyle(.primary)
                    Text(presentation.consequence)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        // One element reading title, consequence and selected state, with the
        // native single-select semantics VoiceOver already understands.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(presentation.title)。\(presentation.consequence)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// How the conflict screen was reached. This is presentation only — it never
/// fakes or changes `session.status`, and both modes call the same guarded
/// `resolveConflict`.
enum InventoryMergeConflictPresentationMode {
    /// The flow root for a `.conflict` session: `confirmMerge` uploaded what it
    /// could and parked the leftovers here. Resolving the last one flips the
    /// status back to `.previewReady` and the root swaps to the preview by
    /// itself — the pre-existing UI-5B2B-B1 behavior, unchanged.
    case postPartialRoot
    /// Pushed from the preview before any confirm, so the user can decide
    /// conflicts up front. The session stays `.previewReady`, nothing
    /// auto-returns, and the user navigates back when they choose.
    case preConfirmNavigation
}

struct InventoryMergeConflictView: View {
    @ObservedObject var controller: GuestMergeController
    var mode: InventoryMergeConflictPresentationMode = .postPartialRoot
    /// Ids whose `resolveConflict` call is still in flight. Purely transient: it
    /// exists only so one tap cannot start two overlapping resolves, and is
    /// never consulted to decide which option appears selected.
    @State private var inFlight: Set<UUID> = []

    private var conflicts: [InventoryMergeCandidate] { controller.plan?.conflicts ?? [] }

    var body: some View {
        Form {
            if mode == .preConfirmNavigation && conflicts.isEmpty {
                // Pushed destinations are not swapped out by the flow root, so
                // this screen has to say for itself when there is nothing left.
                Section {
                    Text("待处理冲突已全部选择")
                        .font(.body.weight(.semibold))
                        .accessibilityIdentifier("guestMergePreConfirmAllResolved")
                } footer: {
                    Text("返回上一页即可查看处理结果，或继续确认合并。")
                }
            }
            Section {
                Text("以下条目需要你逐条选择，不会自动覆盖。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                LabeledContent("待处理", value: "\(conflicts.count) 条")
                    .accessibilityIdentifier("guestMergeConflictPendingCount")
            }
            ForEach(conflicts) { candidate in
                Section {
                    // A controller rejection (for example the session status
                    // changed under a screen that was already open) must be
                    // visible here too, never a silent no-op.
                    if let error = controller.conflictChoiceError(for: candidate.localItemId) {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("guestMergeConflictChoiceError-\(candidate.localItemId.uuidString)")
                    }
                    LabeledContent("本机", value: localDescription(for: candidate))
                    LabeledContent("家庭", value: remoteDescription(for: candidate))
                    if let reason = candidate.conflictReason {
                        Text(reasonText(reason))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Vertical single-select rows rather than a segmented control:
                    // four 3–4 character CJK labels in one segmented control
                    // compress or truncate outright at Accessibility sizes, and a
                    // segment has nowhere to carry the per-option consequence text
                    // this screen needs.
                    ForEach(InventoryMergeConflictChoicePresentation.orderedChoices, id: \.self) { choice in
                        InventoryMergeConflictChoiceRow(
                            presentation: InventoryMergeConflictChoicePresentation.make(
                                choice: choice,
                                // Computed here, for copy selection only. It
                                // mirrors the condition `applyingChoice` uses to
                                // decide behavior, but is never fed back into
                                // applyingChoice, readyToUpload, resolveConflict,
                                // confirmMerge, fork-id allocation, or persistence.
                                isSameRemoteRecord: candidate.remoteItemId == candidate.localItemId
                            ),
                            // Selection comes only from the persisted choice.
                            // There is deliberately no fallback value: until the
                            // user picks, `userChoice` is nil and nothing reads as
                            // selected.
                            isSelected: candidate.userChoice == choice,
                            isBusy: inFlight.contains(candidate.localItemId)
                        ) {
                            select(choice, for: candidate)
                        }
                        .accessibilityIdentifier(
                            "guestMergeConflictChoice-\(choice.rawValue)-\(candidate.localItemId.uuidString)"
                        )
                    }
                } header: {
                    Text(candidate.name)
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
        .navigationTitle(mode == .preConfirmNavigation ? "确认前处理冲突" : "处理冲突")
        // Same as the preview screen: the tab bar is hidden for the whole merge
        // flow, so the system safe area is sufficient here too.
    }

    /// One tap, one `resolveConflict`. Data semantics are unchanged: the choice
    /// persists immediately and the row leaves the unresolved list.
    private func select(_ choice: InventoryMergeConflictChoice, for candidate: InventoryMergeCandidate) {
        let id = candidate.localItemId
        guard !inFlight.contains(id) else { return }
        inFlight.insert(id)
        Task {
            await controller.resolveConflict(candidateId: id, choice: choice)
            inFlight.remove(id)
        }
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

/// UI-5B2B-B2A: read-only review of conflicts the user has already decided.
///
/// Strictly a viewer. It takes an immutable plan rather than the controller, so
/// it has no way to call `resolveConflict`, stage anything, or change a choice —
/// re-editing is UI-5B2B-B2B. Unresolved conflicts and non-conflict candidates
/// are not shown at all: the former still belong to the conflict screen, the
/// latter were never decisions.
struct InventoryMergeResolvedReviewView: View {
    /// Observed, not snapshotted: an edit made in the pushed per-candidate
    /// editor has to move the candidate into its new group the moment the user
    /// comes back, and the edit entry has to disappear the moment this session
    /// starts syncing. A captured `InventoryMergePlan` would show stale groups.
    @ObservedObject var controller: GuestMergeController

    private var plan: InventoryMergePlan? { controller.plan }
    private var session: GuestMergeSession? { controller.session }

    private var availability: InventoryMergeChoiceEditingAvailability {
        InventoryMergeChoiceEditingAvailability.make(session: session)
    }
    private var canEdit: Bool { availability.isEditable }

    private var groups: [InventoryMergeCandidateGroupPresentation] {
        plan.map(InventoryMergeCandidateGroupPresentation.make) ?? []
    }
    private var summary: InventoryMergeSummaryPresentation? {
        plan.map(InventoryMergeSummaryPresentation.make)
    }

    var body: some View {
        Form {
            if plan == nil {
                ContentUnavailableView("没有可查看的处理结果", systemImage: "tray")
                    .accessibilityIdentifier("guestMergeReviewUnavailable")
            }
            #if DEBUG
            // UI-test-only trigger so a test can flip this session to
            // "sync started" without leaving the screen, proving the review
            // re-renders read-only live. It is an ordinary visible row, so it is
            // gated twice: the launch argument must ask for it, *and* the screen
            // must still be editable. Once the seam fires, `canEdit` goes false
            // and the row disappears along with the 修改选择 entries — a
            // read-only review therefore never renders it, including in
            // screenshots.
            if canEdit, ProcessInfo.processInfo.arguments.contains("UITEST_ALLOW_SYNC_START_SEAM") {
                Button("uitest.markSyncStarted") {
                    Task { await controller.markSyncStartedForUITesting() }
                }
                .accessibilityIdentifier("uitest.markSyncStarted")
            }
            #endif
            if let summary {
            Section {
                LabeledContent("已处理", value: "\(summary.resolvedCount) 条")
                    .accessibilityIdentifier("guestMergeReviewResolvedCount")
                if summary.skippedThisTime > 0 {
                    LabeledContent("其中本次跳过", value: "\(summary.skippedThisTime) 条")
                        .accessibilityIdentifier("guestMergeReviewSkippedCount")
                }
            } footer: {
                // Never asserts a per-item upload state in either direction: a
                // session that partially confirmed carries a plan mixing
                // already-uploaded choices with newly-decided ones.
                Text(InventoryMergeReviewFooterPresentation.make(session: session).text)
                    .accessibilityIdentifier("guestMergeReviewFooter")
            }
            }
            Section {
                if canEdit {
                    Text("确认合并前可以修改已选择的处理方式")
                        .font(.footnote)
                        .accessibilityIdentifier("guestMergeReviewEditableNotice")
                } else if availability == .readOnlyAfterSyncStarted {
                    Text("此会话已经开始同步，已记录的处理方式仅供查看。")
                        .font(.footnote)
                        .accessibilityIdentifier("guestMergeReviewReadOnlyNotice")
                }
            }
            ForEach(groups) { group in
                Section {
                    DisclosureGroup {
                        ForEach(group.candidates) { candidate in
                            if canEdit {
                                NavigationLink {
                                    InventoryMergeChoiceEditorView(controller: controller, candidateId: candidate.id)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        InventoryMergeResolvedCandidateRow(candidate: candidate)
                                        Text("修改选择")
                                            .font(.footnote.weight(.semibold))
                                    }
                                }
                                .accessibilityIdentifier("guestMergeReviewEdit-\(candidate.id.uuidString)")
                            } else {
                                InventoryMergeResolvedCandidateRow(candidate: candidate)
                            }
                        }
                    } label: {
                        // Combined into one element so the group header reads as a
                        // single "name + count" announcement, and so the identifier
                        // resolves to exactly one element rather than propagating to
                        // both the LabeledContent and its title/value children.
                        LabeledContent(group.title, value: "\(group.count) 条")
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("guestMergeReviewGroup-\(group.group.rawValue)")
                    }
                }
            }
        }
        .navigationTitle("处理结果")
        .navigationBarTitleDisplayMode(.inline)
        // The flow root already hides the tab bar and SwiftUI scopes that to
        // pushed destinations, so this screen inherits it. Asserted by UI tests
        // rather than assumed.
    }

}

/// Per-candidate editor for a choice that was already recorded, reachable only
/// before the first confirm. Reuses the UI-5B2B-B1 choice rows verbatim so the
/// options, consequence copy, and selected-state semantics cannot drift.
///
/// It reads the candidate live from the controller so the selected state
/// reflects what was actually persisted, and it never navigates away on its own.
struct InventoryMergeChoiceEditorView: View {
    @ObservedObject var controller: GuestMergeController
    let candidateId: UUID
    @State private var isBusy = false

    private var candidate: InventoryMergeCandidate? {
        controller.plan?.candidates.first { $0.localItemId == candidateId }
    }
    private var availability: InventoryMergeChoiceEditingAvailability {
        InventoryMergeChoiceEditingAvailability.make(session: controller.session)
    }

    var body: some View {
        Form {
            // Surfaced here, not just held on the controller: a rejected edit
            // must be visible on the screen the user tapped.
            if let error = controller.conflictChoiceError(for: candidateId) {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("guestMergeChoiceEditError")
                }
            }
            if let candidate {
                Section {
                    LabeledContent("本机", value: InventoryMergeResolvedCandidatePresentation.valueText(
                        quantity: candidate.localQuantity, expiry: candidate.localExpiryDate, unit: candidate.unit
                    ))
                    LabeledContent("家庭", value: candidate.remoteQuantity.map {
                        InventoryMergeResolvedCandidatePresentation.valueText(
                            quantity: $0, expiry: candidate.remoteExpiryDate, unit: candidate.unit
                        )
                    } ?? "—")
                    if let reason = candidate.conflictReason {
                        Text(InventoryMergeResolvedCandidatePresentation.reasonText(reason))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(candidate.name)
                }

                Section {
                    ForEach(InventoryMergeConflictChoicePresentation.orderedChoices, id: \.self) { choice in
                        InventoryMergeConflictChoiceRow(
                            presentation: InventoryMergeConflictChoicePresentation.make(
                                choice: choice,
                                isSameRemoteRecord: candidate.remoteItemId == candidate.localItemId
                            ),
                            isSelected: candidate.userChoice == choice,
                            isBusy: isBusy
                        ) {
                            select(choice)
                        }
                        .accessibilityIdentifier("guestMergeEditChoice-\(choice.rawValue)-\(candidateId.uuidString)")
                    }
                } footer: {
                    Text("修改后仍需返回并确认合并才会上传。")
                }

                if availability != .editable {
                    Section {
                        Text("此会话已经开始同步，已记录的处理方式仅供查看。")
                            .font(.footnote)
                    }
                }
            } else {
                // Fail closed: the candidate is looked up live every render, so
                // if the plan is replaced or the candidate disappears there is
                // no stale snapshot to keep writing from.
                ContentUnavailableView("找不到这条记录", systemImage: "questionmark.circle")
                    .accessibilityIdentifier("guestMergeEditUnavailable")
            }
        }
        .navigationTitle("修改选择")
        .navigationBarTitleDisplayMode(.inline)
        // Only on open, and only for *other* candidates: a rejection this screen
        // just produced must survive the controller's own state publish.
        .task(id: candidateId) {
            controller.clearConflictChoiceError(unless: candidateId)
        }
    }

    /// The controller re-checks the same rule and is the final boundary; this
    /// view stays put either way, so a rejected edit simply leaves the selected
    /// state unchanged.
    private func select(_ choice: InventoryMergeConflictChoice) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            await controller.resolveConflict(candidateId: candidateId, choice: choice)
            isBusy = false
        }
    }
}

/// One resolved candidate, presentation only. Selection is conveyed by text —
/// the recorded choice is named outright — never by colour alone.
private struct InventoryMergeResolvedCandidateRow: View {
    let candidate: InventoryMergeResolvedCandidatePresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(candidate.name)
                .font(.subheadline.weight(.semibold))
            Text("当前选择：\(candidate.choiceTitle)")
                .font(.footnote)
            Text(candidate.consequence)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("本机 \(candidate.localValue) · 家庭 \(candidate.remoteValue)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("guestMergeReviewCandidate-\(candidate.id.uuidString)")
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
                            .disabled(controller.isBusy || controller.clientUpgradeRequired)
                            .accessibilityIdentifier("guestMergeRollbackButton")
                    } footer: {
                        Text(controller.clientUpgradeRequired
                            ? "当前版本过旧，更新 App 后才能回滚。"
                            : "只回滚本次新增的记录，不影响合并前已存在的家庭库存或本机库存。")
                    }
                }
                if session.status == .rolledBack {
                    Text("已回滚本次新增的记录。").foregroundStyle(.secondary)
                }
                if let lastErrorMessage = controller.lastErrorMessage {
                    Section {
                        Text(lastErrorMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("guestMergeRollbackErrorMessage")
                    }
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

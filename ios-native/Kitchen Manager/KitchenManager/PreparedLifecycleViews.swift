import SwiftUI

struct PreparedLifecycleEditor: View {
    @EnvironmentObject private var store: KitchenStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PreparedLifecycleFormDraft
    @State private var saveError: PreparedComponentMutationError?
    @State private var hasSaveFailure = false
    @AccessibilityFocusState private var reviewFocused: Bool
    let groupLabel: String
    let onSuccess: (String) -> Void

    init(draft: PreparedLifecycleFormDraft, groupLabel: String, onSuccess: @escaping (String) -> Void) {
        _draft = State(initialValue: draft); self.groupLabel = groupLabel; self.onSuccess = onSuccess
    }
    private var current: PreparedComponent? { store.preparedComponents.first { $0.id == draft.expected.id } }
    private var recordedMass: Int64? {
        guard let grouping = draft.expected.grouping else { return nil }
        return (try? PreparedAllocatedGroup(id: draft.expected.id, sourceID: grouping.source.id, count: draft.expected.portionsRemaining,
            massPerPortionDecigrams: grouping.massPerPortionDecigrams))?.totalMassDecigrams
    }
    private var proposedStatus: String {
        "\(draft.action == .markCooked ? PreparedComponentState.cooked.title : draft.expected.state.title) · 冷藏"
            + (draft.action == .beginThaw ? " · 解冻中" : "")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(draft.expected.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text("\(groupLabel) · \(draft.expected.portionsRemaining)份")
                        .accessibilityIdentifier("prepared.lifecycle.group")
                    if let grouping = draft.expected.grouping, let mass = recordedMass {
                        Text("本组原记录分配 \(PreparedMassInput.grams(mass)) · 每份\(PreparedMassInput.grams(grouping.massPerPortionDecigrams))")
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("prepared.lifecycle.mass")
                        Text("原记\(grouping.source.name)，共\(PreparedMassInput.grams(grouping.source.initialMassDecigrams))、\(grouping.source.initialPortionCount)份。重量不代表做熟后的称重。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text("所选备餐") } footer: {
                    Text(draft.expected.grouping != nil && draft.expected.portionsRemaining > 1
                        ? "操作影响这组的每一份。只处理部分份数时，请先取消并分出整份。"
                        : "操作影响这条记录的全部\(draft.expected.portionsRemaining)份。")
                }
                Section("核对变化") {
                    Text("当前：\(PreparedLifecyclePresentation.status(draft.expected))")
                    Text("确认后：\(proposedStatus)").accessibilityIdentifier("prepared.lifecycle.proposed")
                    ForEach(PreparedLifecyclePresentation.events(draft.expected), id: \.self) { Text($0) }
                    if draft.expected.grouping == nil && draft.expected.lifecycle == nil {
                        Text("首次确认后，状态和存放通过这些操作更改；名称、份数和日期仍可编辑。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("原日期：\(draft.expected.expiryDate.formatted(date: .abbreviated, time: .omitted))")
                    DatePicker("确认后建议吃完", selection: Binding(get: { draft.expiryDate }, set: { draft.selectExpiry($0) }), displayedComponents: .date)
                        .accessibilityIdentifier("prepared.lifecycle.expiry")
                    Toggle(isOn: $draft.expiryReviewed) {
                        Text("我已核对这组的建议吃完日期").fixedSize(horizontal: false, vertical: true)
                            .frame(minHeight: AppTheme.minimumHitTarget)
                    }
                    .accessibilityIdentifier("prepared.lifecycle.review")
                    .accessibilityFocused($reviewFocused)
                } header: { Text("建议吃完日期") } footer: {
                    Text("日期只是记录和安排的参考，不保证食品安全。默认不会延长原日期；请按实际情况核对。解冻不会自动完成。")
                }
                if store.isPreparedComponentUnavailable {
                    PreparedCollectionUnavailableView(identifierPrefix: "prepared.lifecycle")
                }
                if hasSaveFailure && !store.isPreparedComponentUnavailable {
                    Section("本次尚未保存") {
                        Text("操作和日期已保留。未改动的重试沿用本次确认时间。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("重新读取备餐，保留本次填写") {
                            if case .failure(let error) = store.reloadPreparedComponents() { saveError = error }
                        }
                        .frame(minHeight: AppTheme.minimumHitTarget)
                        .accessibilityIdentifier("prepared.lifecycle.reload")
                    }
                }
                if let current, current != draft.expected {
                    Section("记录有更新") {
                        Text("当前：\(current.name)，\(current.portionsRemaining)份，\(PreparedLifecyclePresentation.status(current))")
                            .fixedSize(horizontal: false, vertical: true)
                        Text("当前建议吃完：\(current.expiryDate.formatted(date: .abbreviated, time: .omitted))。重新核对后，需要再次确认日期。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("按当前记录重新核对") { draft.recheck(current); reviewFocused = true }
                            .frame(minHeight: AppTheme.minimumHitTarget)
                            .accessibilityIdentifier("prepared.lifecycle.recheck")
                    }
                } else if current == nil {
                    Text("这组已不存在，不能继续操作。填写内容仍保留。")
                        .accessibilityIdentifier("prepared.lifecycle.missing")
                }
                #if DEBUG
                if PreparedPortionGroupingUIFixture.simulateStaleEdit {
                    Button("模拟其他入口使用一份") { _ = store.consumePreparedPortion(id: draft.expected.id) }
                        .frame(minHeight: AppTheme.minimumHitTarget)
                        .accessibilityIdentifier("prepared.lifecycle.fixture.consume")
                    Button("模拟其他入口移除这组") { _ = store.removePreparedComponent(id: draft.expected.id) }
                        .frame(minHeight: AppTheme.minimumHitTarget)
                        .accessibilityIdentifier("prepared.lifecycle.fixture.remove")
                }
                #endif
            }
            .navigationTitle(draft.action.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Text("取消").frame(minWidth: AppTheme.minimumHitTarget, minHeight: AppTheme.minimumHitTarget)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("prepared.lifecycle.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { confirm() } label: {
                        Text("确认").frame(minWidth: AppTheme.minimumHitTarget, minHeight: AppTheme.minimumHitTarget)
                            .contentShape(Rectangle())
                    }
                        .buttonStyle(.plain)
                        .disabled(!draft.expiryReviewed || store.isPreparedComponentUnavailable || current == nil
                            || !PreparedLifecyclePresentation.actions(for: draft.expected).contains(draft.action))
                        .accessibilityLabel("确认\(draft.action.title)，\(draft.expected.name)，\(groupLabel)，\(draft.expected.portionsRemaining)份")
                        .accessibilityIdentifier("prepared.lifecycle.confirm")
                }
            }
            .preparedFailureAlert($saveError)
        }
    }
    private func confirm() {
        let intent: PreparedLifecycleIntent
        do { intent = try draft.makeReviewedIntent(at: Date(), calendar: .current) }
        catch {
            saveError = (error as? PreparedLifecycleError) == .invalidExpiryReview ? .expiryReviewRequired : .invalidTransition
            reviewFocused = true; return
        }
        switch store.transitionPreparedComponent(id: draft.expected.id, expected: draft.expected, intent: intent) {
        case .success:
            onSuccess("\(draft.expected.name) · \(groupLabel)：\(draft.action.title)"); dismiss()
        case .failure(let error): hasSaveFailure = true; saveError = error
        }
    }
}

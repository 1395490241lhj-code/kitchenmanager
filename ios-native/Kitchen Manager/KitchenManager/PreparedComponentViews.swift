import SwiftUI

/// Prepared stays separate from Inventory; sections are projections of live group UUIDs.
struct PreparedComponentsView: View {
    @EnvironmentObject private var store: KitchenStore
    @State private var editing: PreparedComponent?
    @State private var splitting: PreparedComponent?
    @State private var lifecycleDraft: PreparedLifecycleFormDraft?
    @State private var isAdding = false
    @State private var isAssembling = false
    @State private var toastMessage: String?
    @State private var operationError: PreparedComponentMutationError?

    private var sections: Result<[PreparedSourceSection], Error> {
        Result { try PreparedSourceSection.make(store.preparedComponents) }
    }
    var body: some View {
        List {
            Section {
                Button("搭配一顿") { isAssembling = true }
                    .font(.subheadline.weight(.medium)).foregroundStyle(AppTheme.brand)
                    .frame(minHeight: ChromeMetrics.minimumRowHeight)
                    .accessibilityIdentifier("prepared.assemble")
                    .accessibilityHint("用现有食材配一份主食、蛋白和蔬菜")
            }
            if store.isPreparedComponentUnavailable {
                PreparedCollectionUnavailableView(identifierPrefix: "prepared")
            } else {
                switch sections {
                case .failure:
                    PreparedCollectionUnavailableView(identifierPrefix: "prepared")
                case .success(let sections):
                    if sections.isEmpty {
                        ContentUnavailableView("还没有备餐", systemImage: "takeoutbag.and.cup.and.straw",
                            description: Text("提前做好或腌好的菜可以记在这里，每次取用一份。"))
                    }
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.components) { component in
                                PreparedGroupedRow(component: component, groupLabel: section.groupLabel(for: component),
                                    onEdit: { editing = component }, onConsume: { consume(component) },
                                    onSplit: { splitting = component },
                                    onLifecycle: { lifecycleDraft = PreparedLifecycleFormDraft(expected: component, action: $0) })
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) { remove(id: component.id) } label: {
                                        Text(component.grouping == nil ? "删除" : "删除这组")
                                    }
                                    .accessibilityIdentifier("prepared.delete.\(component.id.uuidString)")
                                    .accessibilityHint("仅移除这条记录，其余分组保留")
                                }
                            }
                        } header: {
                            if section.source != nil { PreparedSourceHeader(section: section) }
                        }
                    }
                }
            }
            if !store.isPreparedComponentUnavailable, let notice = store.preparedComponentNotice {
                Text(notice).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("prepared.notice")
            }
        }
        .navigationTitle("备餐").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("添加备餐", systemImage: "plus") { isAdding = true }
                .frame(minWidth: AppTheme.minimumHitTarget, minHeight: AppTheme.minimumHitTarget)
                .disabled(store.isPreparedComponentUnavailable)
                .accessibilityIdentifier("prepared.add.button")
        }
        .sheet(isPresented: $isAdding) { PreparedComponentEditor(component: nil) }
        .sheet(item: $editing) { PreparedComponentEditor(component: $0) }
        .sheet(item: $splitting) { component in
            PreparedPortionSplitEditor(component: component) { count in showToast("已分出\(count)份，其余份数留在原组") }
        }
        .sheet(isPresented: $isAssembling) { ComponentMealView() }
        .sheet(item: $lifecycleDraft) { draft in
            PreparedLifecycleEditor(draft: draft, groupLabel: groupLabel(for: draft.expected), onSuccess: showToast)
        }
        .preparedFailureAlert($operationError)
        .overlay(alignment: .bottom) {
            if let toastMessage { FeedbackToast(message: toastMessage, style: .success) }
        }
    }
    private func groupLabel(for row: PreparedComponent) -> String {
        guard case .success(let sections) = sections,
              let section = sections.first(where: { $0.components.contains(where: { $0.id == row.id }) }) else { return "所选分组" }
        return section.groupLabel(for: row)
    }
    private func remove(id: UUID) {
        switch store.removePreparedComponent(id: id) {
        case .success: showToast("这条备餐记录已移除")
        case .failure(let error): toastMessage = nil; operationError = error
        }
    }
    private func consume(_ component: PreparedComponent) {
        switch store.consumePreparedPortion(id: component.id) {
        case .success(let previous):
            showToast(PreparedPortionConsumptionFeedback.message(for: previous, context: .preparedList))
        case .failure(let error): toastMessage = nil; operationError = error
        }
    }
    private func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if toastMessage == message { toastMessage = nil }
        }
    }
}

/// A read failure is distinct from an empty collection on every Prepared
/// surface. Reload is non-destructive; a failed retry leaves this state visible.
struct PreparedCollectionUnavailableView: View {
    @EnvironmentObject private var store: KitchenStore
    let identifierPrefix: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("备餐记录暂时无法读取")
                .font(.headline)
                .accessibilityIdentifier("\(identifierPrefix).unavailable")
            Text(store.preparedComponentNotice ?? PreparedComponentMutationError.unavailable.localizedDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                store.reloadPreparedComponents()
            } label: {
                Text("重新读取备餐")
                    .frame(minHeight: AppTheme.minimumHitTarget)
            }
            .accessibilityIdentifier("\(identifierPrefix).reload")
        }
    }
}

// MARK: - Name hint
//
// A batch's roles are inferred from its name — nothing on `PreparedComponent`
// records them, and this phase deliberately did not add a role picker or change
// the schema. When a name places nowhere, the batch is simply invisible to the
// assembling layers, which is silent and confusing. So the editor says so.
//
// It never guesses. An unrecognised name stays unrecognised: letting it stand
// in as a generic finished dish would put a batch into suggestions on the
// strength of nothing at all.

enum PreparedComponentNameHint {
    static let message = "这个名称可能无法用于智能搭配，建议写具体一些，例如「鸡肉」或「卤鸡腿」。"

    /// True when the name places nowhere at all — no role *and* no form. A name
    /// like 剩菜 or 卤味 carries no role either, but its form still lets Quick
    /// Meal use it as a finished dish, so warning about it would be wrong.
    ///
    /// An empty name gets no hint: the save button is already disabled, and a
    /// warning about nothing the user has typed yet would just be noise.
    static func needsHint(for name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let profile = QuickFoodProfileClassifier.profile(for: trimmed)
        return profile.roles.isEmpty && profile.form == nil
    }
}

// MARK: - Editor

private struct PreparedComponentEditor: View {
    @EnvironmentObject private var store: KitchenStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PreparedComponentFormDraft
    @State private var hasEditedExpiry: Bool
    @State private var saveError: PreparedComponentMutationError?
    @State private var hasSaveFailure = false
    private enum Field: Hashable { case name, mass }
    @FocusState private var focusedField: Field?

    init(component: PreparedComponent?) {
        _draft = State(initialValue: PreparedComponentFormDraft(existing: component))
        _hasEditedExpiry = State(initialValue: component != nil)
    }
    private var grouped: PreparedPortionGrouping? { draft.expected?.grouping }
    private var protected: Bool { grouped != nil || draft.expected?.lifecycle != nil }
    private var current: PreparedComponent? {
        guard let id = draft.expected?.id else { return nil }
        return store.preparedComponents.first { $0.id == id }
    }
    var body: some View {
        NavigationStack {
            Form {
                if store.isPreparedComponentUnavailable {
                    PreparedCollectionUnavailableView(identifierPrefix: "prepared.editor")
                }
                if hasSaveFailure && !store.isPreparedComponentUnavailable {
                    Section("本次尚未保存") {
                        Text("填写内容已保留。可以直接重试，或先重新读取备餐后核对。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("重新读取备餐，保留填写内容") {
                            if case .failure(let error) = store.reloadPreparedComponents() { saveError = error }
                        }
                        .frame(minHeight: AppTheme.minimumHitTarget)
                        .accessibilityIdentifier("prepared.editor.reload")
                    }
                }
                Section {
                    TextField("名称", text: $draft.name)
                        .focused($focusedField, equals: .name)
                        .accessibilityIdentifier("prepared.editor.name")
                    if grouped == nil {
                        PreparedPortionCountControl(title: "份数", value: $draft.portions,
                            range: PreparedComponent.portionRange, identifier: "prepared.editor.portions")
                    } else {
                        LabeledContent("本组份数", value: "\(draft.portions)份")
                    }
                    if draft.expected == nil {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("总重量（g，可选）").font(.footnote).foregroundStyle(.secondary)
                            TextField("不填写则按份记录", text: $draft.massText)
                                .keyboardType(.decimalPad).focused($focusedField, equals: .mass)
                                .frame(minHeight: AppTheme.minimumHitTarget)
                                .accessibilityLabel("总重量，克，可选")
                                .accessibilityIdentifier("prepared.editor.mass")
                        }
                    }
                } footer: {
                    if PreparedComponentNameHint.needsHint(for: draft.name) { Text(PreparedComponentNameHint.message).accessibilityIdentifier("prepared.editor.nameHint") }
                }
                if let grouping = grouped {
                    Section("分装记录") {
                        Text("每份\(PreparedMassInput.grams(grouping.massPerPortionDecigrams))")
                        Text("原记\(grouping.source.name)，共\(PreparedMassInput.grams(grouping.source.initialMassDecigrams))、\(grouping.source.initialPortionCount)份")
                        Text("重量和份数按原分装记录保留；可以分出整份。状态和存放通过这组的操作更改。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.accessibilityIdentifier("prepared.editor.protected")
                } else if let allocation = try? draft.allocation() {
                    Section("实际分装") {
                        Text(allocation.groups.map { "\(PreparedMassInput.grams($0.massPerPortionDecigrams)) × \($0.count)份" }.joined(separator: "；"))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("prepared.editor.allocation")
                        Text("合计\(PreparedMassInput.grams(allocation.totalMassDecigrams)) · \(allocation.portionCount)份")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let message = draft.validationMessage, !draft.name.isEmpty || !draft.massText.isEmpty {
                    Text(message).font(.footnote).foregroundStyle(AppTheme.warningInk)
                        .accessibilityIdentifier("prepared.editor.validation")
                }
                Section {
                    if !protected {
                        Picker("状态", selection: $draft.state) {
                            ForEach(PreparedComponentState.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.frame(minHeight: ChromeMetrics.minimumRowHeight).accessibilityIdentifier("prepared.editor.state")
                        Picker("存放", selection: $draft.storage) {
                            ForEach(PreparedStorage.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.frame(minHeight: ChromeMetrics.minimumRowHeight).accessibilityIdentifier("prepared.editor.storage")
                    } else {
                        LabeledContent("状态", value: draft.state.title)
                        LabeledContent("存放", value: draft.storage.title)
                        Text("状态和存放请使用这组的解冻或做熟操作更改。")
                            .font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("prepared.editor.lifecycleProtected")
                    }
                }
                Section {
                    DatePicker("做好时间", selection: $draft.preparedAt, displayedComponents: .date)
                        .accessibilityIdentifier("prepared.editor.preparedAt")
                    DatePicker("建议吃完", selection: $draft.expiryDate, displayedComponents: .date)
                        .accessibilityIdentifier("prepared.editor.expiry")
                } footer: { Text("默认日期只是根据状态和存放方式给的起点，可以按自己的判断修改。") }
                #if DEBUG
                if PreparedPortionGroupingUIFixture.simulateStaleEdit, let expected = draft.expected {
                    Button("模拟其他入口使用一份") { _ = store.consumePreparedPortion(id: expected.id) }
                        .accessibilityIdentifier("prepared.editor.fixture.consume")
                }
                #endif
                if let expected = draft.expected, !store.isPreparedComponentUnavailable {
                    if let current, current != expected {
                        Section("记录有更新") {
                            Text("当前：\(current.name)，剩\(current.portionsRemaining)份，\(current.state.title) · \(current.storage.title)")
                            Text("本次填写的名称和日期已保留，请核对当前记录后重试。")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button("保留填写内容，按当前记录核对") { _ = draft.acceptCurrent(current) }
                                .frame(minHeight: AppTheme.minimumHitTarget)
                                .accessibilityIdentifier("prepared.editor.recheck")
                        }
                    } else if current == nil {
                        Text("这条记录已不存在；本次填写内容仍保留，不能重新添加为旧记录。")
                            .font(.footnote).accessibilityIdentifier("prepared.editor.missing")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(draft.expected == nil ? "添加备餐" : "编辑备餐")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        switch draft.save(in: store) {
                        case .success: dismiss()
                        case .failure(let error): hasSaveFailure = true; saveError = error
                        }
                    }
                    .disabled(draft.validationMessage != nil || store.isPreparedComponentUnavailable)
                    .accessibilityIdentifier("prepared.editor.save")
                }
                ToolbarItem(placement: .keyboard) {
                    Button("完成输入") { focusedField = nil }.accessibilityIdentifier("prepared.editor.keyboardDone")
                }
            }
            .onChange(of: draft.state) { _, _ in refreshSuggestedExpiry() }
            .onChange(of: draft.storage) { _, _ in refreshSuggestedExpiry() }
            .onChange(of: draft.preparedAt) { _, _ in refreshSuggestedExpiry() }
            .onChange(of: draft.expiryDate) { old, new in if old != new { hasEditedExpiry = true } }
            .preparedFailureAlert($saveError)
        }
    }
    private func refreshSuggestedExpiry() {
        guard !hasEditedExpiry else { return }
        draft.expiryDate = PreparedComponentExpirySuggestion.suggestedExpiryDate(
            state: draft.state, storage: draft.storage, preparedAt: draft.preparedAt)
        hasEditedExpiry = false
    }
}

#Preview("备餐列表") {
    NavigationStack { PreparedComponentsView().environmentObject(KitchenStore()) }
}

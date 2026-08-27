import SwiftUI

// MARK: - Prepared components UI (P1-B)
//
// A list of its own, reached from the 食材 tab's existing 更多食材操作 menu.
// Deliberately never mixed into the ingredient list: a batch of 卤鸡腿 is not a
// grocery, and showing them side by side is what would invite the confusion
// between raw stock and finished food that this whole type exists to prevent.
//
// Native and light on purpose — no weekly planning, no charts, no nutrition.

struct PreparedComponentsView: View {
    @EnvironmentObject private var store: KitchenStore
    @State private var editing: PreparedComponent?
    @State private var isAdding = false
    @State private var isAssembling = false
    @State private var toastMessage: String?

    var body: some View {
        List {
            // Component Meal's only entry point. It lives here rather than on
            // Home because a 主食 + 蛋白 + 蔬菜 plate is a meal structure, not a
            // day rhythm — no DayType owns it and Home gains no section for it.
            Section {
                Button("搭配一顿") { isAssembling = true }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.brand)
                    .frame(minHeight: ChromeMetrics.minimumRowHeight)
                    .accessibilityIdentifier("prepared.assemble")
                    .accessibilityHint("用现有食材配一份主食、蛋白和蔬菜")
            }

            if store.preparedComponents.isEmpty {
                ContentUnavailableView(
                    "还没有备餐",
                    systemImage: "takeoutbag.and.cup.and.straw",
                    description: Text("提前做好或腌好的菜可以记在这里，每次取用一份。")
                )
            } else {
                ForEach(store.preparedComponents) { component in
                    Button {
                        editing = component
                    } label: {
                        PreparedComponentRow(component: component) {
                            consume(component)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    for index in offsets {
                        store.removePreparedComponent(id: store.preparedComponents[index].id)
                    }
                }
            }

            if let notice = store.preparedComponentNotice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("prepared.notice")
            }
        }
        .navigationTitle("备餐")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("添加备餐", systemImage: "plus") { isAdding = true }
                .frame(minWidth: AppTheme.minimumHitTarget, minHeight: AppTheme.minimumHitTarget)
                .accessibilityIdentifier("prepared.add.button")
        }
        .sheet(isPresented: $isAdding) {
            PreparedComponentEditor(component: nil)
        }
        .sheet(item: $editing) { component in
            PreparedComponentEditor(component: component)
        }
        .sheet(isPresented: $isAssembling) {
            ComponentMealView()
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                FeedbackToast(message: toastMessage, style: .success)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(height: ChromeMetrics.bottomClearance)
                .accessibilityHidden(true)
        }
    }

    private func consume(_ component: PreparedComponent) {
        guard let previous = store.consumePreparedPortion(id: component.id) else { return }
        // No undo affordance: the app's toast carries a message only, and
        // building an undo stack for this is not worth a first version. The
        // message says plainly what happened instead.
        showToast(
            previous.portionsRemaining > 1
                ? "已吃掉一份，还剩 \(previous.portionsRemaining - 1) 份"
                : "「\(previous.name)」已吃完，记录已移除"
        )
    }

    private func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if toastMessage == message { toastMessage = nil }
        }
    }
}

private struct PreparedComponentRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let component: PreparedComponent
    let onConsume: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(component.name)
                    .font(.headline)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                Spacer(minLength: 8)
                Text(component.portionsText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text("\(component.state.title) · \(component.storage.title) · \(expiryText)")
                .font(.footnote)
                .foregroundStyle(.secondary)

            // The height belongs inside the label. Applied to the Button it
            // leaves the hit target — and the accessibility frame — the size of
            // the text, which measures 18pt; P1-D found the same shape on Home
            // and this row had it too.
            Button(action: onConsume) {
                Text("吃掉一份")
                    .font(.subheadline.weight(.medium))
                    .frame(minHeight: AppTheme.minimumHitTarget)
                    .contentShape(Rectangle())
            }
                .foregroundStyle(AppTheme.brand)
                .buttonStyle(.plain)
                .accessibilityIdentifier("prepared.consume.\(component.id.uuidString)")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(component.name)，\(component.portionsText)，\(component.state.title)，\(component.storage.title)")
    }

    /// Wording stays a plain date. It is the user's own note about when they
    /// mean to finish the batch, not a safety claim the app is in a position
    /// to make.
    private var expiryText: String {
        // Shared with the Home board so both read 8月31日 rather than Aug 31.
        "建议 \(MealPrepBoard.dateText(for: component.expiryDate)) 前吃完"
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

    private let existing: PreparedComponent?
    @State private var name: String
    @State private var portions: Int
    @State private var state: PreparedComponentState
    @State private var storage: PreparedStorage
    @State private var preparedAt: Date
    @State private var expiryDate: Date
    /// Once the user edits the date by hand, changing state or storage stops
    /// overwriting it — their judgement outranks the suggestion.
    @State private var hasEditedExpiry: Bool

    init(component: PreparedComponent?) {
        existing = component
        let now = component?.preparedAt ?? Date()
        let initialState = component?.state ?? .cooked
        let initialStorage = component?.storage ?? .refrigerated
        _name = State(initialValue: component?.name ?? "")
        _portions = State(initialValue: component?.portionsRemaining ?? 4)
        _state = State(initialValue: initialState)
        _storage = State(initialValue: initialStorage)
        _preparedAt = State(initialValue: now)
        _expiryDate = State(initialValue: component?.expiryDate
            ?? PreparedComponentExpirySuggestion.suggestedExpiryDate(
                state: initialState, storage: initialStorage, preparedAt: now
            ))
        _hasEditedExpiry = State(initialValue: component != nil)
    }

    private var isSaveEnabled: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称", text: $name)
                        .accessibilityIdentifier("prepared.editor.name")
                    Stepper(value: $portions, in: PreparedComponent.portionRange) {
                        LabeledContent("份数", value: "\(portions) 份")
                    }
                    .frame(minHeight: ChromeMetrics.minimumRowHeight)
                    .accessibilityIdentifier("prepared.editor.portions")
                } footer: {
                    // Advisory only — saving is never blocked, and no role is
                    // guessed on the user's behalf. A name that places nowhere
                    // simply will not turn up in 快手 or 搭配一顿, and saying so
                    // here is cheaper than leaving them to notice the absence.
                    if PreparedComponentNameHint.needsHint(for: name) {
                        Text(PreparedComponentNameHint.message)
                            .accessibilityIdentifier("prepared.editor.nameHint")
                    }
                }

                Section {
                    Picker("状态", selection: $state) {
                        ForEach(PreparedComponentState.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .frame(minHeight: ChromeMetrics.minimumRowHeight)
                    .accessibilityIdentifier("prepared.editor.state")

                    Picker("存放", selection: $storage) {
                        ForEach(PreparedStorage.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .frame(minHeight: ChromeMetrics.minimumRowHeight)
                    .accessibilityIdentifier("prepared.editor.storage")
                }

                Section {
                    DatePicker("做好时间", selection: $preparedAt, displayedComponents: .date)
                    DatePicker("建议吃完", selection: $expiryDate, displayedComponents: .date)
                        .accessibilityIdentifier("prepared.editor.expiry")
                } footer: {
                    Text("默认日期只是根据状态和存放方式给的起点，可以按自己的判断修改。")
                }
            }
            .navigationTitle(existing == nil ? "添加备餐" : "编辑备餐")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!isSaveEnabled)
                        .accessibilityIdentifier("prepared.editor.save")
                }
            }
            .onChange(of: state) { _, _ in refreshSuggestedExpiry() }
            .onChange(of: storage) { _, _ in refreshSuggestedExpiry() }
            .onChange(of: preparedAt) { _, _ in refreshSuggestedExpiry() }
            .onChange(of: expiryDate) { old, new in
                if old != new { hasEditedExpiry = true }
            }
        }
    }

    private func refreshSuggestedExpiry() {
        guard !hasEditedExpiry else { return }
        let suggested = PreparedComponentExpirySuggestion.suggestedExpiryDate(
            state: state, storage: storage, preparedAt: preparedAt
        )
        // Assigning also fires the expiry onChange, so clear the flag after.
        expiryDate = suggested
        hasEditedExpiry = false
    }

    private func save() {
        let component = PreparedComponent(
            id: existing?.id ?? UUID(),
            name: name,
            portionsRemaining: portions,
            state: state,
            storage: storage,
            preparedAt: preparedAt,
            expiryDate: expiryDate
        )
        if existing == nil {
            store.addPreparedComponent(component)
        } else {
            store.updatePreparedComponent(component)
        }
        dismiss()
    }
}

// MARK: - Previews

#Preview("备餐列表") {
    NavigationStack {
        PreparedComponentsView()
            .environmentObject(KitchenStore())
    }
}

import SwiftUI

// MARK: - Special plan form + recipe picker

struct RecipePickerView: View {
    @EnvironmentObject private var recipeStore: RecipeStore
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    let onSelect: (Recipe) -> Void

    private var recipes: [Recipe] {
        let all = recipeStore.recipesForDisplay
        guard !searchText.isEmpty else { return all }
        return all.filter { recipe in
            recipe.title.localizedCaseInsensitiveContains(searchText)
                || recipe.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
                || (recipe.ingredients + recipe.seasonings).contains {
                    $0.localizedCaseInsensitiveContains(searchText)
                }
        }
    }

    var body: some View {
        List(recipes) { recipe in
            Button {
                onSelect(recipe)
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recipe.title).font(.headline)
                        if let time = recipe.cookingTime {
                            Text("\(time) 分钟")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(AppTheme.brand)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("添加菜品")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索菜名或食材")
    }
}

struct SpecialPlanDraft {
    var title = ""
    var scheduledAt = Date()
    var peopleCount = 2
    var constraintNotes: [String] = []
    var notes = ""
}

enum SpecialPlanFormMode: Identifiable {
    case create
    case edit(SpecialPlan)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let plan): "edit-\(plan.id.uuidString)"
        }
    }
}

/// Create/Edit form sheet. Owns its dismiss via the environment; the parent
/// supplies only the save callback.
struct SpecialPlanFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    let mode: SpecialPlanFormMode
    let onSave: (SpecialPlanDraft) -> Void

    @State private var draft: SpecialPlanDraft
    @State private var constraintText = ""

    init(mode: SpecialPlanFormMode, onSave: @escaping (SpecialPlanDraft) -> Void) {
        self.mode = mode
        self.onSave = onSave
        switch mode {
        case .create:
            _draft = State(initialValue: SpecialPlanDraft())
        case .edit(let plan):
            _draft = State(initialValue: SpecialPlanDraft(
                title: plan.title,
                scheduledAt: plan.scheduledAt,
                peopleCount: plan.peopleCount,
                constraintNotes: plan.constraintNotes,
                notes: plan.notes
            ))
        }
        _constraintText = State(initialValue: (mode.editPlan?.constraintNotes ?? []).joined(separator: "\n"))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("活动名称", text: $draft.title)
                    DatePicker(
                        "日期",
                        selection: $draft.scheduledAt,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    Stepper("\(draft.peopleCount) 人", value: $draft.peopleCount, in: 1...99)
                }
                Section("忌口与注意事项") {
                    TextField(
                        "每行一条，例如：1 人不吃辣",
                        text: $constraintText,
                        axis: .vertical
                    )
                    .lineLimit(2...6)
                }
                Section("备注") {
                    TextField("补充说明", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...6)
                }
            }
            .navigationTitle(mode.isEdit ? "编辑特殊计划" : "新建特殊计划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.constraintNotes = constraintText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        onSave(draft)
        dismiss()
    }
}

extension SpecialPlanFormMode {
    var isEdit: Bool {
        switch self {
        case .create: false
        case .edit: true
        }
    }

    var editPlan: SpecialPlan? {
        switch self {
        case .create: nil
        case .edit(let plan): plan
        }
    }
}

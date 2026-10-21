import SwiftUI

struct EditableRecipeDraft: Equatable {
    var id = "user-ai-\(UUID().uuidString.lowercased())"
    var title = ""
    /// The base yield the finished recipe will carry, or `nil` when nobody has
    /// stated one.
    ///
    /// Deliberately optional: this used to default to `2` and be dropped on
    /// save, which was harmless only because it was discarded. Now that it
    /// reaches `Recipe`, a non-optional default would turn "nobody said" into
    /// "the recipe serves 2" for every AI, imported and legacy draft.
    var baseServings: Int?
    var cookingTime: Int?
    var difficulty = ""
    var tagsText = ""
    var ingredientsText = ""
    var seasoningsText = ""
    var stepsText = ""
    var tipsText = ""
    var source: RecipeSourceMetadata?

    var isSaveEligible: Bool { (try? makeRecipe()) != nil }

    func makeRecipe() throws -> Recipe {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            throw RecipeDraftValidationError.missingTitle
        }

        let ingredients = Self.nonEmptyLines(ingredientsText)
        let seasonings = Self.nonEmptyLines(seasoningsText)
        let steps = Self.nonEmptyLines(stepsText)
            .map(Self.cleanStep)
            .filter { !$0.isEmpty }
        let tips = Self.nonEmptyLines(tipsText).map { tip in
            tip.hasPrefix("小贴士：") ? tip : "小贴士：\(tip)"
        }

        guard !ingredients.isEmpty else {
            throw RecipeDraftValidationError.missingIngredients
        }
        guard !steps.isEmpty else {
            throw RecipeDraftValidationError.missingSteps
        }

        return Recipe(
            id: id,
            title: cleanTitle,
            cookingTime: cookingTime.flatMap { $0 > 0 ? $0 : nil },
            difficulty: difficulty.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            tags: Self.uniqueTags(tagsText),
            ingredients: ingredients,
            seasonings: seasonings,
            steps: steps + tips,
            baseServings: baseServings,
            source: source
        )
    }

    nonisolated static func nonEmptyLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    nonisolated static func uniqueTags(_ text: String) -> [String] {
        var seen = Set<String>()
        return text
            .components(separatedBy: CharacterSet(charactersIn: ",，、\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    nonisolated static func cleanStep(_ step: String) -> String {
        step
            .replacingOccurrences(
                of: #"^\s*(?:(?:\d+\s*[\.、\)）:：])|(?:第[一二三四五六七八九十\d]+步[:：]?)|(?:[一二三四五六七八九十]+、))\s*"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum RecipeDraftValidationError: LocalizedError {
    case missingTitle
    case missingIngredients
    case missingSteps

    var errorDescription: String? {
        switch self {
        case .missingTitle:
            return "请先填写菜名。"
        case .missingIngredients:
            return "请至少保留一种食材。"
        case .missingSteps:
            return "请至少保留一个制作步骤。"
        }
    }
}

struct RecipeDraftEditorSections: View {
    @Binding var draft: EditableRecipeDraft
    var showsExtendedFields = false

    /// Base yield has three states, not two: a stated number, "not stated", and
    /// the act of stating one. A bare Stepper can only express a number, so
    /// opening a legacy recipe would silently invent a yield just by rendering.
    /// The opt-in row keeps "未标注" a real, preserved answer.
    @ViewBuilder
    private var baseServingsControl: some View {
        if let baseServings = draft.baseServings {
            Stepper(
                "基准份量：\(baseServings) 人份",
                value: Binding(
                    get: { baseServings },
                    set: { draft.baseServings = $0 }
                ),
                in: Recipe.validBaseServings
            )
            .accessibilityIdentifier("recipe.draft.baseServings.stepper")
            Button("清除基准份量") { draft.baseServings = nil }
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("recipe.draft.baseServings.clear")
        } else {
            HStack {
                Text("基准份量")
                Spacer()
                Text("未标注").foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("recipe.draft.baseServings.unset")
            // 2 is this control's starting point once the user asks for one —
            // never a value the app assumes on their behalf.
            Button("设置基准份量") { draft.baseServings = 2 }
                .accessibilityIdentifier("recipe.draft.baseServings.set")
        }
    }

    var body: some View {
        Section("基本信息") {
            LabeledContent("菜名") {
                TextField("菜名", text: $draft.title)
                    .multilineTextAlignment(.trailing)
            }


            if showsExtendedFields {
                baseServingsControl
                LabeledContent("烹饪时间") {
                    HStack(spacing: 4) {
                        TextField("烹饪时间（分钟）", value: $draft.cookingTime, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("烹饪时间（分钟）")
                        Text("分钟").foregroundStyle(KitchenTheme.textSecondary)
                    }
                }

                Picker("难度", selection: $draft.difficulty) {
                    Text("未设置").tag("")
                    Text("简单").tag("简单")
                    Text("中等").tag("中等")
                    Text("较难").tag("较难")
                }
            }

            LabeledContent("标签") {
                TextField("标签，用逗号分隔", text: $draft.tagsText, axis: .vertical)
                    .lineLimit(2...4)
                    .multilineTextAlignment(.trailing)
            }

        }

        Section("食材") {
            RecipeIngredientBucketEditor(
                placeholder: "新增食材",
                moveTitle: "移到调料与辅料",
                text: $draft.ingredientsText,
                otherText: $draft.seasoningsText
            )
        }

        Section("调料与辅料") {
            RecipeIngredientBucketEditor(
                placeholder: "新增调料或辅料",
                moveTitle: "移到食材",
                text: $draft.seasoningsText,
                otherText: $draft.ingredientsText
            )
        }

        Section("步骤") {
            TextField("每行一个步骤", text: $draft.stepsText, axis: .vertical)
                .lineLimit(6...16)
        }

        if showsExtendedFields {
            Section("小贴士") {
                TextField("每行一条小贴士", text: $draft.tipsText, axis: .vertical)
                    .lineLimit(3...8)
            }
        }
    }
}

/// One editable ingredient line with an identity that survives edits.
///
/// The editor used to derive its rows from the joined text with empty lines
/// dropped and identify them by position. Emptying a row removed it on the
/// next read, every later row moved up, and the focused field — still the
/// same position — was now editing the next line. A row keeps its id while
/// it is empty; empty lines are only dropped when the recipe is saved
/// (`EditableRecipeDraft.makeRecipe`).
struct RecipeEditableLine: Identifiable, Equatable {
    let id: UUID
    var text: String
}

enum RecipeEditableLines {
    /// Rows for `text`, reusing the ids of `existing` by position. Returns
    /// `existing` untouched when it already spells `text`, which is what keeps
    /// an edit from rebuilding the row being typed in.
    static func rows(for text: String, reusing existing: [RecipeEditableLine] = []) -> [RecipeEditableLine] {
        if joined(existing) == text { return existing }
        let lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        return lines.enumerated().map { index, line in
            RecipeEditableLine(id: existing.indices.contains(index) ? existing[index].id : UUID(), text: line)
        }
    }

    static func joined(_ rows: [RecipeEditableLine]) -> String {
        rows.map(\.text).joined(separator: "\n")
    }

    static func removing(_ id: RecipeEditableLine.ID, from rows: [RecipeEditableLine]) -> [RecipeEditableLine] {
        rows.filter { $0.id != id }
    }

    /// Moves one row to the other bucket. A line the other bucket already
    /// holds word for word is not added twice.
    static func moving(
        _ id: RecipeEditableLine.ID,
        from rows: [RecipeEditableLine],
        into otherText: String
    ) -> (rows: [RecipeEditableLine], otherText: String) {
        guard let row = rows.first(where: { $0.id == id }) else { return (rows, otherText) }
        var destination = EditableRecipeDraft.nonEmptyLines(otherText)
        let value = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, !destination.contains(value) { destination.append(value) }
        return (removing(id, from: rows), destination.joined(separator: "\n"))
    }
}

private struct RecipeIngredientBucketEditor: View {
    let placeholder: String
    let moveTitle: String
    @Binding var text: String
    @Binding var otherText: String
    @State private var newLine = ""
    @State private var rows: [RecipeEditableLine]

    init(placeholder: String, moveTitle: String, text: Binding<String>, otherText: Binding<String>) {
        self.placeholder = placeholder
        self.moveTitle = moveTitle
        _text = text
        _otherText = otherText
        _rows = State(initialValue: RecipeEditableLines.rows(
            for: EditableRecipeDraft.nonEmptyLines(text.wrappedValue).joined(separator: "\n")
        ))
    }

    var body: some View {
        ForEach($rows) { $row in
            HStack {
                TextField(placeholder, text: $row.text)
                Menu {
                    Button(moveTitle, systemImage: "arrow.right") { move(row.id) }
                    Button("删除", systemImage: "trash", role: .destructive) { remove(row.id) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("编辑\(row.text)")
            }
        }
        TextField(placeholder, text: $newLine)
            .onSubmit(add)
            // Rows are the editing truth; the draft text follows them, and a
            // change made from outside (a line moved in from the other bucket)
            // is folded back into the rows without renumbering them.
            .onChange(of: rows) { _, updated in
                let joined = RecipeEditableLines.joined(updated)
                if joined != text { text = joined }
            }
            .onChange(of: text) { _, updated in
                rows = RecipeEditableLines.rows(for: updated, reusing: rows)
            }
        Button("添加", systemImage: "plus") { add() }
            .disabled(newLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func add() {
        let clean = newLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        rows.append(RecipeEditableLine(id: UUID(), text: clean))
        newLine = ""
    }

    private func move(_ id: RecipeEditableLine.ID) {
        let moved = RecipeEditableLines.moving(id, from: rows, into: otherText)
        rows = moved.rows
        otherText = moved.otherText
    }

    private func remove(_ id: RecipeEditableLine.ID) {
        rows = RecipeEditableLines.removing(id, from: rows)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

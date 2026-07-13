import SwiftUI

struct EditableRecipeDraft: Equatable {
    var id = "user-ai-\(UUID().uuidString.lowercased())"
    var title = ""
    var servings = 2
    var cookingTime: Int?
    var difficulty = ""
    var tagsText = ""
    var ingredientsText = ""
    var seasoningsText = ""
    var stepsText = ""
    var tipsText = ""
    var source: RecipeSourceMetadata?

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

    var body: some View {
        Section("基本信息") {
            TextField("菜名", text: $draft.title)

            if showsExtendedFields {
                Stepper("人数：\(draft.servings) 人", value: $draft.servings, in: 1...12)
                TextField(
                    "烹饪时间（分钟）",
                    value: $draft.cookingTime,
                    format: .number
                )
                .keyboardType(.numberPad)
                Picker("难度", selection: $draft.difficulty) {
                    Text("未设置").tag("")
                    Text("简单").tag("简单")
                    Text("中等").tag("中等")
                    Text("较难").tag("较难")
                }
            }

            TextField("标签，用逗号分隔", text: $draft.tagsText, axis: .vertical)
                .lineLimit(2...4)
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

private struct RecipeIngredientBucketEditor: View {
    let placeholder: String
    let moveTitle: String
    @Binding var text: String
    @Binding var otherText: String
    @State private var newLine = ""

    private var lines: [String] { EditableRecipeDraft.nonEmptyLines(text) }

    var body: some View {
        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
            HStack {
                TextField(placeholder, text: lineBinding(index, fallback: line))
                Menu {
                    Button(moveTitle, systemImage: "arrow.right") { move(index) }
                    Button("删除", systemImage: "trash", role: .destructive) { remove(index) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("编辑\(line)")
            }
        }
        TextField(placeholder, text: $newLine)
            .onSubmit(add)
        Button("添加", systemImage: "plus") { add() }
            .disabled(newLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func lineBinding(_ index: Int, fallback: String) -> Binding<String> {
        Binding(
            get: { lines.indices.contains(index) ? lines[index] : fallback },
            set: { value in
                var updated = lines
                guard updated.indices.contains(index) else { return }
                updated[index] = value
                text = updated.joined(separator: "\n")
            }
        )
    }

    private func add() {
        let clean = newLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var updated = lines
        updated.append(clean)
        text = updated.joined(separator: "\n")
        newLine = ""
    }

    private func move(_ index: Int) {
        var updated = lines
        guard updated.indices.contains(index) else { return }
        let value = updated.remove(at: index)
        text = updated.joined(separator: "\n")
        var destination = EditableRecipeDraft.nonEmptyLines(otherText)
        if !destination.contains(value) { destination.append(value) }
        otherText = destination.joined(separator: "\n")
    }

    private func remove(_ index: Int) {
        var updated = lines
        guard updated.indices.contains(index) else { return }
        updated.remove(at: index)
        text = updated.joined(separator: "\n")
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

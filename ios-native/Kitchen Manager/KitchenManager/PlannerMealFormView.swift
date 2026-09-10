import SwiftUI

// MARK: - Ordinary meal form
//
// One native `Form` behind a sheet, in create or edit mode. The modes differ
// in three places and nowhere else: the title, whether the recipe row can be
// changed, and which canonical store call `save` makes.

struct PlannerMealFormView: View {
    enum Mode: Equatable {
        case create
        /// Editing an existing meal. The item supplies identity and starting
        /// values; the store stays the authority for whether it still exists
        /// when Save is pressed.
        case edit(MealPlanItem)

        var title: String {
            switch self {
            case .create: "新建一餐"
            case .edit: "编辑这一餐"
            }
        }

        var editedPlan: MealPlanItem? {
            switch self {
            case .create: nil
            case .edit(let item): item
            }
        }
    }

    @EnvironmentObject private var kitchenStore: KitchenStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRecipe: Recipe?
    @State private var date: Date
    @State private var isServingsStated = false
    @State private var servings = 2
    @State private var saveError: String?

    private let mode: Mode
    private let calendar: Calendar
    private let onSaved: (MealPlanItem) -> Void

    /// Creates a new meal, starting on `defaultDate`.
    init(
        defaultDate: Date,
        calendar: Calendar = .current,
        onSaved: @escaping (MealPlanItem) -> Void
    ) {
        self.init(mode: .create, startingDate: defaultDate, startingServings: nil,
                  calendar: calendar, onSaved: onSaved)
    }

    /// Edits an existing meal, seeded from its current values.
    init(
        editing item: MealPlanItem,
        calendar: Calendar = .current,
        onSaved: @escaping (MealPlanItem) -> Void
    ) {
        self.init(mode: .edit(item), startingDate: item.date, startingServings: item.plannedServings,
                  calendar: calendar, onSaved: onSaved)
    }

    private init(
        mode: Mode,
        startingDate: Date,
        startingServings: Int?,
        calendar: Calendar,
        onSaved: @escaping (MealPlanItem) -> Void
    ) {
        self.mode = mode
        self.calendar = calendar
        self.onSaved = onSaved
        _date = State(initialValue: startingDate)
        _isServingsStated = State(initialValue: startingServings != nil)
        _servings = State(initialValue: startingServings ?? 2)
    }

    /// A completed meal's target is the number its inventory deduction already
    /// used, so changing it afterwards would misdescribe a cook that happened
    /// while moving no inventory. The date stays editable — relocating a
    /// finished meal is a bookkeeping correction.
    private var isServingsLocked: Bool { mode.editedPlan?.isCooked == true }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    recipeRow

                    DatePicker("日期", selection: $date, displayedComponents: .date)
                        // Every other date in the product is pinned to
                        // zh_Hans_CN (PlannerDateText, HomeDatePresentation,
                        // MealPrepBoard). Without this the picker inherits the
                        // device locale and renders "Sep 10, 2026" in a form
                        // that is Chinese everywhere else.
                        .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
                        .accessibilityIdentifier("planner.mealForm.date")
                }

                Section {
                    Toggle("指定份量", isOn: $isServingsStated)
                        .disabled(isServingsLocked)
                        .accessibilityIdentifier("planner.mealForm.servingsToggle")
                    if isServingsStated {
                        Stepper(value: $servings, in: 1...12) {
                            Text("\(servings) 人份")
                        }
                        .disabled(isServingsLocked)
                        .accessibilityIdentifier("planner.mealForm.servings")
                    }
                } footer: {
                    // An unstated target is a real state, not a missing one: it
                    // is what keeps a plan from asserting a headcount nobody gave.
                    Text(isServingsLocked ? "这道菜已完成，份量不再可改" : "不指定时，这一餐不写份量。")
                        .accessibilityIdentifier(
                            isServingsLocked ? "planner.mealForm.cookedFooter" : "planner.mealForm.servingsFooter"
                        )
                }

                if let saveError {
                    Section {
                        Label(saveError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(KitchenTheme.textPrimary)
                            .accessibilityIdentifier("planner.mealForm.error")
                    }
                }
            }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .accessibilityIdentifier("planner.mealForm.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(!canSave)
                        .accessibilityIdentifier("planner.mealForm.save")
                }
            }
        }
    }

    /// Create picks a recipe; edit shows the one already chosen and does not
    /// offer to change it. Swapping the dish is a delete and a re-add, not an
    /// edit, so the row is plain text rather than a disabled control inviting a
    /// tap it would refuse.
    @ViewBuilder
    private var recipeRow: some View {
        switch mode {
        case .create:
            NavigationLink {
                RecipePickerView(title: "选择菜谱", accessory: .selection(selectedRecipe?.id)) { recipe in
                    selectedRecipe = recipe
                    saveError = nil
                }
            } label: {
                LabeledContent("菜谱") {
                    Text(selectedRecipe?.title ?? "选择菜谱")
                        .foregroundStyle(selectedRecipe == nil ? .secondary : .primary)
                }
            }
            .accessibilityIdentifier("planner.mealForm.recipe")
        case .edit(let item):
            LabeledContent("菜谱") {
                Text(item.recipeName)
            }
            .accessibilityIdentifier("planner.mealForm.recipe")
        }
    }

    private var canSave: Bool {
        switch mode {
        case .create: selectedRecipe != nil
        case .edit: true
        }
    }

    /// Saves through the canonical store API and reads its outcome directly.
    ///
    /// The sheet never inspects `planNotice`: that is user-facing copy, not a
    /// result. A failed write leaves the store untouched, so keeping the sheet
    /// open with every field intact is an honest retry rather than a second
    /// chance at a half-applied change.
    private func save() {
        switch mode {
        case .create:
            guard let selectedRecipe else { return }
            handle(kitchenStore.addPlan(
                recipe: selectedRecipe,
                on: date,
                plannedServings: statedServings,
                calendar: calendar
            ))
        case .edit(let item):
            handle(kitchenStore.updatePlan(
                id: item.id,
                on: date,
                // A locked target is passed back unchanged rather than
                // recomputed from the disabled controls.
                plannedServings: isServingsLocked ? item.plannedServings : statedServings,
                calendar: calendar
            ))
        }
    }

    private var statedServings: Int? { isServingsStated ? servings : nil }

    private func handle(_ outcome: PlanMutationOutcome<MealPlanItem>) {
        switch outcome {
        case .saved(let item):
            saveError = nil
            onSaved(item)
            dismiss()
        case .persistenceFailed:
            saveError = "这一餐没能保存，请重试。"
        case .notFound:
            // Add cannot produce this. Edit can, if the meal went away while
            // the sheet was open — a retry cannot help, so the message says so
            // instead of inviting one.
            saveError = "这一餐已经不在计划里了。"
        }
    }
}

#Preview("新建一餐") {
    PlannerMealFormView(defaultDate: Date()) { _ in }
        .environmentObject(KitchenStore())
        .environmentObject(RecipeStore())
}

#Preview("编辑这一餐") {
    PlannerMealFormView(
        editing: MealPlanItem(recipeID: "sample-mapotofu", recipeName: "麻婆豆腐", plannedServings: 2)
    ) { _ in }
        .environmentObject(KitchenStore())
        .environmentObject(RecipeStore())
}

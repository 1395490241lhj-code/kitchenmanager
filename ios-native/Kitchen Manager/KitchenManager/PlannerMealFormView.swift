import SwiftUI

// MARK: - Ordinary meal form
//
// One native `Form` behind a sheet. Create mode is the only mode that exists
// today; `mode` is here so an edit mode can be added by adding a case and a
// save branch rather than by rewriting the view.

struct PlannerMealFormView: View {
    enum Mode {
        case create

        var title: String {
            switch self {
            case .create: "新建一餐"
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

    init(
        mode: Mode = .create,
        defaultDate: Date,
        calendar: Calendar = .current,
        onSaved: @escaping (MealPlanItem) -> Void
    ) {
        self.mode = mode
        self.calendar = calendar
        self.onSaved = onSaved
        _date = State(initialValue: defaultDate)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
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
                        .accessibilityIdentifier("planner.mealForm.servingsToggle")
                    if isServingsStated {
                        Stepper(value: $servings, in: 1...12) {
                            Text("\(servings) 人份")
                        }
                        .accessibilityIdentifier("planner.mealForm.servings")
                    }
                } footer: {
                    // An unstated target is a real state, not a missing one: it
                    // is what keeps a plan from asserting a headcount nobody gave.
                    Text("不指定时，这一餐不写份量。")
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
                        .disabled(selectedRecipe == nil)
                        .accessibilityIdentifier("planner.mealForm.save")
                }
            }
        }
    }

    /// Saves through the canonical store API and reads its outcome directly.
    ///
    /// The sheet never inspects `planNotice`: that is user-facing copy, not a
    /// result. A failed write leaves the store untouched, so keeping the sheet
    /// open with every field intact is an honest retry rather than a second
    /// chance at a half-applied change.
    private func save() {
        guard let selectedRecipe else { return }
        let outcome = kitchenStore.addPlan(
            recipe: selectedRecipe,
            on: date,
            plannedServings: isServingsStated ? servings : nil,
            calendar: calendar
        )
        switch outcome {
        case .saved(let item):
            saveError = nil
            onSaved(item)
            dismiss()
        case .persistenceFailed:
            saveError = "这一餐没能保存，请重试。"
        case .notFound:
            // Add cannot produce this. Reported as a failure rather than
            // silently treated as success if it ever does.
            saveError = "这一餐没能保存，请重试。"
        }
    }
}

#Preview("新建一餐") {
    PlannerMealFormView(defaultDate: Date()) { _ in }
        .environmentObject(KitchenStore())
        .environmentObject(RecipeStore())
}

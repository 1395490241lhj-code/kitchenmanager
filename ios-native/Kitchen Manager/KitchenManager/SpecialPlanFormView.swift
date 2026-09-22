import SwiftUI

// MARK: - Recipe picker (add a dish from the library)

/// How a picker row presents its action. A Special Plan adds a dish every time
/// it is tapped, so every row offers a plus; ordinary meal creation chooses one
/// recipe, so the current choice is marked instead.
enum RecipePickerAccessory {
    case add
    case selection(String?)
}

struct RecipePickerView: View {
    @EnvironmentObject private var recipeStore: RecipeStore
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    var title: String = "添加菜品"
    var accessory: RecipePickerAccessory = .add
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
        Group {
            if recipes.isEmpty {
                // Not reachable while `recipesForDisplay` falls back to
                // `Recipe.samples`, but a blank List explaining nothing is the
                // wrong thing to render if that ever changes.
                ContentUnavailableView {
                    Label(searchText.isEmpty ? "还没有菜谱" : "没有找到菜谱", systemImage: "book.closed")
                } description: {
                    Text(searchText.isEmpty ? "先在菜谱里添加一道菜，再来安排。" : "换一个菜名或食材试试。")
                }
            } else {
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
                            accessoryView(for: recipe)
                        }
                        .contentShape(Rectangle())
                        .frame(minHeight: AppTheme.minimumHitTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("planner.recipe.pick.\(recipe.id)")
                    .plannerRow()
                }
                .plannerList()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索菜名或食材")
    }

    @ViewBuilder
    private func accessoryView(for recipe: Recipe) -> some View {
        switch accessory {
        case .add:
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(AppTheme.brand)
                .accessibilityHidden(true)
        case .selection(let selectedID):
            if recipe.id == selectedID {
                Image(systemName: "checkmark")
                    .foregroundStyle(AppTheme.brand)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - AI composer
//
// Creating or editing a Special Plan is one request in the user's own words
// plus one decision the words cannot carry safely: whether the food in the
// home refrigerator is available where this meal is cooked. Everything else —
// date, headcount, constraints, dish count, cuisine — is read from the request
// by the same AI call that writes the menu. There is no form behind this
// sheet, and no transcript: the request is the state.

enum SpecialPlanComposerMode: Identifiable {
    /// A new plan. `contextDate` is the Planner day the sheet was opened from,
    /// used only when the request itself names no date.
    case create(contextDate: Date?)
    case edit(SpecialPlan)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let plan): "edit-\(plan.id.uuidString)"
        }
    }
}

/// What a successful composition hands back: the plan as it should now be
/// stored, and the menu draft the detail screen should show for it.
struct SpecialPlanComposerResult {
    var plan: SpecialPlan
    var dishes: [SpecialPlanMenuDraftDish]
}

struct SpecialPlanComposerSheet: View {
    @EnvironmentObject private var kitchenStore: KitchenStore
    @EnvironmentObject private var recipeStore: RecipeStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let mode: SpecialPlanComposerMode
    let onComposed: (SpecialPlanComposerResult) -> Void

    @State private var requestText: String
    @State private var usesHomeInventory: Bool
    @StateObject private var draft = SpecialPlanMenuDraftStore()
    @FocusState private var isEditing: Bool
    /// Half height is enough for two controls at ordinary sizes; an
    /// accessibility size needs the whole sheet or the toggle sits under the
    /// action bar.
    @State private var detent: PresentationDetent = .medium

    static let placeholder = "例如：这周六 7 个人吃饭，1 人不吃辣，想做 5–6 道中式家常菜，简单一点。"

    init(mode: SpecialPlanComposerMode, onComposed: @escaping (SpecialPlanComposerResult) -> Void) {
        self.mode = mode
        self.onComposed = onComposed
        switch mode {
        case .create:
            _requestText = State(initialValue: "")
            // Off for a new plan: a meal cooked elsewhere must not have the
            // home refrigerator subtracted from its shopping list.
            _usesHomeInventory = State(initialValue: false)
        case .edit(let plan):
            _requestText = State(initialValue: plan.effectiveRequestText)
            _usesHomeInventory = State(initialValue: plan.usesHomeInventory)
        }
    }

    private var canGenerate: Bool {
        !requestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !draft.isBusy
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    requestField
                    inventoryToggle
                    if let message = draft.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.warningInk)
                            .accessibilityIdentifier("planner.compose.error")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(KitchenTheme.canvas)
            .safeAreaInset(edge: .bottom) { generateBar }
            .navigationTitle(mode.isEdit ? "重新描述这次做饭" : "这次想怎么做饭？")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Always enabled. A sheet's cancellation slot means "leave",
                    // and a network wait is not a reason to take leaving away —
                    // this control used to be disabled for the whole request,
                    // which turned a 50 s timeout into a 50 s trap.
                    Button("取消") {
                        draft.cancelGeneration()
                        dismiss()
                    }
                }
            }
            // Swiping the sheet down is the same exit, and cancels the same way.
            .onDisappear { draft.cancelGeneration() }
            .onAppear { isEditing = true }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .onAppear { if dynamicTypeSize.isAccessibilitySize { detent = .large } }
    }

    private var requestField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("用一句话描述这次做饭")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            TextField(Self.placeholder, text: $requestText, axis: .vertical)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3...8 : 4...10)
                .font(.body)
                .textInputAutocapitalization(.never)
                .focused($isEditing)
                .disabled(draft.isBusy)
                .padding(14)
                .background(KitchenTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityIdentifier("planner.compose.request")
        }
    }

    private var inventoryToggle: some View {
        Toggle(isOn: $usesHomeInventory) {
            VStack(alignment: .leading, spacing: 3) {
                Text("参考家中冰箱现有食材")
                    .font(.body)
                Text("在家做饭时开启")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // A Toggle truncates its label to one line by default, which drops
            // the second half of this one at accessibility sizes.
            .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(draft.isBusy)
        .padding(14)
        .background(KitchenTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("planner.compose.inventory")
    }

    private var generateBar: some View {
        VStack(spacing: 8) {
            if draft.isBusy {
                // Stop and stay. 取消生成 is distinct from the toolbar's 取消,
                // which stops and leaves: a user who wants to change one word
                // of the request should not have to reopen the sheet to do it.
                KitchenAIStatus(
                    phase: .waiting,
                    message: "正在设计菜单…",
                    messageIdentifier: "planner.compose.generating",
                    cancel: .init("取消生成", identifier: "planner.compose.cancelGeneration") {
                        draft.cancelGeneration()
                    },
                    presentation: .planner
                )
                .font(.subheadline)
                .frame(maxWidth: .infinity, minHeight: AppTheme.minimumHitTarget)
            } else {
                Button {
                    Task { await compose() }
                } label: {
                    Label("生成菜单", systemImage: KitchenAISymbol.emblem)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: AppTheme.minimumHitTarget)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.cookingActionFill)
                .foregroundStyle(AppTheme.onCookingAction)
                .disabled(!canGenerate)
                .accessibilityIdentifier("planner.compose.generate")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func compose() async {
        let text = requestText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isEditing = false
        let input: SpecialPlanMenuGenerator.Input
        let excluded: [String]
        switch mode {
        case .create(let contextDate):
            input = SpecialPlanMenuGenerator.Input(
                requestText: text,
                usesHomeInventory: usesHomeInventory,
                contextDate: contextDate
            )
            excluded = []
        case .edit:
            // No context date: the previous time is kept verbatim when the
            // new words name none (see `apply(to:)`). No exclusions: a
            // re-description may well land on the same dishes; only the
            // detail's explicit 重新设计 asks for a different menu.
            input = SpecialPlanMenuGenerator.Input(
                requestText: text,
                usesHomeInventory: usesHomeInventory,
                contextDate: nil
            )
            excluded = []
        }
        guard let interpretation = await draft.compose(
            input,
            kitchenStore: kitchenStore,
            recipeStore: recipeStore,
            excludedRecipeNames: excluded
        ) else { return }

        let plan: SpecialPlan
        switch mode {
        case .create(let contextDate):
            plan = interpretation.makePlan(
                requestText: text,
                usesHomeInventory: usesHomeInventory,
                contextDate: contextDate
            )
        case .edit(let existing):
            plan = interpretation.apply(
                to: existing,
                requestText: text,
                usesHomeInventory: usesHomeInventory
            )
        }
        onComposed(SpecialPlanComposerResult(plan: plan, dishes: draft.dishes))
        dismiss()
    }
}

extension SpecialPlanComposerMode {
    var isEdit: Bool {
        switch self {
        case .create: false
        case .edit: true
        }
    }
}

#if DEBUG
import SwiftUI

/// Isolated UI-test host. It exercises the real import save operation and
/// keeps its result visible using the view's existing onSaved callback.
/// Normal launches never enter this host or replace application persistence.
@MainActor
struct KitchenMotionImportFixture: View {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("UITEST_MOTION_IMPORT")
            || ProcessInfo.processInfo.arguments.contains("UITEST_MOTION_LABELS")
    }

    @StateObject private var store: RecipeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init() {
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let persistence = FailOneWrite(wrapping: bundle.userRecipes)
        let suite = "ui-motion-import-\(ProcessInfo.processInfo.processIdentifier)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = RecipeStore(userDefaults: defaults,
                                userRecipePersistence: persistence,
                                recipePreferencePersistence: bundle.recipePreferences)
        // Arm after initialization, so migration/loads remain ordinary reads.
        persistence.failNextWrite = ProcessInfo.processInfo.arguments.contains("UITEST_MOTION_FAIL_FIRST_SAVE")
        defaults.removePersistentDomain(forName: suite)
        _store = StateObject(wrappedValue: store)
    }

    var body: some View {
        NavigationStack {
            if ProcessInfo.processInfo.arguments.contains("UITEST_MOTION_LABELS") {
                phaseGallery
            } else {
                ImportRecipeView(onSaved: {})
            }
        }
        .environmentObject(store)
        .overlay(alignment: .topLeading) {
            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Motion environment")
                .accessibilityValue(reduceMotion && UIAccessibility.isReduceMotionEnabled ? "reduced" : "standard")
                .accessibilityIdentifier("motion.environment")
        }
    }

    private var phaseGallery: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("组件状态预览（非保存操作）").font(.caption)
                ForEach(KitchenActionPhase.allCases, id: \.self) { phase in
                    Button {} label: {
                        HStack {
                            Spacer()
                            KitchenActionLabel(phase: phase, idleTitle: "保存到菜谱库", idleSymbol: "square.and.arrow.down")
                                .tint(AppTheme.onManagementAction)
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.managementActionFill)
                    .foregroundStyle(AppTheme.onManagementAction)
                    .accessibilityIdentifier("motion.preview.\(phase)")
                }
            }
            .padding(20)
        }
        .background(KitchenTheme.canvas)
        .navigationTitle("组件状态预览")
        .navigationBarTitleDisplayMode(.inline)
    }

    private final class FailOneWrite: UserRecipePersistenceProtocol {
        let wrapped: any UserRecipePersistenceProtocol
        var failNextWrite = false
        init(wrapping wrapped: any UserRecipePersistenceProtocol) { self.wrapped = wrapped }
        func loadRecipes() throws -> [Recipe] { try wrapped.loadRecipes() }
        func storedRecordCount() throws -> Int { try wrapped.storedRecordCount() }
        func deleteAll() throws { try wrapped.deleteAll() }
        func replaceRecipes(with recipes: [Recipe]) throws {
            if failNextWrite {
                failNextWrite = false
                throw CocoaError(.fileWriteUnknown)
            }
            try wrapped.replaceRecipes(with: recipes)
        }
    }
}
#endif

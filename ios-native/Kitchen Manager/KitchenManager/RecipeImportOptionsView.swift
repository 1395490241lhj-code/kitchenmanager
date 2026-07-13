import SwiftUI

private enum RecipeImportRoute: Hashable {
    case link
    case image
    case ai
    case manual
}

struct RecipeImportOptionsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path = NavigationPath()
    var onSaved: () -> Void

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("选择导入方式") {
                    NavigationLink(value: RecipeImportRoute.link) {
                        Label("从链接导入", systemImage: "link")
                    }
                    NavigationLink(value: RecipeImportRoute.image) {
                        Label("从图片导入", systemImage: "photo.badge.plus")
                    }
                    NavigationLink(value: RecipeImportRoute.ai) {
                        Label("AI 做菜", systemImage: "sparkles")
                    }
                    NavigationLink(value: RecipeImportRoute.manual) {
                        Label("手动添加", systemImage: "square.and.pencil")
                    }
                }
            }
            .navigationTitle("导入菜谱")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .navigationDestination(for: RecipeImportRoute.self) { route in
                switch route {
                case .link:
                    ImportRecipeView(onSaved: finish)
                case .image:
                    RecipeImageImportView()
                case .ai:
                    AIGeneratorView()
                case .manual:
                    ManualRecipeView()
                }
            }
        }
    }

    private func finish() {
        dismiss()
        onSaved()
    }
}

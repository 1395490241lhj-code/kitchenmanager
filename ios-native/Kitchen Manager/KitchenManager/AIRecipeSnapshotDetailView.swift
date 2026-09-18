import SwiftUI

/// A read-only detail view for transient AI recipe proposals and snapshot fallbacks.
/// It deliberately exposes NO mutation actions (no adding to today plan, no adding to shopping,
/// no editing, no bookmarking, no deletion) so transient recipes cannot bypass the materialization gate.
struct AIRecipeSnapshotDetailView: View {
    let recipe: Recipe
    let reason: String?
    let isTransient: Bool

    init(recipe: Recipe, reason: String? = nil, isTransient: Bool = false) {
        self.recipe = recipe
        self.reason = reason
        self.isTransient = isTransient
    }

    private var cookingSteps: [String] { recipe.steps.filter { !$0.hasPrefix("小贴士：") } }
    private var tips: [String] { recipe.steps.compactMap { $0.hasPrefix("小贴士：") ? String($0.dropFirst("小贴士：".count)) : nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: KitchenTheme.sectionSpacing) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(recipe.title)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(KitchenTheme.textPrimary)
                        Spacer()
                        Text(isTransient ? "AI 推荐草稿" : "菜谱快照")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(KitchenTheme.filterSurface, in: Capsule())
                            .foregroundStyle(KitchenTheme.textSecondary)
                    }

                    if let reason = reason, !reason.isEmpty {
                        Text(reason)
                            .font(.subheadline)
                            .foregroundStyle(KitchenTheme.textSecondary)
                    }

                    HStack(spacing: 12) {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                            Text("\(recipe.cookingTime) 分钟")
                        }
                        if let difficulty = recipe.difficulty, !difficulty.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "chart.bar")
                                Text(difficulty)
                            }
                        }
                        HStack(spacing: 4) {
                            Image(systemName: "basket")
                            Text("\(recipe.ingredients.count) 种食材")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(KitchenTheme.textSecondary)
                }
                .padding(.bottom, 4)

                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                    Text(isTransient ? "此菜谱为 AI 对话草稿，在确认应用或添加到计划前仅供预览浏览。" : "原始菜谱已从菜谱库移除，当前展示为历史快照。")
                        .font(.caption)
                }
                .foregroundStyle(KitchenTheme.textSecondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(KitchenTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: KitchenTheme.compactRadius, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Text("食材")
                        .font(.headline)
                        .foregroundStyle(KitchenTheme.textPrimary)

                    if recipe.ingredients.isEmpty {
                        Text("暂未记录食材")
                            .font(.subheadline)
                            .foregroundStyle(KitchenTheme.textSecondary)
                    } else {
                        VStack(spacing: 6) {
                            ForEach(Array(recipe.ingredients.enumerated()), id: \.offset) { _, item in
                                HStack {
                                    Text(item)
                                        .font(.subheadline)
                                        .foregroundStyle(KitchenTheme.textPrimary)
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .padding(KitchenTheme.modulePadding)
                        .background(KitchenTheme.surface, in: RoundedRectangle(cornerRadius: KitchenTheme.compactRadius, style: .continuous))
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("制作步骤")
                        .font(.headline)
                        .foregroundStyle(KitchenTheme.textPrimary)

                    if cookingSteps.isEmpty {
                        Text("暂未记录步骤")
                            .font(.subheadline)
                            .foregroundStyle(KitchenTheme.textSecondary)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(cookingSteps.enumerated()), id: \.offset) { index, step in
                                HStack(alignment: .top, spacing: 10) {
                                    Text("\(index + 1)")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(KitchenTheme.cookingGreen)
                                        .frame(width: 20, height: 20)
                                        .background(KitchenTheme.cookingGreen.opacity(0.12), in: Circle())

                                    Text(step)
                                        .font(.subheadline)
                                        .foregroundStyle(KitchenTheme.textPrimary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .padding(KitchenTheme.modulePadding)
                        .background(KitchenTheme.surface, in: RoundedRectangle(cornerRadius: KitchenTheme.compactRadius, style: .continuous))
                    }
                }

                if !tips.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("小贴士")
                            .font(.headline)
                            .foregroundStyle(KitchenTheme.textPrimary)

                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(tips, id: \.self) { tip in
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "lightbulb")
                                        .font(.caption)
                                        .foregroundStyle(KitchenTheme.cookingGreen)
                                    Text(tip)
                                        .font(.subheadline)
                                        .foregroundStyle(KitchenTheme.textSecondary)
                                }
                            }
                        }
                        .padding(KitchenTheme.modulePadding)
                        .background(KitchenTheme.surface, in: RoundedRectangle(cornerRadius: KitchenTheme.compactRadius, style: .continuous))
                    }
                }
            }
            .padding(.horizontal, KitchenTheme.pageGutter)
            .padding(.vertical, 20)
        }
        .background(KitchenTheme.canvas)
        .navigationTitle(isTransient ? "推荐菜谱草稿" : "菜谱快照")
        .navigationBarTitleDisplayMode(.inline)
    }
}

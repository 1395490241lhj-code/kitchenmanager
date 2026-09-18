import SwiftUI

struct MessageRowView: View {
    let message: AIConversationMessage

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(message.plainTextSummary)
                    .font(.body)
                    .foregroundStyle(KitchenTheme.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(KitchenTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(.leading, 32)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(message.contentBlocks) { block in
                    ContentBlockView(block: block)
                }
                if message.state == .streaming {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("思考并回复中…")
                            .font(.footnote)
                            .foregroundStyle(KitchenTheme.textSecondary)
                    }
                    .padding(.top, 4)
                    .accessibilityLabel("AI 正在回复中")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 16)
        }
    }
}

struct ContentBlockView: View {
    let block: AIContentBlock

    var body: some View {
        switch block {
        case let .text(textBlock):
            AITextBlockView(block: textBlock)
        case let .recipe(recipeBlock):
            AIRecipeBlockView(block: recipeBlock)
        case let .plannerPreview(previewBlock):
            AIPlannerPreviewBlockView(block: previewBlock)
        case let .contextResult(resultBlock):
            AIContextResultBlockView(block: resultBlock)
        case let .actionStatus(statusBlock):
            AIActionStatusBlockView(block: statusBlock)
        case let .error(errorBlock):
            AIErrorBlockView(block: errorBlock)
        }
    }
}

struct AITextBlockView: View {
    let block: AITextBlock

    var body: some View {
        Text(block.text)
            .font(.body)
            .lineSpacing(5)
            .foregroundStyle(KitchenTheme.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AIRecipeBlockView: View {
    let block: AIRecipeBlock
    @EnvironmentObject private var recipeStore: RecipeStore

    var displayRecipe: Recipe {
        if !block.isTransient, let live = recipeStore.recipe(id: block.recipe.id) {
            return live
        }
        return block.recipe
    }

    var isLiveRecipe: Bool {
        !block.isTransient && recipeStore.recipe(id: block.recipe.id) != nil
    }

    @ViewBuilder
    private var destinationDetailView: some View {
        if isLiveRecipe {
            RecipeDetailView(recipe: displayRecipe)
        } else {
            AIRecipeSnapshotDetailView(recipe: displayRecipe, reason: block.reason, isTransient: block.isTransient)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let reason = block.reason, !reason.isEmpty {
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(KitchenTheme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(displayRecipe.title)
                        .font(.headline)
                        .foregroundStyle(KitchenTheme.textPrimary)
                    Spacer()
                    if block.isTransient {
                        Text("AI 推荐草稿")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(KitchenTheme.filterSurface, in: Capsule())
                            .foregroundStyle(KitchenTheme.textSecondary)
                    }
                }

                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .accessibilityHidden(true)
                        Text("\(displayRecipe.cookingTime) 分钟")
                    }
                    if let difficulty = displayRecipe.difficulty, !difficulty.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "chart.bar")
                                .accessibilityHidden(true)
                            Text(difficulty)
                        }
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "basket")
                            .accessibilityHidden(true)
                        Text("\(displayRecipe.ingredients.count) 种食材")
                    }
                }
                .font(.caption)
                .foregroundStyle(KitchenTheme.textSecondary)

                if !displayRecipe.ingredients.isEmpty {
                    Text(displayRecipe.ingredients.prefix(4).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(KitchenTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(KitchenTheme.modulePadding)
            .background(KitchenTheme.surface, in: RoundedRectangle(cornerRadius: KitchenTheme.functionalRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: KitchenTheme.functionalRadius, style: .continuous)
                    .stroke(KitchenTheme.separator.opacity(KitchenTheme.borderOpacity), lineWidth: 1)
            )

            NavigationLink(destination: destinationDetailView) {
                HStack {
                    Text("查看菜谱")
                        .font(.subheadline.weight(.medium))
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                }
                .frame(minHeight: KitchenTheme.controlHeight)
                .foregroundStyle(KitchenTheme.cookingGreen)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("kitchenAI.recipe.view.\(displayRecipe.id)")
        }
        .padding(.vertical, 4)
    }
}

struct AIPlannerPreviewBlockView: View {
    let block: AIPlannerPreviewBlock
    @EnvironmentObject private var controller: AIConversationController

    var isActionPending: Bool {
        guard let pendingID = block.pendingActionID,
              let prepared = controller.preparedAction else { return false }
        return pendingID == prepared.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "calendar.badge.clock")
                    .foregroundStyle(KitchenTheme.cookingGreen)
                Text(block.title)
                    .font(.headline)
                    .foregroundStyle(KitchenTheme.textPrimary)
            }

            VStack(spacing: 8) {
                ForEach(block.changes) { change in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("原有")
                                .font(.caption2)
                                .foregroundStyle(KitchenTheme.textSecondary)
                            Text(change.before)
                                .font(.subheadline)
                                .foregroundStyle(KitchenTheme.textSecondary)
                                .strikethrough(color: KitchenTheme.separator)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(KitchenTheme.cookingGreen)
                            .padding(.top, 14)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("修改为")
                                .font(.caption2)
                                .foregroundStyle(KitchenTheme.cookingGreen)
                            Text(change.after)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(KitchenTheme.textPrimary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(10)
                    .background(KitchenTheme.surface, in: RoundedRectangle(cornerRadius: KitchenTheme.compactRadius, style: .continuous))
                }
            }
            .padding(KitchenTheme.modulePadding)
            .background(KitchenTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: KitchenTheme.functionalRadius, style: .continuous))

            if isActionPending {
                Button {
                    controller.confirmPreparedAction()
                } label: {
                    HStack {
                        Image(systemName: "checkmark")
                        Text(block.changes.count > 1 ? "应用 \(block.changes.count) 项修改" : "应用修改")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: KitchenTheme.controlHeight)
                    .background(KitchenTheme.cookingFill, in: RoundedRectangle(cornerRadius: KitchenTheme.compactRadius, style: .continuous))
                }
                .accessibilityIdentifier("kitchenAI.planner.apply")
            }
        }
        .padding(.vertical, 4)
    }
}

struct AIContextResultBlockView: View {
    let block: AIContextResultBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(KitchenTheme.textSecondary)
                Text(block.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(KitchenTheme.textPrimary)
            }

            VStack(spacing: 4) {
                ForEach(block.rows) { row in
                    HStack {
                        Text(row.label)
                            .font(.caption)
                            .foregroundStyle(KitchenTheme.textSecondary)
                        Spacer()
                        Text(row.detail)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(KitchenTheme.textPrimary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(KitchenTheme.modulePadding)
            .background(KitchenTheme.surface, in: RoundedRectangle(cornerRadius: KitchenTheme.compactRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: KitchenTheme.compactRadius, style: .continuous)
                    .stroke(KitchenTheme.separator.opacity(KitchenTheme.borderOpacity), lineWidth: 1)
            )
        }
        .padding(.vertical, 4)
    }
}

struct AIActionStatusBlockView: View {
    let block: AIActionStatusBlock
    @EnvironmentObject private var controller: AIConversationController

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: block.isFailure ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(block.isFailure ? KitchenTheme.statusTerracotta : KitchenTheme.cookingGreen)

            Text(block.message)
                .font(.subheadline)
                .foregroundStyle(KitchenTheme.textPrimary)

            Spacer()

            if block.canUndo {
                Button("撤销") {
                    controller.undo(actionID: block.actionID)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(KitchenTheme.cookingGreen)
                .frame(minHeight: KitchenTheme.controlHeight)
                .accessibilityIdentifier("kitchenAI.action.undo")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(KitchenTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: KitchenTheme.compactRadius, style: .continuous))
        .padding(.vertical, 4)
    }
}

struct AIErrorBlockView: View {
    let block: AIErrorBlock
    @EnvironmentObject private var controller: AIConversationController

    var isRetrySafe: Bool {
        guard let retry = block.retry else { return false }
        return retry != .action && controller.canRetryGeneration
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(KitchenTheme.statusTerracotta)
                Text(block.message)
                    .font(.subheadline)
                    .foregroundStyle(KitchenTheme.textPrimary)
            }

            if isRetrySafe {
                Button {
                    controller.retryGeneration()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("重试")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(KitchenTheme.cookingGreen)
                    .frame(minHeight: KitchenTheme.controlHeight)
                }
                .accessibilityIdentifier("kitchenAI.error.retry")
            }
        }
        .padding(KitchenTheme.modulePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KitchenTheme.surface, in: RoundedRectangle(cornerRadius: KitchenTheme.compactRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: KitchenTheme.compactRadius, style: .continuous)
                .stroke(KitchenTheme.statusTerracotta.opacity(0.3), lineWidth: 1)
        )
        .padding(.vertical, 4)
    }
}
